// HTTP client for the recommendation service (FR-022 of spec 002, FR-003 to FR-009 of spec 005).
// It talks to the service on this Mac over loopback, or, when the owner has set up their CA and a
// device certificate, to their recommender on the home network over HTTPS, after the recommender has
// proved itself with a certificate from that CA. It refuses any other address, follows no
// redirects, uses no proxy, and keeps no cache, cookies or credentials, so email text can neither
// leave the home network through it nor land on disk.
import Foundation
import Security

public enum ServiceError: Error, Equatable {
    /// The address is neither this Mac nor the home network (spec 005, research R3).
    case destinationRefused
    case unreachable
    /// The recommender could not prove it holds a certificate from the owner's CA. Nothing was sent.
    case untrusted
    /// The recommender refused this Mac's device certificate.
    case notAllowed
    /// This Mac's device certificate is not in the keychain.
    case noDeviceCertificate
    case api(status: Int, code: String, message: String)
    case badResponse(status: Int)
}

public protocol RecommenderAPI: Sendable {
    func listSets() async throws -> [CategorySetSummary]
    func createSet(name: String, categories: [String]) async throws -> String
    func getSet(id: String) async throws -> SetDetail
    func addCategory(setId: String, path: String) async throws -> String
    func deleteCategory(id: String, cascade: Bool) async throws
    /// Renames or moves a category. Its id, and so its learning, stay.
    func updateCategory(id: String, name: String?, parent: ParentChange) async throws
    /// The most recent emails learned for a category, newest first.
    func learnedEmails(categoryId: String, limit: Int) async throws -> [LearnedEmail]
    /// `allowDelete`: the window can act on a suggestion to delete. `trash`: emails from the same
    /// sender in the Trash, which the service uses as evidence and does not keep.
    func suggest(email: Email, setId: String, allowDelete: Bool, trash: [TrashedEmail]) async throws -> Suggestion
    func feedback(suggestionId: String, email: Email, decision: FeedbackDecision) async throws
}

extension RecommenderAPI {
    /// A first request with many labels can outlast the service's model timeout. The model keeps
    /// what it read in its prompt cache, so one retry usually answers at once. Both windows send
    /// exactly this request for an email (specs/004-batch-recommendations, SC-006).
    public func suggestWithRetry(
        email: Email, setId: String, allowDelete: Bool, trash: [TrashedEmail]
    ) async throws -> Suggestion {
        do {
            return try await suggest(email: email, setId: setId, allowDelete: allowDelete, trash: trash)
        } catch ServiceError.api(status: 503, code: "llm_unavailable", _) {
            return try await suggest(email: email, setId: setId, allowDelete: allowDelete, trash: trash)
        }
    }

    /// A suggestion that can only be a label.
    public func suggest(email: Email, setId: String) async throws -> Suggestion {
        try await suggest(email: email, setId: setId, allowDelete: false, trash: [])
    }
}

