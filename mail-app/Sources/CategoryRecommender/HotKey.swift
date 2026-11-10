// The keyboard shortcut. Registered only while Mail is the active app, so it never takes the
// combination away from other apps.
import AppKit
import Carbon.HIToolbox

final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var observer: NSObjectProtocol?
    private let action: () -> Void

    private static let identifier = EventHotKeyID(signature: OSType(0x4352_4543), id: 1)  // "CREC"

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { hotKey.action() }
                return noErr
            }, 1, &spec, me, &handler)

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.update(active: app?.bundleIdentifier)
        }
        update(active: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func update(active bundleIdentifier: String?) {
        if bundleIdentifier == "com.apple.mail" {
            guard reference == nil else { return }
            // Control-Option-L.
            RegisterEventHotKey(
                UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey), Self.identifier,
                GetApplicationEventTarget(), 0, &reference)
        } else if let current = reference {
            UnregisterEventHotKey(current)
            reference = nil
        }
    }
}
