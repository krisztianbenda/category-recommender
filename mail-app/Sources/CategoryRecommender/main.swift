// Entry point. With no arguments this is the menu bar app. The other modes exist for checks:
//   --diagnose --out FILE          counts about the real Mail, no names or text
//   --self-test-local --out FILE   real Mail, temporary local mailboxes, pass or fail only
//   --self-test-account --out FILE owner-run check on the selected email, in any account, pass or
//                                  fail only (--self-test-gmail is the old name)
//   --demo [--newsletter] [--snapshot FILE]
//                                  synthetic Mail, nothing real is touched; --newsletter shows
//                                  an email like three in the synthetic Trash
import AppKit
import Foundation
import MailCore

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

let settings = AppSettings()
let bridgeScript =
    Bundle.main.url(forResource: "mail-bridge", withExtension: "js")
    ?? URL(fileURLWithPath: value(after: "--bridge") ?? "Resources/mail-bridge.js")
let scriptedMail = ScriptedMail(script: bridgeScript)

let check: (String, TimeInterval)? =
    arguments.contains("--diagnose")
    ? ("diagnose", 180)
    : arguments.contains("--self-test-local")
        ? ("selftestLocal", 300)
        : arguments.contains("--self-test-account") || arguments.contains("--self-test-gmail")
            ? ("selftestAccount", 400) : nil

if let (command, timeout) = check {
    Task {
        var text: String
        do {
            text = try await scriptedMail.rawCheck(command, timeout: timeout)
            if command == "diagnose" {
                // Times what the window does when it opens. Keeps only the time and the counts.
                let started = Date()
                let opening = try? await scriptedMail.opening()
                let labels = opening?.labels.map { LabelCatalog(mailboxes: $0.mailboxes).entries.count } ?? -1
                let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
                text += "\n{\"openingMilliseconds\":\(milliseconds),\"labelsForSelectedEmail\":\(labels)}"
            }
        } catch {
            text = "{\"ok\":false,\"error\":{\"number\":0,\"message\":\"\(RecommenderSession.describe(error))\"}}"
        }
        if let out = value(after: "--out") {
            try? (text + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
        exit(0)
    }
    RunLoop.main.run()
}

guard let client = try? ServiceClient(baseURL: settings.baseURL) else {
    FileHandle.standardError.write(Data("Refused: the service address must be on this computer.\n".utf8))
    exit(2)
}

let logURL = ProcessInfo.processInfo.environment["CATREC_MAIL_LOG"].map(URL.init(fileURLWithPath:))
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".catrec/logs/mail-app.log")
let log = EventLog(url: logURL)
let launch = InstallInfo.load().map {
    Backend.Launch(script: URL(fileURLWithPath: $0.runLocalScript), path: $0.path)
}
let backend = Backend(client: client, launch: launch, idleMinutes: settings.idleMinutes, logger: log)

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

MainActor.assumeIsolated {
    if arguments.contains("--demo") {
        let demoSettings = AppSettings(defaults: UserDefaults(suiteName: "com.catrec.mail.demo")!)
        let demo = arguments.contains("--newsletter") ? DemoMail.newsletter() : DemoMail()
        let environment = AppEnvironment(mail: demo, client: client, backend: backend, log: log)
        let delegate = AppDelegate(settings: demoSettings, environment: environment)
        application.delegate = delegate
        runDemo(delegate)
        withExtendedLifetime(delegate) { application.run() }
    } else {
        let environment = AppEnvironment(mail: scriptedMail, client: client, backend: backend, log: log)
        let delegate = AppDelegate(settings: settings, environment: environment)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
func runDemo(_ delegate: AppDelegate) {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 300_000_000)
        let controller = delegate.panelController
        controller.show()
        let snapshotPath = value(after: "--snapshot")
        let drivePath = value(after: "--drive")
        guard snapshotPath != nil || drivePath != nil else { return }
        guard let session = controller.currentSession else { exit(1) }
        waiting: for _ in 0..<600 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            switch session.recommendation {
            case .ready, .unavailable: break waiting
            default: continue
            }
        }
        if let drivePath {
            let report = await driveKeyboard(session: session, controller: controller, mail: delegate.demoMail)
            try? report.write(toFile: drivePath, atomically: true, encoding: .utf8)
            exit(0)
        }
        guard let path = snapshotPath else { return }
        if let query = value(after: "--query") { session.query = query }
        if arguments.contains("--ask-delete"),
            let entry = session.rows.first(where: { $0.title == "Gadgets" })?.entry
        {
            await session.askToDelete(entry)?.value
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        try? controller.snapshot(to: URL(fileURLWithPath: path))
        exit(0)
    }
}

/// Presses keys through the real event path, against the synthetic Mail, and reports what happened.
@MainActor
func driveKeyboard(session: RecommenderSession, controller: PanelController, mail: DemoMail?) async -> String {
    func press(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) async {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)
        else { return }
        NSApp.postEvent(event, atStart: false)
        try? await Task.sleep(nanoseconds: 150_000_000)
    }
    var report: [String: String] = [:]
    let recommended = session.rows.first
    report["recommended"] = recommended?.title
    report["startsOnRecommended"] = String(session.highlightedID == recommended?.id)

    await press(125, "\u{F701}")  // Down
    report["downMoves"] = String(session.highlightedID == session.rows.dropFirst().first?.id)
    await press(126, "\u{F700}")  // Up
    report["upReturns"] = String(session.highlightedID == recommended?.id)

    for (code, character) in [(17 as UInt16, "t"), (15, "r"), (34, "i")] { await press(code, character) }
    report["typingGoesToSearch"] = String(session.query == "tri")
    report["filtered"] = session.rows.map(\.title).joined(separator: "|")
    for _ in 0..<3 { await press(51, "\u{7F}") }  // Backspace
    report["backspaceClears"] = String(session.query.isEmpty)
    report["highlightBackOnRecommended"] = String(session.highlightedID == recommended?.id)

    if recommended?.action == .trash, let mail {
        // Command-Delete edits text in the search field, and moves to the Trash when it is empty.
        await press(7, "x")
        await press(51, "\u{7F}", .command)
        report["commandDeleteEditsTheSearch"] = String(session.query.isEmpty && mail.movedToTrash.isEmpty)
        await press(51, "\u{7F}", .command)
        for _ in 0..<40 where controller.isOpen { try? await Task.sleep(nanoseconds: 100_000_000) }
        report["commandDeleteMovedToTrash"] = String(mail.movedToTrash.count == 1 && mail.filed.isEmpty)
        report["windowClosedAfterTrash"] = String(!controller.isOpen)
        let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    await press(36, "\r")  // Return
    for _ in 0..<40 where controller.isOpen { try? await Task.sleep(nanoseconds: 100_000_000) }
    report["returnFiledInto"] = mail?.filed.last?.target
    report["windowClosedAfterFiling"] = String(!controller.isOpen)

    let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}
