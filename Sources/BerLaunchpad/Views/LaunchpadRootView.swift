import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let focusLaunchpadSearch = Notification.Name("BerLaunchpad.FocusSearch")
    static let clearLaunchpadFocus = Notification.Name("BerLaunchpad.ClearFocus")
}

struct LaunchpadRootView: View {
    @ObservedObject var store: LaunchpadStore
    @FocusState private var isSearchFocused: Bool
    @State private var pendingEdgeSwitchWorkItem: DispatchWorkItem?

    var body: some View {
        GeometryReader { geo in
            let screenSize = geo.size
            let topBarInset = max(46, screenSize.height * 0.055)
            let bottomInset = max(44, screenSize.height * 0.05)

            ZStack {
                // Fullscreen Sequoia Frosted Wallpaper Blur
                VisualEffectView(material: .fullScreenUI, blendingMode: .behindWindow, state: .active)
                    .ignoresSafeArea()

                Color.black.opacity(store.settings.backgroundOpacity)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleBackgroundTap()
                    }
                    .onDrop(of: [.text], delegate: BackgroundFallbackDropDelegate(store: store))

                VStack(spacing: 0) {
                    // Top Bar: Centered Search + Right Controls
                    topBar(screenWidth: screenSize.width)
                        .padding(.top, topBarInset)
                        .padding(.bottom, 14)

                    // Center Area: Search Results or Recent Apps + Paged App Grid
                    ZStack {
                        if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            searchResultsView(screenSize: screenSize)
                                .transition(.opacity)
                        } else {
                            VStack(spacing: 0) {
                                if store.settings.showRecentApps && !store.recentApps.isEmpty {
                                    recentAppsSection(screenWidth: screenSize.width)
                                        .transition(.opacity)
                                }

                                GeometryReader { gridGeo in
                                    pagedGridView(availableSize: gridGeo.size)
                                }
                            }
                            .transition(.opacity)
                        }

                        // Edge drop zones for dragging items across pages
                        if store.draggedEntry != nil && store.searchText.isEmpty && store.openedFolderID == nil {
                            HStack {
                                Color.clear
                                    .frame(width: 56)
                                    .contentShape(Rectangle())
                                    .onDrop(
                                        of: [.text],
                                        delegate: EdgePageDropDelegate(
                                            direction: -1,
                                            store: store,
                                            pendingSwitchWorkItem: $pendingEdgeSwitchWorkItem
                                        )
                                    )
                                Spacer()
                                Color.clear
                                    .frame(width: 56)
                                    .contentShape(Rectangle())
                                    .onDrop(
                                        of: [.text],
                                        delegate: EdgePageDropDelegate(
                                            direction: 1,
                                            store: store,
                                            pendingSwitchWorkItem: $pendingEdgeSwitchWorkItem
                                        )
                                    )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Bottom Bar: Page Indicator Dots
                    Group {
                        if store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            PageDotsView(
                                pageCount: store.pages.count,
                                currentPage: store.currentPage,
                                onSelectPage: { page in
                                    store.currentPage = page
                                    store.selectedIndex = nil
                                }
                            )
                        } else {
                            Color.clear.frame(height: 26)
                        }
                    }
                    .padding(.bottom, bottomInset)
                }
                .blur(radius: store.openedFolderID != nil ? 12 : 0)
                .scaleEffect(store.openedFolderID != nil ? 0.97 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.86), value: store.openedFolderID)

                // Expanded Folder Overlay
                if let folder = store.openedFolder {
                    ExpandedFolderOverlayView(store: store, folder: folder, screenSize: screenSize)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .zIndex(10)
                }

                // Settings Modal Overlay
                if store.isSettingsPresented {
                    SettingsOverlayView(store: store)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .zIndex(20)
                }

                // Delete Confirmation Alert Overlay
                if let pendingApp = store.appPendingDelete {
                    DeleteConfirmationOverlayView(
                        app: pendingApp,
                        onCancel: {
                            store.appPendingDelete = nil
                        },
                        onConfirm: {
                            store.executePendingDelete()
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .zIndex(30)
                }
            }
            .animation(.easeOut(duration: 0.16), value: store.searchText.isEmpty)
            .animation(.spring(response: 0.25, dampingFraction: 0.86), value: store.isSettingsPresented)
            .animation(.spring(response: 0.22, dampingFraction: 0.86), value: store.appPendingDelete != nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusLaunchpadSearch)) { _ in
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearLaunchpadFocus)) { _ in
            isSearchFocused = false
        }
        .alert(
            "Unable to Delete Application",
            isPresented: Binding(
                get: { store.deleteErrorMessage != nil },
                set: { if !$0 { store.deleteErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                store.deleteErrorMessage = nil
            }
        } message: {
            Text(store.deleteErrorMessage ?? "")
        }
    }

    // MARK: - Top Bar

    @ViewBuilder
    private func topBar(screenWidth: CGFloat) -> some View {
        ZStack {
            SearchBarView(text: $store.searchText, isFocused: $isSearchFocused)

            HStack {
                if store.isJiggleMode {
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            store.isJiggleMode = false
                        }
                    } label: {
                        Text("Done")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.20))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.32), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }

                Spacer()

                Button {
                    isSearchFocused = false
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        store.isSettingsPresented.toggle()
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.12))
                                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.8))
                        )
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }
            .padding(.horizontal, max(28, screenWidth * 0.04))
        }
    }

    // MARK: - Grid Metrics & Recent Apps Row

    private struct GridMetrics {
        let gridWidth: CGFloat
        let cols: Int
        let colSpacing: CGFloat
        let tileWidth: CGFloat
    }

    private func gridMetrics(for width: CGFloat) -> GridMetrics {
        let horizontalPadding = max(72, width * 0.085)
        let gridWidth = max(320, width - horizontalPadding * 2)
        let cols = store.settings.columns
        let colSpacing = max(
            12,
            min(32, (gridWidth - CGFloat(cols) * CGFloat(store.settings.iconSize + 28)) / CGFloat(max(1, cols - 1)))
        )
        let tileWidth = max(92, (gridWidth - colSpacing * CGFloat(cols - 1)) / CGFloat(cols))
        return GridMetrics(gridWidth: gridWidth, cols: cols, colSpacing: colSpacing, tileWidth: tileWidth)
    }

    @ViewBuilder
    private func recentAppsSection(screenWidth: CGFloat) -> some View {
        let metrics = gridMetrics(for: screenWidth)
        let recentSlice = Array(store.recentApps.prefix(metrics.cols))
        let gridColumns = Array(repeating: GridItem(.fixed(metrics.tileWidth), spacing: metrics.colSpacing), count: metrics.cols)

        VStack(alignment: .leading, spacing: 8) {
            Text("Recent app")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(.white.opacity(0.88))
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .padding(.leading, 6)

            LazyVGrid(columns: gridColumns, spacing: 0) {
                ForEach(recentSlice) { app in
                    AppIconTileView(
                        app: app,
                        iconSize: store.settings.iconSize,
                        isJiggleMode: false,
                        isSelected: false,
                        isDropTarget: false,
                        showDeleteBadge: false,
                        onTap: {
                            store.launchApp(app)
                        },
                        onLongPress: {},
                        onDeleteTap: {}
                    )
                }
            }
            .frame(width: metrics.gridWidth, alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: metrics.gridWidth, height: 1)
                .padding(.top, 10)
                .padding(.bottom, 8)
        }
        .frame(width: metrics.gridWidth, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: - Paged App Grid

    @ViewBuilder
    private func pagedGridView(availableSize: CGSize) -> some View {
        let metrics = gridMetrics(for: availableSize.width)
        let gridWidth = metrics.gridWidth
        let cols = metrics.cols
        let rows = store.settings.rows
        let colSpacing = metrics.colSpacing
        let tileWidth = metrics.tileWidth
        let rowSpacing = max(12, min(32, (availableSize.height - CGFloat(rows) * CGFloat(store.settings.iconSize + 52)) / CGFloat(max(1, rows))))

        let pageWidth = availableSize.width

        HStack(spacing: 0) {
            ForEach(Array(store.pages.enumerated()), id: \.offset) { pageIndex, entries in
                let gridColumns = Array(repeating: GridItem(.fixed(tileWidth), spacing: colSpacing), count: cols)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack {
                        LazyVGrid(columns: gridColumns, spacing: rowSpacing) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { itemIndex, entry in
                                gridTile(
                                    entry: entry,
                                    pageIndex: pageIndex,
                                    itemIndex: itemIndex,
                                    tileWidth: tileWidth
                                )
                            }
                        }
                        .frame(width: gridWidth, alignment: .top)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                    .frame(width: pageWidth)
                    .frame(minHeight: availableSize.height, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleBackgroundTap()
                    }
                }
                .frame(width: pageWidth, height: availableSize.height, alignment: .top)
            }
        }
        .frame(width: pageWidth, height: availableSize.height, alignment: .leading)
        .offset(x: -CGFloat(store.currentPage) * pageWidth + store.scrollDragOffset)
        .clipped()
        .animation(
            store.scrollDragOffset == 0
                ? .spring(response: 0.36, dampingFraction: 0.86)
                : .interactiveSpring(response: 0.12, dampingFraction: 1.0),
            value: store.currentPage
        )
        .animation(
            .interactiveSpring(response: 0.14, dampingFraction: 0.95),
            value: store.scrollDragOffset
        )
    }

    @ViewBuilder
    private func gridTile(entry: GridEntry, pageIndex: Int, itemIndex: Int, tileWidth: CGFloat) -> some View {
        let isSelected = (pageIndex == store.currentPage && store.selectedIndex == itemIndex)
        let isDropTarget = (store.dropTargetEntryID == entry.id)

        Group {
            switch entry {
            case .app(let app):
                AppIconTileView(
                    app: app,
                    iconSize: store.settings.iconSize,
                    isJiggleMode: store.isJiggleMode,
                    isSelected: isSelected,
                    isDropTarget: isDropTarget,
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
            case .folder(let folder):
                FolderIconTileView(
                    folder: folder,
                    iconSize: store.settings.iconSize,
                    isJiggleMode: store.isJiggleMode,
                    isSelected: isSelected,
                    isDropTarget: isDropTarget,
                    onTap: {
                        isSearchFocused = false
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            store.openedFolderID = folder.id
                            store.selectedIndex = nil
                        }
                    },
                    onLongPress: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            store.isJiggleMode = true
                        }
                    }
                )
            }
        }
        .onDrag {
            store.draggedEntry = entry
            store.draggedFromFolderID = nil
            return NSItemProvider(object: entry.id as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: MainGridDropDelegate(
                targetEntry: entry,
                targetPage: pageIndex,
                targetIndex: itemIndex,
                tileWidth: tileWidth,
                iconSize: store.settings.iconSize,
                store: store
            )
        )
    }

    // MARK: - Search Results Grid

    @ViewBuilder
    private func searchResultsView(screenSize: CGSize) -> some View {
        let matches = store.filteredApps
        let metrics = gridMetrics(for: screenSize.width)
        let gridWidth = metrics.gridWidth
        let gridColumns = Array(repeating: GridItem(.fixed(metrics.tileWidth), spacing: metrics.colSpacing), count: metrics.cols)

        if matches.isEmpty {
            VStack {
                Spacer()
                Text("No Results")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.white.opacity(0.42))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                handleBackgroundTap()
            }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: gridColumns, spacing: 26) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, app in
                        AppIconTileView(
                            app: app,
                            iconSize: store.settings.iconSize,
                            isJiggleMode: false,
                            isSelected: store.selectedIndex == index,
                            isDropTarget: false,
                            showDeleteBadge: false,
                            onTap: {
                                store.launchApp(app)
                            },
                            onLongPress: {},
                            onDeleteTap: {}
                        )
                    }
                }
                .frame(width: gridWidth)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                handleBackgroundTap()
            }
        }
    }

    // MARK: - Actions

    private func handleBackgroundTap() {
        isSearchFocused = false
        if store.isSettingsPresented {
            store.isSettingsPresented = false
            return
        }
        if store.appPendingDelete != nil {
            store.appPendingDelete = nil
            return
        }
        if store.openedFolderID != nil {
            store.openedFolderID = nil
            return
        }
        if store.isJiggleMode {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                store.isJiggleMode = false
            }
            return
        }
        store.onRequestHide?(true)
    }
}
