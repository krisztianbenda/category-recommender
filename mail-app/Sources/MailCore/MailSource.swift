// What the app needs from Mail and from the local service's lifecycle. The real implementations
// live in the app; tests and the demo mode use synthetic ones.
import Foundation

public struct MailMessageRef: Codable, Equatable, Sendable {
    public let id: Int
    public let mailbox: String
    public let account: String
    public let date: Double
    public let messageId: String?
    /// Whether it is in its account's Inbox, whatever the Inbox is called there. Nil if Mail did not say.
    public let inInbox: Bool?

    public init(
        id: Int, mailbox: String, account: String, date: Double = 0, messageId: String? = nil,
        inInbox: Bool? = nil
    ) {
        self.id = id
        self.mailbox = mailbox
        self.account = account
        self.date = date
        self.messageId = messageId
        self.inInbox = inInbox
    }

    public var isInInbox: Bool { inInbox ?? LabelText.isInbox(mailbox) }
}

public struct MailSelection: Codable, Equatable, Sendable {
    public let running: Bool
    public let total: Int
    public let messages: [MailMessageRef]
    public let latest: Email?

    public init(running: Bool = true, total: Int? = nil, messages: [MailMessageRef], latest: Email?) {
        self.running = running
        self.total = total ?? messages.count
        self.messages = messages
        self.latest = latest
    }
}

/// How an account keeps emails. It decides what filing and deleting mean.
public enum AccountKind: String, Codable, Sendable {
    /// Mailboxes are labels: an email can have several, and stays in All Mail without any.
    case gmail
    /// Mailboxes are folders (iCloud, Exchange, other IMAP): an email is in exactly one.
    case folders
}

public struct MailAccount: Codable, Equatable, Sendable {
    public let name: String
    public let addresses: [String]
    public let kind: AccountKind

    public init(name: String, addresses: [String], kind: AccountKind = .gmail) {
        self.name = name
        self.addresses = addresses
        self.kind = kind
    }
}

public struct AccountLabels: Codable, Equatable, Sendable {
    public let mailboxes: [String]
    /// The account's own Inbox, Sent, Drafts, Junk and Trash, by the names they have there.
    public let system: [String]?
    public let inbox: String?

    public init(mailboxes: [String], system: [String]? = nil, inbox: String? = nil) {
        self.mailboxes = mailboxes
        self.system = system
        self.inbox = inbox
    }
}

/// What the window needs when it opens, read in one go so that it fills quickly.
public struct MailOpening: Codable, Equatable, Sendable {
    public let selection: MailSelection
    public let accounts: [MailAccount]
    /// The labels or folders of the selected email's account, if it is one of `accounts`.
    public let labels: AccountLabels?

    public init(selection: MailSelection, accounts: [MailAccount], labels: AccountLabels?) {
        self.selection = selection
        self.accounts = accounts
        self.labels = labels
    }
}

public struct FileItem: Codable, Equatable, Sendable {
    public let id: Int
    public let mailbox: String
    public let mode: FilingMode

    public init(id: Int, mailbox: String, mode: FilingMode) {
        self.id = id
        self.mailbox = mailbox
        self.mode = mode
    }
}

/// Why the app could not click a command in Mail's menus.
public enum MenuProblem: String, Codable, Equatable, Sendable {
    /// macOS does not let this app use other apps' menus (Accessibility). The switch can look on
    /// and still belong to an earlier install: the app is signed ad hoc, so each install is new.
    case notAllowed
    /// This app may not control System Events (Automation).
    case systemEventsNotAllowed
    /// Mail has no such command, or it is greyed out right now.
    case commandUnavailable
}

public enum ArchiveResult: String, Codable, Equatable, Sendable {
    case archived
    /// See `MenuProblem`.
    case notAllowed, systemEventsNotAllowed, commandUnavailable
    /// Mail's selection is no longer exactly the filed emails, so nothing was archived.
    case selectionChanged
    case stillThere
}

