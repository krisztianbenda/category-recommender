// Keeps a category set in step with the account's labels. It is a diff, so category ids, and the
// learning attached to them, survive (FR-004). Learned decisions are never dropped without the
// owner's say-so (FR-007, constitution V).
import Foundation

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
}

public enum LabelSync {
    /// The API takes this many categories when creating a set.
    static let createLimit = 500

    /// One category set per account. Gmail's name is from before other accounts were supported,
    /// and stays, because the learning hangs on it.
    public static func setName(address: String, kind: AccountKind = .gmail) -> String {
        "\(kind == .gmail ? "Gmail" : "Mail"): \(String(address.prefix(73)))"
    }

    public static func run(api: RecommenderAPI, setName: String, catalog: LabelCatalog) async throws -> SyncResult {
        let key = LabelText.normalise(setName)
        let setId: String
        if let existing = try await api.listSets().first(where: { LabelText.normalise($0.name) == key }) {
            setId = existing.id
        } else {
            let paths = catalog.considered.map(\.path)
            setId = try await api.createSet(name: setName, categories: Array(paths.prefix(createLimit)))
        }

        var detail = try await api.getSet(id: setId)
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
        return SyncResult(setId: setId, categories: detail.categories, orphaned: plan.orphaned, failed: failed)
    }
}
