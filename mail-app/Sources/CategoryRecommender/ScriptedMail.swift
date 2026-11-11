// MailSource over the bridge script. Each call is one `osascript` child process, so a slow Mail
// cannot freeze the window. The Automation permission belongs to this app, its parent.
import Foundation
import MailCore

struct ScriptedMail: MailSource {
    let script: URL

    private struct Reply<Result: Decodable>: Decodable {
        struct Failure: Decodable {
            let number: Int
            let message: String
        }
        let ok: Bool
        let result: Result?
        let error: Failure?
    }

    private struct Empty: Decodable {}

    private struct Command: Encodable {
        let command: String
        var account: String?
        var target: String?
        var path: String?
        var items: [FileItem]?
        var stamp: Int?
        var mbox: String?
        var titles: [String]?
        var messageIds: [String]?
        var sender: String?
        var limit: Int?
        var mailboxes: [String]?
        var emails: [LearnedEmail]?
    }

    private func call<Result: Decodable>(_ command: Command, timeout: TimeInterval) async throws -> Result {
        let argument = try BridgeJSON.encode(command)
        let output = try await Self.run(
            arguments: ["-l", "JavaScript", script.path, argument], timeout: timeout)
        guard let reply = try? JSONDecoder().decode(Reply<Result>.self, from: output) else {
            // osascript itself failed before the script could report anything.
            let text = String(decoding: output, as: UTF8.self)
            if text.contains("-1743") { throw MailError.notAuthorized }
            throw MailError.script(number: 0, message: "Mail gave an unexpected answer.")
        }
        if reply.ok, let result = reply.result { return result }
        let failure = reply.error
        switch failure?.number {
        case -1743: throw MailError.notAuthorized
        case -600: throw MailError.mailNotRunning
        case -1712: throw MailError.timedOut
        case -1728: throw MailError.notFound(failure?.message ?? "Not found in Mail.")
        default:
            throw MailError.script(number: failure?.number ?? 0, message: failure?.message ?? "Mail reported an error.")
        }
    }

