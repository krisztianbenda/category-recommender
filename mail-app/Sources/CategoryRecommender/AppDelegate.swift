// Menu bar icon, keyboard shortcut and the Mail > Services entry. Click the icon to run; right-click
// for the menu.
import AppKit
import MailCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings: AppSettings
    private let environment: AppEnvironment
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private let panel: PanelController

    init(settings: AppSettings, environment: AppEnvironment) {
        self.settings = settings
        self.environment = environment
        panel = PanelController(log: environment.log) {
            let session = RecommenderSession(
                mail: environment.mail, api: environment.client, backend: environment.backend,
                keepInInbox: settings.keepInInbox)
            session.onKeepInInboxChange = { settings.keepInInbox = $0 }
            return session
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "tag", accessibilityDescription: "Category Recommender")
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        hotKey = HotKey { [weak self] in self?.trigger() }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        environment.log.log("app_started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.backend.stop()
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            guard let item = statusItem, let button = item.button else { return }
            let menu = makeMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
        } else {
            trigger()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let recommend = NSMenuItem(
            title: "Recommend a Label for the Selected Email", action: #selector(triggerFromMenu), keyEquivalent: "l")
        recommend.keyEquivalentModifierMask = [.control, .option]
        recommend.target = self
        menu.addItem(recommend)
        menu.addItem(.separator())
        let web = NSMenuItem(title: "Open Learned Data\u{2026}", action: #selector(openWeb), keyEquivalent: "")
        web.target = self
        menu.addItem(web)
        if environment.backend.isManaged {
            let stop = NSMenuItem(title: "Stop Local Model Now", action: #selector(stopModel), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Category Recommender", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return menu
    }

    @objc private func triggerFromMenu() { trigger() }

    @objc private func openWeb() {
        NSWorkspace.shared.open(environment.client.baseURL)
    }

    @objc private func stopModel() {
        environment.backend.stop()
    }

    private func trigger() {
        environment.log.log("triggered")
        panel.show()
    }

    /// Mail > Services > Recommend a Label.
    @objc func recommendLabel(
        _ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        trigger()
    }

    var panelController: PanelController { panel }
    var demoMail: DemoMail? { environment.mail as? DemoMail }
}
