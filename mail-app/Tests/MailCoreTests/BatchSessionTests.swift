// The batch window's state (specs/004-batch-recommendations), against a fake Mail and a fake
// service. Synthetic emails only.
import Foundation
import Testing

@testable import MailCore

@MainActor
struct BatchSessionTests {
    let mail = FakeMail()
    let api = FakeAPI()
    let backend = FakeBackend()

    static let lunch = Email(from: "Dad <dad@example.test>", subject: "Sunday lunch", body: "See you at noon")
    static let baby = Email(from: "Clinic <clinic@example.test>", subject: "Baby check-up", body: "Friday 10:00")
    static let shop = Email(from: "Shop <deals@shop.example.test>", subject: "Deals 4", body: "Shoes on sale")
    static let porto = Email(from: "Air <trips@air.example.test>", subject: "Flight to Porto", body: "Confirmed")
    static let porto2 = Email(from: "Hotel <stay@hotel.example.test>", subject: "Hotel in Porto", body: "Booked")
    static let empty = Email(from: "Nobody <no@example.test>", subject: "", body: "")

    /// A batch of these emails, ids m1, m2, … in this order (newest first).
    private func opening(_ emails: [Email], total: Int? = nil) -> MailOpening {
        let refs = emails.enumerated().map { i, email in
            MailMessageRef(
                id: i + 1, mailbox: "[Gmail]/All Mail", account: "Google", date: Double(100 - i),
                messageId: "m\(i + 1)", from: email.from, subject: email.subject)
        }
        for (ref, email) in zip(refs, emails) { mail.emails[ref.messageId!] = email }
        return MailOpening(
            selection: MailSelection(total: total ?? emails.count, messages: refs, latest: nil),
            accounts: mail.accounts, labels: AccountLabels(mailboxes: mail.mailboxes), viewed: ["INBOX"])
    }

    private func started(_ emails: [Email], total: Int? = nil, keepInInbox: Bool = false) async -> BatchSession {
        let s = BatchSession(mail: mail, api: api, backend: backend, keepInInbox: keepInInbox)
        await s.start(with: opening(emails, total: total)).value
        return s
    }

    private func suggest(_ email: Email, _ id: String, _ category: String, action: SuggestedAction = .file) {
        api.bySubject[email.subject] = Suggestion(suggestionId: id, action: action, category: category)
    }

    private func id(_ n: Int) -> String { "m:m\(n)" }

    /// Two emails: one for Family, and a newsletter recommended for the Trash.
    private func startedWithATrashRecommendation() async -> BatchSession {
        mail.trashLookups2 = TrashLookups(found: true)
        suggest(Self.lunch, "S1", "Family")
        suggest(Self.shop, "S2", "Gadgets", action: .delete)
        return await started([Self.lunch, Self.shop])
    }

    /// Starts a batch whose first recommendation is held until `api.openGate()`.
    private func startedHeld(_ emails: [Email]) async -> (BatchSession, Task<Void, Never>) {
        api.holdSuggestion = true
        let s = BatchSession(mail: mail, api: api, backend: backend)
        let started = s.start(with: opening(emails))
        while !api.suggestStarted { await Task.yield() }
        return (s, started)
    }

    private func feedback(_ suggestionId: String) -> FeedbackDecision? {
        api.feedbacks.first { $0.id == suggestionId }?.decision
    }

    private func run(_ task: Task<Void, Never>?, _ s: BatchSession) async {
        await task?.value
        await s.settle()
    }

    // MARK: Opening

    @Test func opensWithEveryRowAndRecommendsEachEmailOnItsOwn() async {
        suggest(Self.lunch, "S1", "Family")
        suggest(Self.baby, "S2", "Family/Baby")
        let s = await started([Self.lunch, Self.baby], total: 5)
        #expect(s.stage == .ready)
        #expect(s.rows.map(\.subject) == ["Sunday lunch", "Baby check-up"])
        #expect(s.leftOut == 3)
        #expect(s.rows.map(\.recommended?.title) == ["Family", "Family/Baby"])
        #expect(s.readyCount == 2)
        #expect(api.suggestCalls.map(\.subject) == ["Sunday lunch", "Baby check-up"])
        #expect(mail.trashLookupCalls.count == 1)
        #expect(mail.touched.isEmpty)
    }

