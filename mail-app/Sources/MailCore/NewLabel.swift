// "New label…" in the batch window's Choose a label: the owner names a label and puts it at the
// top level or inside a label they already have, as in Mail's own New Mailbox. It files the same
// way as a label typed into the search, such as "Trips/Lisbon".
import Foundation

public struct NewLabelForm: Equatable, Sendable {
    public var name: String
    /// The mailbox of the label it goes inside, or nil for the top level.
    public var parent: String?

    public init(name: String = "", parent: String? = nil) {
        self.name = name
        self.parent = parent
    }

    /// Starts from what was typed in the search. "Trips/Lis" puts "Lis" inside Trips when Trips is
    /// a label, so the owner only has to finish the name, and "Trips/" starts an empty name there.
    public static func from(query: String, catalog: LabelCatalog) -> NewLabelForm {
        var parts = LabelText.segments(query)
        let name = query.trimmingCharacters(in: .whitespaces).hasSuffix("/") ? "" : parts.popLast() ?? ""
        guard !parts.isEmpty else { return NewLabelForm(name: name) }
        // Found as the service would find it, so "trips" or "Tríps" is still Trips.
        guard let parent = catalog.existing(forNewMailbox: parts.joined(separator: "/")) else {
            return NewLabelForm(name: (parts + [name]).joined(separator: "/"))
        }
        return NewLabelForm(name: name, parent: parent.mailbox)
    }

    /// The mailbox it would create. Nil while the name is empty.
    public var mailbox: String? {
        let parts = LabelText.segments(name)
        guard !parts.isEmpty else { return nil }
        let own = parts.joined(separator: "/")
        return parent.map { "\($0)/\(own)" } ?? own
    }

    public func outcome(in catalog: LabelCatalog) -> NewLabelOutcome {
        guard let mailbox else { return .empty }
        // Inside one of the owner's labels, such as a folder in the Inbox, any name is theirs.
        let ownsName = parent != nil || LabelText.cleanTyped(mailbox) != nil
        if !ownsName || catalog.isAccountFolder(mailbox) { return .reserved(mailbox) }
        if let same = catalog.existing(forNewMailbox: mailbox) { return .exists(same) }
        return .create(mailbox)
    }
}

public enum NewLabelOutcome: Equatable, Sendable {
    /// No name yet.
    case empty
    /// One of the account's own mailboxes, such as Inbox or Trash.
    case reserved(String)
    /// The label is there already, so it is filed under that one.
    case exists(LabelEntry)
    /// Creates this mailbox, then files under it.
    case create(String)

    public var isExisting: Bool {
        if case .exists = self { return true }
        return false
    }

    public var isReserved: Bool {
        if case .reserved = self { return true }
        return false
    }

    public var action: RowAction? {
        switch self {
        case .empty, .reserved: return nil
        case .exists(let entry): return .existing(entry)
        case .create(let mailbox): return .createTyped(mailbox)
        }
    }
}