    /// Runs osascript and returns its standard output. Standard error goes along for error codes.
    private static func run(arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: MailError.script(number: 0, message: "Could not run osascript."))
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let errorData = DispatchQueue.global()
                var collected = Data()
                let group = DispatchGroup()
                group.enter()
                errorData.async {
                    collected = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                killer.cancel()
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: MailError.timedOut)
                } else {
                    continuation.resume(returning: output.isEmpty ? collected : output)
                }
            }
        }
    }

    func opening() async throws -> MailOpening {
        try await call(Command(command: "opening"), timeout: 45)
    }

    func labels(account: String) async throws -> AccountLabels {
        try await call(Command(command: "labels", account: account), timeout: 30)
    }

    func file(_ items: [FileItem], into target: String, account: String) async throws {
        let timeout = 30 + TimeInterval(items.count)
        let _: Empty = try await call(
            Command(command: "file", account: account, target: target, items: items), timeout: timeout)
    }

    /// One fabricated message in a mailbox file, for --self-test-local.
    private static func syntheticMailbox(stamp: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catrec-selftest-\(stamp)")
        let mailbox = root.appendingPathComponent("catrec-selftest-\(stamp).mbox")
        try FileManager.default.createDirectory(at: mailbox, withIntermediateDirectories: true)
        let content = [
            "From selftest@example.test Thu Nov  5 12:00:00 2026",
            "From: Self Test <selftest@example.test>",
            "To: owner@example.test",
            "Subject: Self-test subject",
            "Date: Thu, 05 Nov 2026 12:00:00 +0000",
            "Message-ID: <catrec-selftest-\(stamp)@example.test>",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "Self-test body. This message is fabricated.",
            "",
        ].joined(separator: "\n")
        try content.write(to: mailbox.appendingPathComponent("mbox"), atomically: true, encoding: .utf8)
        return mailbox
    }

    private struct Created: Decodable { let created: Bool }

    @discardableResult
    func createLabel(_ path: String, account: String) async throws -> Bool {
        let reply: Created = try await call(Command(command: "create", account: account, path: path), timeout: 45)
        return reply.created
    }

    private struct Archived: Decodable { let result: ArchiveResult }

    func archive(messageIds: [String], account: String) async throws -> ArchiveResult {
        let reply: Archived = try await call(
            Command(
                command: "archive", account: account, titles: Self.menuTitles(.archive), messageIds: messageIds),
            // The first time, macOS may ask for permission to use System Events while this runs.
            timeout: 120)
        return reply.result
    }

    func trashSimilar(sender: String, messageIds: [String], account: String) async throws -> TrashLookup {
        try await call(
            Command(command: "trashSimilar", account: account, messageIds: messageIds, sender: sender, limit: 20),
            timeout: 30)
    }

    private struct Held: Decodable { let counts: [Int] }

    func holding(_ emails: [LearnedEmail], in mailboxes: [String], account: String) async throws -> [Int] {
        let reply: Held = try await call(
            Command(command: "holding", account: account, mailboxes: mailboxes, emails: emails),
            timeout: 30)
        return reply.counts
    }

    private struct Trashed: Decodable { let result: TrashResult }

    func moveToTrash(messageIds: [String], account: String) async throws -> TrashResult {
        let reply: Trashed = try await call(
            Command(command: "trash", account: account, titles: Self.menuTitles(.delete), messageIds: messageIds),
            // The first time, macOS may ask for permission to use System Events while this runs.
            timeout: 120)
        return reply.result
    }

    private struct Started: Decodable {
        let automatic: Bool
        let problem: MenuProblem?
    }
    private struct Exists: Decodable { let exists: Bool }

    func beginDeleteLabel(_ path: String, account: String) async throws -> DeleteStart {
        let reply: Started = try await call(
            Command(command: "deleteBegin", account: account, path: path, titles: Self.menuTitles(.deleteMailbox)),
            // The first time, macOS may ask for permission to use System Events while this runs.
            timeout: 120)
        return reply.automatic ? .confirmInMail : .chooseInMail(reply.problem ?? .notAllowed)
    }

    func labelExists(_ path: String, account: String) async throws -> Bool {
        let reply: Exists = try await call(Command(command: "exists", account: account, path: path), timeout: 15)
        return reply.exists
    }

    enum MenuCommand {
        case deleteMailbox
        case archive
        /// Edit > Delete, which moves the selected emails to the Trash.
        case delete

        /// Where Mail keeps the title, and the English title as a fallback.
        var source: (table: String, key: String, english: String) {
            switch self {
            case .deleteMailbox: return ("Localizable", "DeleteMailboxMenuItem", "Delete Mailbox\u{2026}")
            case .archive: return ("MainMenu", "1100456.title", "Archive")
            case .delete: return ("MainMenu", "1649.title", "Delete")
            }
        }
    }

    /// The title of one of Mail's menu commands, in every language Mail has.
    static func menuTitles(_ command: MenuCommand) -> [String] {
        let (table, key, english) = command.source
        let url = URL(fileURLWithPath: "/System/Applications/Mail.app/Contents/Resources/\(table).loctable")
        var titles: Set<String> = [english]
        if let data = try? Data(contentsOf: url),
            let languages = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        {
            for case let strings as [String: Any] in languages.values {
                if let title = strings[key] as? String { titles.insert(title) }
            }
        }
        return Array(titles)
    }

    private struct Count: Decodable { let count: Int }

    func messageCount(_ path: String, account: String) async throws -> Int {
        let reply: Count = try await call(Command(command: "count", account: account, path: path), timeout: 20)
        return reply.count
    }

    /// Diagnostics print whatever the bridge returns; those commands carry counts and pass or fail only.
    func rawCheck(_ command: String, timeout: TimeInterval) async throws -> String {
        let stamp = Int(Date().timeIntervalSince1970)
        let mbox = command == "selftestLocal" ? try? Self.syntheticMailbox(stamp: stamp) : nil
        defer { if let mbox { try? FileManager.default.removeItem(at: mbox.deletingLastPathComponent()) } }
        let titles = command == "selftestAccount" ? Self.menuTitles(.archive) : nil
        let argument = try BridgeJSON.encode(
            Command(command: command, stamp: stamp, mbox: mbox?.path, titles: titles))
        let output = try await Self.run(
            arguments: ["-l", "JavaScript", script.path, argument], timeout: timeout)
        return String(decoding: output, as: UTF8.self)
    }
}
