// Preferences and install-time configuration. Nothing here is hard-coded per host (constitution IV):
// the installer writes install.json into the app bundle.
import Foundation
import MailCore

final class AppSettings: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["idleMinutes": 30.0])
    }

    var keepInInbox: Bool {
        get { defaults.bool(forKey: "keepInInbox") }
        set { defaults.set(newValue, forKey: "keepInInbox") }
    }

    var idleMinutes: Double { max(1, defaults.double(forKey: "idleMinutes")) }

    var baseURL: URL {
        if let text = setting("CATREC_BASE_URL", "baseURL"), let url = URL(string: text) {
            return url
        }
        return ServiceClient.defaultBaseURL
    }

    // A recommender on the home network (specs/005-mail-app-lan, contracts/client-settings.md).

    /// Path to the copy of the owner's CA certificate.
    var caCertificate: String? { setting("CATREC_CA_FILE", "caCertificate") }
    /// Label of this Mac's identity in the keychain. Never a key.
    var deviceCertificate: String? { setting("CATREC_DEVICE_CERT", "deviceCertificate") }
    /// For tests only: a keychain file to search instead of the user's keychains.
    var testKeychain: String? { setting("CATREC_KEYCHAIN", nil) }
    var recommenderName: String? { setting(nil, "recommenderName") }

    private func setting(_ variable: String?, _ key: String?) -> String? {
        let text = variable.flatMap { ProcessInfo.processInfo.environment[$0] } ?? key.flatMap { defaults.string(forKey: $0) }
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }

    /// What the menu and the windows call a recommender on the home network.
    func displayName(for url: URL) -> String {
        if let recommenderName { return recommenderName }
        var host = url.host ?? "the recommender"
        if host.lowercased().hasSuffix(".local") { host = String(host.dropLast(".local".count)) }
        return host.replacingOccurrences(of: "-", with: " ")
    }

    enum Refusal: Error {
        case address, missingTrust, badCA

        var message: String {
            switch self {
            case .address: return "Refused: the recommender's address is not on this Mac or the home network."
            case .missingTrust: return "A recommender on the home network needs caCertificate and deviceCertificate."
            case .badCA: return "caCertificate is not a readable certificate file."
            }
        }
    }

    /// The client these settings describe, after the start-up rules of the settings contract.
    func makeClient() throws -> ServiceClient {
        let url = baseURL
        guard Destination.isLoopback(url) && caCertificate == nil else {
            guard let caCertificate, let deviceCertificate else {
                throw Destination.check(url, trusted: true) ? Refusal.missingTrust : Refusal.address
            }
            guard Destination.check(url, trusted: true) else { throw Refusal.address }
            guard let pem = FileManager.default.contents(atPath: caCertificate),
                let trust = try? RecommenderTrust(caPEM: pem, keychainPath: testKeychain)
            else { throw Refusal.badCA }
            return try ServiceClient(baseURL: url, trust: trust, deviceLabel: deviceCertificate)
        }
        do {
            return try ServiceClient(baseURL: url)
        } catch {
            throw Refusal.address
        }
    }
}

struct InstallInfo: Decodable {
    let runLocalScript: String
    let path: String

    static func load() -> InstallInfo? {
        guard let url = Bundle.main.url(forResource: "install", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(InstallInfo.self, from: data)
    }
}

/// What the app runs against: the real Mail, or a synthetic one in demo mode.
struct AppEnvironment {
    let mail: MailSource
    let client: ServiceClient
    let backend: Backend
    let log: EventLog
}