/// An email in the Trash, as far as the recommender needs it: never its text.
public struct TrashedEmail: Codable, Equatable, Sendable {
    public let from: String
    public let subject: String

    public init(from: String, subject: String) {
        self.from = from
        self.subject = subject
    }
}

public struct TrashLookup: Codable, Equatable, Sendable {
    /// The account's Trash was found. Without it, nothing is deleted.
    public let found: Bool
    /// A selected email is in the Trash already, where Mail's Delete would erase it.
    public let inTrash: Bool
    /// Emails from the same sender in the Trash, newest first.
    public let messages: [TrashedEmail]

    public init(found: Bool = true, inTrash: Bool = false, messages: [TrashedEmail] = []) {
        self.found = found
        self.inTrash = inTrash
        self.messages = messages
    }
}

public enum TrashResult: String, Codable, Equatable, Sendable {
    case trashed
    /// See `MenuProblem`.
    case notAllowed, systemEventsNotAllowed, commandUnavailable
    /// Mail's selection is no longer exactly these emails, so nothing was deleted.
    case selectionChanged
    /// Deleting in the Trash erases for good, so nothing was done.
    case alreadyInTrash
    /// The account's Trash was not found, so nothing was done.
    case noTrash
    /// Mail's Delete ran, but the emails did not arrive in the Trash.
    case notInTrash
}

public enum DeleteStart: Equatable, Sendable {
    /// Mail's confirmation is showing.
    case confirmInMail
    /// Mail is showing the label, and the owner has to choose Delete Mailbox from Mail's menu,
    /// because the app could not.
    case chooseInMail(MenuProblem)
}

public enum MailError: Error, Equatable {
    case notAuthorized
    case mailNotRunning
    case timedOut
    case notFound(String)
    case script(number: Int, message: String)
}

public protocol MailSource: Sendable {
    func opening() async throws -> MailOpening
    func labels(account: String) async throws -> AccountLabels
    /// Gmail: adds the label, and taking emails out of the Inbox is `archive`. A folder account: moves
    /// the items whose mode is `move` to the folder, and copies the others.
    func file(_ items: [FileItem], into target: String, account: String) async throws
    /// Takes the selected emails out of the Inbox with Mail's own Archive command, only if Mail's
    /// selection is exactly these emails.
    func archive(messageIds: [String], account: String) async throws -> ArchiveResult
    /// Returns false if the label already existed.
    @discardableResult func createLabel(_ path: String, account: String) async throws -> Bool
    /// Opens Mail's own deletion for this label. Mail asks for confirmation, so the label is not
    /// gone yet when this returns: watch `labelExists`.
    func beginDeleteLabel(_ path: String, account: String) async throws -> DeleteStart
    func labelExists(_ path: String, account: String) async throws -> Bool
    func messageCount(_ path: String, account: String) async throws -> Int
    /// Reads the Trash: emails from this sender, and whether these emails are there already.
    func trashSimilar(sender: String, messageIds: [String], account: String) async throws -> TrashLookup
    /// Moves the selected emails to the Trash with Mail's own Delete command, only if Mail's
    /// selection is exactly these emails and none of them is in the Trash already.
    func moveToTrash(messageIds: [String], account: String) async throws -> TrashResult
}

public protocol BackendControl: Sendable {
    /// Returns when the service can answer. Calls `onStarting` first if it has to be started.
    func ensureRunning(onStarting: @escaping @Sendable () -> Void) async throws
    /// Marks the service as in use, which postpones the idle stop.
    func noteActivity()
}

/// JSON for the Mail bridge's command line: ASCII only, whatever the content.
public enum BridgeJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        let text = String(decoding: data, as: UTF8.self)
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for unit in text.utf16 {
            if unit < 0x7F {
                out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            } else {
                out += String(format: "\\u%04x", unit)
            }
        }
        return out
    }
}
