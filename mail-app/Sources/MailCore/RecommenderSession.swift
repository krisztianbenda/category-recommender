// The state behind the window for one email: read it, show the labels, get a recommendation, file
// it or move it to the Trash. Neither waits for the model (FR-010), and nothing changes without an
// explicit action (FR-011). Mail is changed first and learning second, so a failed action teaches
// nothing.
import Combine
import Foundation

public enum BlockReason: Equatable, Sendable {
    case mailNotRunning
    case noSelection
    /// The selection is not all in one account that Mail lists, such as emails under On My Mac.
    case unsupportedSelection
    case noAccount
    case notAuthorized
    case other(String)
}

public enum Stage: Equatable, Sendable {
    case reading
    case ready
    case blocked(BlockReason)
}

public enum RecommendationState: Equatable, Sendable {
    case none
    case startingModel
    case thinking
    case ready(Suggestion)
    case unavailable(String)
}

public enum RowAction: Equatable, Sendable {
    case existing(LabelEntry)
    case acceptProposal(NewCategory)
    /// The recommended category's label has gone from the account.
    case recreate(String)
    case createTyped(String)
    /// Move the email to the Trash instead of filing it.
    case trash
}

public enum RowSection: String, Equatable, Sendable {
    case recommended
    case likely
    case all
    case create
}

public struct LabelRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let action: RowAction
    public let section: RowSection

    public var entry: LabelEntry? {
        if case .existing(let entry) = action { return entry }
        return nil
    }
}

extension LabelRow {
    public static let trash = LabelRow(id: "trash", title: "Move to Trash", action: .trash, section: .recommended)
}

public struct DeleteRequest: Equatable, Sendable {
    public let entry: LabelEntry
    public let emailCount: Int?
    public let learnedDecisions: Int
}

public struct DeleteWait: Equatable, Sendable {
    public let entry: LabelEntry
    public let start: DeleteStart
}

@MainActor
public final class RecommenderSession: ObservableObject {
    @Published public private(set) var stage: Stage = .reading
    @Published public private(set) var recommendation: RecommendationState = .none
    @Published public private(set) var subject = ""
    @Published public private(set) var sender = ""
    @Published public private(set) var messageCount = 0
    @Published public private(set) var rows: [LabelRow] = []
    @Published public private(set) var highlightedID: String?
    @Published public private(set) var busy = false
    @Published public private(set) var notice: String?
    @Published public private(set) var orphaned: [CategoryItem] = []
    @Published public private(set) var deleteRequest: DeleteRequest?
    @Published public private(set) var deleteWait: DeleteWait?
    @Published public private(set) var notConsidered = 0
    @Published public private(set) var labelCount = 0
    /// Moving to the Trash is possible: Mail identifies the emails, the account has a Trash, and
    /// they are not in it already (where Mail's Delete would erase them).
    @Published public private(set) var canTrash = false
    /// The account has folders, not Gmail labels: filing moves the email, and deleting a folder
    /// deletes the emails in it.
    @Published public private(set) var usesFolders = false
    @Published public var keepInInbox: Bool {
        didSet { onKeepInInboxChange?(keepInInbox) }
    }
    @Published public var query = "" {
        didSet { if oldValue != query { queryChanged() } }
    }

    public var onFinish: (() -> Void)?
    public var onKeepInInboxChange: ((Bool) -> Void)?

    private let mail: MailSource
    private let api: RecommenderAPI
    private let backend: BackendControl
    private var account: MailAccount?
    private var catalog = LabelCatalog(mailboxes: [])
    private var selection: MailSelection?
    private var email: Email?
    private var setId: String?
    private var categories: [CategoryItem] = []
    private var deletedKeys = Set<String>()
    private var userMovedHighlight = false
    private var filed = false
    private var recommendationTask: Task<Suggestion?, Never>?
    private let deletePollInterval: TimeInterval
    private let deleteTimeout: TimeInterval

    public init(
        mail: MailSource, api: RecommenderAPI, backend: BackendControl, keepInInbox: Bool = false,
        deletePollInterval: TimeInterval = 1, deleteTimeout: TimeInterval = 180
    ) {
        self.deletePollInterval = deletePollInterval
        self.deleteTimeout = deleteTimeout
        self.mail = mail
        self.api = api
        self.backend = backend
        self.keepInInbox = keepInInbox
    }

