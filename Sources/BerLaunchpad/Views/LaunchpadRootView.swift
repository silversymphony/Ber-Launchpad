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
            let hasRecent = store.settings.showRecentApps && !store.recentApps.isEmpty
            let layout = LaunchpadLayoutMetrics.compute(
                screenSize: screenSize,
                settings: store.settings,
                hasRecentApps: hasRecent
            )

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
                        .frame(height: 30)
                        .padding(.top, layout.topBarInset)
                        .padding(.bottom, 6)

                    // Center Area: Search Results or Recent Apps + Paged App Grid
                    ZStack {
                        if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            searchResultsView(screenSize: screenSize, layout: layout)
                                .transition(.opacity)
                        } else {
                            VStack(spacing: 0) {
                                if hasRecent {
                                    recentAppsSection(layout: layout)
                                        .transition(.opacity)
                                }

                                GeometryReader { gridGeo in
                                    pagedGridView(availableSize: gridGeo.size, layout: layout)
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
                            .frame(height: 22)
                        } else {
                            Color.clear.frame(height: 22)
                        }
                    }
                    .padding(.bottom, layout.bottomInset)
                }
                .blur(radius: store.openedFolderID != nil ? 12 : 0)
                .scaleEffect(store.openedFolderID != nil ? 0.97 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.86), value: store.openedFolderID)

                // Expanded Folder Overlay
                if let folder = store.openedFolder {
                    ExpandedFolderOverlayView(
                        store: store,
                        folder: folder,
                        screenSize: screenSize,
                        effectiveIconSize: layout.effectiveIconSize
                    )
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
                        },
                        onHideInstead: {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                store.hideApp(pendingApp)
                                store.appPendingDelete = nil
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .zIndex(30)
                }

                // In-App Delete Error Overlay (avoids spawning external NSAlert sheets)
                if let errorInfo = store.deleteErrorInfo {
                    DeleteErrorOverlayView(
                        errorInfo: errorInfo,
                        onHideInstead: {
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                                store.hideApp(errorInfo.app)
                                store.deleteErrorInfo = nil
                            }
                        },
                        onOpenPrivacySettings: {
                            store.openPrivacySettingsForDelete(isAutomationError: errorInfo.isAutomationError)
                        },
                        onDismiss: {
                            store.deleteErrorInfo = nil
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .zIndex(35)
                }
            }
            .animation(.easeOut(duration: 0.16), value: store.searchText.isEmpty)
            .animation(.spring(response: 0.25, dampingFraction: 0.86), value: store.isSettingsPresented)
            .animation(.spring(response: 0.22, dampingFraction: 0.86), value: store.appPendingDelete != nil)
            .animation(.spring(response: 0.22, dampingFraction: 0.86), value: store.deleteErrorInfo != nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusLaunchpadSearch)) { _ in
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearLaunchpadFocus)) { _ in
            isSearchFocused = false
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

    // MARK: - Recent Apps Row

    @ViewBuilder
    private func recentAppsSection(layout: LaunchpadLayoutMetrics) -> some View {
        let recentSlice = Array(store.recentApps.prefix(layout.columns))
        let gridColumns = Array(repeating: GridItem(.fixed(layout.tileWidth), spacing: layout.colSpacing), count: layout.columns)

        VStack(alignment: .leading, spacing: LaunchpadLayoutMetrics.recentTileSpacing) {
            Text("Recent app")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(.white.opacity(0.88))
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .frame(height: LaunchpadLayoutMetrics.recentHeaderHeight, alignment: .leading)
                .padding(.leading, 6)

            LazyVGrid(columns: gridColumns, spacing: 0) {
                ForEach(recentSlice) { app in
                    AppIconTileView(
                        app: app,
                        iconSize: layout.effectiveIconSize,
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
            .frame(width: layout.gridWidth, alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: layout.gridWidth, height: 1)
                .padding(.top, 3)
                .padding(.bottom, 3)
        }
        .frame(width: layout.gridWidth, alignment: .leading)
        .padding(.top, LaunchpadLayoutMetrics.recentTopPadding)
    }

    // MARK: - Paged App Grid

    @ViewBuilder
    private func pagedGridView(availableSize: CGSize, layout: LaunchpadLayoutMetrics) -> some View {
        let gridWidth = layout.gridWidth
        let cols = layout.columns
        let colSpacing = layout.colSpacing
        let tileWidth = layout.tileWidth
        let rowSpacing = layout.rowSpacing
        let pageWidth = availableSize.width

        HStack(spacing: 0) {
            ForEach(Array(store.pages.enumerated()), id: \.offset) { pageIndex, entries in
                let gridColumns = Array(repeating: GridItem(.fixed(tileWidth), spacing: colSpacing), count: cols)

                VStack(spacing: 0) {
                    LazyVGrid(columns: gridColumns, spacing: rowSpacing) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { itemIndex, entry in
                            gridTile(
                                entry: entry,
                                pageIndex: pageIndex,
                                itemIndex: itemIndex,
                                tileWidth: tileWidth,
                                iconSize: layout.effectiveIconSize
                            )
                        }
                    }
                    .frame(width: gridWidth, alignment: .top)
                    Spacer(minLength: 0)
                }
                .padding(.top, LaunchpadLayoutMetrics.gridTopPadding)
                .padding(.bottom, LaunchpadLayoutMetrics.gridBottomPadding)
                .frame(width: pageWidth, height: availableSize.height, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleBackgroundTap()
                }
                .onDrop(of: [.text], delegate: BackgroundFallbackDropDelegate(store: store))
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
    private func gridTile(
        entry: GridEntry,
        pageIndex: Int,
        itemIndex: Int,
        tileWidth: CGFloat,
        iconSize: Double
    ) -> some View {
        let isSelected = (pageIndex == store.currentPage && store.selectedIndex == itemIndex)
        let isDropTarget = (store.dropTargetEntryID == entry.id)

        Group {
            switch entry {
            case .app(let app):
                AppIconTileView(
                    app: app,
                    iconSize: iconSize,
                    isJiggleMode: store.isJiggleMode,
                    isSelected: isSelected,
                    isDropTarget: isDropTarget,
                    showDeleteBadge: true,
                    showHideBadge: true,
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
                    },
                    onHideTap: {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                            store.hideApp(app)
                        }
                    }
                )
            case .folder(let folder):
                FolderIconTileView(
                    folder: folder,
                    iconSize: iconSize,
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
                iconSize: iconSize,
                store: store
            )
        )
    }

    // MARK: - Search Results Grid

    @ViewBuilder
    private func searchResultsView(screenSize: CGSize, layout: LaunchpadLayoutMetrics) -> some View {
        let matches = store.filteredApps
        let gridWidth = layout.gridWidth
        let gridColumns = Array(repeating: GridItem(.fixed(layout.tileWidth), spacing: layout.colSpacing), count: layout.columns)

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
                            iconSize: layout.effectiveIconSize,
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
        if store.deleteErrorInfo != nil {
            store.deleteErrorInfo = nil
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
