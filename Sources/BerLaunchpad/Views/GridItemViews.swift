import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Jiggle Animation Modifier

struct JiggleModifier: ViewModifier {
    let isJiggling: Bool
    let seed: Int

    @State private var phase: Bool = false

    private var angle: Double {
        (seed % 2 == 0) ? 1.85 : -1.85
    }

    private var offsetY: CGFloat {
        (seed % 3 == 0) ? 0.9 : -0.9
    }

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(isJiggling ? (phase ? angle : -angle) : 0))
            .offset(x: isJiggling ? (phase ? -0.6 : 0.6) : 0, y: isJiggling ? (phase ? offsetY : -offsetY) : 0)
            .animation(
                isJiggling
                    ? .easeInOut(duration: 0.12 + Double(seed % 5) * 0.008).repeatForever(autoreverses: true)
                    : .spring(response: 0.25, dampingFraction: 0.8),
                value: isJiggling ? phase : false
            )
            .onChange(of: isJiggling) { _, active in
                if active {
                    phase = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(seed % 4) * 0.025) {
                        phase.toggle()
                    }
                } else {
                    phase = false
                }
            }
            .onAppear {
                if isJiggling {
                    phase.toggle()
                }
            }
    }
}

// MARK: - App Icon Tile

struct AppIconTileView: View {
    let app: AppItem
    let iconSize: Double
    let isJiggleMode: Bool
    let isSelected: Bool
    let isDropTarget: Bool
    let showDeleteBadge: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onDeleteTap: () -> Void

    @ObservedObject private var iconCache = IconCache.shared
    @State private var isPressed = false
    @State private var isHovered = false

    private var seed: Int {
        abs(app.path.hashValue)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                ZStack {
                    if isDropTarget {
                        RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous)
                            .fill(Color.white.opacity(0.24))
                            .overlay(
                                RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous)
                                    .stroke(Color.white.opacity(0.55), lineWidth: 1.5)
                            )
                            .frame(width: iconSize * 1.18, height: iconSize * 1.18)
                            .transition(.scale.combined(with: .opacity))
                    }

                    Image(nsImage: iconCache.icon(for: app.path))
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: iconSize, height: iconSize)
                        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
                        .scaleEffect(isPressed ? 0.90 : (isDropTarget ? 0.84 : (isHovered ? 1.03 : 1.0)))
                }
                .frame(width: iconSize * 1.18, height: iconSize * 1.05)

                if isJiggleMode && showDeleteBadge && !app.isSystemApp {
                    Button(action: onDeleteTap) {
                        ZStack {
                            Circle()
                                .fill(Color(white: 0.22).opacity(0.92))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
                                )
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 2, y: -4)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .modifier(JiggleModifier(isJiggling: isJiggleMode, seed: seed))

            Text(app.name)
                .font(.system(size: max(11.5, min(13.5, iconSize * 0.165)), weight: .regular))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.75), radius: 2.5, x: 0, y: 1)
                .frame(height: 34, alignment: .top)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.18) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isSelected ? Color.white.opacity(0.38) : Color.clear, lineWidth: 1.2)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            if !isJiggleMode {
                onTap()
            }
        }
        .onLongPressGesture(
            minimumDuration: 0.42,
            maximumDistance: 12,
            pressing: { pressing in
                withAnimation(.easeOut(duration: 0.1)) {
                    isPressed = pressing
                }
            },
            perform: onLongPress
        )
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isDropTarget)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isJiggleMode)
        .id("\(app.path)-\(iconCache.loadedToken >= 0 ? 1 : 0)")
    }
}

// MARK: - Folder Icon Tile (3x3 Miniature Grid)

struct FolderIconTileView: View {
    let folder: FolderItem
    let iconSize: Double
    let isJiggleMode: Bool
    let isSelected: Bool
    let isDropTarget: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    @ObservedObject private var iconCache = IconCache.shared
    @State private var isPressed = false
    @State private var isHovered = false

    private var seed: Int {
        abs(folder.id.hashValue)
    }

    private var miniIconSize: CGFloat {
        max(12, (iconSize - 22) / 3.0)
    }

    var body: some View {
        let previewApps = Array(folder.apps.prefix(9))
        let folderBoxSize = isDropTarget ? iconSize * 1.12 : iconSize

        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: folderBoxSize * 0.23, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: folderBoxSize * 0.23, style: .continuous)
                            .fill(Color.white.opacity(isDropTarget ? 0.22 : 0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: folderBoxSize * 0.23, style: .continuous)
                            .stroke(
                                Color.white.opacity(isDropTarget ? 0.65 : 0.28),
                                lineWidth: isDropTarget ? 1.8 : 1.0
                            )
                    )
                    .frame(width: folderBoxSize, height: folderBoxSize)
                    .shadow(color: .black.opacity(0.32), radius: 10, x: 0, y: 5)

                let columns = Array(repeating: GridItem(.fixed(miniIconSize), spacing: 3), count: 3)
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(previewApps) { app in
                        Image(nsImage: iconCache.icon(for: app.path))
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: miniIconSize, height: miniIconSize)
                            .cornerRadius(miniIconSize * 0.18)
                    }
                }
                .padding(8)
                .frame(width: folderBoxSize, height: folderBoxSize, alignment: .topLeading)
            }
            .frame(width: iconSize * 1.18, height: iconSize * 1.05)
            .scaleEffect(isPressed ? 0.91 : (isHovered ? 1.03 : 1.0))
            .modifier(JiggleModifier(isJiggling: isJiggleMode, seed: seed))

            Text(folder.name)
                .font(.system(size: max(11.5, min(13.5, iconSize * 0.165)), weight: .regular))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.75), radius: 2.5, x: 0, y: 1)
                .frame(height: 34, alignment: .top)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.18) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isSelected ? Color.white.opacity(0.38) : Color.clear, lineWidth: 1.2)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            if !isJiggleMode {
                onTap()
            }
        }
        .onLongPressGesture(
            minimumDuration: 0.42,
            maximumDistance: 12,
            pressing: { pressing in
                withAnimation(.easeOut(duration: 0.1)) {
                    isPressed = pressing
                }
            },
            perform: onLongPress
        )
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isDropTarget)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isJiggleMode)
    }
}

