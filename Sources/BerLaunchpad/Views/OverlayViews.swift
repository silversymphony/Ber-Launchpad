import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Expanded Folder Overlay

struct ExpandedFolderOverlayView: View {
    @ObservedObject var store: LaunchpadStore
    let folder: FolderItem
    let screenSize: CGSize

    @State private var folderTitle: String
    @FocusState private var isEditingTitle: Bool

    init(store: LaunchpadStore, folder: FolderItem, screenSize: CGSize) {
        self.store = store
        self.folder = folder
        self.screenSize = screenSize
        _folderTitle = State(initialValue: folder.name)
    }

    private var iconSize: Double {
        store.settings.iconSize
    }

    private var tileWidth: CGFloat {
        max(96, CGFloat(iconSize + 40))
    }

    private let colSpacing: CGFloat = 18
    private let rowSpacing: CGFloat = 20
    private let cardPadding: CGFloat = 28

    private var maxColsOnScreen: Int {
        max(
            store.settings.columns,
            Int((screenSize.width * 0.94 - cardPadding * 2 + colSpacing) / (tileWidth + colSpacing))
        )
    }

    private var columnCount: Int {
        let appCount = max(1, folder.apps.count)
        let baseCols = store.settings.columns
        if appCount <= baseCols {
            return appCount
        } else if appCount <= baseCols * 2 {
            return baseCols
        } else {
            return min(maxColsOnScreen, max(baseCols, Int(ceil(sqrt(Double(appCount) * 1.6)))))
        }
    }

    private var rowCount: Int {
        let appCount = max(1, folder.apps.count)
        return Int(ceil(Double(appCount) / Double(columnCount)))
    }

    private var rowHeight: CGFloat {
        CGFloat(iconSize * 1.05 + 56)
    }

    private var idealContentHeight: CGFloat {
        CGFloat(rowCount) * rowHeight
            + CGFloat(max(0, rowCount - 1)) * rowSpacing
            + cardPadding * 2
    }

    private var maxCardHeight: CGFloat {
        screenSize.height * 0.82
    }

    private var cardWidth: CGFloat {
        min(
            screenSize.width * 0.94,
            max(
                240,
                CGFloat(columnCount) * tileWidth
                    + CGFloat(max(0, columnCount - 1)) * colSpacing
                    + cardPadding * 2
            )
        )
    }

    private var cardHeight: CGFloat {
        min(maxCardHeight, max(rowHeight + cardPadding * 2, idealContentHeight))
    }

    var body: some View {
        ZStack {
            // Backdrop: click to close, or drop an app here to extract out of folder
            Color.black.opacity(0.32)
                .background(.ultraThinMaterial.opacity(0.65))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    commitTitle()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        store.openedFolderID = nil
                        store.selectedIndex = nil
                    }
                }
                .onDrop(of: [.text], delegate: BackgroundFallbackDropDelegate(store: store))

            VStack(spacing: 22) {
                TextField("Folder Name", text: $folderTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .focused($isEditingTitle)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isEditingTitle ? Color.white.opacity(0.16) : Color.clear)
                    )
                    .frame(maxWidth: 460)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .onSubmit {
                        commitTitle()
                        isEditingTitle = false
                    }
                    .onChange(of: isEditingTitle) { _, editing in
                        if !editing {
                            commitTitle()
                        }
                    }

