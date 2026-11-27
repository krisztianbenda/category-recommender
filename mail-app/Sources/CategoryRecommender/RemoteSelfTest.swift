// --self-test-remote (specs/005-mail-app-lan, contracts/self-test-remote.md): checks the connection
// to a recommender on the home network, step by step, with a fabricated email. It creates no category
// set and sends no feedback, so nothing is learned. The report has results and fixed hints only: no
// address, no certificate field, no content.
import Foundation
import MailCore
import Network

struct RemoteSelfTest {
    let client: ServiceClient

    static let steps = ["address", "reachable", "identity", "accepted", "model", "timing"]

    static let fabricatedEmail = Email(
        from: "Self Test <selftest@example.test>", subject: "Self-test",
        body: "A fabricated email, to time one recommendation. It is not filed and not learned.")
    static let fabricatedLabels = ["Self-test/First", "Self-test/Second"]

    private struct Report {
        var results: [(name: String, result: String, hint: String?)] = []
        var timingMs: Int?

        mutating func pass(_ name: String) { results.append((name, "pass", nil)) }

        mutating func fail(_ name: String, _ hint: String) { results.append((name, "fail", hint)) }

        func json() -> String {
            var steps: [[String: String]] = results.map { step in
                var item = ["name": step.name, "result": step.result]
                if let hint = step.hint { item["hint"] = hint }
                return item
            }
            for name in RemoteSelfTest.steps.dropFirst(results.count) {
                steps.append(["name": name, "result": "not_run"])
            }
            var object: [String: Any] = [
                "ok": results.count == RemoteSelfTest.steps.count && results.allSatisfy { $0.result == "pass" },
                "steps": steps,
            ]
            if let timingMs { object["timingMs"] = timingMs }
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
    }

    static func write(_ text: String, to path: String?) {
        if let path {
            try? (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }

    /// The settings were refused at start-up, before any connection.
    static func writeRefused(_ refusal: AppSettings.Refusal, to path: String?) {
        var report = Report()
        report.fail("address", refusal.message)
        write(report.json(), to: path)
    }

    func run(to path: String?) async {
        Self.write(await report().json(), to: path)
    }

    private func report() async -> Report {
        var report = Report()
        guard client.isRemote else {
            report.fail("address", "This app is set up for the service on this Mac.")
            return report
        }
        guard await client.resolvesToHomeNetwork() else {
            report.fail("address", "The address is not on this Mac or the home network.")
            return report
        }
        report.pass("address")

        let port = client.baseURL.port ?? 443
        guard let host = client.baseURL.host, await Self.connects(host: host, port: port, within: 5) else {
            report.fail(
                "reachable",
                "Is the Mac mini awake and on this network? Is Local Network allowed for Category Recommender in "
                    + "System Settings > Privacy & Security?")
            return report
        }
        report.pass("reachable")

        let health: Health
        do {
            health = try await client.health()
            report.pass("identity")
            report.pass("accepted")
        } catch ServiceError.noDeviceCertificate {
            report.pass("identity")
            report.fail("accepted", "Not installed: open this Mac's .p12 file to add it to the keychain.")
            return report
        } catch ServiceError.notAllowed {
            report.pass("identity")
            report.fail("accepted", "Refused: add this device's fingerprint to access.devices on the recommender.")
            return report
        } catch {
            report.fail(
                "identity", "The recommender's certificate is not from your CA, or does not name this address.")
            return report
        }
        guard health.isReady else {
            report.fail("model", "The model on the recommender is not ready yet.")
            return report
        }
        report.pass("model")

        let started = Date()
        do {
            _ = try await client.suggest(email: Self.fabricatedEmail, categories: Self.fabricatedLabels)
            report.timingMs = Int(Date().timeIntervalSince(started) * 1000)
            report.pass("timing")
        } catch {
            report.fail("timing", "The recommender did not answer in time.")
        }
        return report
    }

    /// Whether a TCP connection opens. A refused or unroutable connection fails at once.
    static func connects(host: String, port: Int, within seconds: Double) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let answer = Once()
        return await withCheckedContinuation { continuation in
            let finish = { (ok: Bool) in
                if answer.claim() {
                    connection.cancel()
                    continuation.resume(returning: ok)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(false) }
        }
    }
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
