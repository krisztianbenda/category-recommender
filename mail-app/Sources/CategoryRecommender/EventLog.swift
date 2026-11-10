// Metadata-only log: event names and numbers. Never subjects, addresses, labels or email text
// (FR-023, constitution). The path can be overridden for tests.
import Foundation

final class EventLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    func log(_ event: String, _ numbers: [String: Int] = [:]) {
        let details = numbers.sorted { $0.key < $1.key }.map { " \($0.key)=\($0.value)" }.joined()
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(event)\(details)\n"
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}
