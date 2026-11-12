// Gmail labels and other accounts' folders, as Mail shows them, mapped to the service's categories.
//
// The service allows two levels and 60-character names, and folds case and accents when comparing.
// Gmail allows more. Every category therefore remembers the exact mailbox it stands for, so a
// recommendation can always be applied to the right label (FR-006).
import Foundation

public enum LabelText {
    public static let maxNameLength = 60
    public static let deepSeparator = " \u{203A} "

    private static let systemNames: Set<String> = [
        "inbox", "sent", "sent mail", "sent messages", "sent items", "drafts", "draft", "trash", "bin",
        "deleted messages", "deleted items", "junk", "junk e-mail", "junk email", "spam", "all mail", "archive",
        "notes", "outbox", "starred", "important", "snoozed", "chats", "conversation history", "sync issues",
        "sync issues/conflicts", "sync issues/local failures", "sync issues/server failures", "rss feeds",
        "rss subscriptions",
    ]

    /// Same folding as the service's `normaliseName`: accents removed, lower-cased, whitespace collapsed.
    public static func normalise(_ text: String) -> String {
        let marks: Set<Unicode.GeneralCategory> = [.nonspacingMark, .spacingMark, .enclosingMark]
        let scalars = text.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !marks.contains($0.properties.generalCategory) }
        return collapse(String(String.UnicodeScalarView(scalars)).lowercased())
    }

    public static func pathKey(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { normalise(String($0)) }
            .joined(separator: "/")
    }

    /// A category path's parent, if any, and the category's own name. Names never contain "/".
    public static func split(_ path: String) -> (parent: String?, name: String) {
        let parts = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : (nil, path)
    }

    /// The label's own name, folded: the last part of its path, however deep the label sits. It is
    /// what stays the same when a label is moved to another parent.
    public static func leafKey(_ path: String) -> String {
        let name = split(path).name
        return normalise(name.components(separatedBy: deepSeparator).last ?? name)
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func segments(_ mailbox: String) -> [String] {
        mailbox.split(separator: "/").map { collapse(String($0)) }.filter { !$0.isEmpty }
    }

    /// Shortens to the service's limit, which it counts in UTF-16 units.
    static func fit(_ name: String, limit: Int = maxNameLength) -> String {
        guard name.utf16.count > limit else { return name }
        var out = ""
        for character in name {
            if out.utf16.count + character.utf16.count > limit - 1 { break }
            out.append(character)
        }
        return out + "\u{2026}"
    }

    public static func isInbox(_ mailbox: String) -> Bool {
        mailbox.caseInsensitiveCompare("INBOX") == .orderedSame
    }

    /// Gmail's system folders always sit under "[Gmail]", whatever language their names are in. The
    /// plain names are Mail's own folders, and Gmail's in case an account lists them at the top level.
    public static func isSystem(_ mailbox: String) -> Bool {
        let name = mailbox.lowercased()
        if name == "[gmail]" || name == "[google mail]" { return true }
        if name.hasPrefix("[gmail]/") || name.hasPrefix("[google mail]/") { return true }
        return systemNames.contains(name)
    }

    /// Cleans a typed label name: "  Trips / Lisbon " becomes "Trips/Lisbon". Nil if unusable.
    public static func cleanTyped(_ text: String) -> String? {
        let parts = segments(text)
        guard !parts.isEmpty else { return nil }
        let cleaned = parts.joined(separator: "/")
        return isSystem(cleaned) || isSystem(parts[0]) ? nil : cleaned
    }
}

public struct LabelEntry: Identifiable, Equatable, Sendable {
    /// The exact mailbox in Mail.
    public let mailbox: String
    /// The category in the service.
    public let path: String
    public let key: String
    /// False for a parent that exists only because a nested label implies it.
    public let existsInAccount: Bool

    public var id: String { key }
}

public struct LabelCatalog: Equatable, Sendable {
    /// Keeps the prompt within the model's context (plan: Labels and categories).
    public static let defaultLimit = 300

    public let entries: [LabelEntry]
    public let limit: Int
    /// The account's own folders, by the names they have there.
    private let system: Set<String>
    private let inbox: String?