    @Test func aSelectionAcrossAccountsIsBlocked() async {
        var batch = opening([Self.lunch, Self.baby])
        let refs = batch.selection.messages
        let other = MailMessageRef(id: 9, mailbox: "INBOX", account: "iCloud", messageId: "x")
        batch = MailOpening(
            selection: MailSelection(messages: [refs[0], other], latest: nil), accounts: mail.accounts,
            labels: batch.labels, viewed: [])
        let s = BatchSession(mail: mail, api: api, backend: backend)
        await s.start(with: batch).value
        #expect(s.stage == .blocked(.unsupportedSelection))
        #expect(api.suggestCalls.isEmpty)
    }

    @Test func eachRequestIsTheOneTheSingleWindowSendsForThatEmail() async {
        // SC-006: the same email gets the same request, whether alone or in a batch.
        mail.selectionResult = MailSelection(
            messages: [MailMessageRef(id: 1, mailbox: "INBOX", account: "Google", messageId: "m1")],
            latest: Self.baby)
        let single = RecommenderSession(mail: mail, api: api, backend: backend)
        await single.start().value
        let alone = (api.suggestCalls.last!, api.suggestOptions.last!)
        _ = await started([Self.lunch, Self.baby])
        let inBatch = (api.suggestCalls.last!, api.suggestOptions.last!)
        #expect(alone.0 == inBatch.0)
        #expect(alone.1.allowDelete == inBatch.1.allowDelete)
        #expect(alone.1.trash == inBatch.1.trash)
    }

    // MARK: Story 1: approve all

    @Test func approveAllFilesEachEmailUnderItsOwnLabelAndLearnsEach() async {
        suggest(Self.lunch, "S1", "Family")
        suggest(Self.baby, "S2", "Family/Baby")
        suggest(Self.porto, "S3", "Family")
        let s = await started([Self.lunch, Self.baby, Self.porto])
        var finished = false
        s.onFinish = { finished = true }
        await run(s.approveAll(), s)
        #expect(mail.filed.map(\.target) == ["Family", "Family/Baby"])
        #expect(mail.filed[0].items.map(\.id) == [1001, 1003])
        #expect(mail.batchArchived.count == 1)
        #expect(Set(mail.batchArchived[0]) == ["m1", "m2", "m3"])
        #expect(feedback("S1") == .confirm && feedback("S2") == .confirm && feedback("S3") == .confirm)
        #expect(s.rows.allSatisfy { $0.state == .done })
        #expect(s.rows[1].outcome == "Filed in Family/Baby")
        #expect(mail.touched == ["m1", "m2", "m3"])
        #expect(finished)
    }

    @Test func approveAllLeavesWaitingRowsAlone() async {
        let (s, started) = await startedHeld([Self.lunch, Self.baby])
        #expect(s.approveAll() == nil)
        #expect(s.rows.allSatisfy { $0.state == .pending })
        api.openGate()
        await started.value
        #expect(mail.touched.isEmpty)
        #expect(api.feedbacks.isEmpty)
    }

    @Test func approveAllLeavesOutSkippedRowsAndRowsWithoutARecommendation() async {
        suggest(Self.lunch, "S1", "Family")
        suggest(Self.baby, "S2", "Family/Baby")
        let s = await started([Self.lunch, Self.baby, Self.empty])
        #expect(s.rows[2].recommendation == .unavailable("This email has no text to go on. Choose a label for it."))
        s.highlight(id(2))
        s.toggleSkip()
        var finished = false
        s.onFinish = { finished = true }
        await run(s.approveAll(), s)
        #expect(mail.touched == ["m1"])
        #expect(s.rows[1].skipped && s.rows[1].state == .ready)
        #expect(!finished)
    }

    @Test func movingToTheTrashInApproveAllAsksFirst() async {
        let s = await startedWithATrashRecommendation()
        #expect(s.rows[1].recommended == .trash)
        #expect(s.approveAll() == nil)
        #expect(s.confirmation?.fileCount == 1 && s.confirmation?.trashCount == 1)
        #expect(mail.touched.isEmpty)
        await run(s.confirm(), s)
        #expect(mail.batchTrashed == [["m2"]])
        #expect(feedback("S2") == .delete)
        #expect(feedback("S1") == .confirm)
        #expect(s.rows[1].outcome == "Moved to the Trash")
    }

