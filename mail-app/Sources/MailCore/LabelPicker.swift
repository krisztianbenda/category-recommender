// The list of labels to file under: the recommendation and its runners-up first, then every label,
// or the labels matching a search and an entry to create a new one. Shared by the single-email
// window and the batch window's "Choose a label".
import Foundation

/// Moving a highlight through a list by its ids, stopping at either end.
public enum Highlight {
    public static func moved(_ ids: [String], from current: String?, by delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        let index = ids.firstIndex { $0 == current } ?? 0
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }
}

public enum LabelPicker {
    public static func rows(
        catalog: LabelCatalog, suggestion: Suggestion?, canTrash: Bool, deletedKeys: Set<String> = [],
        query: String
    ) -> [LabelRow] {
        var out: [LabelRow] = []
        let search = LabelText.normalise(query)
        if !search.isEmpty {
            out = catalog.entries
                .filter { LabelText.normalise($0.path).contains(search) }
                .map { row($0, .all) }
            if let typed = LabelText.cleanTyped(query), catalog.existing(forNewMailbox: typed) == nil,
                !catalog.isAccountFolder(typed)
            {
                out.append(
                    LabelRow(id: "create:\(typed)", title: typed, action: .createTyped(typed), section: .create))
            }
            return out
        }
        var taken = Set<String>()
        if let suggestion {
            // When deleting is suggested, the label it would go to if kept comes next.
            let toTrash = suggestion.action == .delete && canTrash
            if toTrash { out.append(.trash) }
            let keep: RowSection = toTrash ? .likely : .recommended
            if let first = recommendedRow(catalog: catalog, suggestion: suggestion, deletedKeys: deletedKeys) {
                out.append(LabelRow(id: first.id, title: first.title, action: first.action, section: keep))
                if let entry = first.entry { taken.insert(entry.key) }
            }
            for runner in suggestion.runnersUp {
                guard let entry = catalog.entry(forPath: runner.path), taken.insert(entry.key).inserted else {
                    continue
                }
                out.append(row(entry, .likely))
            }
        }
        out += catalog.entries.filter { !taken.contains($0.key) }.map { row($0, .all) }
        return out
    }

    /// Where the suggestion would file the email: an existing label, a proposed new one, or the
    /// recommended label again when it has gone from the account. Nil if it was deleted on purpose.
    public static func recommendedRow(
        catalog: LabelCatalog, suggestion: Suggestion, deletedKeys: Set<String> = []
    ) -> LabelRow? {
        if suggestion.isNew, let proposal = suggestion.newCategory {
            return LabelRow(id: "proposal", title: proposal.path, action: .acceptProposal(proposal), section: .recommended)
        }
        if let entry = catalog.entry(forPath: suggestion.category) {
            return row(entry, .recommended)
        }
        if !deletedKeys.contains(LabelText.pathKey(suggestion.category)) {
            return LabelRow(
                id: "recreate", title: suggestion.category, action: .recreate(suggestion.category),
                section: .recommended)
        }
        return nil
    }

    public static func row(_ entry: LabelEntry, _ section: RowSection) -> LabelRow {
        LabelRow(id: "label:\(entry.key)", title: entry.path, action: .existing(entry), section: section)
    }
}
