// The floating window. It does not activate this app, so Mail stays the active app while the
// window has the keyboard.
import AppKit
import Combine
import MailCore
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    static let width: CGFloat = 400
    static let height: CGFloat = 540

    private var panel: FloatingPanel?
    private var keyMonitor: Any?
    private var session: RecommenderSession?
    private let makeSession: () -> RecommenderSession
    private let log: EventLog

    init(log: EventLog, makeSession: @escaping () -> RecommenderSession) {
        self.log = log
        self.makeSession = makeSession
    }

    var isOpen: Bool { panel?.isVisible == true }
    var windowNumber: Int { panel?.windowNumber ?? 0 }

    func show() {
        close()
        let session = makeSession()
        session.onFinish = { [weak self] in self?.close() }
        self.session = session

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PanelView(session: session))
        panel.setContentSize(NSSize(width: Self.width, height: Self.height))
        position(panel)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor(session: session)
        log.log("panel_opened")
        session.start()
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return panel.center() }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - panel.frame.height - 16))
    }

    private func installKeyMonitor(session: RecommenderSession) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Command-Delete moves the email to the Trash, as in Finder. While there is text in the
            // search field, it edits the text instead.
            if modifiers.subtracting([.function, .numericPad]) == .command, event.keyCode == 51,
                session.query.isEmpty, session.deleteRequest == nil, session.deleteWait == nil
            {
                session.moveToTrash()
                return nil
            }
            guard modifiers.subtracting([.function, .numericPad]).isEmpty else { return event }
            switch event.keyCode {
            case 53:  // Escape
                if session.deleteWait != nil {
                    session.cancelDeleteWait()
                } else if session.deleteRequest != nil {
                    session.cancelDelete()
                } else {
                    self.close()
                }
                return nil
            case 125:  // Down
                session.moveHighlight(by: 1)
                return nil
            case 126:  // Up
                session.moveHighlight(by: -1)
                return nil
            case 36, 76:  // Return, Enter
                if session.deleteRequest != nil || session.deleteWait != nil {
                    return event
                }
                session.acceptHighlighted()
                return nil
            default:
                return event
            }
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        session?.onFinish = nil
        session = nil
    }

    /// For demo snapshots: draws the window's content into a PNG without any screen permission.
    func snapshot(to url: URL) throws {
        guard let view = panel?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }

    var currentSession: RecommenderSession? { session }
}
