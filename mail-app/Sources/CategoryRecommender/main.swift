// Entry point. With no arguments this is the menu bar app. The other modes exist for checks:
//   --diagnose --out FILE          counts about the real Mail, no names or text
//   --self-test-local --out FILE   real Mail, temporary local mailboxes, pass or fail only
//   --self-test-account --out FILE owner-run check on the selected email, in any account, pass or
//                                  fail only (--self-test-gmail is the old name)
//   --self-test-selection --out FILE
//                                  owner-run check that Mail lets the app select some of the
//                                  selected emails; changes no email, pass or fail only
//   --demo [--newsletter | --batch] [--snapshot FILE | --drive FILE]
//                                  synthetic Mail, nothing real is touched; --newsletter shows
//                                  an email like three in the synthetic Trash, --batch six
//                                  synthetic emails selected at once
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
        : arguments.contains("--self-test-locate")
        ? ("selftestLocate", 300)
        : arguments.contains("--self-test-recover")
            ? ("selftestRecover", 300)
            : arguments.contains("--self-test-account") || arguments.contains("--self-test-gmail")
                ? ("selftestAccount", 400)
                : arguments.contains("--self-test-selection") ? ("selftestSelection", 120) : nil

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
        let demo =
            arguments.contains("--batch")
            ? DemoMail.batch() : arguments.contains("--newsletter") ? DemoMail.newsletter() : DemoMail()
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
        for _ in 0..<100 where controller.currentSession == nil && controller.currentBatch == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if let batch = controller.currentBatch {
            await batch.recommendationsFinished()
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let drivePath {
                let report = await driveBatch(batch: batch, controller: controller, mail: delegate.demoMail)
                try? report.write(toFile: drivePath, atomically: true, encoding: .utf8)
                exit(0)
            }
            try? controller.snapshot(to: URL(fileURLWithPath: snapshotPath!))
            exit(0)
        }
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
        await pressKey(keyCode, characters, modifiers, in: controller, settle: 150_000_000)
    }
    func waitUntilClosed() async {
        for _ in 0..<40 where controller.isOpen { try? await Task.sleep(nanoseconds: 100_000_000) }
    }
    var report: [String: String] = [:]
    func json() -> String {
        let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
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
        await waitUntilClosed()
        report["commandDeleteMovedToTrash"] = String(mail.movedToTrash.count == 1 && mail.filed.isEmpty)
        report["windowClosedAfterTrash"] = String(!controller.isOpen)
        return json()
    }

    await press(36, "\r")  // Return
    await waitUntilClosed()
    report["returnFiledInto"] = mail?.filed.last?.target
    report["windowClosedAfterFiling"] = String(!controller.isOpen)

    return json()
}

