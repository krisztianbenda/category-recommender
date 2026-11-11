// Keeps a category set in step with the account's labels. It is a diff, so category ids, and the
// learning attached to them, survive (FR-004). A label that was moved or renamed in the account
// keeps its category, so what was learned for it follows it (FR-025). Learned decisions are never
// dropped without the owner's say-so (FR-007, constitution V).
import Foundation

/// A category that follows its label to a new place or name. Its id, and so its learning, stay.
public struct LabelMove: Equatable, Sendable {
    /// The category before the move.
    public let item: CategoryItem
    /// Its path from now on.
    public let to: String

    public init(item: CategoryItem, to: String) {
        self.item = item
        self.to = to
    }
}

/// The account does not say that a label was moved or renamed: the old one disappears and a new
/// one appears. When one sync sees both, they are paired, but only on clear evidence:
///
/// - Same name: the label is now under another parent, at the top level, or under a parent for
///   the first time.
/// - A parent whose children reappear under one new parent was renamed, and they came with it.
/// - Same emails (see `LabelSync`): the new label holds the emails learned for the old one.
///
/// A name that is not unique on both sides is not paired. Whatever is left goes through `SyncPlan`.
public struct MovePlan: Equatable, Sendable {
    public private(set) var moves: [LabelMove] = []
    /// Categories with learning whose label is gone and was not found by name. Paths as they will
    /// be after `moves`.
    public private(set) var unmatched: [CategoryItem] = []
    /// Labels that are new to the set and that no category was paired with.
    public private(set) var unclaimed: [LabelEntry] = []

    public init(catalog: LabelCatalog, existing: [CategoryItem]) {
        let wanted = catalog.considered
        let wantedKeys = Set(wanted.map(\.key))
        func isGone(_ item: CategoryItem) -> Bool { !wantedKeys.contains(LabelText.pathKey(item.path)) }
        let existingKeys = Set(existing.map { LabelText.pathKey($0.path) })
        let fresh = wanted.filter { !existingKeys.contains($0.key) }

        // Renamed parents: most of the old parent's children are under the new one.
        var current = existing
        var renames: [(parent: CategoryItem, to: LabelEntry)] = []
        for parent in existing where parent.parentId == nil && isGone(parent) {
            let children = existing.filter { $0.parentId == parent.id }
            guard !children.isEmpty else { continue }
            let scored = fresh.filter { LabelText.split($0.path).parent == nil }.map {
                top -> (top: LabelEntry, score: Int) in
                let under = Set(wanted.filter { $0.path.hasPrefix(top.path + "/") }.map { LabelText.leafKey($0.path) })
                return (top: top, score: children.filter { under.contains(LabelText.leafKey($0.path)) }.count)
            }
            guard let best = scored.max(by: { $0.score < $1.score }), best.score * 2 > children.count,
                scored.filter({ $0.score == best.score }).count == 1
            else { continue }
            renames.append((parent, best.top))
        }
        for rename in renames where renames.filter({ $0.to.key == rename.to.key }).count == 1 {
            let (parent, top) = rename
            moves.append(LabelMove(item: parent, to: top.path))
            current = current.map { item in
                if item.id == parent.id {
                    return CategoryItem(id: item.id, path: top.path, parentId: nil, exampleCount: item.exampleCount)
                }
                guard item.parentId == parent.id else { return item }
                let path = "\(top.path)/\(LabelText.split(item.path).name)"
                return CategoryItem(id: item.id, path: path, parentId: parent.id, exampleCount: item.exampleCount)
            }
        }

        // Moved labels: the same name somewhere else.
        let currentKeys = Set(current.map { LabelText.pathKey($0.path) })
        let gone = current.filter(isGone)
        var open = wanted.filter { !currentKeys.contains($0.key) }
        let goneByLeaf = Dictionary(grouping: gone) { LabelText.leafKey($0.path) }
        let openByLeaf = Dictionary(grouping: open) { LabelText.leafKey($0.path) }
        var matched = Set<String>()
        for item in gone {
            let leaf = LabelText.leafKey(item.path)
            guard goneByLeaf[leaf]?.count == 1, let targets = openByLeaf[leaf], targets.count == 1 else { continue }
            moves.append(LabelMove(item: item, to: targets[0].path))
            matched.insert(item.id)
            open.removeAll { $0.key == targets[0].key }
        }

        unmatched = gone.filter { !matched.contains($0.id) && $0.exampleCount > 0 }
        // A parent that is only implied by deeper labels holds no emails of its own.
        unclaimed = open.filter(\.existsInAccount)
    }

