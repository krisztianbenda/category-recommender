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
    /// a label, so the owner only has to finish the name.
    public static func from(query: String, catalog: LabelCatalog) -> NewLabelForm {
        let parts = LabelText.segments(query)
        guard parts.count > 1 else { return NewLabelForm(name: parts.first ?? "") }
        let parentMailbox = parts.dropLast().joined(separator: "/")
        let parent = catalog.entries.first {
            $0.mailbox.caseInsensitiveCompare(parentMailbox) == .orderedSame
        }
        guard let parent else { return NewLabelForm(name: parts.joined(separator: "/")) }
        return NewLabelForm(name: parts.last!, parent: parent.mailbox)
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
        if LabelText.cleanTyped(mailbox) == nil || catalog.isAccountFolder(mailbox) {
            return .reserved(mailbox)
        }
        // The service folds case and accents, so "trips" is the same category as "Trips".
        let same =
            catalog.entries.first { $0.mailbox.caseInsensitiveCompare(mailbox) == .orderedSame }
            ?? catalog.newCategory(forMailbox: mailbox).flatMap { catalog.entry(forPath: $0.category.path) }
        if let same { return .exists(same) }
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
