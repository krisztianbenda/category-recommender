// The state behind the batch window (specs/004-batch-recommendations): several selected emails,
// each with its own recommendation. Emails are read ahead in the background, recommendations are
// made one at a time, and nothing changes in Mail without an owner action that covers the email
// (FR-009). Mail is changed first and learning second, so a failed action teaches nothing (FR-023).
import Combine
import Foundation

public enum BatchRowState: Equatable, Sendable {
    /// Not read or not recommended yet. It can still be decided (FR-015).
    case pending
    /// Has a recommendation, or a reason there is none.
    case ready
    /// Queued or running in Mail.
    case applying
    /// Mail did it; waiting for the recommendation, to learn from it.
    case applied
    case done
    /// Mail could not apply it. Nothing was learned, and it can be decided again.
    case problem
}

public struct BatchRow: Identifiable, Equatable, Sendable {
    public let ref: MailMessageRef
    public internal(set) var placement: Placement?
    public internal(set) var email: Email?
    public internal(set) var recommendation: RecommendationState = .none
    /// What accepting the recommendation does: a label, a new label, or the Trash.
    public internal(set) var recommended: LabelRow?
    /// The email is in the Trash already, so Move to Trash is neither recommended nor offered.
    public internal(set) var inTrash = false
    public internal(set) var marked = false
    public internal(set) var skipped = false
    public internal(set) var state: BatchRowState = .pending
    /// What was done, once it was: "Filed in Family", "Moved to the Trash".
    public internal(set) var outcome: String?
    public internal(set) var notice: String?
    var read = false
    var decided = false

    public var id: String { ref.messageId.map { "m:\($0)" } ?? "r:\(ref.account)/\(ref.mailbox)/\(ref.id)" }
    public var subject: String { email?.subject ?? ref.subject ?? "" }
    public var sender: String { email?.from ?? ref.from ?? "" }
    public var suggestion: Suggestion? {
        if case .ready(let suggestion) = recommendation { return suggestion }
        return nil
    }
    /// Can be acted on: not running in Mail and not done.
    public var isOpen: Bool { state == .pending || state == .ready || state == .problem }
}

/// Shown before an action that covers more than one email and moves any of them to the Trash.
public struct BatchConfirmation: Equatable, Sendable {
    public let fileCount: Int
    public let trashCount: Int
    let items: [BatchItem]
}

struct BatchItem: Equatable, Sendable {
    let rowID: String
    let action: RowAction
}

/// Runs model requests one at a time, in the order they ask (constitution V).
@MainActor
final class ModelGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

@MainActor
public final class BatchSession: ObservableObject {
    public static let chunk = 5

    @Published public private(set) var stage: Stage = .reading
    @Published public private(set) var rows: [BatchRow] = []
    @Published public private(set) var highlightedID: String?
    /// Selected in Mail but not in the batch (FR-003).
    @Published public private(set) var leftOut = 0
    /// A notice for the whole window, such as a permission to allow.
    @Published public private(set) var notice: String?
    @Published public private(set) var confirmation: BatchConfirmation?
    @Published public private(set) var modelStarting = false
    @Published public private(set) var usesFolders = false
    @Published public private(set) var notConsidered = 0
    @Published public var keepInInbox: Bool {
        didSet { onKeepInInboxChange?(keepInInbox) }
    }

    // Choose a label, for the scope.
    @Published public private(set) var pickerScope: [String]?
    @Published public private(set) var pickerRows: [LabelRow] = []
    @Published public private(set) var pickerHighlightedID: String?
    @Published public var pickerQuery = "" {
        didSet { if oldValue != pickerQuery { rebuildPicker(resetHighlight: true) } }
    }
    /// New label…, open inside Choose a label.
    @Published public var newLabel: NewLabelForm?

    public var onFinish: (() -> Void)?
    public var onKeepInInboxChange: ((Bool) -> Void)?
    /// Metadata only: event names and counts (constitution, logs).
    public var onEvent: ((String, [String: Int]) -> Void)?