    /// Pairs a category with a label found to hold its emails.
    public mutating func follow(_ item: CategoryItem, to entry: LabelEntry) {
        moves.append(LabelMove(item: item, to: entry.path))
        unmatched.removeAll { $0.id == item.id }
        unclaimed.removeAll { $0.key == entry.key }
    }

    /// In an order the service accepts: a parent has to be at the top level before anything moves
    /// under it, and a category can only move under a parent once its own children have left.
    public var ordered: [LabelMove] {
        func stage(_ move: LabelMove) -> Int {
            if LabelText.split(move.to).parent == nil { return 0 }
            return move.item.parentId != nil ? 1 : 2
        }
        return moves.enumerated()
            .sorted { (stage($0.element), $0.offset) < (stage($1.element), $1.offset) }
            .map(\.element)
    }
}

public struct SyncPlan: Equatable, Sendable {
    /// Parents come first.
    public var add: [String] = []
    /// Children come first.
    public var remove: [CategoryItem] = []
    /// Labels that are gone but hold learned decisions.
    public var orphaned: [CategoryItem] = []

    public init(catalog: LabelCatalog, existing: [CategoryItem]) {
        let wanted = catalog.considered
        let wantedKeys = Set(wanted.map(\.key))
        let existingKeys = Set(existing.map { LabelText.pathKey($0.path) })
        add = wanted.filter { !existingKeys.contains($0.key) }.map(\.path)

        let leaving = existing.filter { !wantedKeys.contains(LabelText.pathKey($0.path)) }
        orphaned = leaving.filter { $0.exampleCount > 0 }
        let keptIds = Set(existing.filter { wantedKeys.contains(LabelText.pathKey($0.path)) }.map(\.id))
            .union(orphaned.map(\.id))
        remove = leaving
            .filter { item in
                item.exampleCount == 0
                    && !existing.contains { $0.parentId == item.id && keptIds.contains($0.id) }
            }
            .sorted { ($0.parentId != nil) && ($1.parentId == nil) }
    }
}

public struct SyncResult: Equatable, Sendable {
    public let setId: String
    public let categories: [CategoryItem]
    public let orphaned: [CategoryItem]
    /// Labels the service would not take; they can still be filed under by hand.
    public let failed: Int
    /// Categories that followed their label to a new place or name.
    public let moved: Int
}

public enum LabelSync {
    /// The API takes this many categories when creating a set.
    static let createLimit = 500
    /// Looking for emails in Mail is slow, so it is bounded. It only happens when labels changed.
    static let emailsPerCategory = 5
    static let categoriesLookedFor = 10
    static let mailboxesLookedIn = 20

    /// For each mailbox, how many of the emails it holds.
    public typealias Holding = @Sendable (_ emails: [LearnedEmail], _ mailboxes: [String]) async throws -> [Int]

    /// One category set per account. Gmail's name is from before other accounts were supported,
    /// and stays, because the learning hangs on it.
    public static func setName(address: String, kind: AccountKind = .gmail) -> String {
        "\(kind == .gmail ? "Gmail" : "Mail"): \(String(address.prefix(73)))"
    }