/// Presses the batch window's keys through the real event path, against the synthetic Mail, and
/// reports what happened (specs/004-batch-recommendations/contracts/batch-window.md).
@MainActor
func driveBatch(batch: BatchSession, controller: PanelController, mail: DemoMail?) async -> String {
    func press(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) async {
        await pressKey(keyCode, characters, modifiers, in: controller, settle: 200_000_000)
    }
    func touched() -> Set<String> {
        guard let mail else { return [] }
        let filed = mail.filed.flatMap { $0.items.map(\.id) }
        let ids = batch.rows.filter { row in filed.contains(row.placement?.id ?? -1) }.compactMap(\.ref.messageId)
        return Set(ids + mail.movedToTrash.flatMap { $0 })
    }
    var report: [String: Bool] = [:]
    let ids = batch.rows.map(\.id)
    let messageIds = batch.rows.compactMap(\.ref.messageId)
    report["sixRows"] = ids.count == 6
    report["startsOnFirstRow"] = batch.highlightedID == ids.first

    await press(125, "\u{F701}")  // Down
    report["downMoves"] = batch.highlightedID == ids[1]
    await press(126, "\u{F700}")  // Up
    report["upReturns"] = batch.highlightedID == ids[0]

    // Return accepts only the highlighted row.
    await press(36, "\r")
    for _ in 0..<40 where batch.rows[0].state != .done { try? await Task.sleep(nanoseconds: 50_000_000) }
    report["returnAppliesOnlyTheHighlightedRow"] = touched() == [messageIds[0]]

    // Typing opens Choose a label with the search.
    await press(125, "\u{F701}")
    await press(5, "g")
    report["typingOpensChooseALabel"] = batch.pickerScope == [ids[1]] && batch.pickerQuery == "g"
    await press(0, "a")
    report["typingAddsToTheSearch"] = batch.pickerQuery == "ga"

    // Command-N opens New label with the search as its name, to finish; Up and Down choose where
    // it goes.
    await press(45, "n", .command)
    report["commandNOpensNewLabel"] = batch.newLabel == NewLabelForm(name: "ga")
    await press(7, "x")
    report["typingFinishesTheNewLabelName"] = batch.newLabel?.name == "gax"
    await press(125, "\u{F701}")
    report["downPutsTheNewLabelInsideOne"] = batch.newLabel?.parent == batch.newLabelParents.first?.mailbox
    await press(126, "\u{F700}")
    report["upPutsTheNewLabelAtTheTop"] = batch.newLabel != nil && batch.newLabel?.parent == nil
    await press(53, "\u{1B}")
    report["escapeLeavesNewLabelForTheSearch"] =
        batch.newLabel == nil && batch.pickerScope == [ids[1]] && batch.pickerQuery == "ga"
    await press(53, "\u{1B}")  // Escape
    report["escapeReturnsToTheList"] = batch.pickerScope == nil && touched().count == 1

    // Space marks; Command-Delete on two marked rows asks first.
    await press(49, " ")
    await press(125, "\u{F701}")
    await press(49, " ")
    report["spaceMarks"] = batch.rows[1].marked && batch.rows[2].marked
    await press(51, "\u{7F}", .command)
    report["trashingMarkedRowsAsksFirst"] = batch.confirmation?.trashCount == 2 && touched().count == 1
    await press(53, "\u{1B}")
    report["escapeCancelsTheConfirmation"] = batch.confirmation == nil && touched().count == 1

    // Return on marked rows applies only them.
    await press(36, "\r")
    for _ in 0..<40 where batch.rows[2].state != .done { try? await Task.sleep(nanoseconds: 50_000_000) }
    report["returnAppliesOnlyTheMarkedRows"] = touched() == Set(messageIds[0..<3])

    // Delete skips; Command-Return approves the ready rows that are not skipped.
    await press(125, "\u{F701}")
    await press(51, "\u{7F}")
    report["deleteSkips"] = batch.rows[3].skipped
    await press(36, "\r", .command)
    if batch.confirmation != nil { await press(36, "\r") }
    for _ in 0..<60 where batch.rows[4].state != .done { try? await Task.sleep(nanoseconds: 50_000_000) }
    report["approveAllLeavesSkippedAndUnrecommendedRows"] =
        !touched().contains(messageIds[3]) && !touched().contains(messageIds[5]) && touched().contains(messageIds[4])

    await press(53, "\u{1B}")
    for _ in 0..<20 where controller.isOpen { try? await Task.sleep(nanoseconds: 50_000_000) }
    report["escapeCloses"] = !controller.isOpen
    report["undecidedLeftAlone"] = !touched().contains(messageIds[3]) && !touched().contains(messageIds[5])

    let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
    return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}

/// Posts one key press to the window through the real event path, then lets it settle.
@MainActor
func pressKey(
    _ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags, in controller: PanelController,
    settle nanoseconds: UInt64
) async {
    guard
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode)
    else { return }
    NSApp.postEvent(event, atStart: false)
    try? await Task.sleep(nanoseconds: nanoseconds)
}