    private let mail: MailSource
    private let api: RecommenderAPI
    private let backend: BackendControl
    private let gate = ModelGate()
    private var account: MailAccount?
    private var viewed: [String] = []
    private var labels = AccountLabels(mailboxes: [])
    private var catalog = LabelCatalog(mailboxes: [])
    private var setId: String?
    private var trash: Task<TrashLookups?, Never>?
    private var trashFound = false
    private var reads: [Task<Void, Never>] = []
    private var worker: Task<Void, Never>?
    private var lastAction: Task<Void, Never>?
    private var closed = false
    /// Labels created in Mail during this batch, by path key (FR-019).
    private var createdKeys = Set<String>()
    /// New categories already taught to the service during this batch, by path key (research R5).
    private var taughtKeys = Set<String>()
    /// Rows applied before their recommendation, with what to learn once it arrives.
    private var waitingToLearn: [String: (action: RowAction, alreadyAdded: Bool)] = [:]
    private var learning: [Task<Void, Never>] = []

    public init(mail: MailSource, api: RecommenderAPI, backend: BackendControl, keepInInbox: Bool = false) {
        self.mail = mail
        self.api = api
        self.backend = backend
        self.keepInInbox = keepInInbox
    }

    /// What the account calls a mailbox.
    public var noun: String { usesFolders ? "folder" : "label" }
    public var readyCount: Int { rows.filter { $0.state != .pending }.count }
    public var approvable: [BatchRow] { rows.filter(isApprovable) }
    public var markedCount: Int { rows.filter { $0.marked && $0.isOpen }.count }
    public var accountHasTrash: Bool { trashFound }

    // MARK: Starting

    @discardableResult
    public func start(with opening: MailOpening) -> Task<Void, Never> {
        Task { await begin(opening) }
    }

    private func begin(_ opening: MailOpening) async {
        let selection = opening.selection
        guard selection.running else { return block(.mailNotRunning) }
        guard let first = selection.messages.first else { return block(.noSelection) }
        guard !opening.accounts.isEmpty else { return block(.noAccount) }
        guard let account = opening.accounts.first(where: { $0.name == first.account }),
            selection.messages.allSatisfy({ $0.account == first.account })
        else { return block(.unsupportedSelection) }
        self.account = account
        usesFolders = account.kind == .folders
        viewed = opening.viewed ?? []
        rows = selection.messages.map { BatchRow(ref: $0) }
        highlightedID = rows.first?.id
        leftOut = max(0, selection.total - rows.count)
        do {
            if let given = opening.labels { labels = given } else { labels = try await mail.labels(account: account.name) }
        } catch {
            return block(.other(MailAdvice.describe(error)))
        }
        catalog = LabelCatalog(mailboxes: labels.mailboxes, system: labels.system ?? [], inbox: labels.inbox)
        notConsidered = catalog.notConsidered
        stage = .ready
        onEvent?("batch_opened", ["rows": rows.count, "leftOut": leftOut])

        startReading()
        trash = lookUpTrash()
        let worker = Task { [weak self] in
            guard let self else { return }
            await self.recommendAll()
        }
        self.worker = worker
        await worker.value
    }

    private func block(_ reason: BlockReason) {
        stage = .blocked(reason)
    }

    // MARK: Reading ahead

    /// Reads the emails five at a time, in row order, independent of the model (research R2).
    private func startReading() {
        guard let account else { return }
        let ids = rows.map(\.id)
        var previous: Task<Void, Never>?
        for start in stride(from: 0, to: ids.count, by: Self.chunk) {
            let chunk = Array(ids[start..<min(start + Self.chunk, ids.count)])
            let before = previous
            let task = Task { [weak self] in
                await before?.value
                await self?.read(chunk, account: account.name)
            }
            reads.append(task)
            previous = task
        }
    }

    private func read(_ ids: [String], account: String) async {
        let refs = ids.compactMap { id in rows.first { $0.id == id }?.ref }
        do {
            let items = try await mail.read(refs, viewed: viewed, account: account)
            for (id, ref) in zip(ids, refs) {
                let item = items.first { $0.messageId == ref.messageId && ref.messageId != nil }
                update(id) { row in
                    row.read = true
                    if let item, item.found, let placement = item.placement, let email = item.email {
                        row.placement = placement
                        row.email = EmailText.prepared(email)
                    } else {
                        row.notice = "This email can no longer be found in Mail."
                        if row.recommendation == .none { row.recommendation = .unavailable(row.notice!) }
                        if !row.decided { row.state = .problem }
                    }
                }
            }
        } catch {
            let text = MailAdvice.describe(error)
            for id in ids {
                update(id) { row in
                    row.read = true
                    row.notice = "Could not read it from Mail: \(text)"
                    if row.recommendation == .none { row.recommendation = .unavailable(text) }
                    if !row.decided { row.state = .problem }
                }
            }
        }
    }