    /// `holding` lets renamed labels be found by the emails learned for them. Without it, only moves
    /// by name are followed.
    public static func run(
        api: RecommenderAPI, setName: String, catalog: LabelCatalog, holding: Holding? = nil
    ) async throws -> SyncResult {
        let key = LabelText.normalise(setName)
        let setId: String
        var isNew = false
        if let existing = try await api.listSets().first(where: { LabelText.normalise($0.name) == key }) {
            setId = existing.id
        } else {
            let paths = catalog.considered.map(\.path)
            setId = try await api.createSet(name: setName, categories: Array(paths.prefix(createLimit)))
            isNew = true
        }

        var detail = try await api.getSet(id: setId)
        var moved = 0
        if !isNew {
            var moves = MovePlan(catalog: catalog, existing: detail.categories)
            if let holding { await findByEmails(&moves, api: api, holding: holding) }
            if !moves.moves.isEmpty {
                moved = try await apply(moves.ordered, setId: setId, categories: detail.categories, api: api)
                detail = try await api.getSet(id: setId)
            }
        }

        let plan = SyncPlan(catalog: catalog, existing: detail.categories)
        var failed = 0
        for path in plan.add {
            do {
                _ = try await api.addCategory(setId: setId, path: path)
            } catch ServiceError.api(status: 400, _, _) {
                failed += 1
            }
        }
        for item in plan.remove {
            do {
                try await api.deleteCategory(id: item.id, cascade: false)
            } catch ServiceError.api(status: 404, _, _) {
                continue  // went with its parent
            }
        }
        if !plan.add.isEmpty || !plan.remove.isEmpty {
            detail = try await api.getSet(id: setId)
        }
        return SyncResult(
            setId: setId, categories: detail.categories, orphaned: plan.orphaned, failed: failed, moved: moved)
    }

    /// Pairs gone categories with new labels that hold the emails learned for them. A failure only
    /// means no pairing: the category is kept as before.
    static func findByEmails(_ plan: inout MovePlan, api: RecommenderAPI, holding: Holding) async {
        let wanted = plan.unmatched.sorted { $0.exampleCount > $1.exampleCount }.prefix(categoriesLookedFor)
        for item in wanted {
            guard !plan.unclaimed.isEmpty else { return }
            // A rename usually keeps the parent, so its siblings are looked in first.
            let parent = LabelText.split(item.path).parent.map(LabelText.normalise)
            func sameParent(_ entry: LabelEntry) -> Bool {
                LabelText.split(entry.path).parent.map(LabelText.normalise) == parent
            }
            let candidates = Array(
                (plan.unclaimed.filter(sameParent) + plan.unclaimed.filter { !sameParent($0) })
                    .prefix(mailboxesLookedIn))
            guard let emails = try? await api.learnedEmails(categoryId: item.id, limit: emailsPerCategory),
                !emails.isEmpty,
                let counts = try? await holding(emails, candidates.map(\.mailbox)),
                counts.count == candidates.count,
                let best = counts.max(), best > 0, counts.filter({ $0 == best }).count == 1,
                let index = counts.firstIndex(of: best)
            else { continue }
            plan.follow(item, to: candidates[index])
        }
    }

    /// Renames and moves categories in place. One the service refuses is left to the diff that
    /// follows, which adds the label and keeps or removes the category as before.
    static func apply(
        _ moves: [LabelMove], setId: String, categories initial: [CategoryItem], api: RecommenderAPI
    ) async throws -> Int {
        var categories = initial
        var moved = 0
        for move in moves {
            guard let item = categories.first(where: { $0.id == move.item.id }) else { continue }
            let target = LabelText.split(move.to)
            do {
                var parent = ParentChange.keep
                if let parentPath = target.parent {
                    let parentKey = LabelText.pathKey(parentPath)
                    let parentId: String
                    if let known = categories.first(where: {
                        $0.parentId == nil && LabelText.pathKey($0.path) == parentKey
                    }) {
                        parentId = known.id
                    } else {
                        parentId = try await api.addCategory(setId: setId, path: parentPath)
                    }
                    if item.parentId != parentId { parent = .under(parentId) }
                } else if item.parentId != nil {
                    parent = .topLevel
                }
                let name = LabelText.split(item.path).name == target.name ? nil : target.name
                guard name != nil || parent != .keep else { continue }
                try await api.updateCategory(id: item.id, name: name, parent: parent)
                moved += 1
            } catch ServiceError.api(status: 400, _, _) {
                // For example, the new name is too close to another category's.
            } catch ServiceError.api(status: 404, _, _) {
            }
            categories = try await api.getSet(id: setId).categories
        }
        return moved
    }
}
