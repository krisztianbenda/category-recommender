import Foundation
import Testing

@testable import MailCore

final class FakeMail: MailSource, @unchecked Sendable {
    var selectionResult = MailSelection(
        messages: [MailMessageRef(id: 1, mailbox: "INBOX", account: "Google", messageId: "m1@example.test")],
        latest: Email(from: "Dad <dad@example.test>", subject: "Sunday lunch", body: "See you at noon"))
    var accounts = [MailAccount(name: "Google", addresses: ["owner@gmail.example"])]
    var mailboxes = ["INBOX", "Family", "Family/Baby", "Gadgets", "[Gmail]/All Mail"]
    var system: [String]?
    var inbox: String?
    var counts: [String: Int] = [:]
    var filed: [(items: [FileItem], target: String)] = []
    var created: [String] = []
    var deleted: [String] = []
    var fileError: Error?
    var createError: Error?
    var selectionError: Error?
    var deleteError: Error?
    var deleteStart = DeleteStart.confirmInMail
    var ownerDeclinesInMail = false

    func opening() async throws -> MailOpening {
        if let selectionError { throw selectionError }
        let owner = selectionResult.messages.first?.account
        let isGmail = accounts.contains { $0.name == owner }
        return MailOpening(
            selection: selectionResult, accounts: accounts,
            labels: isGmail ? AccountLabels(mailboxes: mailboxes, system: system, inbox: inbox) : nil)
    }
    func labels(account: String) async throws -> AccountLabels {
        AccountLabels(mailboxes: mailboxes, system: system, inbox: inbox)
    }
    func file(_ items: [FileItem], into target: String, account: String) async throws {
        if let fileError { throw fileError }
        filed.append((items, target))
    }
    var archiveResult = ArchiveResult.archived
    var archived: [[String]] = []
    func archive(messageIds: [String], account: String) async throws -> ArchiveResult {
        archived.append(messageIds)
        return archiveResult
    }
    func createLabel(_ path: String, account: String) async throws -> Bool {
        if let createError { throw createError }
        created.append(path)
        if mailboxes.contains(path) { return false }
        mailboxes.append(path)
        return true
    }
    func beginDeleteLabel(_ path: String, account: String) async throws -> DeleteStart {
        if let deleteError { throw deleteError }
        deleted.append(path)
        if !ownerDeclinesInMail { mailboxes.removeAll { $0 == path } }
        return deleteStart
    }
    func labelExists(_ path: String, account: String) async throws -> Bool { mailboxes.contains(path) }
    func messageCount(_ path: String, account: String) async throws -> Int { counts[path] ?? 0 }
    var trashLookup = TrashLookup()
    var trashLookupError: Error?
    var trashLookups: [(sender: String, messageIds: [String])] = []
    var trashResult = TrashResult.trashed
    var movedToTrash: [[String]] = []
    func trashSimilar(sender: String, messageIds: [String], account: String) async throws -> TrashLookup {
        trashLookups.append((sender, messageIds))
        if let trashLookupError { throw trashLookupError }
        return trashLookup
    }
    func moveToTrash(messageIds: [String], account: String) async throws -> TrashResult {
        movedToTrash.append(messageIds)
        return trashResult
    }
    /// Which emails each mailbox holds, by subject.
    var held: [String: [String]] = [:]
    var holdingCalls: [(emails: [LearnedEmail], mailboxes: [String])] = []
    var holdingError: Error?
    func holding(_ emails: [LearnedEmail], in mailboxes: [String], account: String) async throws -> [Int] {
        holdingCalls.append((emails, mailboxes))
        if let holdingError { throw holdingError }
        return mailboxes.map { box in emails.filter { (held[box] ?? []).contains($0.subject) }.count }
    }
}

final class FakeAPI: RecommenderAPI, @unchecked Sendable {
    var sets: [CategorySetSummary] = []
    var categories: [String: [CategoryItem]] = [:]
    var suggestion = Suggestion(suggestionId: "S1", category: "Family")
    var suggestError: Error?
    var suggestFailures = 0
    var feedbackError: Error?
    var feedbacks: [(id: String, email: Email, decision: FeedbackDecision)] = []
    var suggestCalls: [Email] = []
    var suggestOptions: [(allowDelete: Bool, trash: [TrashedEmail])] = []
    var deletedCategories: [String] = []
    var addedCategories: [String] = []
    var acceptNewFailsWith400 = false
    private var next = 0
    var gate: CheckedContinuation<Void, Never>?
    var holdSuggestion = false
    var suggestStarted = false