    /// Waits until the row has been read, or found missing.
    private func ensureRead(_ id: String) async {
        guard let index = rows.firstIndex(where: { $0.id == id }), !rows[index].read else { return }
        let chunk = index / Self.chunk
        if chunk < reads.count { await reads[chunk].value }
    }

    // MARK: The Trash

    /// Reads the Trash once, for every sender of the batch (research R6). A failure only means no
    /// evidence and no Move to Trash.
    private func lookUpTrash() -> Task<TrashLookups?, Never> {
        guard let account else { return Task { nil } }
        let senders = Array(Set(rows.compactMap { $0.ref.from })).sorted()
        let ids = rows.compactMap(\.ref.messageId)
        let mail = self.mail
        return Task { [weak self] in
            let lookup = try? await mail.trashSimilar(senders: senders, messageIds: ids, account: account.name)
            guard let self else { return lookup }
            self.trashFound = lookup?.found == true
            let inTrash = Set(lookup?.inTrashIds ?? [])
            for row in self.rows where row.ref.messageId.map(inTrash.contains) == true {
                self.update(row.id) { $0.inTrash = true }
            }
            for row in self.rows where row.suggestion != nil { self.plan(row.id) }
            return lookup
        }
    }

    /// Move to Trash is possible for this row: the account has a Trash, Mail identifies the email,
    /// and it is not in the Trash already.
    public func canTrash(_ row: BatchRow) -> Bool {
        trashFound && !row.inTrash && row.ref.messageId != nil
    }

    // MARK: Recommendations

    private func recommendAll() async {
        guard let account else { return }
        do {
            try await backend.ensureRunning { [weak self] in
                Task { @MainActor in self?.modelStarting = true }
            }
            modelStarting = false
            backend.noteActivity()
            let name = LabelSync.setName(address: account.addresses.first ?? account.name, kind: account.kind)
            setId = try await LabelSync.run(api: api, setName: name, catalog: catalog).setId
        } catch {
            modelStarting = false
            let text = MailAdvice.describe(error)
            for row in rows where row.recommendation == .none {
                update(row.id) {
                    $0.recommendation = .unavailable(text)
                    if $0.state == .pending { $0.state = .ready }
                }
                giveUpLearning(row.id)
            }
            return
        }
        while let id = nextToRecommend() {
            await recommend(id)
        }
    }

    /// Undecided rows first, in row order; rows the owner already decided last, since their
    /// recommendation is only needed for learning (research R4). After closing, only those.
    private func nextToRecommend() -> String? {
        let waiting = rows.filter { $0.recommendation == .none }
        if !closed, let row = waiting.first(where: { !$0.decided }) { return row.id }
        return waiting.first(where: { $0.decided && waitingToLearn[$0.id] != nil })?.id
            ?? (closed ? nil : waiting.first?.id)
    }

    private func recommend(_ id: String) async {
        update(id) { $0.recommendation = .thinking }
        await ensureRead(id)
        guard let row = rows.first(where: { $0.id == id }), let setId else { return }
        guard let email = row.email else {
            if case .thinking = row.recommendation {
                update(id) { $0.recommendation = .unavailable(row.notice ?? "Could not read it from Mail.") }
            }
            return giveUpLearning(id)
        }
        guard !email.subject.isEmpty || !email.body.isEmpty else {
            update(id) {
                $0.recommendation = .unavailable("This email has no text to go on. Choose a \(self.noun) for it.")
                if $0.state == .pending { $0.state = .ready }
            }
            return giveUpLearning(id)
        }
        let lookup = await trash?.value
        let allowDelete = canTrash(row)
        let evidence = allowDelete ? lookup?.matches(for: email.from) ?? [] : []
        do {
            let suggestion = try await gate.run {
                try await self.api.suggestWithRetry(email: email, setId: setId, allowDelete: allowDelete, trash: evidence)
            }
            backend.noteActivity()
            update(id) {
                $0.recommendation = .ready(suggestion)
                if $0.state == .pending { $0.state = .ready }
            }
            plan(id)
            if let waiting = waitingToLearn.removeValue(forKey: id) {
                learn(id, action: waiting.action, alreadyAdded: waiting.alreadyAdded)
            }
        } catch {
            update(id) {
                $0.recommendation = .unavailable(MailAdvice.describe(error))
                if $0.state == .pending { $0.state = .ready }
            }
            giveUpLearning(id)
        }
    }