/// The session's own delegate refuses redirects only. Everything else, including the TLS challenges,
/// goes to the per-request `RequestDelegate`, which is why this one must not answer challenges.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// One per request: refuses redirects, checks the recommender against the owner's CA, answers with
/// this Mac's device certificate, and remembers why a request failed, so the caller can tell an
/// impostor from a Mac mini that is asleep.
private final class RequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let trust: RecommenderTrust?
    let deviceLabel: String?
    private let lock = NSLock()
    private var failure: ServiceError?

    init(trust: RecommenderTrust?, deviceLabel: String?) {
        self.trust = trust
        self.deviceLabel = deviceLabel
    }

    var recordedFailure: ServiceError? { lock.withLock { failure } }

    private func record(_ error: ServiceError) {
        lock.withLock { failure = failure ?? error }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard let trust else {
            // The service on this Mac: as before.
            return completionHandler(.performDefaultHandling, nil)
        }
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let serverTrust = space.serverTrust, trust.evaluate(serverTrust, host: space.host) else {
                record(.untrusted)
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        case NSURLAuthenticationMethodClientCertificate:
            guard let deviceLabel, let identity = trust.deviceIdentity(label: deviceLabel) else {
                record(.noDeviceCertificate)
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        default:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// A name's check against the home network, kept for a minute so a batch resolves it once.
private final class ResolutionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var checked: (host: String, ok: Bool, at: Date)?

    func isHomeNetwork(_ host: String, resolver: @escaping @Sendable (String) -> [String]?) async -> Bool {
        if let ok = cached(host) { return ok }
        let ok = await Task.detached { Destination.resolvesToHomeNetwork(host, resolver: resolver) }.value
        lock.withLock { checked = (host, ok, Date()) }
        return ok
    }

    private func cached(_ host: String) -> Bool? {
        lock.withLock {
            guard let checked, checked.host == host, Date().timeIntervalSince(checked.at) < 60 else { return nil }
            return checked.ok
        }
    }
}

public final class ServiceClient: RecommenderAPI, @unchecked Sendable {
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8080")!

    public let baseURL: URL
    private let session: URLSession
    private let trust: RecommenderTrust?
    private let deviceLabel: String?
    private let resolver: @Sendable (String) -> [String]?
    private let resolution = ResolutionCache()

    public static func isLoopback(_ url: URL) -> Bool { Destination.isLoopback(url) }

    /// A recommender on the home network, or one reached through the owner's CA.
    public var isRemote: Bool { trust != nil || !Destination.isLoopback(baseURL) }

    /// - Parameters:
    ///   - trust: the owner's CA, for a recommender on the home network.
    ///   - deviceLabel: this Mac's device certificate in the keychain.
    ///   - resolver: for tests only.
    ///   - protocolClasses: for tests only.
    public init(
        baseURL: URL = ServiceClient.defaultBaseURL, trust: RecommenderTrust? = nil, deviceLabel: String? = nil,
        resolver: @escaping @Sendable (String) -> [String]? = Destination.systemResolve,
        protocolClasses: [AnyClass]? = nil
    ) throws {
        guard Destination.check(baseURL, trusted: trust != nil && deviceLabel != nil) else {
            throw ServiceError.destinationRefused
        }
        self.baseURL = baseURL
        self.trust = trust
        self.deviceLabel = trust == nil ? nil : deviceLabel
        self.resolver = resolver
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

    /// Whether the base URL's name resolves into the home network. True for addresses.
    public func resolvesToHomeNetwork() async -> Bool {
        guard Destination.needsResolving(baseURL), let host = Destination.host(of: baseURL) else { return true }
        return await resolution.isHomeNetwork(host, resolver: resolver)
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
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
            url.host == baseURL.host, url.port == baseURL.port,
            Destination.check(url, trusted: deviceLabel != nil)
        else {
            throw ServiceError.destinationRefused
        }
        guard await resolvesToHomeNetwork() else { throw ServiceError.destinationRefused }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
        }
        let delegate = RequestDelegate(trust: trust, deviceLabel: deviceLabel)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: delegate)
        } catch {
            throw delegate.recordedFailure ?? Self.transportError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ServiceError.badResponse(status: 0) }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                if isRemote, http.statusCode == 403, envelope.error.code == "forbidden" {
                    throw ServiceError.notAllowed
                }
                throw ServiceError.api(
                    status: http.statusCode, code: envelope.error.code, message: envelope.error.message)
            }
            throw ServiceError.badResponse(status: http.statusCode)
        }
        return data
    }

    static func transportError(_ error: Error) -> ServiceError {
        switch (error as? URLError)?.code {
        case .clientCertificateRejected?, .clientCertificateRequired?: return .notAllowed
        default: return .unreachable
        }
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

    private struct UpdateCategoryBody: Encodable {
        let name: String?
        let parent: ParentChange

        enum CodingKeys: String, CodingKey { case name, parentId }

        /// Moving to the top level needs an explicit null, and keeping the parent needs no key.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(name, forKey: .name)
            switch parent {
            case .keep: break
            case .topLevel: try container.encodeNil(forKey: .parentId)
            case .under(let id): try container.encode(id, forKey: .parentId)
            }
        }
    }

    public func updateCategory(id: String, name: String?, parent: ParentChange) async throws {
        let body = try JSONEncoder().encode(UpdateCategoryBody(name: name, parent: parent))
        // A new name is embedded for the near-duplicate check.
        _ = try await send("PATCH", "/v1/categories/\(id)", body: body, timeout: 60)
    }

    private struct LearnedPage: Decodable {
        struct Item: Decodable {
            let sender: String
            let subject: String
        }
        let items: [Item]
    }

    public func learnedEmails(categoryId: String, limit: Int) async throws -> [LearnedEmail] {
        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "categoryId", value: categoryId), URLQueryItem(name: "limit", value: String(limit)),
        ]
        let data = try await send("GET", "/v1/learning-examples?\(query.percentEncodedQuery ?? "")")
        return try decode(LearnedPage.self, data).items.map { LearnedEmail(from: $0.sender, subject: $0.subject) }
    }

    private struct SuggestBody: Encodable {
        let email: Email
        let categorySetId: String
        let allowDelete: Bool
        let trash: [TrashedEmail]
    }

    private struct InlineSuggestBody: Encodable {
        let email: Email
        let categories: [String]
    }

    /// A suggestion among categories given with the request, so no category set is created. For the
    /// remote self-test, which never sends feedback for it: the suggestion expires on the service.
    public func suggest(email: Email, categories: [String]) async throws -> Suggestion {
        let body = try JSONEncoder().encode(InlineSuggestBody(email: email, categories: categories))
        return try decode(Suggestion.self, try await send("POST", "/v1/suggestions", body: body, timeout: 180))
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
