import AppKit
import Carbon
import Foundation

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private var windowController: LaunchpadWindowController?
    private let toggleNotification = Notification.Name("com.ber.launchpad.toggle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure single instance: if already running, ask it to toggle and exit
        if let bundleID = Bundle.main.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            let others = running.filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                DistributedNotificationCenter.default().postNotificationName(
                    toggleNotification,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
                NSApp.terminate(nil)
                return
            }
        }

        // Background accessory mode (no Dock icon unless pinned, no Menu Bar icon)
        NSApp.setActivationPolicy(.accessory)

        let store = LaunchpadStore.shared
        store.initialize()

        let controller = LaunchpadWindowController(store: store)
        self.windowController = controller

        store.onRequestHide = { [weak controller] restorePrevious in
            controller?.hide(restorePreviousApp: restorePrevious)
        }

        let syncHotKeys: () -> Void = { [weak controller] in
            let s = LaunchpadStore.shared.settings
            HotKeyManager.shared.applySystemHotKeyOverrides(
                disableDefaultApps: s.disableDefaultAppsOnShortcut,
                replaceF4: s.replaceF4LaunchpadKey,
                activeKeyCode: s.hotkeyKeyCode,
                activeModifiers: s.hotkeyModifiers
            )
            HotKeyManager.shared.register(
                keyCode: s.hotkeyKeyCode,
                modifiers: s.hotkeyModifiers,
                replaceF4: s.replaceF4LaunchpadKey
            ) {
                HotKeyManager.shared.applySystemHotKeyOverrides(
                    disableDefaultApps: LaunchpadStore.shared.settings.disableDefaultAppsOnShortcut,
                    replaceF4: LaunchpadStore.shared.settings.replaceF4LaunchpadKey,
                    activeKeyCode: LaunchpadStore.shared.settings.hotkeyKeyCode,
                    activeModifiers: LaunchpadStore.shared.settings.hotkeyModifiers
                )
                controller?.toggle()
            }
        }

        store.onHotkeyChanged = { _, _ in
            syncHotKeys()
        }

        store.onHotKeySettingsChanged = {
            syncHotKeys()
        }

        syncHotKeys()

        DistributedNotificationCenter.default().addObserver(
            forName: toggleNotification,
            object: nil,
            queue: .main
        ) { [weak controller] _ in
            Task { @MainActor in
                controller?.toggle()
            }
        }

        // Open Launchpad immediately on interactive launch unless started silently in background
        let isBackgroundLaunch = CommandLine.arguments.contains("--background")
        if !isBackgroundLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                controller.show()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.toggle()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
    }
}
