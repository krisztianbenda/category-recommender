// Synthetic Mail for demo mode and window snapshots. It never touches the real Mail, so its output
// is safe to share (constitution II).
import Foundation
import MailCore

final class DemoMail: MailSource, @unchecked Sendable {
    private let lock = NSLock()
    private var mailboxes = [
        "INBOX", "[Gmail]/All Mail", "[Gmail]/Spam", "[Gmail]/Trash", "Family", "Family/Baby", "Finance",
        "Finance/Invoices", "Gadgets", "Travelling", "Travelling/Trip Lisbon", "Work/Clients/Acme",
    ]
    private let email: Email
    private let trashed: [TrashedEmail]
    private(set) var filed: [(target: String, items: [FileItem])] = []
    private(set) var movedToTrash: [[String]] = []
    private(set) var archived: [[String]] = []
    /// A batch (`--batch`): several emails, each with its own Message-ID.
    private var batch: [(ref: MailMessageRef, email: Email)] = []

    init(email: Email? = nil) {
        self.email =
            email
            ?? Email(
                from: "Dr. Example Clinic <clinic@example.test>", to: ["owner@example.test"],
                subject: "Your newborn's check-up on Friday",
                body: "Hello, this is a reminder that the baby's paediatrician appointment is on Friday at 10:00.")
        trashed = []
    }

    /// A newsletter like three in the synthetic Trash, so deletion is suggested.
    static func newsletter() -> DemoMail {
        DemoMail(
            email: Email(
                from: "Shop Deals <deals@shop.example.test>", to: ["owner@example.test"],
                subject: "Weekly shoe discount voucher 4",
                body: "Voucher 4: discount on shoes, sneakers and boots this weekend only. Unsubscribe anytime."),
            trashed: (1...3).map {
                TrashedEmail(from: "Shop Deals <deals@shop.example.test>", subject: "Weekly shoe discount voucher \($0)")
            })
    }

    private init(email: Email, trashed: [TrashedEmail]) {
        self.email = email
        self.trashed = trashed
    }

    /// Six synthetic emails selected at once (specs/004-batch-recommendations): two for one label,
    /// one for another, one that needs a new label, a newsletter like three in the Trash, and one with
    /// no text at all.
    static func batch() -> DemoMail {
        let shop = "Shop Deals <deals@shop.example.test>"
        let demo = DemoMail(
            email: Email(from: "", subject: "", body: ""),
            trashed: (1...3).map { TrashedEmail(from: shop, subject: "Weekly shoe discount voucher \($0)") })
        let emails = [
            Email(
                from: "Dr. Example Clinic <clinic@example.test>", subject: "Your newborn's check-up on Friday",
                body: "Hello, this is a reminder that the baby's paediatrician appointment is on Friday at 10:00."),
            Email(
                from: "Nursery Example <hello@nursery.example.test>", subject: "Baby swimming lessons start in May",
                body: "Your baby's swimming course for infants starts on 5 May. Bring a towel and a swim nappy."),
            Email(
                from: "Example Energy <billing@energy.example.test>", subject: "Your invoice for October",
                body: "Invoice 2026-10 is attached. Amount due: 42.00 EUR by 15 November."),
            Email(
                from: "Example Air <trips@air.example.test>", subject: "Booking confirmed: Lisbon to Porto",
                body: "Your flight to Porto on 12 June is confirmed. Check in opens 24 hours before departure."),
            Email(
                from: shop, subject: "Weekly shoe discount voucher 4",
                body: "Voucher 4: discount on shoes, sneakers and boots this weekend only. Unsubscribe anytime."),
            Email(from: "Unknown <noreply@example.test>", subject: "", body: ""),
        ]
        demo.batch = emails.enumerated().map { i, email in
            let ref = MailMessageRef(
                id: 100 + i, mailbox: "INBOX", account: "Demo", date: Double(2_000_000 - i * 1000),
                messageId: "demo-\(i + 1)@example.test", from: email.from, subject: email.subject)
            return (ref, email)
        }
        return demo
    }

    func opening() async throws -> MailOpening {
        let batch = lock.withLock { self.batch }
        if !batch.isEmpty {
            return MailOpening(
                selection: MailSelection(total: batch.count, messages: batch.map(\.ref), latest: nil),
                accounts: [MailAccount(name: "Demo", addresses: ["demo@example.test"])],
                labels: lock.withLock { AccountLabels(mailboxes: mailboxes, inbox: "INBOX") },
                viewed: ["INBOX"])
        }
        return MailOpening(
            selection: MailSelection(
                messages: [MailMessageRef(id: 1, mailbox: "INBOX", account: "Demo", messageId: "demo@example.test")], latest: email),
            accounts: [MailAccount(name: "Demo", addresses: ["demo@example.test"])],
            labels: lock.withLock { AccountLabels(mailboxes: mailboxes) })
    }

    func labels(account: String) async throws -> AccountLabels {
        lock.withLock { AccountLabels(mailboxes: mailboxes) }
    }

    func file(_ items: [FileItem], into target: String, account: String) async throws {
        lock.withLock { filed.append((target, items)) }
    }

    func archive(messageIds: [String], account: String) async throws -> ArchiveResult { .archived }

    @discardableResult
    func createLabel(_ path: String, account: String) async throws -> Bool {
        lock.withLock {
            if mailboxes.contains(path) { return false }
            mailboxes.append(path)
            return true
        }
    }

    func beginDeleteLabel(_ path: String, account: String) async throws -> DeleteStart {
        lock.withLock { mailboxes.removeAll { $0 == path } }
        return .confirmInMail
    }

    func labelExists(_ path: String, account: String) async throws -> Bool {
        lock.withLock { mailboxes.contains(path) }
    }

    func messageCount(_ path: String, account: String) async throws -> Int { 12 }

    func trashSimilar(sender: String, messageIds: [String], account: String) async throws -> TrashLookup {
        TrashLookup(messages: trashed)
    }

    func holding(_ emails: [LearnedEmail], in mailboxes: [String], account: String) async throws -> [Int] {
        mailboxes.map { _ in 0 }
    }

    func moveToTrash(messageIds: [String], account: String) async throws -> TrashResult {
        lock.withLock { movedToTrash.append(messageIds) }
        return .trashed
    }

    func read(_ refs: [MailMessageRef], viewed: [String], account: String) async throws -> [ReadEmail] {
        let batch = lock.withLock { self.batch }
        return refs.map { ref in
            guard let found = batch.first(where: { $0.ref.messageId == ref.messageId }) else {
                return ReadEmail(messageId: ref.messageId, found: false)
            }
            return ReadEmail(
                messageId: ref.messageId, placement: Placement(id: ref.id, mailbox: ref.mailbox, inInbox: true),
                email: found.email)
        }
    }

    func archive(_ emails: [SelectedEmail], viewed: [String], account: String) async throws -> ArchiveOutcome {
        lock.withLock { archived.append(emails.map(\.messageId)) }
        return ArchiveOutcome(result: .archived)
    }

    func moveToTrash(_ emails: [SelectedEmail], viewed: [String], account: String) async throws -> TrashOutcome {
        lock.withLock { movedToTrash.append(emails.map(\.messageId)) }
        return TrashOutcome(result: .trashed)
    }

    func trashSimilar(senders: [String], messageIds: [String], account: String) async throws -> TrashLookups {
        var bySender: [String: [TrashedEmail]] = [:]
        for sender in senders {
            let address = TrashLookups.address(sender)
            bySender[address] = trashed.filter { TrashLookups.address($0.from) == address }
        }
        return TrashLookups(bySender: bySender)
    }
}