    /// What accepting the row's recommendation does.
    private func plan(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }), let suggestion = row.suggestion else { return }
        let recommended: LabelRow?
        if suggestion.action == .delete && canTrash(row) {
            recommended = .trash
        } else {
            recommended = LabelPicker.recommendedRow(catalog: catalog, suggestion: suggestion)
        }
        update(id) { $0.recommended = recommended }
    }

    // MARK: Highlight and marks

    public func moveHighlight(by delta: Int) {
        highlightedID = Highlight.moved(rows.map(\.id), from: highlightedID, by: delta) ?? highlightedID
    }

    public func highlight(_ id: String) {
        highlightedID = id
    }

    public func toggleMark(_ id: String? = nil) {
        guard let id = id ?? highlightedID else { return }
        update(id) { if $0.isOpen { $0.marked.toggle() } }
    }

    /// Marks every open row; when all are marked already, unmarks them.
    public func toggleMarkAll() {
        let open = rows.filter(\.isOpen)
        let mark = !open.allSatisfy(\.marked)
        for row in open { update(row.id) { $0.marked = mark } }
    }

    /// The marked rows if any, else the highlighted row (contracts/batch-window.md, Scope).
    public var scope: [String] {
        let marked = rows.filter { $0.marked && $0.isOpen }.map(\.id)
        if !marked.isEmpty { return marked }
        guard let id = highlightedID, let row = rows.first(where: { $0.id == id }), row.isOpen else { return [] }
        return [id]
    }

    /// Skips or unskips the scope: approve all leaves skipped rows out (FR-013).
    public func toggleSkip() {
        let ids = scope
        let skip = !ids.allSatisfy { id in rows.first { $0.id == id }?.skipped == true }
        for id in ids { update(id) { $0.skipped = skip } }
    }

    // MARK: Actions

    private func isApprovable(_ row: BatchRow) -> Bool {
        row.state == .ready && !row.skipped && row.recommended != nil
    }

    /// Applies every ready, unskipped recommendation (FR-010). Waiting rows are not affected.
    @discardableResult
    public func approveAll() -> Task<Void, Never>? {
        submit(approvable.compactMap { row in row.recommended.map { BatchItem(rowID: row.id, action: $0.action) } })
    }

    /// Accepts the recommendations of the scope. Rows without one are left as they are.
    @discardableResult
    public func acceptScope() -> Task<Void, Never>? {
        let rows = scope.compactMap { id in self.rows.first { $0.id == id } }
        let items = rows.compactMap { row in
            row.recommended.map { BatchItem(rowID: row.id, action: $0.action) }
        }
        let without = rows.count - items.count
        notice = without > 0 ? "Left as they are: \(without) without a recommendation." : nil
        return submit(items)
    }

    /// Files the scope under a label from Choose a label, or moves it to the Trash.
    @discardableResult
    public func applyToScope(_ action: RowAction, scope ids: [String]? = nil) -> Task<Void, Never>? {
        let ids = ids ?? scope
        if action == .trash {
            let open = ids.compactMap { id in rows.first { $0.id == id } }
            let refused = open.filter { !canTrash($0) }
            if !refused.isEmpty {
                notice = refused.contains(where: \.inTrash)
                    ? MailAdvice.trash(.alreadyInTrash)
                    : MailAdvice.trash(.noTrash)
            }
            return submit(open.filter(canTrash).map { BatchItem(rowID: $0.id, action: .trash) })
        }
        return submit(ids.map { BatchItem(rowID: $0, action: action) })
    }

    @discardableResult
    public func moveScopeToTrash() -> Task<Void, Never>? {
        applyToScope(.trash)
    }

    @discardableResult
    public func confirm() -> Task<Void, Never>? {
        guard let confirmation else { return nil }
        self.confirmation = nil
        return run(confirmation.items)
    }

    public func cancelConfirmation() {
        confirmation = nil
    }

    /// Asks first when more than one email is covered and any goes to the Trash (FR-014).
    private func submit(_ items: [BatchItem]) -> Task<Void, Never>? {
        let open = items.filter { item in rows.first { $0.id == item.rowID }?.isOpen == true }
        guard !open.isEmpty, confirmation == nil else { return nil }
        let trashCount = open.filter { $0.action == .trash }.count
        if open.count > 1 && trashCount > 0 {
            confirmation = BatchConfirmation(fileCount: open.count - trashCount, trashCount: trashCount, items: open)
            return nil
        }
        return run(open)
    }

    /// Actions run one at a time, in the order the owner gave them.
    private func run(_ items: [BatchItem]) -> Task<Void, Never> {
        for item in items {
            update(item.rowID) {
                $0.state = .applying
                $0.decided = true
                $0.marked = false
                $0.notice = nil
            }
        }
        let before = lastAction
        let task = Task { [weak self] in
            await before?.value
            await self?.apply(items)
        }
        lastAction = task
        return task
    }

    private func apply(_ items: [BatchItem]) async {
        guard let account else { return }
        for item in items { await ensureRead(item.rowID) }
        var live: [BatchItem] = []
        for item in items {
            guard let row = rows.first(where: { $0.id == item.rowID }) else { continue }
            if row.placement == nil {
                fail(item.rowID, row.notice ?? "This email can no longer be found in Mail.")
            } else {
                live.append(item)
            }
        }
        var applied: [(item: BatchItem, alreadyAdded: Bool)] = []

        // File, one call per target label, creating each new label once (FR-019).
        let filing = live.filter { $0.action != .trash }
        var targets: [(mailbox: String, create: Bool, items: [BatchItem])] = []
        for item in filing {
            guard let (mailbox, create) = target(for: item.action) else {
                fail(item.rowID, "There is nothing to file it under.")
                continue
            }
            if let index = targets.firstIndex(where: { $0.mailbox == mailbox }) {
                targets[index].items.append(item)
            } else {
                targets.append((mailbox, create, [item]))
            }
        }
        var archive: [String] = []
        for target in targets {
            let key = LabelText.pathKey(target.mailbox)
            do {
                try await file(target.items, into: target.mailbox, create: target.create, account: account.name)
            } catch {
                for item in target.items { fail(item.rowID, "Not filed: \(MailAdvice.describe(error))") }
                continue
            }
            for item in target.items {
                // The first email to name a new category teaches it; the others learn it as it
                // exists by then (research R5).
                applied.append((item, taughtKeys.contains(key)))
                if Self.teachesNew(item.action) { taughtKeys.insert(key) }
                update(item.rowID) { $0.outcome = "Filed in \(LabelText.segments(target.mailbox).joined(separator: "/"))" }
                if account.kind == .gmail, mode(for: item.rowID) == .move { archive.append(item.rowID) }
            }
        }
        if !archive.isEmpty { await takeOutOfInbox(archive, account: account.name) }

        // Move to the Trash, in one call.
        let trashing = live.filter { $0.action == .trash }
        if !trashing.isEmpty {
            for item in await moveToTrash(trashing, account: account.name) { applied.append((item, false)) }
        }

        backend.noteActivity()
        for (item, alreadyAdded) in applied {
            update(item.rowID) { $0.state = .applied }
            learn(item.rowID, action: item.action, alreadyAdded: alreadyAdded)
        }
        onEvent?(
            "batch_action",
            ["rows": items.count, "applied": applied.count, "failed": items.count - applied.count])
        finishIfDone()
    }

    private static func teachesNew(_ action: RowAction) -> Bool {
        switch action {
        case .acceptProposal, .createTyped: return true
        default: return false
        }
    }

    private func target(for action: RowAction) -> (mailbox: String, create: Bool)? {
        switch action {
        case .existing(let entry): return (entry.mailbox, !entry.existsInAccount)
        case .acceptProposal(let proposal): return (catalog.mailbox(for: proposal), true)
        case .recreate(let path): return (path, true)
        case .createTyped(let mailbox): return (mailbox, true)
        case .trash: return nil
        }
    }

    private func mode(for id: String) -> FilingMode {
        let inInbox = rows.first { $0.id == id }?.placement?.inInbox ?? false
        return Filing.mode(inInbox: inInbox, keepInInbox: keepInInbox, kind: account?.kind ?? .gmail)
    }

    /// Creates the label once per batch, then files. A label that has gone from the account since
    /// the batch opened is created again, as a recommended label is in the single window.
    private func file(_ items: [BatchItem], into mailbox: String, create: Bool, account: String) async throws {
        let key = LabelText.pathKey(mailbox)
        if create, !createdKeys.contains(key) {
            try await mail.createLabel(mailbox, account: account)
            createdKeys.insert(key)
            addToCatalog(mailbox)
        }
        let fileItems = items.compactMap { item -> FileItem? in
            guard let placement = rows.first(where: { $0.id == item.rowID })?.placement else { return nil }
            return FileItem(id: placement.id, mailbox: placement.mailbox, mode: mode(for: item.rowID))
        }
        do {
            try await mail.file(fileItems, into: mailbox, account: account)
        } catch MailError.notFound(let message) {
            guard (try? await mail.labelExists(mailbox, account: account)) == false else {
                throw MailError.notFound(message)
            }
            try await mail.createLabel(mailbox, account: account)
            createdKeys.insert(key)
            try await mail.file(fileItems, into: mailbox, account: account)
        }
    }

    private func addToCatalog(_ mailbox: String) {
        guard !labels.mailboxes.contains(mailbox) else { return }
        labels = AccountLabels(mailboxes: labels.mailboxes + [mailbox], system: labels.system, inbox: labels.inbox)
        catalog = LabelCatalog(mailboxes: labels.mailboxes, system: labels.system ?? [], inbox: labels.inbox)
    }

    private func selected(_ id: String) -> SelectedEmail? {
        guard let row = rows.first(where: { $0.id == id }), let messageId = row.ref.messageId else { return nil }
        return SelectedEmail(
            messageId: messageId, view: MessageLocation(id: row.ref.id, mailbox: row.ref.mailbox),
            placement: row.placement.map { MessageLocation(id: $0.id, mailbox: $0.mailbox) })
    }

    /// Takes emails filed from the Inbox out of it, in one Archive. They stay filed if it fails.
    private func takeOutOfInbox(_ ids: [String], account: String) async {
        let emails = ids.compactMap(selected)
        for id in ids where selected(id) == nil {
            update(id) { $0.notice = MailAdvice.batchArchive(.selectionChanged) }
        }
        guard !emails.isEmpty else { return }
        let outcome: ArchiveOutcome
        do {
            outcome = try await mail.archive(emails, viewed: viewed, account: account)
        } catch {
            for id in ids { update(id) { $0.notice = "Labelled, but still in the Inbox: \(MailAdvice.describe(error))" } }
            return
        }
        guard let advice = MailAdvice.batchArchive(outcome.result, selectErrors: outcome.selectErrors) else { return }
        let left = Set(outcome.left ?? emails.map(\.messageId))
        for id in ids where rows.first(where: { $0.id == id })?.ref.messageId.map(left.contains) == true {
            update(id) { $0.notice = advice }
        }
        if outcome.result == .notAllowed || outcome.result == .systemEventsNotAllowed { notice = advice }
    }

    /// Moves emails to the Trash in one Delete. Returns the items that arrived there.
    private func moveToTrash(_ items: [BatchItem], account: String) async -> [BatchItem] {
        var emails: [SelectedEmail] = []
        var ready: [BatchItem] = []
        for item in items {
            guard let row = rows.first(where: { $0.id == item.rowID }), canTrash(row), let email = selected(item.rowID)
            else {
                let inTrash = rows.first(where: { $0.id == item.rowID })?.inTrash == true
                fail(item.rowID, MailAdvice.trash(inTrash ? .alreadyInTrash : .noTrash)!)
                continue
            }
            emails.append(email)
            ready.append(item)
        }
        guard !emails.isEmpty else { return [] }
        let outcome: TrashOutcome
        do {
            outcome = try await mail.moveToTrash(emails, viewed: viewed, account: account)
        } catch {
            for item in ready { fail(item.rowID, "Not moved to the Trash: \(MailAdvice.describe(error))") }
            return []
        }
        switch outcome.result {
        case .trashed:
            for item in ready { update(item.rowID) { $0.outcome = "Moved to the Trash" } }
            return ready
        case .notInTrash:
            let left = Set(outcome.left ?? emails.map(\.messageId))
            var arrived: [BatchItem] = []
            for item in ready {
                if rows.first(where: { $0.id == item.rowID })?.ref.messageId.map(left.contains) == true {
                    fail(item.rowID, MailAdvice.trash(.notInTrash)!)
                } else {
                    update(item.rowID) { $0.outcome = "Moved to the Trash" }
                    arrived.append(item)
                }
            }
            return arrived
        default:
            let advice =
                MailAdvice.batchTrash(outcome.result, selectErrors: outcome.selectErrors) ?? "Not moved to the Trash."
            for item in ready { fail(item.rowID, advice) }
            if outcome.result == .alreadyInTrash || outcome.result == .noTrash {
                for item in ready { update(item.rowID) { $0.inTrash = outcome.result == .alreadyInTrash } }
                if outcome.result == .noTrash { trashFound = false }
            }
            if outcome.result == .notAllowed || outcome.result == .systemEventsNotAllowed { notice = advice }
            return []
        }
    }

    private func fail(_ id: String, _ reason: String) {
        update(id) {
            $0.state = .problem
            $0.notice = reason
            $0.outcome = nil
        }
    }

    // MARK: Learning

    /// Learns from the row now if its recommendation exists, else when it arrives (FR-022).
    private func learn(_ id: String, action: RowAction, alreadyAdded: Bool) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        switch row.recommendation {
        case .ready(let suggestion):
            guard let email = row.email else { return done(id) }
            let teacher = Learning(api: api, catalog: catalog, setId: setId) { [weak self] email, setId in
                guard let self else { throw CancellationError() }
                return try await self.gate.run { try await self.api.suggest(email: email, setId: setId) }
            }
            let task = Task { [weak self] in
                do {
                    try await teacher.send(suggestion: suggestion, action: action, email: email, alreadyAdded: alreadyAdded)
                    self?.done(id)
                } catch {
                    self?.done(id, notice: "Not learned: \(MailAdvice.describe(error))")
                }
            }
            learning.append(task)
        case .unavailable:
            done(id)
        case .none, .thinking, .startingModel:
            waitingToLearn[id] = (action, alreadyAdded)
        }
    }

    /// A decided row whose recommendation will not come: done, with nothing learned.
    private func giveUpLearning(_ id: String) {
        guard waitingToLearn.removeValue(forKey: id) != nil else { return }
        done(id)
    }

    private func done(_ id: String, notice: String? = nil) {
        update(id) {
            $0.state = .done
            if let notice { $0.notice = [$0.notice, notice].compactMap { $0 }.joined(separator: " ") }
        }
        finishIfDone()
    }

    /// Waits for everything learned in the background. For tests.
    public func settle() async {
        while true {
            await lastAction?.value
            let pending = learning
            learning = []
            for task in pending { await task.value }
            if learning.isEmpty { break }
        }
    }

    /// Waits until every recommendation has been made. For tests and the demo.
    public func recommendationsFinished() async {
        await worker?.value
    }

    /// Closes by itself when every row is done and there is nothing to read (Story 1, scenario 7).
    private func finishIfDone() {
        guard !closed, !rows.isEmpty, notice == nil,
            rows.allSatisfy({ $0.state == .done && $0.notice == nil })
        else { return }
        finish()
    }

    private func finish() {
        onFinish?()
    }

    /// Closing leaves undecided emails as they are and stops their recommendations. Rows applied
    /// and waiting for theirs keep it coming, to learn from it (FR-016).
    public func close() {
        guard !closed else { return finish() }
        closed = true
        onEvent?("batch_closed", ["undecided": rows.filter { !$0.decided }.count])
        if waitingToLearn.isEmpty { worker?.cancel() }
        for task in reads where waitingToLearn.isEmpty { task.cancel() }
        finish()
    }

    // MARK: Choose a label

    public func openPicker(query: String = "") {
        let ids = scope
        guard !ids.isEmpty else { return }
        pickerScope = ids
        pickerQuery = query
        rebuildPicker(resetHighlight: true)
    }

    public func closePicker() {
        pickerScope = nil
        pickerQuery = ""
        pickerRows = []
        pickerHighlightedID = nil
        newLabel = nil
    }

    /// The one row the picker is for, when it is for one.
    public var pickerRow: BatchRow? {
        guard let ids = pickerScope, ids.count == 1 else { return nil }
        return rows.first { $0.id == ids[0] }
    }

    private func rebuildPicker(resetHighlight: Bool) {
        guard let ids = pickerScope else { return }
        let scoped = ids.compactMap { id in rows.first { $0.id == id } }
        let suggestion = scoped.count == 1 ? scoped[0].suggestion : nil
        let canTrash = !scoped.isEmpty && scoped.allSatisfy(self.canTrash)
        var out = LabelPicker.rows(catalog: catalog, suggestion: suggestion, canTrash: canTrash, query: pickerQuery)
        if canTrash, pickerQuery.isEmpty, !out.contains(where: { $0.action == .trash }) {
            out.append(LabelRow(id: "trash", title: "Move to Trash", action: .trash, section: .all))
        }
        pickerRows = out
        if resetHighlight || !out.contains(where: { $0.id == pickerHighlightedID }) {
            pickerHighlightedID = out.first?.id
        }
    }

    public func movePickerHighlight(by delta: Int) {
        pickerHighlightedID =
            Highlight.moved(pickerRows.map(\.id), from: pickerHighlightedID, by: delta) ?? pickerHighlightedID
    }

    public func highlightPicker(_ row: LabelRow) {
        pickerHighlightedID = row.id
    }

    /// Files the picker's scope under the highlighted label, and returns to the list.
    @discardableResult
    public func choosePickerHighlighted() -> Task<Void, Never>? {
        guard let row = pickerRows.first(where: { $0.id == pickerHighlightedID }) else { return nil }
        return choose(row)
    }

    @discardableResult
    public func choose(_ row: LabelRow) -> Task<Void, Never>? {
        guard let ids = pickerScope else { return nil }
        closePicker()
        return applyToScope(row.action, scope: ids)
    }

    // MARK: New label

    /// The labels a new one can go inside.
    public var newLabelParents: [LabelEntry] { catalog.entries }

    public var newLabelOutcome: NewLabelOutcome { newLabel?.outcome(in: catalog) ?? .empty }

    /// Opens New label… with what was typed in the search as its name.
    public func openNewLabel() {
        guard pickerScope != nil else { return }
        newLabel = NewLabelForm.from(query: pickerQuery, catalog: catalog)
    }

    /// Back to the label list, with the search as it was.
    public func cancelNewLabel() {
        newLabel = nil
    }

    /// Moves where the new label goes: the top level first, then each label in the list's order.
    public func moveNewLabelParent(by delta: Int) {
        guard let form = newLabel else { return }
        // "" stands for the top level; no mailbox is named "".
        let ids = [""] + newLabelParents.map(\.mailbox)
        let moved = Highlight.moved(ids, from: form.parent ?? "", by: delta) ?? ""
        newLabel?.parent = moved.isEmpty ? nil : moved
    }

    /// Creates the label and files the picker's scope under it, or files under the label of that
    /// name when there is one already. Back to the list.
    @discardableResult
    public func createNewLabel() -> Task<Void, Never>? {
        guard let ids = pickerScope, let action = newLabelOutcome.action else { return nil }
        closePicker()
        return applyToScope(action, scope: ids)
    }

    // MARK: Helpers

    private func update(_ id: String, _ change: (inout BatchRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }
}