                ScrollView(.vertical, showsIndicators: false) {
                    let columns = Array(
                        repeating: GridItem(.fixed(tileWidth), spacing: colSpacing),
                        count: columnCount
                    )
                    LazyVGrid(columns: columns, spacing: rowSpacing) {
                        ForEach(Array(folder.apps.enumerated()), id: \.element.id) { index, app in
                            AppIconTileView(
                                app: app,
                                iconSize: iconSize,
                                isJiggleMode: store.isJiggleMode,
                                isSelected: store.selectedIndex == index,
                                isDropTarget: false,
                                showDeleteBadge: true,
                                onTap: {
                                    store.launchApp(app)
                                },
                                onLongPress: {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                        store.isJiggleMode = true
                                    }
                                },
                                onDeleteTap: {
                                    store.requestDelete(app)
                                }
                            )
                            .onDrag {
                                store.draggedEntry = .app(app)
                                store.draggedFromFolderID = folder.id
                                return NSItemProvider(object: "app:\(app.path)" as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: FolderItemDropDelegate(
                                    folderID: folder.id,
                                    targetApp: app,
                                    targetIndex: index,
                                    store: store
                                )
                            )
                        }
                    }
                    .padding(cardPadding)
                }
                .frame(width: cardWidth, height: cardHeight)
                .animation(.spring(response: 0.28, dampingFraction: 0.84), value: folder.apps.count)
                .animation(.spring(response: 0.28, dampingFraction: 0.84), value: store.settings.iconSize)
                .background(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 34, style: .continuous)
                                .fill(Color.white.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 34, style: .continuous)
                                .stroke(Color.white.opacity(0.28), lineWidth: 1)
                        )
                )
                .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
                .onTapGesture {
                    // Absorb clicks inside the folder card so it doesn't dismiss when clicking empty gap inside folder
                    if isEditingTitle {
                        commitTitle()
                        isEditingTitle = false
                    }
                }

                Text("Drag an app outside the box to remove it from this folder")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(.vertical, 32)
        }
        .onChange(of: folder.name) { _, updated in
            if !isEditingTitle {
                folderTitle = updated
            }
        }
    }

    private func commitTitle() {
        store.renameFolder(folderID: folder.id, newName: folderTitle)
    }
}

// MARK: - Delete Confirmation Overlay

struct DeleteConfirmationOverlayView: View {
    let app: AppItem
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @ObservedObject private var iconCache = IconCache.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 16) {
                Image(nsImage: iconCache.icon(for: app.path))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

                VStack(spacing: 6) {
                    Text("Are you sure you want to delete the application “\(app.name)”?")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    Text("This will move “\(app.name)” to the Trash.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.16))
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: onConfirm) {
                        Text("Delete")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.red.opacity(0.88))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(22)
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThickMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(white: 0.14).opacity(0.72))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.55), radius: 28, y: 12)
        }
    }
}

// MARK: - Settings Overlay

