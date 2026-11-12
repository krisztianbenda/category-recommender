// Types of the service's HTTP API (specs/001-local-llm-categorizer/contracts/http-api.md).
import Foundation

public struct Email: Codable, Equatable, Sendable {
    public var from: String
    public var to: [String]?
    public var subject: String
    public var body: String

    public init(from: String, to: [String]? = nil, subject: String, body: String) {
        self.from = from
        self.to = to
        self.subject = subject
        self.body = body
    }
}

public enum Confidence: String, Codable, Sendable {
    case high, medium, low
}

public struct RankedCategory: Codable, Equatable, Sendable {
    public let path: String
    public let score: Double

    public init(path: String, score: Double) {
        self.path = path
        self.score = score
    }
}

public struct NewCategory: Codable, Equatable, Sendable {
    public let parent: String?
    public let name: String

    public init(parent: String?, name: String) {
        self.parent = parent
        self.name = name
    }

    /// The API requires `parent` to be present, so a missing parent is sent as an explicit null.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(parent, forKey: .parent)
        try container.encode(name, forKey: .name)
    }

    public var path: String { parent.map { "\($0)/\(name)" } ?? name }
}

/// What a suggestion asks the owner to do with the email.
public enum SuggestedAction: String, Codable, Sendable {
    case file
    /// Move it to the Trash. `category` is then where it would go if kept.
    case delete
}

public struct Suggestion: Codable, Equatable, Sendable {
    public let suggestionId: String
    public let action: SuggestedAction
    public let category: String
    public let isNew: Bool
    public let newCategory: NewCategory?
    public let confidence: Confidence
    public let reason: String
    public let runnersUp: [RankedCategory]
    public let similarPastDecisions: Int
    /// Of those, how many the owner deleted.
    public let similarDeleted: Int
    /// Similar emails from the same sender in the Trash.
    public let similarInTrash: Int
    public let truncated: Bool

    public init(
        suggestionId: String, action: SuggestedAction = .file, category: String, isNew: Bool = false,
        newCategory: NewCategory? = nil, confidence: Confidence = .high, reason: String = "",
        runnersUp: [RankedCategory] = [], similarPastDecisions: Int = 0, similarDeleted: Int = 0,
        similarInTrash: Int = 0, truncated: Bool = false
    ) {
        self.suggestionId = suggestionId
        self.action = action
        self.category = category
        self.isNew = isNew
        self.newCategory = newCategory
        self.confidence = confidence
        self.reason = reason
        self.runnersUp = runnersUp
        self.similarPastDecisions = similarPastDecisions
        self.similarDeleted = similarDeleted
        self.similarInTrash = similarInTrash
        self.truncated = truncated
    }

    /// A service from before deletion was suggested sends none of the deletion fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        suggestionId = try c.decode(String.self, forKey: .suggestionId)
        action = try c.decodeIfPresent(SuggestedAction.self, forKey: .action) ?? .file
        category = try c.decode(String.self, forKey: .category)
        isNew = try c.decode(Bool.self, forKey: .isNew)
        newCategory = try c.decodeIfPresent(NewCategory.self, forKey: .newCategory)
        confidence = try c.decode(Confidence.self, forKey: .confidence)
        reason = try c.decode(String.self, forKey: .reason)
        runnersUp = try c.decode([RankedCategory].self, forKey: .runnersUp)
        similarPastDecisions = try c.decode(Int.self, forKey: .similarPastDecisions)
        similarDeleted = try c.decodeIfPresent(Int.self, forKey: .similarDeleted) ?? 0
        similarInTrash = try c.decodeIfPresent(Int.self, forKey: .similarInTrash) ?? 0
        truncated = try c.decode(Bool.self, forKey: .truncated)
    }
}

public struct CategorySetSummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    public let categoryCount: Int

    public init(id: String, name: String, isDefault: Bool = false, categoryCount: Int = 0) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.categoryCount = categoryCount
    }
}

public struct CategoryItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let parentId: String?
    public let exampleCount: Int

    public init(id: String, path: String, parentId: String? = nil, exampleCount: Int = 0) {
        self.id = id
        self.path = path
        self.parentId = parentId
        self.exampleCount = exampleCount
    }
}

/// Where a category goes when it is updated.
public enum ParentChange: Equatable, Sendable {
    case keep
    case topLevel
    case under(String)
}

public struct SetDetail: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    public let categories: [CategoryItem]

    public init(id: String, name: String, isDefault: Bool = false, categories: [CategoryItem]) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.categories = categories
    }
}

public struct Health: Codable, Equatable, Sendable {
    public let status: String
    public let llm: String
    public let embeddings: String

    public var isReady: Bool { status == "ok" }
}

public enum FeedbackDecision: Equatable, Sendable {
    case confirm
    case choose(String)
    case acceptNew(NewCategory)
    /// The owner moved the email to the Trash.
    case delete
}
