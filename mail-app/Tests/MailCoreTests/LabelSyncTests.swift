// Labels moved or renamed in the account keep their category, and so their learning (FR-025).
// Synthetic labels only.
import Foundation
import Testing

@testable import MailCore

struct MovePlanTests {
    private func catalog(_ names: String...) -> LabelCatalog { LabelCatalog(mailboxes: names) }
    private func moves(_ plan: MovePlan) -> [String] { plan.ordered.map { "\($0.item.id)>\($0.to)" } }

    private let family = CategoryItem(id: "f", path: "Family")
    private let baby = CategoryItem(id: "b", path: "Family/Baby", parentId: "f", exampleCount: 3)

    @Test func aChildMovedToAnotherParentKeepsItsCategory() {
        let plan = MovePlan(
            catalog: catalog("Family", "Kids", "Kids/Baby"),
            existing: [family, baby, CategoryItem(id: "k", path: "Kids")])
        #expect(moves(plan) == ["b>Kids/Baby"])
        #expect(plan.unmatched.isEmpty)
        #expect(plan.unclaimed.isEmpty)
    }

    @Test func aChildMovedToANewParentKeepsItsCategory() {
        let plan = MovePlan(catalog: catalog("Family", "Kids", "Kids/Baby"), existing: [family, baby])
        #expect(moves(plan) == ["b>Kids/Baby"])
        // The new parent is added by the diff, as any new label.
        #expect(plan.unclaimed.map(\.path) == ["Kids"])
    }

    @Test func aChildMovedOutOfItsParentKeepsItsCategory() {
        let plan = MovePlan(catalog: catalog("Family", "Baby"), existing: [family, baby])
        #expect(moves(plan) == ["b>Baby"])
    }

    @Test func aLabelMovedUnderAParentKeepsItsCategory() {
        let plan = MovePlan(
            catalog: catalog("Family", "Family/Baby"),
            existing: [family, CategoryItem(id: "b", path: "Baby", exampleCount: 2)])
        #expect(moves(plan) == ["b>Family/Baby"])
    }

    @Test func aMoveMatchesAcrossCaseAndAccents() {
        let plan = MovePlan(
            catalog: catalog("Család", "Gyerekek", "Gyerekek/Baba"),
            existing: [
                CategoryItem(id: "c", path: "Család"), CategoryItem(id: "g", path: "Gyerekek"),
                CategoryItem(id: "b", path: "Család/baba", parentId: "c", exampleCount: 1),
            ])
        #expect(moves(plan) == ["b>Gyerekek/Baba"])
    }

    @Test func aRenamedParentBringsItsChildren() {
        let plan = MovePlan(
            catalog: catalog("Home", "Home/Baby", "Home/School"),
            existing: [
                family, baby, CategoryItem(id: "s", path: "Family/School", parentId: "f", exampleCount: 1),
            ])
        // One rename; the children's paths follow without a move of their own.
        #expect(moves(plan) == ["f>Home"])
        #expect(plan.unmatched.isEmpty)
        #expect(plan.unclaimed.isEmpty)
    }

    @Test func aRenamedParentWhoseChildChangedTooLeavesTheChildForTheEmails() {
        let plan = MovePlan(
            catalog: catalog("Home", "Home/Baby", "Home/School", "Home/Trips"),
            existing: [
                family, baby, CategoryItem(id: "s", path: "Family/School", parentId: "f"),
                CategoryItem(id: "o", path: "Family/Holidays", parentId: "f", exampleCount: 4),
            ])
        #expect(moves(plan) == ["f>Home"])
        #expect(plan.unmatched.map(\.path) == ["Home/Holidays"])
        #expect(plan.unclaimed.map(\.path) == ["Home/Trips"])
    }

    @Test func aParentIsNotRenamedOnTooLittleEvidence() {
        // Only one of three children is under the new parent: that child moved, the parent went.
        let plan = MovePlan(
            catalog: catalog("Kids", "Kids/Baby"),
            existing: [
                family, baby, CategoryItem(id: "s", path: "Family/School", parentId: "f"),
                CategoryItem(id: "t", path: "Family/Trips", parentId: "f"),
            ])
        #expect(moves(plan) == ["b>Kids/Baby"])
    }

    @Test func aLabelWithChildrenMovedUnderAParentMovesItsChildrenFirst() {
        let plan = MovePlan(
            catalog: catalog("Family", "Family/Baby", "Family/Baby/Doctor"),
            existing: [
                family, CategoryItem(id: "b", path: "Baby", exampleCount: 1),
                CategoryItem(id: "d", path: "Baby/Doctor", parentId: "b", exampleCount: 1),
            ])
        #expect(moves(plan) == ["d>Family/Baby \u{203A} Doctor", "b>Family/Baby"])
    }