// MARK: - Search Bar

struct SearchBarView: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.75))

            TextField("", text: $text, prompt: Text("Search").foregroundColor(.white.opacity(0.55)))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundColor(.white)
                .focused(isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.65))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 248, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(isFocused.wrappedValue ? 0.55 : 0.24), lineWidth: 1)
                )
        )
    }
}

// MARK: - Page Dots Indicator

struct PageDotsView: View {
    let pageCount: Int
    let currentPage: Int
    let onSelectPage: (Int) -> Void

    var body: some View {
        if pageCount > 1 {
            HStack(spacing: 10) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                            onSelectPage(index)
                        }
                    } label: {
                        Circle()
                            .fill(Color.white.opacity(index == currentPage ? 0.95 : 0.34))
                            .frame(width: 8, height: 8)
                            .scaleEffect(index == currentPage ? 1.1 : 1.0)
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Drop Delegates

struct MainGridDropDelegate: DropDelegate {
    let targetEntry: GridEntry
    let targetPage: Int
    let targetIndex: Int
    let tileWidth: CGFloat
    let iconSize: Double
    let store: LaunchpadStore

    func dropEntered(info: DropInfo) {
        updateHoverIntent(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHoverIntent(info: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if store.dropTargetEntryID == targetEntry.id {
            store.dropTargetEntryID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            store.draggedEntry = nil
            store.draggedFromFolderID = nil
            store.dropTargetEntryID = nil
        }

        guard let dragged = store.draggedEntry else { return false }
        if dragged.id == targetEntry.id { return true }

        if store.dropTargetEntryID == targetEntry.id {
            store.mergeEntries(draggedID: dragged.id, ontoTargetID: targetEntry.id)
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                store.moveEntry(entryID: dragged.id, toPage: targetPage, atIndex: targetIndex)
            }
        }
        return true
    }

    private func updateHoverIntent(info: DropInfo) {
        guard let dragged = store.draggedEntry, dragged.id != targetEntry.id else {
            return
        }

        // Only .app can merge onto another .app or into a .folder
        let xRatio = tileWidth > 0 ? info.location.x / tileWidth : 0.5
        let isCenterZone = xRatio >= 0.26 && xRatio <= 0.74 && info.location.y <= (iconSize + 24)

        if case .app = dragged, isCenterZone {
            if store.dropTargetEntryID != targetEntry.id {
                store.dropTargetEntryID = targetEntry.id
            }
        } else {
            if store.dropTargetEntryID == targetEntry.id {
                store.dropTargetEntryID = nil
            }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                store.moveEntry(entryID: dragged.id, toPage: targetPage, atIndex: targetIndex)
            }
        }
    }
}

struct EdgePageDropDelegate: DropDelegate {
    let direction: Int // -1 = previous, +1 = next
    let store: LaunchpadStore
    @Binding var pendingSwitchWorkItem: DispatchWorkItem?

    func dropEntered(info: DropInfo) {
        guard store.draggedEntry != nil else { return }
        pendingSwitchWorkItem?.cancel()
        let item = DispatchWorkItem {
            Task { @MainActor in
                let target = store.currentPage + direction
                if target >= 0 && target < store.pages.count {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        store.currentPage = target
                    }
                } else if direction > 0 && store.currentPage == store.pages.count - 1 {
                    // Allow creating a trailing page when dragging to right edge on last page
                    if let dragged = store.draggedEntry {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            store.moveEntry(entryID: dragged.id, toPage: store.pages.count, atIndex: 0)
                            store.currentPage = store.pages.count - 1
                        }
                    }
                }
            }
        }
        pendingSwitchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    func dropExited(info: DropInfo) {
        pendingSwitchWorkItem?.cancel()
        pendingSwitchWorkItem = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        pendingSwitchWorkItem?.cancel()
        pendingSwitchWorkItem = nil
        guard let dragged = store.draggedEntry else { return false }
        store.draggedEntry = nil
        store.dropTargetEntryID = nil
        store.moveEntry(entryID: dragged.id, toPage: store.currentPage, atIndex: nil)
        return true
    }
}

struct FolderItemDropDelegate: DropDelegate {
    let folderID: UUID
    let targetApp: AppItem
    let targetIndex: Int
    let store: LaunchpadStore

    func dropEntered(info: DropInfo) {
        guard let dragged = store.draggedEntry,
              case .app(let draggedApp) = dragged,
              draggedApp.path != targetApp.path else {
            return
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            store.moveAppInsideFolder(folderID: folderID, appPath: draggedApp.path, toIndex: targetIndex)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        store.draggedEntry = nil
        store.draggedFromFolderID = nil
        store.dropTargetEntryID = nil
        return true
    }
}

struct BackgroundFallbackDropDelegate: DropDelegate {
    let store: LaunchpadStore

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            store.draggedEntry = nil
            store.draggedFromFolderID = nil
            store.dropTargetEntryID = nil
        }
        guard let dragged = store.draggedEntry else { return false }

        if let fromFolderID = store.draggedFromFolderID, case .app(let app) = dragged {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                store.extractAppFromFolder(folderID: fromFolderID, appPath: app.path, toPage: store.currentPage)
            }
            return true
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            store.moveEntry(entryID: dragged.id, toPage: store.currentPage, atIndex: nil)
        }
        return true
    }
}
