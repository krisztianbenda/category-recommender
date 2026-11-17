// Turns what the owner did with an email into feedback for the service, so that it is learned.
// Shared by the single-email window and the batch window.
import Foundation

public struct Learning: Sendable {
    public typealias Suggest = @Sendable (Email, String) async throws -> Suggestion

    let api: RecommenderAPI
    let catalog: LabelCatalog
    let setId: String?
    /// Fresh suggestions, made when a category was added after the email's suggestion. The batch
    /// passes its own queue, so that the model still answers one request at a time.
    let suggest: Suggest

    public init(api: RecommenderAPI, catalog: LabelCatalog, setId: String?, suggest: Suggest? = nil) {
        self.api = api
        self.catalog = catalog
        self.setId = setId
        self.suggest = suggest ?? { email, setId in try await api.suggest(email: email, setId: setId) }
    }

    /// `alreadyAdded`: an earlier email of the same batch action created this label's category, so
    /// it is no longer new, and is taught through a fresh suggestion (research R5).
    public func send(
        suggestion: Suggestion, action: RowAction, email: Email, alreadyAdded: Bool = false
    ) async throws {
        switch action {
        case .trash:
            try await api.feedback(suggestionId: suggestion.suggestionId, email: email, decision: .delete)
        case .existing(let entry):
            if alreadyAdded { return try await choose(entry.path, email: email) }
            guard catalog.isConsidered(entry) else { return }
            // When deleting was suggested, "confirm" would mean delete: filing is a choice then.
            let isSuggested =
                suggestion.action == .file && !suggestion.isNew
                && LabelText.pathKey(suggestion.category) == entry.key
            try await api.feedback(
                suggestionId: suggestion.suggestionId, email: email,
                decision: isSuggested ? .confirm : .choose(entry.path))
        case .acceptProposal(let proposal):
            if alreadyAdded { return try await choose(proposal.path, email: email) }
            try await api.feedback(
                suggestionId: suggestion.suggestionId, email: email,
                decision: suggestion.action == .file ? .confirm : .acceptNew(proposal))
        case .recreate(let path):
            try await api.feedback(
                suggestionId: suggestion.suggestionId, email: email,
                decision: suggestion.action == .file ? .confirm : .choose(path))
        case .createTyped(let mailbox):
            guard let new = catalog.newCategory(forMailbox: mailbox) else { return }
            if alreadyAdded { return try await choose(new.category.path, email: email) }
            if new.parentIsKnown {
                do {
                    try await api.feedback(
                        suggestionId: suggestion.suggestionId, email: email, decision: .acceptNew(new.category))
                    return
                } catch ServiceError.api(status: 400, _, _) {
                    // Too close to an existing name for accept_new; add it explicitly below.
                }
            }
            try await addThenChoose(new.category.path, email: email)
        }
    }

    /// `accept_new` only takes parents the suggestion knew about. For anything else, add the
    /// category and teach through a fresh suggestion.
    func addThenChoose(_ path: String, email: Email) async throws {
        guard let setId else { return }
        _ = try await api.addCategory(setId: setId, path: path)
        try await choose(path, email: email)
    }

    /// Teaches a category that exists now but did not when the email's suggestion was made.
    func choose(_ path: String, email: Email) async throws {
        guard let setId else { return }
        let fresh = try await suggest(email, setId)
        try await api.feedback(suggestionId: fresh.suggestionId, email: email, decision: .choose(path))
    }
}
