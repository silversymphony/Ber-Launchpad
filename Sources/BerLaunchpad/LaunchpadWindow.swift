import AppKit
import Carbon
import SwiftUI

final class LaunchpadPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class LaunchpadWindowController: NSObject, NSWindowDelegate {
    private static let overlayWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    private let store: LaunchpadStore
    private var panel: LaunchpadPanel?
    private var hostingView: NSHostingView<LaunchpadContainerView>?

    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var flagsMonitor: Any?
    private var mouseUpMonitor: Any?

    private var previousApp: NSRunningApplication?
    private var lastShowTimestamp: Date = .distantPast
    private var optionHoldWorkItem: DispatchWorkItem?

    private var accumulatedScrollX: CGFloat = 0
    private var isTrackingHorizontalSwipe = false
    private var lastDiscreteScrollPageTime: Date = .distantPast

    private let presentation = LaunchpadPresentationState()

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    init(store: LaunchpadStore) {
        self.store = store
        super.init()
        setupPanel()
        installEventMonitors()
    }

    private func setupPanel() {
        let initialRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = LaunchpadPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.level = Self.overlayWindowLevel
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self

        let rootView = LaunchpadContainerView(store: store, presentation: presentation)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = initialRect
        hostingView.autoresizingMask = [.width, .height]

        panel.contentView = hostingView
        self.panel = panel
        self.hostingView = hostingView
    }

    func toggle() {
        if isVisible {
            hide(restorePreviousApp: true)
        } else {
            show()
        }
    }

    func show() {
        guard let panel else { return }

        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontApp
        }

        let mouseLoc = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        if let targetScreen {
            panel.setFrame(targetScreen.frame, display: true)
        }

        // Reset transient state
        store.searchText = ""
        store.openedFolderID = nil
        store.isJiggleMode = false
        store.isSettingsPresented = false
        store.appPendingDelete = nil
        store.deleteErrorInfo = nil
        store.selectedIndex = nil
        store.scrollDragOffset = 0
        store.draggedEntry = nil
        store.draggedFromFolderID = nil
        store.dropTargetEntryID = nil
        accumulatedScrollX = 0
        isTrackingHorizontalSwipe = false
        lastShowTimestamp = Date()

        store.syncInstalledApps(initialIfNeeded: false)

