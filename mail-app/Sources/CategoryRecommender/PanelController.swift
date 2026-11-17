// The floating window. It does not activate this app, so Mail stays the active app while the
// window has the keyboard. It reads Mail's selection once, then shows the single-email window, or
// the batch window when more than one email is selected (specs/004-batch-recommendations).
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
    static let batchWidth: CGFloat = 600
    static let batchHeight: CGFloat = 560

    private var panel: FloatingPanel?
    private var keyMonitor: Any?
    private var session: RecommenderSession?
    private var batch: BatchSession?
    private var opening: Task<Void, Never>?
    private let mail: MailSource
    private let makeSession: () -> RecommenderSession
    private let makeBatch: () -> BatchSession
    private let log: EventLog

    init(
        log: EventLog, mail: MailSource, makeSession: @escaping () -> RecommenderSession,
        makeBatch: @escaping () -> BatchSession
    ) {
        self.log = log
        self.mail = mail
        self.makeSession = makeSession
        self.makeBatch = makeBatch
    }

    var isOpen: Bool { panel?.isVisible == true }
    var windowNumber: Int { panel?.windowNumber ?? 0 }

    func show() {
        close()
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
        // Appears at once, and fills when Mail has answered (SC-003).
        panel.contentView = NSHostingView(
            rootView: ProgressView().controlSize(.small)
                .frame(width: Self.width, height: Self.height)
                .background(Color(nsColor: .windowBackgroundColor)))
        panel.setContentSize(NSSize(width: Self.width, height: Self.height))
        position(panel)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        log.log("panel_opened")
        let mail = self.mail
        opening = Task { [weak self] in
            let opening = try? await mail.opening()
            guard let self, !Task.isCancelled, self.panel === panel else { return }
            if let opening, opening.isBatch {
                self.showBatch(opening, in: panel)
            } else {
                self.showSingle(opening, in: panel)
            }
        }
    }

    /// One email, or a reason the window cannot work. Without an opening, the session reads Mail
    /// itself and says what went wrong.
    private func showSingle(_ opening: MailOpening?, in panel: FloatingPanel) {
        let session = makeSession()
        session.onFinish = { [weak self] in self?.close() }
        self.session = session
        panel.contentView = NSHostingView(rootView: PanelView(session: session))
        session.start(with: opening)
    }

    private func showBatch(_ opening: MailOpening, in panel: FloatingPanel) {
        let batch = makeBatch()
        batch.onFinish = { [weak self] in self?.close() }
        batch.onEvent = { [log] event, numbers in log.log(event, numbers) }
        self.batch = batch
        panel.contentView = NSHostingView(rootView: BatchView(session: batch))
        panel.setContentSize(NSSize(width: Self.batchWidth, height: Self.batchHeight))
        position(panel)
        batch.start(with: opening)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return panel.center() }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - panel.frame.height - 16))
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if let batch = self.batch { return self.handle(event, batch: batch) }
            if let session = self.session { return self.handle(event, session: session) }
            if event.keyCode == 53 {
                self.close()
                return nil
            }
            return event
        }
    }

    private func handle(_ event: NSEvent, session: RecommenderSession) -> NSEvent? {
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
                close()
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

    /// The batch window's keys (specs/004-batch-recommendations/contracts/batch-window.md).
    private func handle(_ event: NSEvent, batch: BatchSession) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad])
        let isReturn = event.keyCode == 36 || event.keyCode == 76

        if batch.confirmation != nil {
            if event.keyCode == 53 {
                batch.cancelConfirmation()
                return nil
            }
            if isReturn && modifiers.isEmpty {
                batch.confirm()
                return nil
            }
            return nil
        }

        if batch.pickerScope != nil {
            if modifiers == .command, event.keyCode == 51, batch.pickerQuery.isEmpty {
                batch.closePicker()
                batch.moveScopeToTrash()
                return nil
            }
            guard modifiers.isEmpty else { return event }
            switch event.keyCode {
            case 53:  // Escape
                batch.closePicker()
                return nil
            case 123 where batch.pickerQuery.isEmpty:  // Left
                batch.closePicker()
                return nil
            case 125:
                batch.movePickerHighlight(by: 1)
                return nil
            case 126:
                batch.movePickerHighlight(by: -1)
                return nil
            case 36, 76:
                batch.choosePickerHighlighted()
                return nil
            default:
                return event  // typing goes to the search field
            }
        }

        if modifiers == .command {
            switch event.keyCode {
            case 36, 76:  // Command-Return
                batch.approveAll()
                return nil
            case 51:  // Command-Delete
                batch.moveScopeToTrash()
                return nil
            case 0:  // Command-A
                batch.toggleMarkAll()
                return nil
            default:
                return event
            }
        }
        guard modifiers.isEmpty || modifiers == .shift else { return event }
        switch event.keyCode {
        case 53:  // Escape
            close()
            return nil
        case 125:  // Down
            batch.moveHighlight(by: 1)
            return nil
        case 126:  // Up
            batch.moveHighlight(by: -1)
            return nil
        case 49:  // Space
            batch.toggleMark()
            return nil
        case 51:  // Delete
            batch.toggleSkip()
            return nil
        case 36, 76:  // Return
            batch.acceptScope()
            return nil
        case 124, 48:  // Right, Tab
            batch.openPicker()
            return nil
        default:
            // A letter or digit opens Choose a label with it as the search.
            if let text = event.charactersIgnoringModifiers, text.count == 1,
                text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
            {
                batch.openPicker(query: event.characters ?? text)
                return nil
            }
            return event
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        opening?.cancel()
        opening = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        session?.onFinish = nil
        session = nil
        if let batch {
            batch.onFinish = nil
            batch.close()
        }
        batch = nil
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
    var currentBatch: BatchSession? { batch }
}