    @Test func cancellingTheConfirmationChangesNothing() async {
        let s = await startedWithATrashRecommendation()
        s.approveAll()
        s.cancelConfirmation()
        await s.settle()
        #expect(mail.touched.isEmpty && api.feedbacks.isEmpty)
        #expect(s.rows.allSatisfy { $0.state == .ready })
    }

    @Test func aNewLabelForTwoEmailsIsCreatedOnceAndLearnedForBoth() async {
        let proposal = NewCategory(parent: nil, name: "Trip Porto")
        api.bySubject[Self.porto.subject] = Suggestion(
            suggestionId: "S1", category: "Trip Porto", isNew: true, newCategory: proposal)
        api.bySubject[Self.porto2.subject] = Suggestion(
            suggestionId: "S2", category: "Trip Porto", isNew: true, newCategory: proposal)
        let s = await started([Self.porto, Self.porto2])
        await run(s.approveAll(), s)
        #expect(mail.created == ["Trip Porto"])
        #expect(mail.filed.count == 1 && mail.filed[0].items.count == 2)
        #expect(feedback("S1") == .confirm)
        #expect(feedback("S2") == nil)
        #expect(feedback("S2-fresh1") == .choose("Trip Porto"))
    }

    @Test func aFailedLabelLeavesTheOtherLabelsFiled() async {
        suggest(Self.lunch, "S1", "Family")
        suggest(Self.baby, "S2", "Gadgets")
        mail.fileFailsFor = ["Gadgets"]
        let s = await started([Self.lunch, Self.baby])
        await run(s.approveAll(), s)
        #expect(s.rows[0].state == .done)
        #expect(s.rows[1].state == .problem)
        #expect(s.rows[1].notice?.hasPrefix("Not filed:") == true)
        #expect(feedback("S1") == .confirm && feedback("S2") == nil)
    }

    @Test func archiveThatFailsLeavesTheEmailsLabelledWithANotice() async {
        suggest(Self.lunch, "S1", "Family")
        suggest(Self.baby, "S2", "Family")
        mail.archiveOutcome = ArchiveOutcome(result: .selectionChanged)
        var finished = false
        let s = await started([Self.lunch, Self.baby])
        s.onFinish = { finished = true }
        await run(s.approveAll(), s)
        #expect(s.rows.allSatisfy { $0.state == .done })
        #expect(s.rows[0].notice == MailAdvice.batchArchive(.selectionChanged))
        #expect(feedback("S1") == .confirm)
        #expect(!finished)
    }

    @Test func keepingInTheInboxFilesWithoutArchiving() async {
        suggest(Self.lunch, "S1", "Family")
        suggest(Self.baby, "S2", "Family")
        let s = await started([Self.lunch, Self.baby], keepInInbox: true)
        await run(s.approveAll(), s)
        #expect(mail.filed[0].items.map(\.mode) == [.copy, .copy])
        #expect(mail.batchArchived.isEmpty)
    }

    // MARK: Story 2: one at a time

    @Test func acceptingOneRowFilesOnlyThatEmail() async {
        suggest(Self.lunch, "S1", "Family")
        suggest(Self.baby, "S2", "Family/Baby")
        mail.selectionResult = MailSelection(
            messages: [MailMessageRef(id: 99, mailbox: "INBOX", account: "Google", messageId: "outside")],
            latest: nil)
        let s = await started([Self.lunch, Self.baby])
        s.highlight(id(2))
        await run(s.acceptScope(), s)
        #expect(mail.touched == ["m2"])
        #expect(feedback("S2") == .confirm && feedback("S1") == nil)
        #expect(s.rows[0].state == .ready && s.rows[1].state == .done)
    }

