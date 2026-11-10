// HTTP client for the service on this computer (FR-022). It refuses any address other than
// loopback, follows no redirects, uses no proxy, and keeps no cache or cookies, so email text can
// neither leave this computer through it nor land on disk.
import Foundation

public enum ServiceError: Error, Equatable {
    case notLoopback
    case unreachable
    case api(status: Int, code: String, message: String)
    case badResponse(status: Int)
}

public protocol RecommenderAPI: Sendable {
    func listSets() async throws -> [CategorySetSummary]
    func createSet(name: String, categories: [String]) async throws -> String
    func getSet(id: String) async throws -> SetDetail
    func addCategory(setId: String, path: String) async throws -> String
    func deleteCategory(id: String, cascade: Bool) async throws
    /// `allowDelete`: the window can act on a suggestion to delete. `trash`: emails from the same
    /// sender in the Trash, which the service uses as evidence and does not keep.
    func suggest(email: Email, setId: String, allowDelete: Bool, trash: [TrashedEmail]) async throws -> Suggestion
    func feedback(suggestionId: String, email: Email, decision: FeedbackDecision) async throws
}

extension RecommenderAPI {
    /// A suggestion that can only be a label.
    public func suggest(email: Email, setId: String) async throws -> Suggestion {
        try await suggest(email: email, setId: setId, allowDelete: false, trash: [])
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public final class ServiceClient: RecommenderAPI, @unchecked Sendable {
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8080")!
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    public let baseURL: URL
    private let session: URLSession

    public static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https", let host = url.host else { return false }
        return url.user == nil && loopbackHosts.contains(host.lowercased())
    }

    /// - Parameter protocolClasses: for tests only.
    public init(baseURL: URL = ServiceClient.defaultBaseURL, protocolClasses: [AnyClass]? = nil) throws {
        guard Self.isLoopback(baseURL) else { throw ServiceError.notLoopback }
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        config.waitsForConnectivity = false
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    private struct ErrorEnvelope: Decodable {
        struct Inner: Decodable {
            let code: String
            let message: String
        }
        let error: Inner
    }

    private func send(
        _ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 20
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL, Self.isLoopback(url) else {
            throw ServiceError.notLoopback
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServiceError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw ServiceError.badResponse(status: 0) }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw ServiceError.api(
                    status: http.statusCode, code: envelope.error.code, message: envelope.error.message)
            }
            throw ServiceError.badResponse(status: http.statusCode)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, status: Int = 200) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ServiceError.badResponse(status: status)
        }
    }

    private struct IdResponse: Decodable { let id: String }

    public func health() async throws -> Health {
        try decode(Health.self, try await send("GET", "/v1/health", timeout: 5))
    }

    public func listSets() async throws -> [CategorySetSummary] {
        try decode([CategorySetSummary].self, try await send("GET", "/v1/category-sets"))
    }

    private struct CreateSetBody: Encodable {
        let name: String
        let categories: [String]
    }

    public func createSet(name: String, categories: [String]) async throws -> String {
        let body = try JSONEncoder().encode(CreateSetBody(name: name, categories: categories))
        // The service embeds every category name while creating the set.
        let data = try await send("POST", "/v1/category-sets", body: body, timeout: 120)
        return try decode(IdResponse.self, data).id
    }

    public func getSet(id: String) async throws -> SetDetail {
        try decode(SetDetail.self, try await send("GET", "/v1/category-sets/\(id)"))
    }

    private struct AddCategoryBody: Encodable { let path: String }

    public func addCategory(setId: String, path: String) async throws -> String {
        let body = try JSONEncoder().encode(AddCategoryBody(path: path))
        let data = try await send("POST", "/v1/category-sets/\(setId)/categories", body: body, timeout: 60)
        return try decode(IdResponse.self, data).id
    }

    public func deleteCategory(id: String, cascade: Bool) async throws {
        _ = try await send("DELETE", "/v1/categories/\(id)?cascade=\(cascade)")
    }

    private struct SuggestBody: Encodable {
        let email: Email
        let categorySetId: String
        let allowDelete: Bool
        let trash: [TrashedEmail]
    }

    public func suggest(
        email: Email, setId: String, allowDelete: Bool, trash: [TrashedEmail]
    ) async throws -> Suggestion {
        let body = try JSONEncoder().encode(
            SuggestBody(email: email, categorySetId: setId, allowDelete: allowDelete, trash: trash))
        // Requests queue behind one another and may wait for the model to load.
        let data = try await send("POST", "/v1/suggestions", body: body, timeout: 180)
        return try decode(Suggestion.self, data)
    }

    private struct FeedbackBody: Encodable {
        let email: Email
        let decision: String
        var category: String?
        var newCategory: NewCategory?
    }

    public func feedback(suggestionId: String, email: Email, decision: FeedbackDecision) async throws {
        let body: FeedbackBody
        switch decision {
        case .confirm:
            body = FeedbackBody(email: email, decision: "confirm")
        case .choose(let path):
            body = FeedbackBody(email: email, decision: "choose", category: path)
        case .acceptNew(let category):
            body = FeedbackBody(email: email, decision: "accept_new", newCategory: category)
        case .delete:
            body = FeedbackBody(email: email, decision: "delete")
        }
        let data = try JSONEncoder().encode(body)
        _ = try await send("POST", "/v1/suggestions/\(suggestionId)/feedback", body: data, timeout: 60)
    }
}
