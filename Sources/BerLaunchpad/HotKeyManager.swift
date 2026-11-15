import AppKit
import Carbon
import CoreGraphics
import Foundation

@_silgen_name("CGSSetSymbolicHotKeyEnabled")
private func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ isEnabled: Bool) -> Int32

@_silgen_name("CGSIsSymbolicHotKeyEnabled")
private func CGSIsSymbolicHotKeyEnabled(_ hotKey: Int32) -> Bool

@_silgen_name("CGSGetSymbolicHotKeyValue")
private func CGSGetSymbolicHotKeyValue(
    _ hotKey: Int32,
    _ outKeyEquivalent: UnsafeMutablePointer<UniChar>?,
    _ outVirtualKeyCode: UnsafeMutablePointer<UInt16>?,
    _ outModifiers: UnsafeMutablePointer<UInt32>?
) -> Int32

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var primaryHotKeyRef: EventHotKeyRef?
    private var f4LaunchpadHotKeyRef: EventHotKeyRef?
    private var f4StandardHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var globalSystemDefinedMonitor: Any?
    private var localSystemDefinedMonitor: Any?

    private var onTrigger: (() -> Void)?
    private var lastTriggerTimestamp: TimeInterval = 0

    private let hotKeySignature: OSType = 0x424C5044 // 'BLPD'
    private let primaryHotKeyIDValue: UInt32 = 1
    private let f4LaunchpadHotKeyIDValue: UInt32 = 2
    private let f4StandardHotKeyIDValue: UInt32 = 3

    private let hardwareLaunchpadKeyCode: UInt32 = 131 // 0x83
    private let nxKeyTypeLaunchPanel = 13 // NX_KEYTYPE_LAUNCH_PANEL
    private let settingsSyncQueue = DispatchQueue(label: "com.ber.launchpad.symbolichotkeys")

    private init() {
        installHandlerIfNeeded()
    }

    func register(keyCode: UInt32, modifiers: UInt32, replaceF4: Bool, onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        unregister()
        installHandlerIfNeeded()

        let primaryID = EventHotKeyID(signature: hotKeySignature, id: primaryHotKeyIDValue)
        let primaryStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            primaryID,
            GetApplicationEventTarget(),
            0,
            &primaryHotKeyRef
        )
        if primaryStatus != noErr {
            NSLog("BerLaunchpad: Failed to register primary hotkey (status=%d)", primaryStatus)
        }

        if replaceF4 {
            if !(modifiers == 0 && keyCode == hardwareLaunchpadKeyCode) {
                let f4LaunchpadID = EventHotKeyID(signature: hotKeySignature, id: f4LaunchpadHotKeyIDValue)
                let status = RegisterEventHotKey(
                    hardwareLaunchpadKeyCode,
                    0,
                    f4LaunchpadID,
                    GetApplicationEventTarget(),
                    0,
                    &f4LaunchpadHotKeyRef
                )
                if status != noErr {
                    NSLog("BerLaunchpad: Failed to register F4 Launchpad hotkey 131 (status=%d)", status)
                }
            }

            if !(modifiers == 0 && keyCode == UInt32(kVK_F4)) {
                let f4StandardID = EventHotKeyID(signature: hotKeySignature, id: f4StandardHotKeyIDValue)
                let status = RegisterEventHotKey(
                    UInt32(kVK_F4),
                    0,
                    f4StandardID,
                    GetApplicationEventTarget(),
                    0,
                    &f4StandardHotKeyRef
                )
                if status != noErr {
                    NSLog("BerLaunchpad: Failed to register standard F4 hotkey (status=%d)", status)
                }
            }

            installSystemDefinedMonitors()
        }
    }

    func unregister() {
        if let ref = primaryHotKeyRef {
            UnregisterEventHotKey(ref)
            primaryHotKeyRef = nil
        }
        if let ref = f4LaunchpadHotKeyRef {
            UnregisterEventHotKey(ref)
            f4LaunchpadHotKeyRef = nil
        }
        if let ref = f4StandardHotKeyRef {
            UnregisterEventHotKey(ref)
            f4StandardHotKeyRef = nil
        }
        removeSystemDefinedMonitors()
    }

    func applySystemHotKeyOverrides(
        disableDefaultApps: Bool,
        replaceF4: Bool,
        activeKeyCode: UInt32,
        activeModifiers: UInt32
    ) {
        var updates: [(id: Int32, enabled: Bool)] = []

        // 160 = Show Launchpad / Applications (Opt+Space), 161 = slow-motion variant
        updates.append((160, !disableDefaultApps))
        updates.append((161, !disableDefaultApps))

        if disableDefaultApps {
            let cocoaMods = Self.cocoaFlagsFromCarbon(activeModifiers)
            for id in Int32(160)...Int32(176) {
                if id == 160 || id == 161 || id == 173 || id == 174 { continue }
                var keyEq: UniChar = 0
                var vkc: UInt16 = 0
                var mods: UInt32 = 0
                if CGSGetSymbolicHotKeyValue(id, &keyEq, &vkc, &mods) == 0 {
                    let standardMods = mods & 0x1E0000
                    if UInt32(vkc) == activeKeyCode && standardMods == cocoaMods {
                        updates.append((id, false))
                    }
                }
            }
        }

        // 173 & 174 = Hardware F4 Launchpad key (vkc = 131 / 0x83)
        updates.append((173, !replaceF4))
        updates.append((174, !replaceF4))

        for entry in updates {
            let err = CGSSetSymbolicHotKeyEnabled(entry.id, entry.enabled)
            if err != 0 {
                NSLog("BerLaunchpad: CGSSetSymbolicHotKeyEnabled(%d, %d) returned %d", entry.id, entry.enabled ? 1 : 0, err)
            }
        }

        persistSymbolicHotKeysAndActivate(updates: updates)
    }

    func triggerWithDebounce() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTriggerTimestamp >= 0.20 else { return }
        lastTriggerTimestamp = now
        onTrigger?()
    }

    private func persistSymbolicHotKeysAndActivate(updates: [(id: Int32, enabled: Bool)]) {
        var payloads: [(key: String, enabled: Bool, keyEq: Int, vkc: Int, mods: Int)] = []
        for entry in updates {
            var keyEq: UniChar = 65535
            var vkc: UInt16 = 65535
            var mods: UInt32 = 0
            _ = CGSGetSymbolicHotKeyValue(entry.id, &keyEq, &vkc, &mods)
            payloads.append((
                key: String(entry.id),
                enabled: entry.enabled,
                keyEq: Int(keyEq),
                vkc: Int(vkc),
                mods: Int(mods)
            ))
        }

        settingsSyncQueue.async {
            let domain = "com.apple.symbolichotkeys" as CFString
            let dictKey = "AppleSymbolicHotKeys" as CFString

            var symbolicDict = (CFPreferencesCopyAppValue(dictKey, domain) as? [String: Any]) ?? [:]
            var didChange = false

            for item in payloads {
                var entryDict = (symbolicDict[item.key] as? [String: Any]) ?? [:]
                let currentEnabled = (entryDict["enabled"] as? Bool) ?? (entryDict["enabled"] as? NSNumber)?.boolValue
                if currentEnabled != item.enabled || entryDict["value"] == nil {
                    entryDict["enabled"] = item.enabled
                    if entryDict["value"] == nil && item.vkc != 65535 {
                        entryDict["value"] = [
                            "parameters": [item.keyEq, item.vkc, item.mods],
                            "type": "standard"
                        ]
                    }
                    symbolicDict[item.key] = entryDict
                    didChange = true
                }
            }

            if didChange {
                CFPreferencesSetAppValue(dictKey, symbolicDict as CFDictionary, domain)
                CFPreferencesAppSynchronize(domain)

                let activateTool = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
                if FileManager.default.isExecutableFile(atPath: activateTool) {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: activateTool)
                    process.arguments = ["-u"]
                    try? process.run()
                    process.waitUntilExit()
                }
            }

            DispatchQueue.main.async {
                for entry in updates {
                    _ = CGSSetSymbolicHotKeyEnabled(entry.id, entry.enabled)
                }
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var pressedID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard err == noErr else { return err }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                let isKnownID = pressedID.id == manager.primaryHotKeyIDValue ||
                    pressedID.id == manager.f4LaunchpadHotKeyIDValue ||
                    pressedID.id == manager.f4StandardHotKeyIDValue
                if pressedID.signature == manager.hotKeySignature && isKnownID {
                    DispatchQueue.main.async {
                        manager.triggerWithDebounce()
                    }
                    return noErr
                }
                return OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        if status != noErr {
            NSLog("BerLaunchpad: Failed to install hotkey handler (status=%d)", status)
        }
    }

    private func installSystemDefinedMonitors() {
        removeSystemDefinedMonitors()

        globalSystemDefinedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleSystemDefinedEvent(event)
        }

        localSystemDefinedMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            if self?.handleSystemDefinedEvent(event) == true {
                return nil
            }
            return event
        }
    }

    private func removeSystemDefinedMonitors() {
        if let monitor = globalSystemDefinedMonitor {
            NSEvent.removeMonitor(monitor)
            globalSystemDefinedMonitor = nil
        }
        if let monitor = localSystemDefinedMonitor {
            NSEvent.removeMonitor(monitor)
            localSystemDefinedMonitor = nil
        }
    }

    @discardableResult
    private func handleSystemDefinedEvent(_ event: NSEvent) -> Bool {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else {
            return false
        }
        let data1 = event.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8

        // 0x0A = keyDown for NX_KEYTYPE_LAUNCH_PANEL (13)
        if keyCode == nxKeyTypeLaunchPanel && keyState == 0x0A {
            DispatchQueue.main.async { [weak self] in
                self?.triggerWithDebounce()
            }
            return true
        }
        return false
    }

    private static func cocoaFlagsFromCarbon(_ carbonMods: UInt32) -> UInt32 {
        var flags: UInt32 = 0
        if (carbonMods & UInt32(shiftKey)) != 0 { flags |= UInt32(NSEvent.ModifierFlags.shift.rawValue) }
        if (carbonMods & UInt32(controlKey)) != 0 { flags |= UInt32(NSEvent.ModifierFlags.control.rawValue) }
        if (carbonMods & UInt32(optionKey)) != 0 { flags |= UInt32(NSEvent.ModifierFlags.option.rawValue) }
        if (carbonMods & UInt32(cmdKey)) != 0 { flags |= UInt32(NSEvent.ModifierFlags.command.rawValue) }
        return flags
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func formatShortcut(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if (modifiers & UInt32(controlKey)) != 0 { parts.append("⌃") }
        if (modifiers & UInt32(optionKey)) != 0 { parts.append("⌥") }
        if (modifiers & UInt32(shiftKey)) != 0 { parts.append("⇧") }
        if (modifiers & UInt32(cmdKey)) != 0 { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined(separator: " ")
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case 131: return "Launchpad"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "FwdDel"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        default: return "Key\(keyCode)"
        }
    }
}