    @Test func choosingAnotherLabelForOneRowIsACorrection() async {
        suggest(Self.lunch, "S1", "Family")
        let s = await started([Self.lunch, Self.baby])
        s.openPicker(query: "gadg")
        #expect(s.pickerRows.map(\.title) == ["Gadgets", "gadg"])
        await run(s.choosePickerHighlighted(), s)
        #expect(s.pickerScope == nil)
        #expect(mail.filed.map(\.target) == ["Gadgets"])
        #expect(feedback("S1") == .choose("Gadgets"))
    }

    @Test func thePickerForOneRowShowsItsRecommendationFirst() async {
        suggest(Self.lunch, "S1", "Gadgets")
        let s = await started([Self.lunch, Self.baby])
        s.openPicker()
        #expect(s.pickerRow?.id == id(1))
        #expect(s.pickerRows.first?.title == "Gadgets")
        #expect(s.pickerRows.first?.section == .recommended)
    }

    @Test func movingOneRowToTheTrashNeedsNoConfirmation() async {
        mail.trashLookups2 = TrashLookups(found: true)
        suggest(Self.lunch, "S1", "Family")
        let s = await started([Self.lunch, Self.baby])
        await run(s.moveScopeToTrash(), s)
        #expect(s.confirmation == nil)
        #expect(mail.batchTrashed == [["m1"]])
        #expect(feedback("S1") == .delete)
    }

    @Test func anEmailInTheTrashAlreadyIsNeverMovedThere() async {
        mail.trashLookups2 = TrashLookups(found: true, inTrashIds: ["m1"])
        let s = await started([Self.lunch, Self.baby])
        #expect(!s.canTrash(s.rows[0]) && s.canTrash(s.rows[1]))
        await run(s.moveScopeToTrash(), s)
        #expect(mail.batchTrashed.isEmpty)
        #expect(s.notice == MailAdvice.trash(.alreadyInTrash))
        #expect(api.suggestOptions.first?.allowDelete == false)
    }

    @Test func aRowDecidedBeforeItsRecommendationIsLearnedWhenItArrives() async {
        suggest(Self.lunch, "S1", "Family")
        suggest(Self.baby, "S2", "Family/Baby")
        suggest(Self.porto, "S3", "Gadgets")
        let (s, started) = await startedHeld([Self.lunch, Self.baby, Self.porto])
        s.highlight(id(2))
        s.openPicker(query: "Gadgets")
        let filing = s.choosePickerHighlighted()
        await filing?.value
        #expect(mail.filed.map(\.target) == ["Gadgets"])
        #expect(s.rows[1].state == .applied)
        api.openGate()
        await started.value
        await s.settle()
        // The decided row's recommendation is made last.
        #expect(api.suggestCalls.map(\.subject) == ["Sunday lunch", "Flight to Porto", "Baby check-up"])
        #expect(feedback("S2") == .choose("Gadgets"))
        #expect(s.rows[1].state == .done)
    }

    @Test func closingLeavesUndecidedEmailsAloneAndLearnsNothingForThem() async {
        suggest(Self.lunch, "S1", "Family")
        let (s, started) = await startedHeld([Self.lunch, Self.baby, Self.porto])
        s.close()
        api.openGate()
        await started.value
        await s.settle()
        #expect(mail.touched.isEmpty)
        #expect(api.feedbacks.isEmpty)
        #expect(api.suggestCalls.count == 1)
    }

    @Test func anEmailThatIsGoneCannotBeAppliedAndTeachesNothing() async {
        suggest(Self.lunch, "S1", "Family")
        mail.gone = ["m2"]
        let s = await started([Self.lunch, Self.baby])
        #expect(s.rows[1].state == .problem)
        #expect(s.rows[1].notice == "This email can no longer be found in Mail.")
        s.highlight(id(2))
        s.openPicker(query: "Family")
        await run(s.choosePickerHighlighted(), s)
        #expect(mail.touched.isEmpty)
        #expect(s.rows[1].state == .problem)
    }

    @Test func filedButNotLearnedSaysSo() async {
        suggest(Self.lunch, "S1", "Family")
        api.feedbackError = ServiceError.unreachable
        let s = await started([Self.lunch, Self.baby])
        await run(s.acceptScope(), s)
        #expect(s.rows[0].state == .done)
        #expect(s.rows[0].notice?.hasPrefix("Not learned:") == true)
    }