    @Test func aParentGoesToTheTopLevelBeforeAnythingMovesUnderIt() {
        let plan = MovePlan(
            catalog: catalog("Family", "Baby", "Baby/Doctor"),
            existing: [
                family, baby,
                CategoryItem(id: "d", path: "Family/Baby \u{203A} Doctor", parentId: "f", exampleCount: 1),
            ])
        #expect(moves(plan) == ["b>Baby", "d>Baby/Doctor"])
    }

    @Test func namesThatAreNotUniqueAreLeftAlone() {
        let plan = MovePlan(
            catalog: catalog("Bills", "Bills/Receipts", "Trips", "Trips/Receipts"),
            existing: [
                CategoryItem(id: "w", path: "Work"), CategoryItem(id: "h", path: "Home"),
                CategoryItem(id: "wr", path: "Work/Receipts", parentId: "w", exampleCount: 1),
                CategoryItem(id: "hr", path: "Home/Receipts", parentId: "h", exampleCount: 1),
            ])
        #expect(plan.moves.isEmpty)
        #expect(Set(plan.unmatched.map(\.id)) == ["wr", "hr"])
    }

    @Test func aRenamedLabelIsLeftForTheEmails() {
        let plan = MovePlan(catalog: catalog("Family", "Family/Newborn"), existing: [family, baby])
        #expect(plan.moves.isEmpty)
        #expect(plan.unmatched.map(\.id) == ["b"])
        #expect(plan.unclaimed.map(\.path) == ["Family/Newborn"])
    }

    @Test func aRemovedLabelWithoutLearningIsNotLookedFor() {
        let plan = MovePlan(
            catalog: catalog("Family", "Family/Newborn"),
            existing: [family, CategoryItem(id: "b", path: "Family/Baby", parentId: "f")])
        #expect(plan.unmatched.isEmpty)
    }

    @Test func nothingChangedMeansNothingToDo() {
        let plan = MovePlan(catalog: catalog("Family", "Family/Baby"), existing: [family, baby])
        #expect(plan.moves.isEmpty)
        #expect(plan.unmatched.isEmpty)
        #expect(plan.unclaimed.isEmpty)
    }
}

struct LabelSyncTests {
    private let setName = LabelSync.setName(address: "owner@gmail.example")

    private func api(_ categories: [CategoryItem]) -> FakeAPI {
        let api = FakeAPI()
        api.sets = [CategorySetSummary(id: "set", name: setName)]
        api.categories["set"] = categories
        return api
    }

