import Foundation
import Testing

@testable import MailCore

struct LabelsTests {
    @Test func normaliseMatchesTheService() {
        #expect(LabelText.normalise("  Család   Baba ") == "csalad baba")
        #expect(LabelText.pathKey("Család/Számlák") == "csalad/szamlak")
    }

    @Test func systemFoldersAreExcluded() {
        let catalog = LabelCatalog(
            mailboxes: [
                "INBOX", "[Gmail]", "[Gmail]/All Mail", "[Gmail]/Spam", "[Google Mail]/Trash", "Sent Messages",
                "Drafts", "Deleted Messages", "Junk", "Archive", "Notes", "Family",
            ])
        #expect(catalog.entries.map(\.path) == ["Family"])
    }

    @Test func systemFoldersInAnyLanguageAreExcludedByTheirParent() {
        let catalog = LabelCatalog(mailboxes: ["[Gmail]/Összes levél", "[Gmail]/Kuka", "Family"])
        #expect(catalog.entries.map(\.path) == ["Family"])
    }

    @Test func twoLevelLabelsMapDirectly() {
        let catalog = LabelCatalog(mailboxes: ["Family", "Family/Baby"])
        #expect(catalog.entries.map(\.path) == ["Family", "Family/Baby"])
        #expect(catalog.entry(forPath: "family/baby")?.mailbox == "Family/Baby")
    }

    @Test func deeperLabelsMapBackToTheirExactMailbox() {
        let catalog = LabelCatalog(mailboxes: ["Work", "Work/Clients", "Work/Clients/Acme/2026"])
        let entry = catalog.entry(forPath: "Work/Clients \u{203A} Acme \u{203A} 2026")
        #expect(entry?.mailbox == "Work/Clients/Acme/2026")
        #expect(entry?.existsInAccount == true)
    }

    @Test func impliedParentsAreAddedAndMarked() {
        let catalog = LabelCatalog(mailboxes: ["Travel/Lisbon"])
        #expect(catalog.entries.map(\.path) == ["Travel", "Travel/Lisbon"])
        #expect(catalog.entry(forPath: "Travel")?.existsInAccount == false)
    }

    @Test func labelsThatCollideAfterFoldingStaySeparate() {
        let catalog = LabelCatalog(mailboxes: ["Csalad", "Család", "Család/Baba"])
        #expect(catalog.entries.count == 3)
        #expect(Set(catalog.entries.map(\.key)).count == 3)
        #expect(catalog.entry(forPath: "Csalad")?.mailbox == "Csalad")
        #expect(catalog.entry(forPath: "Család (2)")?.mailbox == "Család")
        #expect(catalog.entry(forPath: "Család (2)/Baba")?.mailbox == "Család/Baba")
    }

    @Test func longNamesFitTheServiceLimit() {
        let long = String(repeating: "é", count: 80)
        let catalog = LabelCatalog(mailboxes: [long, long + "x"])
        #expect(catalog.entries.count == 2)
        for entry in catalog.entries {
            #expect(entry.path.utf16.count <= 60)
        }
        #expect(Set(catalog.entries.map(\.key)).count == 2)
        #expect(catalog.entries[0].mailbox == long)
    }

    @Test func emptySegmentsAreIgnored() {
        let catalog = LabelCatalog(mailboxes: ["/", "A//B", " "])
        #expect(catalog.entries.map(\.path) == ["A", "A/B"])
    }

    @Test func limitKeepsTheRestAvailableByHand() {
        let names = (0..<305).map { String(format: "Label %03d", $0) }
        let catalog = LabelCatalog(mailboxes: names)
        #expect(catalog.entries.count == 305)
        #expect(catalog.considered.count == 300)
        #expect(catalog.notConsidered == 5)
        #expect(!catalog.isConsidered(catalog.entries[304]))
    }

    @Test func filingRules() {
        #expect(Filing.mode(source: "INBOX", keepInInbox: false) == .move)
        #expect(Filing.mode(source: "Family", keepInInbox: false) == .copy)
        #expect(Filing.mode(source: "INBOX", keepInInbox: true) == .copy)
        // Folders: an email is in one folder, so it moves, unless a copy is to stay in the Inbox.
        #expect(Filing.mode(inInbox: true, keepInInbox: false, kind: .folders) == .move)
        #expect(Filing.mode(inInbox: true, keepInInbox: true, kind: .folders) == .copy)
        #expect(Filing.mode(inInbox: false, keepInInbox: true, kind: .folders) == .move)
        #expect(Filing.mode(inInbox: false, keepInInbox: false, kind: .gmail) == .copy)
        #expect(LabelSync.setName(address: "a@b.example") == "Gmail: a@b.example")
        #expect(LabelSync.setName(address: "a@b.example", kind: .folders) == "Mail: a@b.example")
        #expect(Filing.mode(source: "[Gmail]/All Mail", keepInInbox: false) == .copy)
        #expect(Filing.mode(source: "All Mail", keepInInbox: false) == .copy)
        #expect(Filing.mode(source: "[Gmail]/Összes levél", keepInInbox: false) == .copy)
    }

    @Test func typedNamesAreCleaned() {
        #expect(LabelText.cleanTyped("  Trips / Lisbon  ") == "Trips/Lisbon")
        #expect(LabelText.cleanTyped("   ") == nil)
        #expect(LabelText.cleanTyped("INBOX") == nil)
        #expect(LabelText.cleanTyped("[Gmail]/Mine") == nil)
    }

