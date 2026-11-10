import Foundation
import Testing

@testable import MailCore

/// Answers requests in-process, so these tests touch no network at all.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.bodies.append(data)
        }
        let (status, headers, data) = Self.handler?(request) ?? (500, [:], Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized)
struct ServiceClientTests {
    private func client() throws -> ServiceClient {
        StubProtocol.requests = []
        StubProtocol.bodies = []
        return try ServiceClient(protocolClasses: [StubProtocol.self])
    }

    @Test(arguments: [
        "http://127.0.0.1:8080", "http://localhost:8080", "http://[::1]:8080",
    ])
    func acceptsLoopback(url: String) {
        #expect(ServiceClient.isLoopback(URL(string: url)!))
    }

    @Test(arguments: [
        "http://192.168.1.10:8080", "https://example.com", "http://127.0.0.1.example.com:8080",
        "http://127.0.0.1@example.com/", "http://localhost.example.com", "ftp://127.0.0.1", "http://10.0.0.1",
    ])
    func refusesEverythingElse(url: String) {
        #expect(!ServiceClient.isLoopback(URL(string: url)!))
        #expect(throws: ServiceError.notLoopback) { try ServiceClient(baseURL: URL(string: url)!) }
    }

    @Test func aRedirectIsNotFollowed() async throws {
        // A real server is needed for a real redirect, so check the delegate decision directly:
        // the session must report the 3xx as an error rather than fetch the new address.
        let client = try client()
        StubProtocol.handler = { _ in (302, ["location": "http://example.com/steal"], Data()) }
        await #expect(throws: ServiceError.self) { _ = try await client.listSets() }
        #expect(StubProtocol.requests.allSatisfy { $0.url?.host == "127.0.0.1" })
    }

    @Test func newCategorySendsAnExplicitNullParent() throws {
        let data = try JSONEncoder().encode(NewCategory(parent: nil, name: "Trips"))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["parent"] is NSNull)
        #expect(object["name"] as? String == "Trips")
    }

    @Test func feedbackBodiesMatchTheContract() async throws {
        let client = try client()
        StubProtocol.handler = { _ in (201, [:], Data("{}".utf8)) }
        let email = Email(from: "a@example.test", subject: "s", body: "b")
        try await client.feedback(suggestionId: "ID", email: email, decision: .confirm)
        try await client.feedback(suggestionId: "ID", email: email, decision: .choose("Family"))
        try await client.feedback(
            suggestionId: "ID", email: email, decision: .acceptNew(NewCategory(parent: "Family", name: "Baby")))
        try await client.feedback(suggestionId: "ID", email: email, decision: .delete)
        let bodies = StubProtocol.bodies.map { try! JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        #expect(bodies[3]["decision"] as? String == "delete")
        #expect(bodies[3]["category"] == nil)
        #expect(bodies[0]["decision"] as? String == "confirm")
        #expect(bodies[0]["category"] == nil)
        #expect(bodies[1]["decision"] as? String == "choose")
        #expect(bodies[1]["category"] as? String == "Family")
        #expect(bodies[2]["decision"] as? String == "accept_new")
        #expect((bodies[2]["newCategory"] as? [String: Any])?["name"] as? String == "Baby")
        #expect(StubProtocol.requests[0].url?.path == "/v1/suggestions/ID/feedback")
        #expect(StubProtocol.requests[0].httpMethod == "POST")
    }

    @Test func suggestionRequestsSayWhetherDeletingIsPossibleAndWhatIsInTheTrash() async throws {
        let client = try client()
        StubProtocol.handler = { _ in (200, [:], Data(Self.suggestionJSON(action: #""action":"delete","#).utf8)) }
        let email = Email(from: "a@example.test", subject: "s", body: "b")
        let trash = [TrashedEmail(from: "a@example.test", subject: "older")]
        let suggestion = try await client.suggest(email: email, setId: "SET", allowDelete: true, trash: trash)
        #expect(suggestion.action == .delete)
        #expect(suggestion.similarInTrash == 1)
        _ = try await client.suggest(email: email, setId: "SET")
        let bodies = StubProtocol.bodies.map { try! JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        #expect(bodies[0]["allowDelete"] as? Bool == true)
        #expect((bodies[0]["trash"] as? [[String: String]]) == [["from": "a@example.test", "subject": "older"]])
        #expect(bodies[1]["allowDelete"] as? Bool == false)
        #expect((bodies[1]["trash"] as? [Any])?.isEmpty == true)
    }

    @Test func aSuggestionWithoutDeletionFieldsIsToFile() throws {
        let suggestion = try JSONDecoder().decode(Suggestion.self, from: Data(Self.suggestionJSON(action: "").utf8))
        #expect(suggestion.action == .file)
        #expect(suggestion.similarDeleted == 0)
    }

    private static func suggestionJSON(action: String) -> String {
        let deletion = action.isEmpty ? "" : #""similarDeleted":0,"similarInTrash":1,"#
        return #"{"suggestionId":"S","# + action + deletion
            + #""category":"Family","isNew":false,"confidence":"low","reason":"r","runnersUp":[],"#
            + #""similarPastDecisions":0,"truncated":false,"expiresAt":"2026-11-09T00:00:00Z"}"#
    }

    @Test func apiErrorsCarryTheirCode() async throws {
        let client = try client()
        StubProtocol.handler = { _ in
            (503, [:], Data(#"{"error":{"code":"llm_unavailable","message":"later"}}"#.utf8))
        }
        await #expect(throws: ServiceError.api(status: 503, code: "llm_unavailable", message: "later")) {
            _ = try await client.listSets()
        }
    }

    @Test func nothingIsSentAnywhereButTheBaseAddress() async throws {
        let client = try client()
        StubProtocol.handler = { _ in (200, [:], Data("[]".utf8)) }
        _ = try await client.listSets()
        #expect(StubProtocol.requests.count == 1)
        #expect(StubProtocol.requests[0].url?.host == "127.0.0.1")
        #expect(StubProtocol.requests[0].url?.port == 8080)
    }
}