    private func paths(_ api: FakeAPI) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (api.categories["set"] ?? []).map { ($0.id, $0.path) })
    }

    private let family = CategoryItem(id: "f", path: "Family")
    private let baby = CategoryItem(id: "b", path: "Family/Baby", parentId: "f", exampleCount: 3)

    @Test func aMovedLabelTakesItsLearningAlong() async throws {
        let api = api([family, baby])
        let result = try await LabelSync.run(
            api: api, setName: setName, catalog: LabelCatalog(mailboxes: ["Family", "Kids", "Kids/Baby"]))
        let kids = try #require(api.categories["set"]?.first { $0.path == "Kids" })
        #expect(api.updates.map(\.id) == ["b"])
        #expect(api.updates.first?.parent == .under(kids.id))
        #expect(api.updates.first?.name == nil)
        #expect(paths(api)["b"] == "Kids/Baby")
        #expect(result.categories.first { $0.path == "Kids/Baby" }?.exampleCount == 3)
        #expect(result.orphaned.isEmpty)
        #expect(result.moved == 1)
        #expect(api.deletedCategories.isEmpty)
        #expect(!api.addedCategories.contains("Kids/Baby"))
    }

    @Test func aLabelMovedOutOfItsParentGoesToTheTopLevel() async throws {
        let api = api([family, baby])
        _ = try await LabelSync.run(api: api, setName: setName, catalog: LabelCatalog(mailboxes: ["Family", "Baby"]))
        #expect(api.updates.first?.parent == .topLevel)
        #expect(paths(api)["b"] == "Baby")
    }

    @Test func aRenamedParentIsRenamedInPlace() async throws {
        let api = api([family, baby])
        let result = try await LabelSync.run(
            api: api, setName: setName, catalog: LabelCatalog(mailboxes: ["Home", "Home/Baby"]))
        #expect(api.updates.count == 1)
        #expect(api.updates.first?.id == "f")
        #expect(api.updates.first?.name == "Home")
        #expect(api.updates.first?.parent == .keep)
        #expect(paths(api) == ["f": "Home", "b": "Home/Baby"])
        #expect(api.addedCategories.isEmpty)
        #expect(result.orphaned.isEmpty)
    }

    @Test func aRenamedLabelIsFoundByTheEmailsLearnedForIt() async throws {
        let api = api([family, baby])
        api.learned["b"] = [LearnedEmail(from: "desk@clinic.example.test", subject: "Check-up on Friday")]
        let mail = FakeMail()
        mail.held = ["Family/Newborn": ["Check-up on Friday"]]
        let result = try await LabelSync.run(
            api: api, setName: setName,
            catalog: LabelCatalog(mailboxes: ["Family", "Family/Newborn", "Gadgets"]),
            holding: { try await mail.holding($0, in: $1, account: "Google") })
        #expect(api.updates.map(\.id) == ["b"])
        #expect(api.updates.first?.name == "Newborn")
        #expect(api.updates.first?.parent == .keep)
        #expect(result.categories.first { $0.path == "Family/Newborn" }?.exampleCount == 3)
        #expect(result.orphaned.isEmpty)
        // Siblings are looked in first.
        #expect(mail.holdingCalls.first?.mailboxes == ["Family/Newborn", "Gadgets"])
    }

    @Test func aLabelReplacedByAnUnrelatedOneKeepsItsLearningApart() async throws {
        let api = api([family, baby])
        api.learned["b"] = [LearnedEmail(from: "desk@clinic.example.test", subject: "Check-up on Friday")]
        let mail = FakeMail()
        let result = try await LabelSync.run(
            api: api, setName: setName, catalog: LabelCatalog(mailboxes: ["Family", "Family/School"]),
            holding: { try await mail.holding($0, in: $1, account: "Google") })
        #expect(api.updates.isEmpty)
        #expect(result.orphaned.map(\.id) == ["b"])
        #expect(api.addedCategories == ["Family/School"])
    }

    @Test func emailsFoundInTwoNewLabelsAreNotEnoughToChoose() async throws {
        let api = api([family, baby])
        api.learned["b"] = [LearnedEmail(from: "desk@clinic.example.test", subject: "Check-up on Friday")]
        let mail = FakeMail()
        mail.held = ["Family/Newborn": ["Check-up on Friday"], "Family/Clinic": ["Check-up on Friday"]]
        let result = try await LabelSync.run(
            api: api, setName: setName,
            catalog: LabelCatalog(mailboxes: ["Family", "Family/Clinic", "Family/Newborn"]),
            holding: { try await mail.holding($0, in: $1, account: "Google") })
        #expect(api.updates.isEmpty)
        #expect(result.orphaned.map(\.id) == ["b"])
    }

    @Test func whenMailCannotLookTheLearningIsKeptAsBefore() async throws {
        let api = api([family, baby])
        api.learned["b"] = [LearnedEmail(from: "desk@clinic.example.test", subject: "Check-up on Friday")]
        let mail = FakeMail()
        mail.holdingError = MailError.timedOut
        let result = try await LabelSync.run(
            api: api, setName: setName, catalog: LabelCatalog(mailboxes: ["Family", "Family/Newborn"]),
            holding: { try await mail.holding($0, in: $1, account: "Google") })
        #expect(result.orphaned.map(\.id) == ["b"])
        #expect(result.categories.contains { $0.path == "Family/Newborn" })
    }

    @Test func mailIsOnlyAskedWhenALabelWithLearningIsMissing() async throws {
        let api = api([family, baby])
        let mail = FakeMail()
        _ = try await LabelSync.run(
            api: api, setName: setName, catalog: LabelCatalog(mailboxes: ["Family", "Family/Baby", "Gadgets"]),
            holding: { try await mail.holding($0, in: $1, account: "Google") })
        #expect(mail.holdingCalls.isEmpty)
        #expect(api.updates.isEmpty)
    }

    @Test func aMoveTheServiceRefusesFallsBackToKeepingTheOldCategory() async throws {
        let api = api([family, baby])
        api.refuseUpdates = ["b"]
        let result = try await LabelSync.run(
            api: api, setName: setName, catalog: LabelCatalog(mailboxes: ["Family", "Kids", "Kids/Baby"]))
        #expect(result.moved == 0)
        #expect(result.orphaned.map(\.id) == ["b"])
        #expect(result.categories.contains { $0.path == "Kids/Baby" })
    }

    @Test func aNewSetHasNothingToFollow() async throws {
        let api = FakeAPI()
        let result = try await LabelSync.run(
            api: api, setName: setName, catalog: LabelCatalog(mailboxes: ["Family", "Family/Baby"]))
        #expect(result.moved == 0)
        #expect(api.updates.isEmpty)
    }
}
