// The real client and session against the real service (with a stub model), run by tests/e2e.sh.
// Skipped otherwise. Synthetic data only.
import Foundation
import Testing

@testable import MailCore

private let liveURL = ProcessInfo.processInfo.environment["CATREC_TEST_BASE_URL"].flatMap(URL.init(string:))
private let redirectURL = ProcessInfo.processInfo.environment["CATREC_TEST_REDIRECT_URL"].flatMap(URL.init(string:))

@MainActor
@Suite(.serialized, .enabled(if: liveURL != nil))
struct LiveServiceTests {
    private func emailSelection(subject: String, body: String) -> MailSelection {
        MailSelection(
            messages: [MailMessageRef(id: 1, mailbox: "INBOX", account: "Live")],
            latest: Email(from: "Sender <sender@example.test>", to: ["owner@example.test"], subject: subject, body: body))
    }

    private func run(
        mail: FakeMail, client: ServiceClient, finishing: Bool = false
    ) async -> RecommenderSession {
        mail.accounts = [MailAccount(name: "Live", addresses: ["\(address)"])]
        let session = RecommenderSession(mail: mail, api: client, backend: FakeBackend())
        await session.start().value
        return session
    }

    private let address = "live-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))@example.test"

    @Test func wholeFlow() async throws {
        let client = try ServiceClient(baseURL: liveURL!)
        let mail = FakeMail()
        mail.mailboxes = [
            "INBOX", "[Gmail]/All Mail", "Család", "Family", "Family/Baby", "Finance", "Gadgets",
            "Work/Clients/Acme/2026",
        ]

        // First run imports the labels and recommends through the real pipeline.
        mail.selectionResult = emailSelection(subject: "Newborn check-up", body: "The baby sees the paediatrician on Friday.")
        var session = await run(mail: mail, client: client)
        #expect(session.stage == .ready)
        guard case .ready(let first) = session.recommendation else {
            Issue.record("no recommendation: \(session.recommendation)")
            return
        }
        #expect(first.category == "Family/Baby")
        #expect(session.rows.first?.title == "Family/Baby")

        let setName = LabelSync.setName(address: address)
        let setId = try #require(try await client.listSets().first { $0.name == setName }?.id)
        var detail = try await client.getSet(id: setId)
        #expect(detail.categories.contains { $0.path == "Work/Clients \u{203A} Acme \u{203A} 2026" })
        #expect(!detail.categories.contains { $0.path.contains("Gmail") || $0.path == "INBOX" })

        // Accepting files through Mail and records the decision in the real service.
        await session.acceptHighlighted()?.value
        #expect(mail.filed.first?.target == "Family/Baby")
        detail = try await client.getSet(id: setId)
        #expect(detail.categories.first { $0.path == "Family/Baby" }?.exampleCount == 1)

        // A correction is recorded under the label the owner chose.
        mail.selectionResult = emailSelection(subject: "Your invoice", body: "The payment for your invoice is due.")
        session = await run(mail: mail, client: client)
        let gadgets = try #require(session.rows.first { $0.title == "Gadgets" })
        await session.accept(gadgets)?.value
        detail = try await client.getSet(id: setId)
        #expect(detail.categories.first { $0.path == "Gadgets" }?.exampleCount == 1)

        // A deep label maps back to its exact mailbox.
        mail.selectionResult = emailSelection(subject: "Project note", body: "Status of the Acme project.")
        session = await run(mail: mail, client: client)
        let deep = try #require(session.rows.first { $0.title.hasPrefix("Work/Clients") })
        await session.accept(deep)?.value
        #expect(mail.filed.last?.target == "Work/Clients/Acme/2026")

        // A proposal creates the label and the category.
        mail.selectionResult = emailSelection(subject: "Hotel booking", body: "Your hotel reservation is confirmed.")
        session = await run(mail: mail, client: client)
        guard case .ready(let proposal) = session.recommendation, proposal.isNew else {
            Issue.record("expected a proposal")
            return
        }
        await session.acceptHighlighted()?.value
        #expect(mail.created.last == proposal.newCategory?.name)
        detail = try await client.getSet(id: setId)
        #expect(detail.categories.first { $0.path == proposal.category }?.exampleCount == 1)

        // A typed label under a known parent.
        mail.selectionResult = emailSelection(subject: "School trip", body: "Details about the school trip.")
        session = await run(mail: mail, client: client)
        session.query = "Family/School"
        await session.accept(try #require(session.rows.first { $0.section == .create }))?.value
        #expect(mail.created.last == "Family/School")
        detail = try await client.getSet(id: setId)
        #expect(detail.categories.first { $0.path == "Family/School" }?.exampleCount == 1)

        // A typed label under a new parent goes through a fresh suggestion.
        mail.selectionResult = emailSelection(subject: "Garden", body: "New plants for the garden.")
        session = await run(mail: mail, client: client)
        session.query = "Home/Garden"
        await session.accept(try #require(session.rows.first { $0.section == .create }))?.value
        detail = try await client.getSet(id: setId)
        #expect(detail.categories.first { $0.path == "Home/Garden" }?.exampleCount == 1)

        // Deleting forgets the label in Mail and in the service.
        mail.selectionResult = emailSelection(subject: "Tidy up", body: "Nothing special here.")
        session = await run(mail: mail, client: client)
        let finance = try #require(session.rows.first { $0.title == "Finance" }?.entry)
        await session.askToDelete(finance)?.value
        await session.confirmDelete()?.value
        #expect(mail.deleted == ["Finance"])
        detail = try await client.getSet(id: setId)
        #expect(!detail.categories.contains { $0.path == "Finance" })

        // A label removed elsewhere that holds learned decisions is kept until forgotten.
        mail.mailboxes.removeAll { $0 == "Gadgets" }
        session = await run(mail: mail, client: client)
        #expect(session.orphaned.map(\.path) == ["Gadgets"])
        detail = try await client.getSet(id: setId)
        #expect(detail.categories.contains { $0.path == "Gadgets" })
        await session.forgetOrphaned()?.value
        detail = try await client.getSet(id: setId)
        #expect(!detail.categories.contains { $0.path == "Gadgets" })

        // A label removed elsewhere with nothing learned simply goes.
        mail.mailboxes.removeAll { $0 == "Család" }
        session = await run(mail: mail, client: client)
        detail = try await client.getSet(id: setId)
        #expect(!detail.categories.contains { $0.path == "Család" })
    }

    @Test func whatWasLearnedFollowsALabelThatIsMovedOrRenamed() async throws {
        let client = try ServiceClient(baseURL: liveURL!)
        let mail = FakeMail()
        mail.mailboxes = ["INBOX", "Family", "Family/Baby", "Gadgets"]
        mail.selectionResult = emailSelection(subject: "Newborn check-up", body: "The baby sees the paediatrician on Friday.")
        var session = await run(mail: mail, client: client)
        await session.accept(try #require(session.rows.first { $0.title == "Family/Baby" }))?.value
        let setId = try #require(try await client.listSets().first { $0.name == LabelSync.setName(address: address) }?.id)
        func learned(at path: String) async throws -> Int? {
            try await client.getSet(id: setId).categories.first { $0.path == path }?.exampleCount
        }
        #expect(try await learned(at: "Family/Baby") == 1)

        // Moved to another parent in the account.
        mail.mailboxes = ["INBOX", "Family", "Kids", "Kids/Baby", "Gadgets"]
        session = await run(mail: mail, client: client)
        #expect(try await learned(at: "Kids/Baby") == 1)
        #expect(try await learned(at: "Family/Baby") == nil)
        #expect(session.orphaned.isEmpty)

        // Renamed: Mail shows the learned email in the label with the new name.
        mail.mailboxes = ["INBOX", "Family", "Kids", "Kids/Newborn", "Gadgets"]
        mail.held = ["Kids/Newborn": ["Newborn check-up"]]
        session = await run(mail: mail, client: client)
        #expect(try await learned(at: "Kids/Newborn") == 1)
        #expect(session.orphaned.isEmpty)

        // The parent renamed: its children come along.
        mail.mailboxes = ["INBOX", "Family", "Children", "Children/Newborn", "Gadgets"]
        mail.held = [:]
        session = await run(mail: mail, client: client)
        #expect(try await learned(at: "Children/Newborn") == 1)
        #expect(session.orphaned.isEmpty)
        let paths = try await client.getSet(id: setId).categories.map(\.path)
        #expect(!paths.contains { $0.hasPrefix("Kids") })
    }

    @Test func anEmailLikeThoseInTheTrashIsSuggestedForDeletion() async throws {
        let client = try ServiceClient(baseURL: liveURL!)
        let mail = FakeMail()
        mail.mailboxes = ["INBOX", "Family", "Shopping"]
        let sender = "Shop Deals <deals@shop.example.test>"
        func newsletter(_ n: Int) -> MailSelection {
            MailSelection(
                messages: [MailMessageRef(id: n, mailbox: "INBOX", account: "Live", messageId: "deals-\(n)@example.test")],
                latest: Email(
                    from: sender, subject: "Weekly shoe discount voucher \(n)",
                    body: "Voucher \(n): discount on shoes, sneakers and boots this weekend only."))
        }
        mail.trashLookup = TrashLookup(
            messages: (1...3).map { TrashedEmail(from: sender, subject: "Weekly shoe discount voucher \($0)") })
        mail.selectionResult = newsletter(4)
        var session = await run(mail: mail, client: client)
        guard case .ready(let suggestion) = session.recommendation else {
            Issue.record("no recommendation: \(session.recommendation)")
            return
        }
        #expect(suggestion.action == .delete)
        #expect(suggestion.similarInTrash == 3)
        #expect(session.rows.first?.action == .trash)
        await session.acceptHighlighted()?.value
        #expect(mail.movedToTrash == [["deals-4@example.test"]])
        #expect(mail.filed.isEmpty)

        // The deletion was learned: the next one counts it, with nothing from the Trash.
        mail.trashLookup = TrashLookup()
        mail.selectionResult = newsletter(5)
        session = await run(mail: mail, client: client)
        guard case .ready(let next) = session.recommendation else {
            Issue.record("no recommendation: \(session.recommendation)")
            return
        }
        #expect(next.similarDeleted == 1)
        #expect(next.similarInTrash == 0)
    }

    @Test func aLongUnicodeEmailIsAccepted() async throws {
        let client = try ServiceClient(baseURL: liveURL!)
        let mail = FakeMail()
        let body = String(repeating: "Számla és fizetés 🧾 invoice payment\r\n\r\n\r\n", count: 20_000)
        mail.selectionResult = emailSelection(subject: "Számla", body: body)
        mail.mailboxes = ["INBOX", "Finance"]
        let session = await run(mail: mail, client: client)
        guard case .ready(let suggestion) = session.recommendation else {
            Issue.record("no recommendation: \(session.recommendation)")
            return
        }
        #expect(suggestion.truncated)
        await session.acceptHighlighted()?.value
        #expect(mail.filed.count == 1)
    }

    @Test func aRealRedirectIsNotFollowed() async throws {
        let base = try #require(redirectURL)
        let client = try ServiceClient(baseURL: base)
        await #expect(throws: ServiceError.badResponse(status: 302)) { _ = try await client.listSets() }
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("hits"))
        let hits = try JSONDecoder().decode([String: Int].self, from: data)
        #expect(hits["hits"] == 0)
    }
}
