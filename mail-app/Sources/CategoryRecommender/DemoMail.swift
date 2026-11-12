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

    func opening() async throws -> MailOpening {
        MailOpening(
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
}