    /// `system` holds the account's own Inbox, Sent, Drafts, Junk and Trash by the names they have
    /// there, which differ by provider and language. They and what is inside them are left out,
    /// except folders inside the Inbox, which are the owner's.
    public init(
        mailboxes: [String], system: [String] = [], inbox: String? = nil,
        limit: Int = LabelCatalog.defaultLimit
    ) {
        self.limit = limit
        self.system = Set(system)
        self.inbox = inbox
        let special = Set(system)
        func isInboxName(_ name: String) -> Bool { name == inbox || LabelText.isInbox(name) }
        let real = Set(mailboxes).filter { mailbox in
            if LabelText.isSystem(mailbox) || special.contains(mailbox) { return false }
            let top = String(mailbox.split(separator: "/").first ?? "")
            return !special.contains(top) || isInboxName(top)
        }.sorted()

        var out: [LabelEntry] = []
        var seen = Set<String>()
        var topDisplay: [String: String] = [:]

        func claim(parent: String?, name: String) -> (path: String, key: String) {
            var candidate = LabelText.fit(name)
            var n = 2
            while true {
                let path = parent.map { "\($0)/\(candidate)" } ?? candidate
                let key = LabelText.pathKey(path)
                if seen.insert(key).inserted { return (path, key) }
                let suffix = " (\(n))"
                candidate = LabelText.fit(name, limit: LabelText.maxNameLength - suffix.utf16.count) + suffix
                n += 1
            }
        }

        for mailbox in real {
            let parts = LabelText.segments(mailbox)
            guard let top = parts.first else { continue }
            if parts.count == 1 {
                guard topDisplay[top] == nil else { continue }
                let claimed = claim(parent: nil, name: top)
                topDisplay[top] = claimed.path
                out.append(
                    LabelEntry(mailbox: mailbox, path: claimed.path, key: claimed.key, existsInAccount: true))
                continue
            }
            if isInboxName(top) {
                // The Inbox itself is not a place to file under, so its folders stand on their own.
                let claimed = claim(parent: nil, name: Self.inboxFolderName(parts))
                out.append(
                    LabelEntry(mailbox: mailbox, path: claimed.path, key: claimed.key, existsInAccount: true))
                continue
            }
            if topDisplay[top] == nil {
                let claimed = claim(parent: nil, name: top)
                topDisplay[top] = claimed.path
                out.append(
                    LabelEntry(mailbox: top, path: claimed.path, key: claimed.key, existsInAccount: false))
            }
            let leaf = parts.dropFirst().joined(separator: LabelText.deepSeparator)
            let claimed = claim(parent: topDisplay[top], name: leaf)
            out.append(LabelEntry(mailbox: mailbox, path: claimed.path, key: claimed.key, existsInAccount: true))
        }
        entries = out
    }

    /// The labels given to the recommender.
    public var considered: [LabelEntry] { Array(entries.prefix(limit)) }

    public var notConsidered: Int { max(0, entries.count - limit) }

    public func entry(forPath path: String) -> LabelEntry? {
        let key = LabelText.pathKey(path)
        return entries.first { $0.key == key }
    }

    /// A folder inside the Inbox is a top-level category named after its whole path.
    private static func inboxFolderName(_ parts: [String]) -> String {
        parts.joined(separator: LabelText.deepSeparator)
    }

    private func isInboxName(_ name: String) -> Bool { name == inbox || LabelText.isInbox(name) }

    /// One of the account's own folders, such as Sent under its local name. Never a place to file.
    public func isAccountFolder(_ mailbox: String) -> Bool {
        let top = String(mailbox.split(separator: "/").first ?? "")
        return system.contains(mailbox) || (system.contains(top) && !isInboxName(top))
    }

    public func isConsidered(_ entry: LabelEntry) -> Bool {
        considered.contains { $0.key == entry.key }
    }

    public func hasChildren(_ entry: LabelEntry) -> Bool {
        entries.contains { $0.mailbox.hasPrefix(entry.mailbox + "/") }
    }

    /// Where a new mailbox would sit among the categories: its parent, if known, and its name.
    public func newCategory(forMailbox mailbox: String) -> (category: NewCategory, parentIsKnown: Bool)? {
        let parts = LabelText.segments(mailbox)
        guard let top = parts.first else { return nil }
        if parts.count == 1 {
            return (NewCategory(parent: nil, name: LabelText.fit(top)), true)
        }
        if isInboxName(top) {
            return (NewCategory(parent: nil, name: LabelText.fit(Self.inboxFolderName(parts))), true)
        }
        let leaf = LabelText.fit(parts.dropFirst().joined(separator: LabelText.deepSeparator))
        let known = entries.first { $0.mailbox == top } ?? entry(forPath: top)
        return (NewCategory(parent: known?.path ?? LabelText.fit(top), name: leaf), known != nil)
    }

    /// The mailbox for a proposal from the recommender, whose parent is a category.
    public func mailbox(for proposal: NewCategory) -> String {
        guard let parent = proposal.parent else { return proposal.name }
        return "\(entry(forPath: parent)?.mailbox ?? parent)/\(proposal.name)"
    }
}

public enum FilingMode: String, Codable, Sendable {
    case move
    case copy
}

public enum Filing {
    /// Filing adds the label, and for an email in the Inbox it also takes it out of the Inbox (the
    /// "move"), unless the owner keeps it there. Anywhere else, including All Mail and other
    /// labels, filing only adds the label (FR-015): Mail cannot remove other labels by script.
    ///
    /// In a folder account filing only copies the email to the folder, and the email stays where
    /// it is. A scripted move once took an owner's email out of the Inbox and Mail never showed it
    /// again, so moving waits until it has been proven safe on real accounts.
    public static func mode(inInbox: Bool, keepInInbox: Bool, kind: AccountKind) -> FilingMode {
        switch kind {
        case .gmail: return inInbox && !keepInInbox ? .move : .copy
        case .folders: return .copy
        }
    }
}