    /// What the account calls a mailbox.
    public var noun: String { usesFolders ? "folder" : "label" }

    // MARK: Starting

    @discardableResult
    public func start() -> Task<Void, Never> {
        Task { await read() }
    }

    private func read() async {
        stage = .reading
        do {
            let opening = try await mail.opening()
            let selection = opening.selection
            guard selection.running else {
                stage = .blocked(.mailNotRunning)
                return
            }
            guard let latest = selection.latest, let first = selection.messages.first else {
                stage = .blocked(.noSelection)
                return
            }
            let accounts = opening.accounts
            guard !accounts.isEmpty else {
                stage = .blocked(.noAccount)
                return
            }
            guard let account = accounts.first(where: { $0.name == first.account }),
                selection.messages.allSatisfy({ $0.account == first.account })
            else {
                stage = .blocked(.unsupportedSelection)
                return
            }
            self.account = account
            usesFolders = account.kind == .folders
            self.selection = selection
            canTrash =
                selection.total == selection.messages.count
                && selection.messages.allSatisfy { $0.messageId != nil }
            let email = EmailText.prepared(latest)
            self.email = email
            subject = email.subject
            sender = email.from
            messageCount = selection.total
            if let labels = opening.labels {
                show(labels)
            } else {
                try await loadLabels()
            }
            stage = .ready

            let name = LabelSync.setName(address: account.addresses.first ?? account.name, kind: account.kind)
            let catalog = self.catalog
            let task = Task<Suggestion?, Never> { [weak self] in
                await self?.recommend(email: email, setName: name, catalog: catalog)
            }
            recommendationTask = task
            _ = await task.value
        } catch MailError.notAuthorized {
            stage = .blocked(.notAuthorized)
        } catch MailError.mailNotRunning {
            stage = .blocked(.mailNotRunning)
        } catch {
            stage = .blocked(.other(Self.describe(error)))
        }
    }

    private func loadLabels() async throws {
        guard let account else { return }
        show(try await mail.labels(account: account.name))
    }

    private func show(_ labels: AccountLabels) {
        catalog = LabelCatalog(mailboxes: labels.mailboxes, system: labels.system ?? [], inbox: labels.inbox)
        labelCount = catalog.entries.count
        notConsidered = catalog.notConsidered
        rebuildRows()
    }

    /// Reads the Trash while the model starts and the labels sync. A failure only means no
    /// evidence from the Trash; moving to the Trash checks everything again when it runs.
    private func lookUpTrash(sender: String) -> Task<TrashLookup?, Never> {
        guard canTrash, let account, let selection else { return Task { nil } }
        let ids = selection.messages.compactMap(\.messageId)
        let mail = self.mail
        return Task { [weak self] in
            let lookup = try? await mail.trashSimilar(sender: sender, messageIds: ids, account: account.name)
            if let lookup, !lookup.found || lookup.inTrash {
                self?.canTrash = false
                self?.rebuildRows()
            }
            return lookup
        }
    }

    private func recommend(email: Email, setName: String, catalog: LabelCatalog) async -> Suggestion? {
        let trashLookup = lookUpTrash(sender: email.from)
        do {
            try await backend.ensureRunning { [weak self] in
                Task { @MainActor in self?.recommendation = .startingModel }
            }
            backend.noteActivity()
            recommendation = .thinking
            let mail = self.mail
            let accountName = account?.name ?? ""
            let result = try await LabelSync.run(api: api, setName: setName, catalog: catalog) { emails, mailboxes in
                try await mail.holding(emails, in: mailboxes, account: accountName)
            }
            setId = result.setId
            categories = result.categories
            orphaned = result.orphaned
            guard !email.subject.isEmpty || !email.body.isEmpty else {
                recommendation = .unavailable("This email has no text to go on. Pick a \(noun) below.")
                return nil
            }
            let lookup = await trashLookup.value
            let allowDelete = canTrash && lookup?.found == true
            let suggestion = try await suggestWithRetry(
                email: email, setId: result.setId, allowDelete: allowDelete,
                trash: allowDelete ? lookup?.messages ?? [] : [])
            backend.noteActivity()
            recommendation = .ready(suggestion)
            rebuildRows()
            return suggestion
        } catch {
            recommendation = .unavailable(Self.describe(error))
            return nil
        }
    }