    func openGate() {
        holdSuggestion = false
        gate?.resume()
        gate = nil
    }
    private func newId() -> String {
        next += 1
        return "ID\(next)"
    }
    func listSets() async throws -> [CategorySetSummary] { sets }
    func createSet(name: String, categories paths: [String]) async throws -> String {
        let id = newId()
        sets.append(CategorySetSummary(id: id, name: name))
        categories[id] = paths.map { CategoryItem(id: newId(), path: $0) }
        return id
    }
    func getSet(id: String) async throws -> SetDetail {
        SetDetail(id: id, name: "x", categories: categories[id] ?? [])
    }
    func addCategory(setId: String, path: String) async throws -> String {
        let id = newId()
        addedCategories.append(path)
        categories[setId, default: []].append(CategoryItem(id: id, path: path))
        return id
    }
    func deleteCategory(id: String, cascade: Bool) async throws {
        deletedCategories.append(id)
        for key in categories.keys { categories[key]?.removeAll { $0.id == id } }
    }
    var updates: [(id: String, name: String?, parent: ParentChange)] = []
    /// Ids whose update the service refuses, as with a name too close to another.
    var refuseUpdates = Set<String>()
    /// Like the service: the id and the example count stay, and children follow a renamed parent.
    func updateCategory(id: String, name: String?, parent: ParentChange) async throws {
        if refuseUpdates.contains(id) {
            throw ServiceError.api(status: 400, code: "invalid_request", message: "too close")
        }
        updates.append((id, name, parent))
        for key in categories.keys {
            guard var list = categories[key], let index = list.firstIndex(where: { $0.id == id }) else { continue }
            let item = list[index]
            let parentId: String?
            switch parent {
            case .keep: parentId = item.parentId
            case .topLevel: parentId = nil
            case .under(let id): parentId = id
            }
            let own = name ?? LabelText.split(item.path).name
            let path = parentId.flatMap { p in list.first { $0.id == p } }.map { "\($0.path)/\(own)" } ?? own
            list[index] = CategoryItem(id: id, path: path, parentId: parentId, exampleCount: item.exampleCount)
            list = list.map {
                guard $0.parentId == id else { return $0 }
                let childPath = "\(path)/\(LabelText.split($0.path).name)"
                return CategoryItem(id: $0.id, path: childPath, parentId: id, exampleCount: $0.exampleCount)
            }
            categories[key] = list
        }
    }
    var learned: [String: [LearnedEmail]] = [:]
    func learnedEmails(categoryId: String, limit: Int) async throws -> [LearnedEmail] {
        Array((learned[categoryId] ?? []).prefix(limit))
    }
    func suggest(email: Email, setId: String, allowDelete: Bool, trash: [TrashedEmail]) async throws -> Suggestion {
        suggestCalls.append(email)
        suggestOptions.append((allowDelete, trash))
        suggestStarted = true
        if holdSuggestion { await withCheckedContinuation { gate = $0 } }
        if suggestFailures > 0 {
            suggestFailures -= 1
            throw ServiceError.api(status: 503, code: "llm_unavailable", message: "later")
        }
        if let suggestError { throw suggestError }
        return suggestion
    }
    func feedback(suggestionId: String, email: Email, decision: FeedbackDecision) async throws {
        if let feedbackError { throw feedbackError }
        if acceptNewFailsWith400, case .acceptNew = decision {
            throw ServiceError.api(status: 400, code: "invalid_request", message: "too close")
        }
        feedbacks.append((suggestionId, email, decision))
    }
}

final class FakeBackend: BackendControl, @unchecked Sendable {
    var error: Error?
    var starts = 0
    var activity = 0
    func ensureRunning(onStarting: @escaping @Sendable () -> Void) async throws {
        if let error { throw error }
        starts += 1
    }
    func noteActivity() { activity += 1 }
}

@MainActor
struct SessionTests {
    let mail = FakeMail()
    let api = FakeAPI()
    let backend = FakeBackend()

    private func session(keepInInbox: Bool = false) -> RecommenderSession {
        RecommenderSession(
            mail: mail, api: api, backend: backend, keepInInbox: keepInInbox,
            deletePollInterval: 0.001, deleteTimeout: 0.05)
    }

    private func started(keepInInbox: Bool = false) async -> RecommenderSession {
        let s = session(keepInInbox: keepInInbox)
        await s.start().value
        return s
    }

    /// Says whether the session has finished, that is, closed its window.
    private func watchFinish(_ s: RecommenderSession) -> () -> Bool {
        var finished = false
        s.onFinish = { finished = true }
        return { finished }
    }

    /// Starts a session whose suggestion the model holds back, and returns once it was asked for.
    private func startedWhileTheModelThinks() async -> (RecommenderSession, Task<Void, Never>) {
        api.holdSuggestion = true
        let s = session()
        let startTask = s.start()
        while !api.suggestStarted { await Task.yield() }
        return (s, startTask)
    }

    /// Lets the held-back model answer, and waits for the feedback the session sends after it.
    private func releaseTheModel(_ startTask: Task<Void, Never>) async {
        api.openGate()
        await startTask.value
        for _ in 0..<50 where api.feedbacks.isEmpty { await Task.yield() }
    }

    @Test func importsLabelsAndRecommends() async {
        let s = await started()
        #expect(s.stage == .ready)
        #expect(s.subject == "Sunday lunch")
        #expect(s.sender == "Dad <dad@example.test>")
        #expect(api.sets.map(\.name) == ["Gmail: owner@gmail.example"])
        #expect(api.categories.values.first?.map(\.path) == ["Family", "Family/Baby", "Gadgets"])
        #expect(s.rows.first?.section == .recommended)
        #expect(s.rows.first?.title == "Family")
        #expect(s.highlightedID == s.rows.first?.id)
        #expect(s.rows.filter { $0.title == "Family" }.count == 1)
        #expect(!s.rows.contains { $0.title.contains("Gmail") || $0.title == "INBOX" })
    }