    @Test func newCategoryPlacement() {
        let catalog = LabelCatalog(mailboxes: ["Family"])
        #expect(catalog.newCategory(forMailbox: "Trips")?.category == NewCategory(parent: nil, name: "Trips"))
        #expect(catalog.newCategory(forMailbox: "Family/Baby")?.category.parent == "Family")
        #expect(catalog.newCategory(forMailbox: "Family/Baby")?.parentIsKnown == true)
        #expect(catalog.newCategory(forMailbox: "Trips/Lisbon")?.parentIsKnown == false)
        #expect(catalog.newCategory(forMailbox: "Family/A/B")?.category.name == "A \u{203A} B")
    }

    @Test func proposalMailboxUsesTheParentsExactName() {
        let catalog = LabelCatalog(mailboxes: ["Csalad", "Család"])
        #expect(catalog.mailbox(for: NewCategory(parent: "Család (2)", name: "Baba")) == "Család/Baba")
        #expect(catalog.mailbox(for: NewCategory(parent: nil, name: "Trips")) == "Trips")
    }
}

struct SyncPlanTests {
    private func catalog(_ names: String...) -> LabelCatalog { LabelCatalog(mailboxes: names) }

    @Test func addsWhatIsMissingParentsFirst() {
        let plan = SyncPlan(
            catalog: catalog("Family", "Family/Baby", "Gadgets"),
            existing: [CategoryItem(id: "1", path: "Family")])
        #expect(plan.add == ["Family/Baby", "Gadgets"])
        #expect(plan.remove.isEmpty)
        #expect(plan.orphaned.isEmpty)
    }

    @Test func removesLabelsWithoutLearningChildrenFirst() {
        let plan = SyncPlan(
            catalog: catalog("Gadgets"),
            existing: [
                CategoryItem(id: "p", path: "Old"),
                CategoryItem(id: "c", path: "Old/Child", parentId: "p"),
                CategoryItem(id: "g", path: "Gadgets"),
            ])
        #expect(plan.remove.map(\.id) == ["c", "p"])
    }

    @Test func keepsLearningOfRemovedLabelsAndReportsIt() {
        let plan = SyncPlan(
            catalog: catalog("Gadgets"),
            existing: [
                CategoryItem(id: "g", path: "Gadgets"),
                CategoryItem(id: "b", path: "Bills", exampleCount: 3),
            ])
        #expect(plan.remove.isEmpty)
        #expect(plan.orphaned.map(\.id) == ["b"])
    }

    @Test func keepsTheParentOfAnOrphan() {
        let plan = SyncPlan(
            catalog: catalog("Gadgets"),
            existing: [
                CategoryItem(id: "p", path: "Old"),
                CategoryItem(id: "c", path: "Old/Child", parentId: "p", exampleCount: 1),
            ])
        #expect(plan.remove.isEmpty)
        #expect(plan.orphaned.map(\.id) == ["c"])
    }

    @Test func matchesAcrossCaseAndAccents() {
        let plan = SyncPlan(catalog: catalog("Család"), existing: [CategoryItem(id: "1", path: "család")])
        #expect(plan.add.isEmpty)
        #expect(plan.remove.isEmpty)
    }
}

struct EmailTextTests {
    @Test func tidyCollapsesBlankSpace() {
        #expect(EmailText.tidy("a  b\r\n\r\n\r\n\n  c \n") == "a b\n\nc")
    }

    @Test func limitsMatchTheAPI() {
        let email = EmailText.prepared(
            Email(
                from: String(repeating: "f", count: 600),
                to: Array(repeating: String(repeating: "t", count: 600), count: 150),
                subject: String(repeating: "s", count: 3000),
                body: String(repeating: "word ", count: 40000)))
        #expect(email.from.count == 500)
        #expect(email.to?.count == 100)
        #expect(email.to?[0].count == 500)
        #expect(email.subject.count == 2000)
        #expect(email.body.utf16.count <= 50000)
    }

    @Test func clippingNeverSplitsACharacter() {
        let clipped = EmailText.clip(String(repeating: "🧾", count: 10), 5)
        #expect(clipped == "🧾🧾")
    }
}

struct BridgeJSONTests {
    @Test func outputIsAsciiAndRoundTrips() throws {
        struct Input: Codable, Equatable { let path: String }
        let text = try BridgeJSON.encode(Input(path: "Család/Számla 🧾"))
        #expect(text.utf8.allSatisfy { $0 < 0x80 })
        let parsed = try JSONDecoder().decode(Input.self, from: Data(text.utf8))
        #expect(parsed.path == "Család/Számla 🧾")
    }
}

struct FolderAccountTests {
    @Test func theAccountsOwnFoldersAreLeftOutWhateverTheyAreCalled() {
        let catalog = LabelCatalog(
            mailboxes: [
                "Beérkezett", "Beérkezett/Projects", "Beérkezett/Projects/Alpha", "Elküldött", "Elküldött/Old",
                "Törölt elemek", "Junk Email", "Conversation History", "Bills", "Bills/2026",
            ],
            system: ["Beérkezett", "Elküldött", "Törölt elemek"], inbox: "Beérkezett")
        #expect(
            catalog.entries.map(\.mailbox) == [
                "Beérkezett/Projects", "Beérkezett/Projects/Alpha", "Bills", "Bills/2026",
            ])
        // Folders inside the Inbox stand on their own: the Inbox is not a category.
        #expect(catalog.entries.first?.path == "Beérkezett\(LabelText.deepSeparator)Projects")
        #expect(catalog.entries.allSatisfy { $0.existsInAccount })
        #expect(!catalog.entries.contains { $0.path.contains("/") && $0.path.hasPrefix("Beérkezett") })
    }

    @Test func foldersInsideAnInboxNamedInboxStandOnTheirOwnToo() {
        let catalog = LabelCatalog(mailboxes: ["INBOX", "INBOX/Receipts", "Archive"])
        #expect(catalog.entries.map(\.mailbox) == ["INBOX/Receipts"])
        #expect(catalog.entries.first?.existsInAccount == true)
    }
}