    /// A first request with many labels can outlast the service's model timeout. The model keeps
    /// what it read in its prompt cache, so one retry usually answers at once.
    private func suggestWithRetry(
        email: Email, setId: String, allowDelete: Bool, trash: [TrashedEmail]
    ) async throws -> Suggestion {
        do {
            return try await api.suggest(email: email, setId: setId, allowDelete: allowDelete, trash: trash)
        } catch ServiceError.api(status: 503, code: "llm_unavailable", _) {
            return try await api.suggest(email: email, setId: setId, allowDelete: allowDelete, trash: trash)
        }
    }

    // MARK: Rows and keyboard

    private func queryChanged() {
        userMovedHighlight = false
        rebuildRows()
    }

    private func rebuildRows() {
        var out: [LabelRow] = []
        let search = LabelText.normalise(query)
        if !search.isEmpty {
            out = catalog.entries
                .filter { LabelText.normalise($0.path).contains(search) }
                .map { Self.row($0, .all) }
            if let typed = LabelText.cleanTyped(query), catalog.entry(forPath: typed) == nil,
                !catalog.entries.contains(where: { $0.mailbox.caseInsensitiveCompare(typed) == .orderedSame })
            {
                out.append(
                    LabelRow(id: "create:\(typed)", title: typed, action: .createTyped(typed), section: .create))
            }
        } else {
            var taken = Set<String>()
            if case .ready(let suggestion) = recommendation {
                // When deleting is suggested, the label it would go to if kept comes next.
                let toTrash = suggestion.action == .delete && canTrash
                if toTrash { out.append(.trash) }
                let keep: RowSection = toTrash ? .likely : .recommended
                if suggestion.isNew, let proposal = suggestion.newCategory {
                    out.append(
                        LabelRow(
                            id: "proposal", title: proposal.path, action: .acceptProposal(proposal),
                            section: keep))
                } else if let entry = catalog.entry(forPath: suggestion.category) {
                    out.append(Self.row(entry, keep))
                    taken.insert(entry.key)
                } else if !deletedKeys.contains(LabelText.pathKey(suggestion.category)) {
                    out.append(
                        LabelRow(
                            id: "recreate", title: suggestion.category, action: .recreate(suggestion.category),
                            section: keep))
                }
                for runner in suggestion.runnersUp {
                    guard let entry = catalog.entry(forPath: runner.path), taken.insert(entry.key).inserted else {
                        continue
                    }
                    out.append(Self.row(entry, .likely))
                }
            }
            out += catalog.entries.filter { !taken.contains($0.key) }.map { Self.row($0, .all) }
        }
        rows = out
        if !userMovedHighlight || !out.contains(where: { $0.id == highlightedID }) {
            highlightedID = out.first?.id
        }
    }

    private static func row(_ entry: LabelEntry, _ section: RowSection) -> LabelRow {
        LabelRow(id: "label:\(entry.key)", title: entry.path, action: .existing(entry), section: section)
    }