        presentation.scale = 1.05
        panel.level = Self.overlayWindowLevel
        panel.alphaValue = 0.0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.post(name: .clearLaunchpadFocus, object: nil)

        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            presentation.scale = 1.0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }
    }

    func hide(restorePreviousApp: Bool) {
        guard let panel, panel.isVisible else { return }
        optionHoldWorkItem?.cancel()
        optionHoldWorkItem = nil

        NotificationCenter.default.post(name: .clearLaunchpadFocus, object: nil)

        let appToRestore = restorePreviousApp ? previousApp : nil
        previousApp = nil

        withAnimation(.easeIn(duration: 0.16)) {
            presentation.scale = 0.96
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel?.orderOut(nil)
                self?.panel?.level = Self.overlayWindowLevel
                self?.panel?.alphaValue = 1.0
                self?.presentation.scale = 1.0
                self?.store.searchText = ""
                self?.store.openedFolderID = nil
                self?.store.isJiggleMode = false
                self?.store.isSettingsPresented = false
                self?.store.appPendingDelete = nil
                self?.store.deleteErrorInfo = nil
                self?.store.draggedEntry = nil
                self?.store.draggedFromFolderID = nil
                self?.store.dropTargetEntryID = nil
                if let appToRestore, !appToRestore.isTerminated {
                    appToRestore.activate()
                }
            }
        })
    }

    func suspendLevelForSystemDialog() {
        guard let panel, panel.isVisible else { return }
        // Lower below all normal/modal/TCC/Touch ID/Finder system prompts so permission dialogs are never covered
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    }

    func reactivateIfVisible() {
        guard let panel, panel.isVisible else { return }
        panel.level = Self.overlayWindowLevel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        // Don't hide mid-drag, while opening, or while delete/permission/settings overlays are active
        guard store.draggedEntry == nil,
              !store.isDeletingApp,
              store.appPendingDelete == nil,
              store.deleteErrorInfo == nil,
              !store.isSettingsPresented,
              Date().timeIntervalSince(lastShowTimestamp) > 0.35 else {
            return
        }
        hide(restorePreviousApp: false)
    }

    // MARK: - Event Monitors

    private func installEventMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handleKeyDown(event)
        }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handleScrollWheel(event)
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.isVisible else { return event }
            self.handleFlagsChanged(event)
            return event
        }

        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, self.isVisible else { return event }
            // Safety cleanup if drag ended without hitting a drop target
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if self.store.draggedEntry != nil {
                    self.store.draggedEntry = nil
                    self.store.draggedFromFolderID = nil
                    self.store.dropTargetEntryID = nil
                }
            }
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let keyCode = Int(event.keyCode)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd + , -> Toggle Settings
        if mods == .command && keyCode == kVK_ANSI_Comma {
            NotificationCenter.default.post(name: .clearLaunchpadFocus, object: nil)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                store.isSettingsPresented.toggle()
            }
            return nil
        }

        // F4 / Hardware Launchpad key toggles Launchpad cleanly when enabled
        if store.settings.replaceF4LaunchpadKey && (keyCode == 131 || keyCode == kVK_F4) && mods.intersection([.command, .control, .option]).isEmpty {
            HotKeyManager.shared.triggerWithDebounce()
            return nil
        }

        // Let ShortcutRecorderButton handle its own key presses while settings are open
        let isEditingText = panel?.firstResponder is NSTextView

        // Escape key layered dismissal
        if keyCode == kVK_Escape {
            if store.deleteErrorInfo != nil {
                store.deleteErrorInfo = nil
                return nil
            }
            if store.appPendingDelete != nil {
                store.appPendingDelete = nil
                return nil
            }
            if store.isSettingsPresented {
                // Allow ShortcutRecorderButton to cancel recording first if active, or close settings
                store.isSettingsPresented = false
                return nil
            }
            if isEditingText && store.openedFolderID != nil {
                NotificationCenter.default.post(name: .clearLaunchpadFocus, object: nil)
                panel?.makeFirstResponder(nil)
                return nil
            }
            if store.openedFolderID != nil {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                    store.openedFolderID = nil
                    store.selectedIndex = nil
                }
                return nil
            }
            if store.isJiggleMode {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    store.isJiggleMode = false
                }
                return nil
            }
            if !store.searchText.isEmpty {
                store.searchText = ""
                NotificationCenter.default.post(name: .clearLaunchpadFocus, object: nil)
                panel?.makeFirstResponder(nil)
                return nil
            }
            hide(restorePreviousApp: true)
            return nil
        }

        // Delete confirmation shortcuts
        if store.appPendingDelete != nil {
            if keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
                store.executePendingDelete()
                return nil
            }
            return nil
        }

        // While Settings modal is open, let controls handle keyboard normally
        if store.isSettingsPresented {
            return event
        }

        // Cmd + Left / Right switches pages directly
        if mods == .command && keyCode == kVK_LeftArrow && store.openedFolderID == nil {
            if store.currentPage > 0 {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    store.currentPage -= 1
                    store.selectedIndex = nil
                }
            }
            return nil
        }
        if mods == .command && keyCode == kVK_RightArrow && store.openedFolderID == nil {
            if store.currentPage < store.pages.count - 1 {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    store.currentPage += 1
                    store.selectedIndex = nil
                }
            }
            return nil
        }

        // If editing folder name, let NSTextView handle all keys
        if isEditingText && store.openedFolderID != nil {
            return event
        }

        // Arrow navigation & Return activation (works both in grid and while typing in Search)
        switch keyCode {
        case kVK_LeftArrow:
            if !isEditingText || !store.searchText.isEmpty {
                store.moveSelection(dx: -1, dy: 0)
                return nil
            }
        case kVK_RightArrow:
            if !isEditingText || !store.searchText.isEmpty {
                store.moveSelection(dx: 1, dy: 0)
                return nil
            }
        case kVK_UpArrow:
            store.moveSelection(dx: 0, dy: -1)
            return nil
        case kVK_DownArrow:
            store.moveSelection(dx: 0, dy: 1)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !store.isJiggleMode {
                store.activateSelected()
                return nil
            }
        default:
            break
        }

        // If Search text field is already focused, let it handle normal typing & IME
        if isEditingText {
            return event
        }

        // Backspace clears last character when not focused in search field
        if keyCode == kVK_Delete && !store.searchText.isEmpty {
            store.searchText.removeLast()
            NotificationCenter.default.post(name: .focusLaunchpadSearch, object: nil)
            return nil
        }

        // Type-to-search from anywhere on main Launchpad view
        if store.openedFolderID == nil && mods.intersection([.command, .control, .option]).isEmpty,
           let chars = event.characters, !chars.isEmpty {
            let scalarSet = chars.unicodeScalars
            let isPrintable = scalarSet.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700
            }
            if isPrintable {
                // Ignore bare Space when nothing searched yet and user already selected an item
                if keyCode == kVK_Space && store.searchText.isEmpty && store.selectedIndex != nil {
                    store.activateSelected()
                    return nil
                }
                store.searchText += chars
                NotificationCenter.default.post(name: .focusLaunchpadSearch, object: nil)
                return nil
            }
        }

        return event
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard store.openedFolderID == nil,
              !store.isSettingsPresented,
              store.appPendingDelete == nil,
              store.searchText.isEmpty,
              store.pages.count > 1 else {
            return event
        }

        let screenWidth = panel?.frame.width ?? 1440

        if event.hasPreciseScrollingDeltas {
            // Trackpad 2-finger gesture
            if event.momentumPhase != [] {
                // Ignore trailing inertia after snapping
                return nil
            }

            if event.phase == .began {
                accumulatedScrollX = 0
                isTrackingHorizontalSwipe = false
            }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY

            if !isTrackingHorizontalSwipe {
                if abs(dx) > abs(dy) * 0.65 && abs(dx) > 0.5 {
                    isTrackingHorizontalSwipe = true
                } else {
                    return event
                }
            }

            if event.phase == .changed || event.phase == .began {
                accumulatedScrollX += dx * 1.4
                let atFirst = store.currentPage == 0 && accumulatedScrollX > 0
                let atLast = store.currentPage == store.pages.count - 1 && accumulatedScrollX < 0
                store.scrollDragOffset = (atFirst || atLast) ? accumulatedScrollX * 0.28 : accumulatedScrollX
            }

            if event.phase == .ended || event.phase == .cancelled {
                let threshold = min(130, screenWidth * 0.13)
                let velocityTriggered = abs(dx) > 16
                var nextPage = store.currentPage

                if (accumulatedScrollX < -threshold || (velocityTriggered && dx < -12 && accumulatedScrollX < -15)) &&
                    store.currentPage < store.pages.count - 1 {
                    nextPage += 1
                } else if (accumulatedScrollX > threshold || (velocityTriggered && dx > 12 && accumulatedScrollX > 15)) &&
                            store.currentPage > 0 {
                    nextPage -= 1
                }

                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    store.currentPage = nextPage
                    store.scrollDragOffset = 0
                }
                accumulatedScrollX = 0
                isTrackingHorizontalSwipe = false
                store.selectedIndex = nil
            }
            return nil
        } else {
            // Standard discrete mouse wheel
            let now = Date()
            guard now.timeIntervalSince(lastDiscreteScrollPageTime) > 0.32 else { return nil }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX
                : event.scrollingDeltaY

            if delta < -0.5 && store.currentPage < store.pages.count - 1 {
                lastDiscreteScrollPageTime = now
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    store.currentPage += 1
                }
            } else if delta > 0.5 && store.currentPage > 0 {
                lastDiscreteScrollPageTime = now
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    store.currentPage -= 1
                }
            }
            return nil
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // Ignore option release immediately after Option+Space opened Launchpad
        guard Date().timeIntervalSince(lastShowTimestamp) > 0.45,
              !store.isSettingsPresented,
              store.appPendingDelete == nil else {
            optionHoldWorkItem?.cancel()
            optionHoldWorkItem = nil
            return
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .option {
            optionHoldWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.isVisible else { return }
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        self.store.isJiggleMode.toggle()
                    }
                }
            }
            optionHoldWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: item)
        } else {
            optionHoldWorkItem?.cancel()
            optionHoldWorkItem = nil
        }
    }
}

@MainActor
final class LaunchpadPresentationState: ObservableObject {
    @Published var scale: CGFloat = 1.0
}

struct LaunchpadContainerView: View {
    @ObservedObject var store: LaunchpadStore
    @ObservedObject var presentation: LaunchpadPresentationState

    var body: some View {
        LaunchpadRootView(store: store)
            .scaleEffect(presentation.scale)
    }
}