    @Test func aLabelDeletedWhileTheWindowIsOpenIsCreatedAgain() async {
        suggest(Self.lunch, "S1", "Gadgets")
        let s = await started([Self.lunch, Self.baby])
        mail.mailboxes.removeAll { $0 == "Gadgets" }
        mail.failUnlessExists = true
        await run(s.acceptScope(), s)
        #expect(mail.created == ["Gadgets"])
        #expect(mail.filed.map(\.target) == ["Gadgets"])
        #expect(feedback("S1") == .confirm)
    }

    // MARK: Story 3: some of them

    @Test func theScopeIsTheMarkedRowsElseTheHighlightedOne() async {
        let s = await started([Self.lunch, Self.baby, Self.porto])
        #expect(s.scope == [id(1)])
        s.toggleMark(id(2))
        s.toggleMark(id(3))
        #expect(s.scope == [id(2), id(3)])
        s.toggleMarkAll()
        #expect(s.rows.allSatisfy { $0.marked })
        s.toggleMarkAll()
        #expect(s.rows.allSatisfy { !$0.marked })
    }

    @Test func acceptingMarkedRowsAppliesEachOnesOwnRecommendation() async {
        suggest(Self.lunch, "S1", "Family")
        suggest(Self.baby, "S2", "Family/Baby")
        suggest(Self.porto, "S3", "Gadgets")
        let s = await started([Self.lunch, Self.baby, Self.porto])
        s.toggleMark(id(1))
        s.toggleMark(id(3))
        await run(s.acceptScope(), s)
        #expect(mail.touched == ["m1", "m3"])
        #expect(Set(mail.filed.map(\.target)) == ["Family", "Gadgets"])
        #expect(s.rows[1].state == .ready)
    }

    @Test func oneLabelForMarkedRowsConfirmsWhereItWasRecommended() async {
        suggest(Self.lunch, "S1", "Family")
        suggest(Self.baby, "S2", "Family/Baby")
        let s = await started([Self.lunch, Self.baby])
        s.toggleMarkAll()
        s.openPicker(query: "Family")
        #expect(s.pickerRow == nil)
        let family = s.pickerRows.first { $0.title == "Family" }!
        await run(s.choose(family), s)
        #expect(mail.filed.count == 1 && mail.filed[0].items.count == 2)
        #expect(feedback("S1") == .confirm)
        #expect(feedback("S2") == .choose("Family"))
    }

    @Test func aTypedNewLabelForMarkedRowsIsCreatedOnceAndLearnedForEach() async {
        suggest(Self.lunch, "S1", "Family")
        suggest(Self.baby, "S2", "Family")
        let s = await started([Self.lunch, Self.baby])
        s.toggleMarkAll()
        s.openPicker(query: "Family/Weekends")
        #expect(s.pickerRows.last?.action == .createTyped("Family/Weekends"))
        await run(s.choose(s.pickerRows.last!), s)
        #expect(mail.created == ["Family/Weekends"])
        #expect(feedback("S1") == .acceptNew(NewCategory(parent: "Family", name: "Weekends")))
        #expect(feedback("S2-fresh1") == .choose("Family/Weekends"))
    }

    @Test func markedRowsGoToTheTrashOnlyAfterConfirming() async {
        mail.trashLookups2 = TrashLookups(found: true)
        let s = await started([Self.lunch, Self.baby, Self.porto])
        s.toggleMark(id(1))
        s.toggleMark(id(2))
        #expect(s.moveScopeToTrash() == nil)
        #expect(s.confirmation?.trashCount == 2 && s.confirmation?.fileCount == 0)
        await run(s.confirm(), s)
        #expect(mail.batchTrashed == [["m1", "m2"]])
        #expect(mail.touched == ["m1", "m2"])
    }

    @Test func doneRowsCannotBeActedOnAgain() async {
        suggest(Self.lunch, "S1", "Family")
        let s = await started([Self.lunch, Self.baby])
        await run(s.acceptScope(), s)
        s.highlight(id(1))
        #expect(s.scope.isEmpty)
        #expect(s.acceptScope() == nil)
        s.toggleMark(id(1))
        #expect(!s.rows[0].marked)
        #expect(mail.filed.count == 1)
    }
}
