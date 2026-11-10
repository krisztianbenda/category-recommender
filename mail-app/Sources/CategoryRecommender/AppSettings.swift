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
        if let text = ProcessInfo.processInfo.environment["CATREC_BASE_URL"] ?? defaults.string(forKey: "baseURL"),
            let url = URL(string: text)
        {
            return url
        }
        return ServiceClient.defaultBaseURL
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