struct SettingsOverlayView: View {
    @ObservedObject var store: LaunchpadStore
    @State private var confirmResetPreset: LayoutPreset?

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        store.isSettingsPresented = false
                    }
                }

            VStack(alignment: .leading, spacing: 18) {
                // Header
                HStack {
                    HStack(spacing: 10) {
                        Image(systemName: "square.grid.3x3.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.linearGradient(
                                colors: [.cyan, .blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                        Text("Ber Launchpad Settings")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            store.isSettingsPresented = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }

                Divider().overlay(Color.white.opacity(0.15))

                // Grid Dimensions
                VStack(alignment: .leading, spacing: 10) {
                    Text("Grid & Appearance")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.65))
                        .textCase(.uppercase)

                    HStack {
                        Text("Columns")
                            .foregroundColor(.white)
                        Spacer()
                        Stepper(
                            "\(store.settings.columns)",
                            value: Binding(
                                get: { store.settings.columns },
                                set: { store.updateGridSize(columns: $0, rows: store.settings.rows) }
                            ),
                            in: 5...10
                        )
                        .foregroundColor(.white)
                    }

                    HStack {
                        Text("Rows")
                            .foregroundColor(.white)
                        Spacer()
                        Stepper(
                            "\(store.settings.rows)",
                            value: Binding(
                                get: { store.settings.rows },
                                set: { store.updateGridSize(columns: store.settings.columns, rows: $0) }
                            ),
                            in: 4...8
                        )
                        .foregroundColor(.white)
                    }

                    HStack(spacing: 12) {
                        Text("Icon Size")
                            .foregroundColor(.white)
                            .frame(width: 90, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { store.settings.iconSize },
                                set: {
                                    store.settings.iconSize = $0
                                    store.saveSettings()
                                }
                            ),
                            in: 56...110,
                            step: 2
                        )
                        Text("\(Int(store.settings.iconSize)) pt")
                            .foregroundColor(.white.opacity(0.75))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }

                    HStack(spacing: 12) {
                        Text("Backdrop Dim")
                            .foregroundColor(.white)
                            .frame(width: 90, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { store.settings.backgroundOpacity },
                                set: {
                                    store.settings.backgroundOpacity = $0
                                    store.saveSettings()
                                }
                            ),
                            in: 0.15...0.78,
                            step: 0.02
                        )
                        Text("\(Int(store.settings.backgroundOpacity * 100))%")
                            .foregroundColor(.white.opacity(0.75))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }

                    Toggle(
                        "Show Recent Apps Row",
                        isOn: Binding(
                            get: { store.settings.showRecentApps },
                            set: { store.setShowRecentApps($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .foregroundColor(.white)
                }

                Divider().overlay(Color.white.opacity(0.15))

                // Shortcut & Startup
                VStack(alignment: .leading, spacing: 10) {
                    Text("Shortcut & Startup")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.65))
                        .textCase(.uppercase)

                    HStack {
                        Text("Global Hotkey")
                            .foregroundColor(.white)
                        Spacer()
                        ShortcutRecorderButton(
                            keyCode: store.settings.hotkeyKeyCode,
                            modifiers: store.settings.hotkeyModifiers,
                            onChange: { newKeyCode, newModifiers in
                                store.updateHotkey(keyCode: newKeyCode, modifiers: newModifiers)
                            }
                        )
                        Button("Reset") {
                            store.updateHotkey(keyCode: 49, modifiers: UInt32(optionKey))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Toggle(
                        "Disable Default macOS Apps Window on Shortcut",
                        isOn: Binding(
                            get: { store.settings.disableDefaultAppsOnShortcut },
                            set: { store.setDisableDefaultAppsOnShortcut($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .foregroundColor(.white)

                    Toggle(
                        "Replace F4 (Launchpad Key) with Ber Launchpad",
                        isOn: Binding(
                            get: { store.settings.replaceF4LaunchpadKey },
                            set: { store.setReplaceF4LaunchpadKey($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .foregroundColor(.white)

                    Toggle(
                        "Launch at Login (Background)",
                        isOn: Binding(
                            get: { store.settings.launchAtLogin },
                            set: { store.setLaunchAtLogin($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .foregroundColor(.white)
                }

                Divider().overlay(Color.white.opacity(0.15))

                // Layout Reset Presets
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reset Layout Preset")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.65))
                        .textCase(.uppercase)

                    ForEach(LayoutPreset.allCases) { preset in
                        Button {
                            confirmResetPreset = preset
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white)
                                    Text(preset.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.6))
                                }
                                Spacer()
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.09))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let preset = confirmResetPreset {
                    HStack(spacing: 10) {
                        Text("Reset layout to “\(preset.title)”?")
                            .font(.system(size: 12))
                            .foregroundColor(.yellow)
                        Spacer()
                        Button("Cancel") {
                            confirmResetPreset = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Confirm") {
                            store.applyLayoutPreset(preset)
                            confirmResetPreset = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.yellow.opacity(0.12))
                    )
                }

                Divider().overlay(Color.white.opacity(0.15))

                HStack {
                    Button(role: .destructive) {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Text("Quit Ber Launchpad")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.red.opacity(0.95))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            store.isSettingsPresented = false
                        }
                    } label: {
                        Text("Done")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.accentColor)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
            .frame(width: 490)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThickMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(white: 0.12).opacity(0.78))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.55), radius: 32, y: 14)
            .onTapGesture {
                // Prevent background tap-to-close from dismissing when clicking inside settings modal
            }
        }
    }
}

// MARK: - Shortcut Recorder

struct ShortcutRecorderButton: View {
    let keyCode: UInt32
    let modifiers: UInt32
    let onChange: (UInt32, UInt32) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            Text(isRecording ? "Press Shortcut..." : HotKeyManager.formatShortcut(keyCode: keyCode, modifiers: modifiers))
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(minWidth: 110)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.65) : Color.white.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(isRecording ? Color.white.opacity(0.75) : Color.white.opacity(0.25), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            let carbonMods = HotKeyManager.carbonModifiers(from: event.modifierFlags)
            let isFunctionKey = (event.keyCode >= UInt16(kVK_F1) && event.keyCode <= UInt16(kVK_F12))
            if carbonMods != 0 || isFunctionKey {
                onChange(UInt32(event.keyCode), carbonMods)
                stopRecording()
                return nil
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