    public func moveHighlight(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == highlightedID } ?? 0
        highlightedID = rows[min(max(current + delta, 0), rows.count - 1)].id
        userMovedHighlight = true
    }

    public func highlight(_ row: LabelRow) {
        highlightedID = row.id
        userMovedHighlight = true
    }

    // MARK: Filing

    @discardableResult
    public func acceptHighlighted() -> Task<Void, Never>? {
        guard let row = rows.first(where: { $0.id == highlightedID }) else { return nil }
        return accept(row)
    }

    @discardableResult
    public func accept(_ row: LabelRow) -> Task<Void, Never>? {
        guard !busy, stage == .ready, !filed, deleteRequest == nil, deleteWait == nil else { return nil }
        if row.action == .trash {
            guard canTrash else { return nil }
            busy = true
            notice = nil
            return Task { await trash(row) }
        }
        busy = true
        notice = nil
        return Task { await file(row) }
    }

    /// Moves the email to the Trash, whatever was recommended.
    @discardableResult
    public func moveToTrash() -> Task<Void, Never>? {
        accept(.trash)
    }

    private func file(_ row: LabelRow) async {
        guard let account, let selection, let email else { return }
        let target: String
        let items = selection.messages.map {
            FileItem(
                id: $0.id, mailbox: $0.mailbox,
                mode: Filing.mode(inInbox: $0.isInInbox, keepInInbox: keepInInbox, kind: account.kind))
        }
        do {
            switch row.action {
            case .existing(let entry):
                target = entry.mailbox
                if !entry.existsInAccount { try await mail.createLabel(target, account: account.name) }
            case .acceptProposal(let proposal):
                target = catalog.mailbox(for: proposal)
                try await mail.createLabel(target, account: account.name)
            case .recreate(let path):
                target = path
                try await mail.createLabel(target, account: account.name)
            case .createTyped(let mailbox):
                target = mailbox
                try await mail.createLabel(target, account: account.name)
            case .trash:
                busy = false
                return
            }
            try await mail.file(items, into: target, account: account.name)
        } catch {
            notice = "Not filed: \(Self.describe(error))"
            busy = false
            return
        }
        filed = true
        backend.noteActivity()
        // A folder account has moved the email already. Gmail only has the label so far.
        let archiveNotice = account.kind == .gmail ? await archiveIfMoving(items, account: account.name) : nil
        await learn(from: row, email: email, keepOpenWith: archiveNotice)
    }

    /// Takes emails filed from the Inbox out of it. Returns a notice if that did not happen.
    private func archiveIfMoving(_ items: [FileItem], account: String) async -> String? {
        let ids = zip(items, selection?.messages ?? []).compactMap { item, ref in
            item.mode == .move ? ref.messageId : nil
        }
        guard !ids.isEmpty else { return nil }
        let result: ArchiveResult
        do {
            result = try await mail.archive(messageIds: ids, account: account)
        } catch {
            return "Labelled, but it is still in the Inbox: \(Self.describe(error))"
        }
        switch result {
        case .archived:
            return nil
        case .notAllowed, .systemEventsNotAllowed:
            let problem: MenuProblem = result == .notAllowed ? .notAllowed : .systemEventsNotAllowed
            return "Labelled, but it is still in the Inbox. \(Self.menuAdvice(problem)!) "
                + "For now, press Control-Command-A in Mail."
        case .commandUnavailable:
            return "Labelled, but it is still in the Inbox, because Mail's Archive command was not available. "
                + "Press Control-Command-A in Mail."
        case .selectionChanged:
            return "Labelled, but it is still in the Inbox, because the selection in Mail changed."
        case .stillThere:
            return "Labelled, but Mail did not archive it, so it is still in the Inbox."
        }
    }

    // MARK: Moving to the Trash

    private func trash(_ row: LabelRow) async {
        guard let account, let selection, let email else { return }
        let result: TrashResult
        do {
            result = try await mail.moveToTrash(
                messageIds: selection.messages.compactMap(\.messageId), account: account.name)
        } catch {
            notice = "Not moved to the Trash: \(Self.describe(error))"
            busy = false
            return
        }
        if let problem = Self.trashProblem(result) {
            if result == .alreadyInTrash || result == .noTrash {
                canTrash = false
                rebuildRows()
            }
            notice = problem
            busy = false
            return
        }
        filed = true
        backend.noteActivity()
        await learn(from: row, email: email, keepOpenWith: nil)
    }

    /// What to allow so that the app can use Mail's menus. Nil when permissions are not the problem.
    public nonisolated static func menuAdvice(_ problem: MenuProblem) -> String? {
        switch problem {
        case .notAllowed:
            return "macOS does not let Category Recommender use Mail's menus. Turn it on in System Settings "
                + "> Privacy & Security > Accessibility. If it is on already, that entry is from before the app "
                + "was reinstalled: remove it with \u{2212}, and add the app again."
        case .systemEventsNotAllowed:
            return "macOS does not let Category Recommender use System Events. Turn on System Events under "
                + "Category Recommender in System Settings > Privacy & Security > Automation."
        case .commandUnavailable:
            return nil
        }
    }

    nonisolated static func trashProblem(_ result: TrashResult) -> String? {
        switch result {
        case .trashed:
            return nil
        case .notAllowed, .systemEventsNotAllowed:
            let problem: MenuProblem = result == .notAllowed ? .notAllowed : .systemEventsNotAllowed
            return "Not moved to the Trash. \(menuAdvice(problem)!) For now, press Delete in Mail."
        case .commandUnavailable:
            return "Not moved to the Trash, because Mail's Delete command was not available. "
                + "Click the email in Mail's list, and try again."
        case .selectionChanged:
            return "Not moved to the Trash, because the selection in Mail changed."
        case .alreadyInTrash:
            return "It is in the Trash already. Deleting it there would erase it for good, so nothing was done."
        case .noTrash:
            return "Not moved to the Trash, because Mail shows no Trash for this account."
        case .notInTrash:
            return "Mail did not put it in the Trash. Check it in Mail, and the Trash setting under "
                + "Mail > Settings > Accounts > Mailbox Behaviors."
        }
    }

    private func finish() {
        busy = false
        onFinish?()
    }

    private func learn(from row: LabelRow, email: Email, keepOpenWith archiveNotice: String?) async {
        // A notice about the Inbox must be read, so the window stays open for it.
        let done = { [weak self] in
            guard let self else { return }
            if let archiveNotice {
                self.notice = archiveNotice
                self.busy = false
            } else {
                self.finish()
            }
        }
        if case .ready(let suggestion) = recommendation {
            do {
                try await sendFeedback(suggestion: suggestion, row: row, email: email)
                done()
            } catch {
                let did = row.action == .trash ? "Moved to the Trash." : "Filed."
                notice = "\(archiveNotice ?? did) This decision was not learned: \(Self.describe(error))"
                busy = false
            }
            return
        }
        // Still thinking, so finish in the background rather than make the owner wait.
        guard let task = recommendationTask else { return done() }
        done()
        Task { [weak self] in
            guard let suggestion = await task.value else { return }
            try? await self?.sendFeedback(suggestion: suggestion, row: row, email: email)
        }
    }

    private func sendFeedback(suggestion: Suggestion, row: LabelRow, email: Email) async throws {
        switch row.action {
        case .trash:
            try await api.feedback(suggestionId: suggestion.suggestionId, email: email, decision: .delete)
        case .existing(let entry):
            guard catalog.isConsidered(entry) else { return }
            // When deleting was suggested, "confirm" would mean delete: filing is a choice then.
            let isSuggested =
                suggestion.action == .file && !suggestion.isNew
                && LabelText.pathKey(suggestion.category) == entry.key
            try await api.feedback(
                suggestionId: suggestion.suggestionId, email: email,
                decision: isSuggested ? .confirm : .choose(entry.path))
        case .acceptProposal(let proposal):
            try await api.feedback(
                suggestionId: suggestion.suggestionId, email: email,
                decision: suggestion.action == .file ? .confirm : .acceptNew(proposal))
        case .recreate(let path):
            try await api.feedback(
                suggestionId: suggestion.suggestionId, email: email,
                decision: suggestion.action == .file ? .confirm : .choose(path))
        case .createTyped(let mailbox):
            guard let new = catalog.newCategory(forMailbox: mailbox) else { return }
            if new.parentIsKnown {
                do {
                    try await api.feedback(
                        suggestionId: suggestion.suggestionId, email: email, decision: .acceptNew(new.category))
                    return
                } catch ServiceError.api(status: 400, _, _) {
                    // Too close to an existing name for accept_new; add it explicitly below.
                }
            }
            try await addThenChoose(new.category.path, email: email)
        }
    }

    /// `accept_new` only takes parents the suggestion knew about. For anything else, add the
    /// category and teach through a fresh suggestion.
    private func addThenChoose(_ path: String, email: Email) async throws {
        guard let setId else { return }
        _ = try await api.addCategory(setId: setId, path: path)
        let fresh = try await api.suggest(email: email, setId: setId)
        try await api.feedback(suggestionId: fresh.suggestionId, email: email, decision: .choose(path))
    }

    public func close() {
        onFinish?()
    }

    // MARK: Deleting

    @discardableResult
    public func askToDelete(_ entry: LabelEntry) -> Task<Void, Never>? {
        guard !busy, let account else { return nil }
        notice = nil
        if catalog.hasChildren(entry) {
            notice = "\u{201C}\(entry.path)\u{201D} has sub-\(noun)s. Delete those first."
            return nil
        }
        return Task {
            let count: Int? = try? await mail.messageCount(entry.mailbox, account: account.name)
            let learned = categories.first { LabelText.pathKey($0.path) == entry.key }?.exampleCount ?? 0
            deleteRequest = DeleteRequest(entry: entry, emailCount: count, learnedDecisions: learned)
        }
    }

    public func cancelDelete() {
        deleteRequest = nil
    }

    /// Hands over to Mail, whose own confirmation has the final say, and waits for the label to go.
    @discardableResult
    public func confirmDelete() -> Task<Void, Never>? {
        guard let request = deleteRequest, let account, !busy else { return nil }
        busy = true
        let entry = request.entry
        return Task {
            defer { busy = false }
            guard entry.existsInAccount else {
                // Only implied by nested labels, so there is nothing to delete in the account.
                deleteRequest = nil
                await forget(entry)
                return
            }
            let start: DeleteStart
            do {
                start = try await mail.beginDeleteLabel(entry.mailbox, account: account.name)
            } catch {
                deleteRequest = nil
                notice = "Not deleted: \(Self.describe(error))"
                return
            }
            deleteRequest = nil
            deleteWait = DeleteWait(entry: entry, start: start)
            busy = false
            await waitForDeletion(of: entry, account: account.name)
        }
    }

    public func cancelDeleteWait() {
        deleteWait = nil
    }

    private func waitForDeletion(of entry: LabelEntry, account: String) async {
        let deadline = Date().addingTimeInterval(deleteTimeout)
        while deleteWait?.entry == entry, Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(deletePollInterval * 1_000_000_000))
            if let exists = try? await mail.labelExists(entry.mailbox, account: account), !exists {
                guard deleteWait?.entry == entry else { return }
                deleteWait = nil
                await forget(entry)
                return
            }
        }
        if deleteWait?.entry == entry {
            deleteWait = nil
            notice = "\u{201C}\(entry.path)\u{201D} is still there. It was not deleted."
        }
    }

    private func forget(_ entry: LabelEntry) async {
        deletedKeys.insert(entry.key)
        if let category = categories.first(where: { LabelText.pathKey($0.path) == entry.key }) {
            try? await api.deleteCategory(id: category.id, cascade: false)
            categories.removeAll { $0.id == category.id }
        }
        do {
            try await loadLabels()
        } catch {
            notice = "Deleted. The \(noun) list could not be refreshed."
        }
    }

    // MARK: Labels removed from the account

    @discardableResult
    public func forgetOrphaned() -> Task<Void, Never>? {
        guard !orphaned.isEmpty, !busy else { return nil }
        busy = true
        let items = orphaned
        return Task {
            defer { busy = false }
            do {
                for item in items.sorted(by: { ($0.parentId != nil) && ($1.parentId == nil) }) {
                    try await api.deleteCategory(id: item.id, cascade: false)
                }
                orphaned = []
            } catch {
                notice = "Could not forget those \(noun)s: \(Self.describe(error))"
            }
        }
    }

    // MARK: Messages

    public nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case ServiceError.unreachable:
            return "The local recommendation service is not responding."
        case ServiceError.api(_, let code, let message):
            return code == "llm_unavailable" ? "The local model is unavailable. Try again shortly." : message
        case ServiceError.notLoopback:
            return "Refused: the service address must be on this computer."
        case ServiceError.badResponse:
            return "The local service gave an unexpected answer."
        case MailError.notAuthorized:
            return "Mail access is not allowed. Turn it on in System Settings > Privacy & Security > Automation."
        case MailError.mailNotRunning:
            return "Mail is not open."
        case MailError.timedOut:
            return "Mail did not answer in time."
        case MailError.notFound(let message):
            return message
        case MailError.script(_, let message):
            return message
        default:
            return (error as? LocalizedError)?.errorDescription ?? String(describing: type(of: error))
        }
    }
}