    /// An Exchange-like account: folders, and its own folders under names no list could know.
    private func useFolderAccount(from mailbox: String = "Beérkezett", inInbox: Bool = true) {
        mail.accounts = [MailAccount(name: "Work", addresses: ["owner@work.example"], kind: .folders)]
        mail.mailboxes = ["Beérkezett", "Beérkezett/Projects", "Elküldött", "Törölt elemek", "Family", "Gadgets"]
        mail.system = ["Beérkezett", "Elküldött", "Törölt elemek"]
        mail.inbox = "Beérkezett"
        mail.selectionResult = MailSelection(
            messages: [
                MailMessageRef(id: 1, mailbox: mailbox, account: "Work", messageId: "m1@example.test", inInbox: inInbox)
            ],
            latest: Email(from: "Dad <dad@example.test>", subject: "Sunday lunch", body: "See you at noon"))
    }

    @Test func aFolderAccountGetsItsOwnSetAndLeavesOutItsOwnFolders() async {
        useFolderAccount()
        let s = await started()
        #expect(s.stage == .ready)
        #expect(s.usesFolders)
        #expect(api.sets.map(\.name) == ["Mail: owner@work.example"])
        #expect(
            Set(s.rows.map(\.title)) == ["Family", "Gadgets", "Beérkezett\(LabelText.deepSeparator)Projects"])
    }

    @Test func filingInAFolderAccountCopiesTheEmailWithoutArchiving() async {
        useFolderAccount()
        let s = await started()
        let finished = watchFinish(s)
        await s.acceptHighlighted()?.value
        #expect(mail.filed.first?.target == "Family")
        #expect(mail.filed.first?.items == [FileItem(id: 1, mailbox: "Beérkezett", mode: .copy)])
        #expect(mail.archived.isEmpty)
        #expect(api.feedbacks.first?.decision == .confirm)
        #expect(finished())
    }

    @Test func keepingInTheInboxFilesACopyInAFolderAccount() async {
        useFolderAccount()
        let s = await started(keepInInbox: true)
        await s.acceptHighlighted()?.value
        #expect(mail.filed.first?.items == [FileItem(id: 1, mailbox: "Beérkezett", mode: .copy)])
        #expect(mail.archived.isEmpty)
    }

    @Test func refilingFromAnotherFolderCopiesToo() async {
        useFolderAccount(from: "Gadgets", inInbox: false)
        let s = await started()
        await s.acceptHighlighted()?.value
        #expect(mail.filed.first?.items == [FileItem(id: 1, mailbox: "Gadgets", mode: .copy)])
    }

    @Test func typingTheAccountsOwnFolderUnderItsLocalNameOffersNoCreate() async {
        useFolderAccount()
        let s = await started()
        s.query = "Elküldött"
        #expect(!s.rows.contains { $0.section == .create })
    }

    @Test func aFolderInsideTheInboxIsFiledUnderItsExactMailbox() async {
        useFolderAccount()
        let s = await started()
        let row = s.rows.first { $0.title.hasSuffix("Projects") }!
        await s.accept(row)?.value
        #expect(mail.filed.first?.target == "Beérkezett/Projects")
        #expect(mail.created.isEmpty)
    }

    @Test func acceptingTheRecommendationFilesAndConfirms() async {
        let s = await started()
        let finished = watchFinish(s)
        await s.acceptHighlighted()?.value
        #expect(mail.filed.first?.target == "Family")
        #expect(mail.filed.first?.items == [FileItem(id: 1, mailbox: "INBOX", mode: .move)])
        #expect(api.feedbacks.first?.decision == .confirm)
        #expect(api.feedbacks.first?.id == "S1")
        #expect(api.feedbacks.first?.email == api.suggestCalls.first)
        #expect(finished())
    }

    @Test func pickingAnotherLabelRecordsACorrection() async {
        let s = await started()
        let other = s.rows.first { $0.title == "Gadgets" }!
        await s.accept(other)?.value
        #expect(mail.filed.first?.target == "Gadgets")
        #expect(api.feedbacks.first?.decision == .choose("Gadgets"))
    }

    @Test func filingFromTheInboxArchivesExactlyTheFiledEmails() async {
        let s = await started()
        await s.acceptHighlighted()?.value
        #expect(mail.archived == [["m1@example.test"]])
    }

    @Test func keepInInboxCopiesInstead() async {
        let s = await started(keepInInbox: true)
        await s.acceptHighlighted()?.value
        #expect(mail.filed.first?.items.first?.mode == .copy)
        #expect(mail.archived.isEmpty)
    }

    @Test func withoutPermissionToArchiveTheWindowSaysSoAndStillLearns() async {
        mail.archiveResult = .notAllowed
        let s = await started()
        let finished = watchFinish(s)
        await s.acceptHighlighted()?.value
        #expect(mail.filed.count == 1)
        #expect(api.feedbacks.first?.decision == .confirm)
        #expect(!finished())
        #expect(s.notice?.contains("Accessibility") == true)
        #expect(s.acceptHighlighted() == nil)
    }

    @Test func eachReasonTheArchiveWasNotClickedHasItsOwnAdvice() async {
        let notices = await withNotices(for: [.notAllowed, .systemEventsNotAllowed, .commandUnavailable]) {
            mail.archiveResult = $0
        }
        // A switch that looks on can be from before a reinstall, which only removing it fixes.
        #expect(notices[0].contains("Accessibility") && notices[0].contains("remove it with \u{2212}"))
        #expect(notices[1].contains("Automation") && !notices[1].contains("Accessibility"))
        #expect(notices[2].contains("Archive command was not available"))
        #expect(notices.allSatisfy { $0.hasPrefix("Labelled, but it is still in the Inbox") })
    }

    /// Files one email per setting, each in a new window, and returns the notices.
    private func withNotices(
        for results: [ArchiveResult], _ set: (ArchiveResult) -> Void
    ) async -> [String] {
        var out: [String] = []
        for result in results {
            set(result)
            let s = await started()
            await s.acceptHighlighted()?.value
            out.append(s.notice ?? "")
        }
        return out
    }

    @Test func aChangedSelectionInMailIsNotArchived() async {
        mail.archiveResult = .selectionChanged
        let s = await started()
        await s.acceptHighlighted()?.value
        #expect(s.notice?.contains("selection in Mail changed") == true)
    }

    @Test func keepInInboxChangeIsReported() async {
        let s = session()
        var seen: Bool?
        s.onKeepInInboxChange = { seen = $0 }
        s.keepInInbox = true
        #expect(seen == true)
    }

    @Test func allMailOnlyAddsTheLabel() async {
        mail.selectionResult = MailSelection(
            messages: [MailMessageRef(id: 5, mailbox: "[Gmail]/All Mail", account: "Google")],
            latest: Email(from: "a", subject: "s", body: "b"))
        let s = await started()
        await s.acceptHighlighted()?.value
        #expect(mail.filed.first?.items.first?.mode == .copy)
        #expect(mail.archived.isEmpty)
    }

    @Test func aWholeSelectionIsFiled() async {
        mail.selectionResult = MailSelection(
            messages: [
                MailMessageRef(id: 1, mailbox: "INBOX", account: "Google"),
                MailMessageRef(id: 2, mailbox: "INBOX", account: "Google"),
            ],
            latest: Email(from: "a", subject: "s", body: "b"))
        let s = await started()
        #expect(s.messageCount == 2)
        await s.acceptHighlighted()?.value
        #expect(mail.filed.first?.items.map(\.id) == [1, 2])
    }

    @Test func runnersUpComeAfterTheRecommendation() async {
        api.suggestion = Suggestion(
            suggestionId: "S1", category: "Family", runnersUp: [RankedCategory(path: "Gadgets", score: 0.5)])
        let s = await started()
        #expect(s.rows.map(\.section) == [.recommended, .likely, .all])
        #expect(s.rows.map(\.title) == ["Family", "Gadgets", "Family/Baby"])
    }

    @Test func runnersUpIgnoreLabelsThatAreGone() async {
        api.suggestion = Suggestion(
            suggestionId: "S1", category: "Family", runnersUp: [RankedCategory(path: "Gone", score: 0.5)])
        let s = await started()
        #expect(!s.rows.contains { $0.title == "Gone" })
    }

    @Test func aProposalCreatesTheLabelAndConfirms() async {
        api.suggestion = Suggestion(
            suggestionId: "S1", category: "Family/Trips", isNew: true,
            newCategory: NewCategory(parent: "Family", name: "Trips"))
        let s = await started()
        #expect(s.rows.first?.action == .acceptProposal(NewCategory(parent: "Family", name: "Trips")))
        await s.acceptHighlighted()?.value
        #expect(mail.created == ["Family/Trips"])
        #expect(mail.filed.first?.target == "Family/Trips")
        #expect(api.feedbacks.first?.decision == .confirm)
    }

    @Test func aRecommendedLabelThatIsGoneIsOfferedForRecreation() async {
        api.suggestion = Suggestion(suggestionId: "S1", category: "Bills")
        let s = await started()
        #expect(s.rows.first?.action == .recreate("Bills"))
        await s.acceptHighlighted()?.value
        #expect(mail.created == ["Bills"])
        #expect(api.feedbacks.first?.decision == .confirm)
    }

    @Test func typingFiltersAndOffersToCreate() async {
        let s = await started()
        s.query = "gad"
        #expect(s.rows.map(\.title) == ["Gadgets", "gad"])
        #expect(s.highlightedID == s.rows.first?.id)
        s.query = "csalad uj"
        #expect(s.rows.map(\.section) == [.create])
        s.query = "family"
        #expect(s.rows.map(\.title).contains("Family/Baby"))
        #expect(!s.rows.contains { $0.section == .create })
        s.query = ""
        #expect(s.rows.first?.section == .recommended)
    }

    @Test func searchIgnoresAccents() async {
        mail.mailboxes = ["Számlák"]
        api.suggestion = Suggestion(suggestionId: "S1", category: "Számlák")
        let s = await started()
        s.query = "szamla"
        #expect(s.rows.first?.title == "Számlák")
    }

    @Test func creatingATypedLabelUnderAKnownParent() async {
        let s = await started()
        s.query = "Family/New Baby"
        let row = s.rows.first { $0.section == .create }!
        await s.accept(row)?.value
        #expect(mail.created == ["Family/New Baby"])
        #expect(mail.filed.first?.target == "Family/New Baby")
        #expect(api.feedbacks.first?.decision == .acceptNew(NewCategory(parent: "Family", name: "New Baby")))
    }

    @Test func creatingATypedLabelUnderANewParentGoesThroughAFreshSuggestion() async {
        let s = await started()
        s.query = "Trips/Lisbon"
        let row = s.rows.first { $0.section == .create }!
        await s.accept(row)?.value
        #expect(api.addedCategories.contains("Trips/Lisbon"))
        #expect(api.suggestCalls.count == 2)
        #expect(api.feedbacks.first?.decision == .choose("Trips/Lisbon"))
    }

    @Test func aNearDuplicateNameIsStillLearned() async {
        api.acceptNewFailsWith400 = true
        let s = await started()
        s.query = "Gad-gets"
        let row = s.rows.first { $0.section == .create }!
        await s.accept(row)?.value
        #expect(mail.filed.first?.target == "Gad-gets")
        #expect(api.feedbacks.first?.decision == .choose("Gad-gets"))
    }

    @Test func anExistingNameIsNotOfferedForCreation() async {
        let s = await started()
        s.query = "family/baby"
        #expect(!s.rows.contains { $0.section == .create })
    }

    @Test func aFailedFilingTeachesNothingAndKeepsTheWindow() async {
        mail.fileError = MailError.script(number: -1, message: "nope")
        let s = await started()
        let finished = watchFinish(s)
        await s.acceptHighlighted()?.value
        #expect(api.feedbacks.isEmpty)
        #expect(!finished())
        #expect(s.notice?.hasPrefix("Not filed") == true)
        #expect(!s.busy)
    }

    @Test func aFailedLearningStepSaysSoAndDoesNotRefile() async {
        api.feedbackError = ServiceError.unreachable
        let s = await started()
        let finished = watchFinish(s)
        await s.acceptHighlighted()?.value
        #expect(mail.filed.count == 1)
        #expect(!finished())
        #expect(s.notice?.hasPrefix("Filed") == true)
        #expect(s.acceptHighlighted() == nil)
    }

    @Test func filingDoesNotWaitForTheModel() async {
        let (s, startTask) = await startedWhileTheModelThinks()
        let finished = watchFinish(s)
        #expect(s.stage == .ready)
        #expect(s.recommendation == .thinking)
        let row = s.rows.first { $0.title == "Gadgets" }!
        await s.accept(row)?.value
        #expect(mail.filed.first?.target == "Gadgets")
        #expect(finished())
        #expect(api.feedbacks.isEmpty)
        await releaseTheModel(startTask)
        #expect(api.feedbacks.first?.decision == .choose("Gadgets"))
    }

    @Test func aModelProblemStillAllowsFilingByHand() async {
        backend.error = ServiceError.unreachable
        let s = await started()
        if case .unavailable = s.recommendation {} else { Issue.record("expected unavailable") }
        let finished = watchFinish(s)
        let row = s.rows.first { $0.title == "Gadgets" }!
        await s.accept(row)?.value
        #expect(mail.filed.first?.target == "Gadgets")
        #expect(api.feedbacks.isEmpty)
        #expect(finished())
    }

    @Test func aFailedRecommendationStillAllowsFilingByHand() async {
        api.suggestError = ServiceError.api(status: 503, code: "llm_unavailable", message: "later")
        let s = await started()
        if case .unavailable = s.recommendation {} else { Issue.record("expected unavailable") }
        #expect(s.rows.count == 3)
    }

    @Test func aModelTimeoutIsRetriedOnce() async {
        api.suggestFailures = 1
        let s = await started()
        #expect(api.suggestCalls.count == 2)
        if case .ready = s.recommendation {} else { Issue.record("expected a recommendation") }

        api.suggestCalls = []
        api.suggestFailures = 5
        let t = await started()
        #expect(api.suggestCalls.count == 2)
        if case .unavailable = t.recommendation {} else { Issue.record("expected unavailable") }
    }

    @Test func aSubjectAndBodylessEmailSkipsTheModel() async {
        mail.selectionResult = MailSelection(
            messages: [MailMessageRef(id: 1, mailbox: "INBOX", account: "Google")],
            latest: Email(from: "a", subject: "", body: ""))
        let s = await started()
        #expect(api.suggestCalls.isEmpty)
        if case .unavailable = s.recommendation {} else { Issue.record("expected unavailable") }
    }

    @Test func blockedStates() async {
        mail.selectionResult = MailSelection(running: false, messages: [], latest: nil)
        #expect(await started().stage == .blocked(.mailNotRunning))

        mail.selectionResult = MailSelection(messages: [], latest: nil)
        #expect(await started().stage == .blocked(.noSelection))

        let oneMessage = MailSelection(
            messages: [MailMessageRef(id: 1, mailbox: "INBOX", account: "iCloud")],
            latest: Email(from: "a", subject: "s", body: "b"))
        mail.selectionResult = oneMessage
        #expect(await started().stage == .blocked(.unsupportedSelection))

        mail.accounts = []
        #expect(await started().stage == .blocked(.noAccount))

        mail.selectionError = MailError.notAuthorized
        #expect(await started().stage == .blocked(.notAuthorized))
    }

    @Test func aMixedSelectionIsRefused() async {
        mail.selectionResult = MailSelection(
            messages: [
                MailMessageRef(id: 1, mailbox: "INBOX", account: "Google"),
                MailMessageRef(id: 2, mailbox: "INBOX", account: "iCloud"),
            ],
            latest: Email(from: "a", subject: "s", body: "b"))
        #expect(await started().stage == .blocked(.unsupportedSelection))
        #expect(mail.filed.isEmpty)
    }

    @Test func deletingAskesFirstThenRemovesBothSides() async {
        mail.counts["Gadgets"] = 7
        let s = await started()
        let setId = api.sets[0].id
        let entry = s.rows.first { $0.title == "Gadgets" }!.entry!
        await s.askToDelete(entry)?.value
        #expect(s.deleteRequest?.emailCount == 7)
        #expect(mail.deleted.isEmpty)

        await s.confirmDelete()?.value
        #expect(mail.deleted == ["Gadgets"])
        #expect(!(api.categories[setId] ?? []).contains { $0.path == "Gadgets" })
        #expect(!s.rows.contains { $0.title == "Gadgets" })
        #expect(s.deleteRequest == nil)
    }

    @Test func aDeclinedDeletionInMailChangesNothing() async {
        mail.ownerDeclinesInMail = true
        let s = await started()
        let setId = api.sets[0].id
        let entry = s.rows.first { $0.title == "Gadgets" }!.entry!
        await s.askToDelete(entry)?.value
        await s.confirmDelete()?.value
        #expect(s.notice?.contains("still there") == true)
        #expect(s.deleteWait == nil)
        #expect(api.deletedCategories.isEmpty)
        #expect((api.categories[setId] ?? []).contains { $0.path == "Gadgets" })
        #expect(s.rows.contains { $0.title == "Gadgets" })
    }

    @Test func aFailedHandOverToMailChangesNothing() async {
        mail.deleteError = MailError.notFound("Mail could not show that label, so nothing was deleted")
        let s = await started()
        let entry = s.rows.first { $0.title == "Gadgets" }!.entry!
        await s.askToDelete(entry)?.value
        await s.confirmDelete()?.value
        #expect(s.notice?.hasPrefix("Not deleted") == true)
        #expect(s.deleteRequest == nil)
        #expect(api.deletedCategories.isEmpty)
    }

    @Test func stoppingTheWaitLeavesTheCategory() async {
        mail.ownerDeclinesInMail = true
        mail.deleteStart = .chooseInMail(.notAllowed)
        let s = RecommenderSession(
            mail: mail, api: api, backend: backend, deletePollInterval: 0.001, deleteTimeout: 30)
        await s.start().value
        let entry = s.rows.first { $0.title == "Gadgets" }!.entry!
        await s.askToDelete(entry)?.value
        let waiting = s.confirmDelete()
        while s.deleteWait == nil { await Task.yield() }
        #expect(s.deleteWait?.start == .chooseInMail(.notAllowed))
        #expect(s.accept(s.rows[0]) == nil)
        s.cancelDeleteWait()
        await waiting?.value
        #expect(api.deletedCategories.isEmpty)
        #expect(s.notice == nil)
    }

    @Test func cancellingADeleteChangesNothing() async {
        let s = await started()
        let entry = s.rows.first { $0.title == "Gadgets" }!.entry!
        await s.askToDelete(entry)?.value
        s.cancelDelete()
        #expect(s.deleteRequest == nil)
        #expect(mail.deleted.isEmpty)
    }

    @Test func aLabelWithSubLabelsCannotBeDeleted() async {
        let s = await started()
        let entry = s.rows.first { $0.title == "Family" }!.entry!
        #expect(s.askToDelete(entry) == nil)
        #expect(s.deleteRequest == nil)
        #expect(s.notice?.contains("sub-labels") == true)
    }

    @Test func deletingTheRecommendedLabelDoesNotOfferToRecreateIt() async {
        api.suggestion = Suggestion(suggestionId: "S1", category: "Gadgets")
        let s = await started()
        let entry = s.rows.first!.entry!
        await s.askToDelete(entry)?.value
        await s.confirmDelete()?.value
        #expect(s.rows.first?.section == .all)
        #expect(!s.rows.contains { $0.title == "Gadgets" })
    }

    @Test func learnedDecisionsOfRemovedLabelsAreKeptUntilForgotten() async {
        let s0 = await started()
        #expect(s0.orphaned.isEmpty)
        let setId = api.sets[0].id
        api.categories[setId]?.append(CategoryItem(id: "OLD", path: "Bills", exampleCount: 4))

        let s = await started()
        #expect(s.orphaned.map(\.id) == ["OLD"])
        #expect(api.deletedCategories.isEmpty)
        #expect(!s.rows.contains { $0.title == "Bills" })

        await s.forgetOrphaned()?.value
        #expect(api.deletedCategories == ["OLD"])
        #expect(s.orphaned.isEmpty)
    }

    @Test func secondRunReusesTheSetAndKeepsIds() async {
        _ = await started()
        let before = api.categories[api.sets[0].id]!.map(\.id)
        _ = await started()
        #expect(api.sets.count == 1)
        #expect(api.categories[api.sets[0].id]!.map(\.id) == before)
    }

    @Test func aNewLabelIsImportedNextTime() async {
        _ = await started()
        mail.mailboxes.append("Trips")
        let s = await started()
        #expect(api.addedCategories == ["Trips"])
        #expect(s.rows.contains { $0.title == "Trips" })
    }

    @Test func keyboardMovesTheHighlightWithinBounds() async {
        let s = await started()
        let first = s.highlightedID
        s.moveHighlight(by: -1)
        #expect(s.highlightedID == first)
        s.moveHighlight(by: 1)
        #expect(s.highlightedID == s.rows[1].id)
        s.moveHighlight(by: 99)
        #expect(s.highlightedID == s.rows.last?.id)
    }

    @Test func aMovedHighlightSurvivesTheRecommendationArriving() async {
        api.holdSuggestion = true
        let s = session()
        let startTask = s.start()
        while !api.suggestStarted { await Task.yield() }
        s.moveHighlight(by: 1)
        let chosen = s.highlightedID
        api.openGate()
        await startTask.value
        #expect(s.highlightedID == chosen)
    }

    @Test func aPlainHighlightJumpsToTheRecommendation() async {
        api.holdSuggestion = true
        api.suggestion = Suggestion(suggestionId: "S1", category: "Gadgets")
        let s = session()
        let startTask = s.start()
        while !api.suggestStarted { await Task.yield() }
        #expect(s.rows.first?.title == "Family")
        api.openGate()
        await startTask.value
        #expect(s.rows.first?.title == "Gadgets")
        #expect(s.highlightedID == s.rows.first?.id)
    }

    @Test func doubleAcceptFilesOnce() async {
        let s = await started()
        let first = s.acceptHighlighted()
        let second = s.acceptHighlighted()
        #expect(second == nil)
        await first?.value
        #expect(mail.filed.count == 1)
    }

    @Test func tooManyLabelsAreReported() async {
        mail.mailboxes = (0..<305).map { String(format: "Label %03d", $0) }
        api.suggestion = Suggestion(suggestionId: "S1", category: "Label 000")
        let s = await started()
        #expect(s.notConsidered == 5)
        #expect(api.categories.values.first?.count == 300)
        #expect(s.labelCount == 305)
    }

    @Test func aLabelBeyondTheLimitCanBeFiledWithoutFeedback() async {
        mail.mailboxes = (0..<305).map { String(format: "Label %03d", $0) }
        api.suggestion = Suggestion(suggestionId: "S1", category: "Label 000")
        let s = await started()
        let row = s.rows.first { $0.title == "Label 304" }!
        await s.accept(row)?.value
        #expect(mail.filed.first?.target == "Label 304")
        #expect(api.feedbacks.isEmpty)
    }

    // MARK: Moving to the Trash

    private static let trashed = [TrashedEmail(from: "Dad <dad@example.test>", subject: "Sunday lunch again")]

    private static func deleteSuggestion(
        category: String = "Family", runnersUp: [RankedCategory] = [], isNew: Bool = false,
        newCategory: NewCategory? = nil
    ) -> Suggestion {
        Suggestion(
            suggestionId: "S1", action: .delete, category: category, isNew: isNew, newCategory: newCategory,
            confidence: .medium, reason: "You deleted 3 similar emails before.", runnersUp: runnersUp,
            similarPastDecisions: 3, similarDeleted: 3)
    }

    @Test func theTrashIsReadAndItsFindingsGoWithTheRequest() async {
        mail.trashLookup = TrashLookup(messages: Self.trashed)
        let s = await started()
        #expect(mail.trashLookups.first?.sender == "Dad <dad@example.test>")
        #expect(mail.trashLookups.first?.messageIds == ["m1@example.test"])
        #expect(api.suggestOptions.first?.allowDelete == true)
        #expect(api.suggestOptions.first?.trash == Self.trashed)
        #expect(s.canTrash)
    }

    @Test func aSuggestionToDeleteLeadsWithTheTrashThenTheLabelItNamed() async {
        api.suggestion = Self.deleteSuggestion(runnersUp: [RankedCategory(path: "Gadgets", score: 0.5)])
        let s = await started()
        #expect(Array(s.rows.map(\.title).prefix(3)) == ["Move to Trash", "Family", "Gadgets"])
        #expect(Array(s.rows.map(\.section).prefix(3)) == [.recommended, .likely, .likely])
        #expect(s.highlightedID == LabelRow.trash.id)
    }

    @Test func acceptingASuggestionToDeleteMovesItToTheTrashAndLearnsIt() async {
        api.suggestion = Self.deleteSuggestion()
        let s = await started()
        let finished = watchFinish(s)
        await s.acceptHighlighted()?.value
        #expect(mail.movedToTrash == [["m1@example.test"]])
        #expect(mail.filed.isEmpty)
        #expect(mail.archived.isEmpty)
        #expect(api.feedbacks.map(\.decision) == [.delete])
        #expect(finished())
        #expect(s.acceptHighlighted() == nil)
    }

    @Test func filingUnderTheLabelItNamedIsAChoiceNotAConfirmation() async {
        api.suggestion = Self.deleteSuggestion()
        let s = await started()
        await s.accept(s.rows[1])?.value
        #expect(mail.filed.first?.target == "Family")
        #expect(mail.movedToTrash.isEmpty)
        #expect(api.feedbacks.map(\.decision) == [.choose("Family")])
    }

    @Test func acceptingTheProposalItNamedCreatesTheLabelWithoutConfirmingTheDeletion() async {
        let proposal = NewCategory(parent: "Family", name: "Trips")
        api.suggestion = Self.deleteSuggestion(category: "Family/Trips", isNew: true, newCategory: proposal)
        let s = await started()
        #expect(s.rows[1].action == .acceptProposal(proposal))
        await s.accept(s.rows[1])?.value
        #expect(mail.created == ["Family/Trips"])
        #expect(api.feedbacks.map(\.decision) == [.acceptNew(proposal)])
    }

    @Test func anyEmailCanBeMovedToTheTrashWhateverWasRecommended() async {
        let s = await started()
        #expect(s.rows.first?.title == "Family")
        await s.moveToTrash()?.value
        #expect(mail.movedToTrash == [["m1@example.test"]])
        #expect(api.feedbacks.map(\.decision) == [.delete])
    }

    @Test func movingToTheTrashDoesNotWaitForTheModel() async {
        let (s, startTask) = await startedWhileTheModelThinks()
        let finished = watchFinish(s)
        await s.moveToTrash()?.value
        #expect(mail.movedToTrash.count == 1)
        #expect(finished())
        #expect(api.feedbacks.isEmpty)
        await releaseTheModel(startTask)
        #expect(api.feedbacks.map(\.decision) == [.delete])
    }

    @Test func whenMailDoesNotMoveItNothingIsLearnedAndTheWindowSaysWhy() async {
        api.suggestion = Self.deleteSuggestion()
        mail.trashResult = .notAllowed
        let s = await started()
        let finished = watchFinish(s)
        await s.acceptHighlighted()?.value
        #expect(api.feedbacks.isEmpty)
        #expect(!finished())
        #expect(s.notice?.contains("Accessibility") == true)
        // The owner can fix the permission and try again.
        mail.trashResult = .trashed
        await s.acceptHighlighted()?.value
        #expect(api.feedbacks.map(\.decision) == [.delete])
    }

    @Test(arguments: [TrashResult.selectionChanged, .notInTrash, .systemEventsNotAllowed, .commandUnavailable])
    func otherProblemsAreReported(result: TrashResult) async {
        mail.trashResult = result
        let s = await started()
        await s.moveToTrash()?.value
        #expect(api.feedbacks.isEmpty)
        #expect(s.notice == RecommenderSession.trashProblem(result))
        #expect(s.canTrash)
    }

    @Test func eachReasonTheDeleteWasNotClickedHasItsOwnAdvice() {
        let advice = [TrashResult.notAllowed, .systemEventsNotAllowed, .commandUnavailable].map {
            RecommenderSession.trashProblem($0) ?? ""
        }
        #expect(advice[0].contains("Accessibility") && advice[0].contains("add the app again"))
        #expect(advice[1].contains("Automation"))
        #expect(advice[2].contains("Delete command was not available"))
        #expect(advice.allSatisfy { $0.hasPrefix("Not moved to the Trash") })
        #expect(RecommenderSession.menuAdvice(.commandUnavailable) == nil)
    }

    @Test func anEmailInTheTrashAlreadyIsNeverOfferedForDeletion() async {
        mail.trashLookup = TrashLookup(inTrash: true, messages: Self.trashed)
        api.suggestion = Self.deleteSuggestion()
        let s = await started()
        #expect(!s.canTrash)
        #expect(api.suggestOptions.first?.allowDelete == false)
        #expect(api.suggestOptions.first?.trash == [])
        #expect(s.rows.first?.title == "Family")
        #expect(!s.rows.contains { $0.action == .trash })
        #expect(s.moveToTrash() == nil)
        #expect(mail.movedToTrash.isEmpty)
    }

    @Test func withoutATrashNothingCanBeDeleted() async {
        mail.trashLookup = TrashLookup(found: false)
        let s = await started()
        #expect(!s.canTrash)
        #expect(api.suggestOptions.first?.allowDelete == false)
        #expect(s.moveToTrash() == nil)
    }

    @Test func whenMailRefusesBecauseOfTheTrashTheActionIsTurnedOff() async {
        mail.trashResult = .alreadyInTrash
        let s = await started()
        await s.moveToTrash()?.value
        #expect(!s.canTrash)
        #expect(s.notice?.contains("erase it for good") == true)
    }

    @Test func aFailedTrashReadOnlyMeansNoSuggestionToDelete() async {
        mail.trashLookupError = MailError.timedOut
        let s = await started()
        #expect(api.suggestOptions.first?.allowDelete == false)
        #expect(s.canTrash)
    }

    @Test func emailsMailCannotIdentifyCannotBeMovedToTheTrash() async {
        mail.selectionResult = MailSelection(
            messages: [MailMessageRef(id: 1, mailbox: "INBOX", account: "Google")],
            latest: Email(from: "a", subject: "s", body: "b"))
        let s = await started()
        #expect(!s.canTrash)
        #expect(mail.trashLookups.isEmpty)
        #expect(s.moveToTrash() == nil)
    }

    @Test func aTrashedEmailWhoseDecisionIsNotLearnedSaysSo() async {
        api.feedbackError = ServiceError.unreachable
        let s = await started()
        await s.moveToTrash()?.value
        #expect(mail.movedToTrash.count == 1)
        #expect(s.notice?.hasPrefix("Moved to the Trash. This decision was not learned") == true)
    }
}
