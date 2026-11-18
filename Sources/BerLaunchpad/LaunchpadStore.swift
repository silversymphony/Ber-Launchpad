import AppKit
import Combine
import Foundation

@MainActor
final class LaunchpadStore: ObservableObject {
    static let shared = LaunchpadStore()

    @Published var pages: [[GridEntry]] = [[]]
    @Published var recentApps: [AppItem] = []
    @Published var hiddenApps: [AppItem] = []
    @Published var settings: AppSettings = .default
    @Published var currentPage: Int = 0
    @Published var searchText: String = "" {
        didSet {
            if oldValue != searchText {
                selectedIndex = searchText.isEmpty ? nil : 0
            }
        }
    }
    @Published var openedFolderID: UUID?
    @Published var isJiggleMode: Bool = false
    @Published var appPendingDelete: AppItem?
    @Published var isSettingsPresented: Bool = false
    @Published var selectedIndex: Int?
    @Published var scrollDragOffset: CGFloat = 0

    // Drag and Drop state
    @Published var draggedEntry: GridEntry?
    @Published var draggedFromFolderID: UUID?
    @Published var dropTargetEntryID: String?

    // Deletion state
    @Published var isDeletingApp: Bool = false
    @Published var deleteErrorInfo: DeleteErrorInfo?

    var onRequestHide: ((_ restorePreviousApp: Bool) -> Void)?
    var onDeleteFlowStarted: (() -> Void)?
    var onDeleteFlowFinished: (() -> Void)?
    var onHotkeyChanged: ((UInt32, UInt32) -> Void)?
    var onHotKeySettingsChanged: (() -> Void)?

    private var directorySources: [DispatchSourceFileSystemObject] = []
    private var directoryFileDescriptors: [Int32] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var rescanWorkItem: DispatchWorkItem?
    private var isInitialized = false
    private var lastScannedApps: [AppItem] = []
    private let customSupportDirectory: URL?

    private var appSupportDir: URL {
        if let customSupportDirectory {
            return customSupportDirectory
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("BerLaunchpad", isDirectory: true)
    }

    private var layoutFileURL: URL {
        appSupportDir.appendingPathComponent("layout.json")
    }

    private var settingsFileURL: URL {
        appSupportDir.appendingPathComponent("settings.json")
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.ber.launchpad.plist")
    }

    init(supportDirectory: URL? = nil) {
        self.customSupportDirectory = supportDirectory
    }

    func initialize() {
        guard !isInitialized else { return }
        isInitialized = true

        ensureSupportDirectory()
        loadSettings()
        let hadSavedLayout = loadLayout()
        if hadSavedLayout {
            refreshRecentApps()
            refreshHiddenAppsList()
        }
        syncInstalledApps(initialIfNeeded: !hadSavedLayout)
        startDirectoryMonitoring()
        startWorkspaceObservation()
    }

    // MARK: - Computed Helpers

    var openedFolder: FolderItem? {
        guard let openedFolderID else { return nil }
        for page in pages {
            for entry in page {
                if case .folder(let folder) = entry, folder.id == openedFolderID {
                    return folder
                }
            }
        }
        return nil
    }

    var allApps: [AppItem] {
        var result: [AppItem] = []
        for page in pages {
            for entry in page {
                switch entry {
                case .app(let app):
                    result.append(app)
                case .folder(let folder):
                    result.append(contentsOf: folder.apps)
                }
            }
        }
        return result
    }

    var filteredApps: [AppItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let foldedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var prefixMatches: [AppItem] = []
        var containsMatches: [AppItem] = []

        for app in allApps {
            let foldedName = app.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if foldedName.hasPrefix(foldedQuery) {
                prefixMatches.append(app)
            } else if foldedName.contains(foldedQuery) {
                containsMatches.append(app)
            }
        }

        return prefixMatches + containsMatches
    }

    // MARK: - Persistence

    private func ensureSupportDirectory() {
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }

    func loadSettings() {
        guard let data = try? Data(contentsOf: settingsFileURL),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            settings = .default
            settings.launchAtLogin = FileManager.default.fileExists(atPath: launchAgentURL.path)
            saveSettings()
            return
        }
        settings = decoded
        settings.launchAtLogin = FileManager.default.fileExists(atPath: launchAgentURL.path)
        saveSettings()
    }

    func saveSettings() {
        ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: settingsFileURL, options: .atomic)
        }
    }

    @discardableResult
    func loadLayout() -> Bool {
        guard let data = try? Data(contentsOf: layoutFileURL),
              let decoded = try? JSONDecoder().decode([[GridEntry]].self, from: data),
              !decoded.isEmpty else {
            return false
        }
        pages = decoded
        return true
    }

    func saveLayout() {
        ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(pages) {
            try? data.write(to: layoutFileURL, options: .atomic)
        }
    }

    // MARK: - App Scanning & Sync

    func syncInstalledApps(initialIfNeeded: Bool = false) {
        Task.detached(priority: .userInitiated) {
            let scanned = AppScanner.scanInstalledApps()
            await MainActor.run {
                self.lastScannedApps = scanned
                if initialIfNeeded || (self.pages.count == 1 && self.pages[0].isEmpty) {
                    self.applyLayoutPreset(.categoryFolders, withScannedApps: scanned)
                } else {
                    self.mergeScannedApps(scanned)
                }
                IconCache.shared.preload(paths: scanned.map(\.path))
            }
        }
    }

    func mergeScannedApps(_ scannedApps: [AppItem]) {
        self.lastScannedApps = scannedApps
        let hiddenSet = Set(settings.hiddenAppPaths)
        let visibleApps = scannedApps.filter { !hiddenSet.contains($0.path) }

        let scannedByPath = Dictionary(uniqueKeysWithValues: visibleApps.map { ($0.path, $0) })
        var existingPaths = Set<String>()
        var updatedPages: [[GridEntry]] = []

        for page in pages {
            var newPage: [GridEntry] = []
            for entry in page {
                switch entry {
                case .app(let app):
                    if let fresh = scannedByPath[app.path] {
                        newPage.append(.app(fresh))
                        existingPaths.insert(fresh.path)
                    }
                case .folder(var folder):
                    let freshApps = folder.apps.compactMap { oldApp -> AppItem? in
                        guard let fresh = scannedByPath[oldApp.path] else { return nil }
                        existingPaths.insert(fresh.path)
                        return fresh
                    }
                    if !freshApps.isEmpty {
                        folder.apps = freshApps
                        newPage.append(.folder(folder))
                    }
                }
            }
            if !newPage.isEmpty {
                updatedPages.append(newPage)
            }
        }

        if updatedPages.isEmpty {
            updatedPages = [[]]
        }

        // Append newly installed apps (into matching category folder when layout uses top-level folders, or onto the last page)
        let newApps = visibleApps.filter { !existingPaths.contains($0.path) }
        let limit = settings.itemsPerPage
        let isFolderOnlyLayout = !updatedPages[0].isEmpty && updatedPages[0].allSatisfy { $0.asFolder != nil }
        for app in newApps {
            if isFolderOnlyLayout,
               let targetLocation = findFolder(named: app.category.displayName, in: updatedPages),
               case .folder(var folder) = updatedPages[targetLocation.page][targetLocation.index] {
                folder.apps.append(app)
                folder.apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                updatedPages[targetLocation.page][targetLocation.index] = .folder(folder)
            } else {
                if updatedPages[updatedPages.count - 1].count >= limit {
                    updatedPages.append([])
                }
                updatedPages[updatedPages.count - 1].append(.app(app))
            }
        }

        pages = normalizePages(updatedPages)
        clampCurrentPage()
        saveLayout()
        refreshRecentApps()
        refreshHiddenAppsList(from: scannedApps)
    }

    private func findFolder(named name: String, in candidatePages: [[GridEntry]]) -> (page: Int, index: Int)? {
        for (pIdx, page) in candidatePages.enumerated() {
            if let iIdx = page.firstIndex(where: { $0.asFolder?.name == name }) {
                return (pIdx, iIdx)
            }
        }
        return nil
    }

    // MARK: - Layout Presets

    func applyLayoutPreset(_ preset: LayoutPreset, withScannedApps providedApps: [AppItem]? = nil) {
        let rawApps = providedApps ?? AppScanner.scanInstalledApps()
        lastScannedApps = rawApps
        let hiddenSet = Set(settings.hiddenAppPaths)
        let apps = rawApps.filter { !hiddenSet.contains($0.path) }
        let entries: [GridEntry]

        switch preset {
        case .categoryFolders:
            var grouped: [AppCategory: [AppItem]] = [:]
            for app in apps {
                grouped[app.category, default: []].append(app)
            }
            let sortedCategories = AppCategory.allCases.sorted { $0.sortOrder < $1.sortOrder }
            entries = sortedCategories.compactMap { category in
                guard let catApps = grouped[category], !catApps.isEmpty else { return nil }
                let sorted = catApps.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return .folder(FolderItem(name: category.displayName, apps: sorted))
            }

        case .appleStandard:
            let utilityKeywords = [
                "utilities", "activity monitor", "audio midi", "bluetooth file exchange",
                "bootcamp", "colorSync", "colorsync", "console", "digital color meter",
                "disk utility", "grapher", "keychain access", "migration assistant",
                "print center", "screenshot", "script editor", "system information",
                "terminal", "voiceover", "automator"
            ]
            var systemPrimary: [AppItem] = []
            var systemOther: [AppItem] = []
            var userApps: [AppItem] = []

            for app in apps {
                if app.isSystemApp {
                    let lowerName = app.name.lowercased()
                    let isUtility = app.path.contains("/Utilities/") ||
                        utilityKeywords.contains(where: { lowerName.contains($0) })
                    if isUtility {
                        systemOther.append(app)
                    } else {
                        systemPrimary.append(app)
                    }
                } else {
                    userApps.append(app)
                }
            }

            var builtEntries: [GridEntry] = systemPrimary.map { .app($0) }
            if !systemOther.isEmpty {
                builtEntries.append(.folder(FolderItem(name: "Other", apps: systemOther)))
            }
            builtEntries.append(contentsOf: userApps.map { .app($0) })
            entries = builtEntries

        case .alphabetical:
            let sorted = apps.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            entries = sorted.map { .app($0) }
        }

        pages = paginate(entries: entries, itemsPerPage: settings.itemsPerPage)
        currentPage = 0
        openedFolderID = nil
        isJiggleMode = false
        selectedIndex = nil
        saveLayout()
        refreshRecentApps()
        refreshHiddenAppsList(from: rawApps)
        IconCache.shared.preload(paths: apps.map(\.path))
    }

    func sortAlphabetically() {
        var allEntries: [GridEntry] = []
        for page in pages {
            for entry in page {
                switch entry {
                case .app(let app):
                    allEntries.append(.app(app))
                case .folder(var folder):
                    folder.apps.sort {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    if folder.apps.count == 1 {
                        allEntries.append(.app(folder.apps[0]))
                    } else if !folder.apps.isEmpty {
                        allEntries.append(.folder(folder))
                    }
                }
            }
        }

        allEntries.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        pages = paginate(entries: allEntries, itemsPerPage: settings.itemsPerPage)
        clampCurrentPage()
        selectedIndex = nil
        saveLayout()
    }

    private func paginate(entries: [GridEntry], itemsPerPage: Int) -> [[GridEntry]] {
        guard !entries.isEmpty else { return [[]] }
        let step = max(1, itemsPerPage)
        var result: [[GridEntry]] = []
        var idx = 0
        while idx < entries.count {
            let end = min(idx + step, entries.count)
            result.append(Array(entries[idx..<end]))
            idx = end
        }
        return result
    }

    func reflowPagesForUpdatedGridSize() {
        let limit = settings.itemsPerPage
        var newPages: [[GridEntry]] = []
        var carry: [GridEntry] = []

        for page in pages {
            let combined = carry + page
            if combined.count <= limit {
                if !combined.isEmpty {
                    newPages.append(combined)
                }
                carry = []
            } else {
                newPages.append(Array(combined.prefix(limit)))
                carry = Array(combined.dropFirst(limit))
            }
        }

        while !carry.isEmpty {
            newPages.append(Array(carry.prefix(limit)))
            carry = Array(carry.dropFirst(limit))
        }

        pages = newPages.isEmpty ? [[]] : newPages
        clampCurrentPage()
        saveLayout()
    }

    private func normalizePages(_ raw: [[GridEntry]]) -> [[GridEntry]] {
        let nonEmpty = raw.filter { !$0.isEmpty }
        return nonEmpty.isEmpty ? [[]] : nonEmpty
    }

    private func clampCurrentPage() {
        currentPage = min(max(0, currentPage), max(0, pages.count - 1))
    }

    // MARK: - Drag, Drop & Folder Manipulation

    func moveEntry(entryID: String, toPage targetPage: Int, atIndex targetIndex: Int?) {
        guard let sourceLoc = locateEntry(id: entryID) else { return }
        var workingPages = pages
        let movingEntry = workingPages[sourceLoc.page].remove(at: sourceLoc.index)

        let clampedTargetPage = min(max(0, targetPage), workingPages.count)
        if clampedTargetPage == workingPages.count {
            workingPages.append([])
        }

        var adjustedIndex: Int
        if let targetIndex {
            if sourceLoc.page == clampedTargetPage && sourceLoc.index < targetIndex {
                adjustedIndex = max(0, targetIndex - 1)
            } else {
                adjustedIndex = targetIndex
            }
            adjustedIndex = min(max(0, adjustedIndex), workingPages[clampedTargetPage].count)
        } else {
            adjustedIndex = workingPages[clampedTargetPage].count
        }

        workingPages[clampedTargetPage].insert(movingEntry, at: adjustedIndex)

        // Ripple overflow items forward if page exceeds itemsPerPage
        let limit = settings.itemsPerPage
        var pageCursor = clampedTargetPage
        while pageCursor < workingPages.count && workingPages[pageCursor].count > limit {
            let overflow = workingPages[pageCursor].removeLast()
            if pageCursor + 1 >= workingPages.count {
                workingPages.append([])
            }
            workingPages[pageCursor + 1].insert(overflow, at: 0)
            pageCursor += 1
        }

        pages = normalizePages(workingPages)
        if currentPage >= pages.count {
            currentPage = max(0, pages.count - 1)
        }
        saveLayout()
    }

    func mergeEntries(draggedID: String, ontoTargetID targetID: String) {
        guard draggedID != targetID,
              let sourceLoc = locateEntry(id: draggedID),
              let targetLoc = locateEntry(id: targetID) else {
            return
        }

        let draggedEntry = pages[sourceLoc.page][sourceLoc.index]
        let targetEntry = pages[targetLoc.page][targetLoc.index]

        guard case .app(let draggedApp) = draggedEntry else {
            // Folders cannot be nested into other folders; reorder instead
            moveEntry(entryID: draggedID, toPage: targetLoc.page, atIndex: targetLoc.index)
            return
        }

        var workingPages = pages

        switch targetEntry {
        case .app(let targetApp):
            let folderName = suggestedFolderName(app1: targetApp, app2: draggedApp)
            let newFolder = FolderItem(name: folderName, apps: [targetApp, draggedApp])
            workingPages[targetLoc.page][targetLoc.index] = .folder(newFolder)
            workingPages[sourceLoc.page].remove(at: sourceLoc.index)

        case .folder(var targetFolder):
            if !targetFolder.apps.contains(where: { $0.path == draggedApp.path }) {
                targetFolder.apps.append(draggedApp)
            }
            workingPages[targetLoc.page][targetLoc.index] = .folder(targetFolder)
            workingPages[sourceLoc.page].remove(at: sourceLoc.index)
        }

        pages = normalizePages(workingPages)
        clampCurrentPage()
        saveLayout()
        refreshRecentApps()
    }

    func moveAppInsideFolder(folderID: UUID, appPath: String, toIndex targetIndex: Int) {
        guard let loc = locateFolder(id: folderID),
              case .folder(var folder) = pages[loc.page][loc.index],
              let fromIdx = folder.apps.firstIndex(where: { $0.path == appPath }) else {
            return
        }
        let item = folder.apps.remove(at: fromIdx)
        let clamped = min(max(0, targetIndex), folder.apps.count)
        folder.apps.insert(item, at: clamped)
        pages[loc.page][loc.index] = .folder(folder)
        saveLayout()
    }

    func extractAppFromFolder(folderID: UUID, appPath: String, toPage: Int? = nil, atIndex: Int? = nil) {
        guard let loc = locateFolder(id: folderID),
              case .folder(var folder) = pages[loc.page][loc.index],
              let appIdx = folder.apps.firstIndex(where: { $0.path == appPath }) else {
            return
        }

        let extractedApp = folder.apps.remove(at: appIdx)
        var workingPages = pages
        let folderRemoved = folder.apps.isEmpty

        if folderRemoved {
            workingPages[loc.page].remove(at: loc.index)
            openedFolderID = nil
        } else if folder.apps.count == 1 {
            // Dissolve 1-app folder back into a standalone app
            workingPages[loc.page][loc.index] = .app(folder.apps[0])
            openedFolderID = nil
        } else {
            workingPages[loc.page][loc.index] = .folder(folder)
        }

        let destPage = min(max(0, toPage ?? loc.page), workingPages.count)
        if destPage == workingPages.count {
            workingPages.append([])
        }

        let defaultIndex: Int
        if destPage == loc.page {
            // Place extracted app immediately after its folder or dissolved partner app
            defaultIndex = folderRemoved ? loc.index : (loc.index + 1)
        } else {
            defaultIndex = workingPages[destPage].count
        }
        let destIdx = min(max(0, atIndex ?? defaultIndex), workingPages[destPage].count)
        workingPages[destPage].insert(.app(extractedApp), at: destIdx)

        // Handle overflow ripple without losing the newly extracted app off-page when slots remain
        let limit = settings.itemsPerPage
        var cursor = destPage
        while cursor < workingPages.count && workingPages[cursor].count > limit {
            let overflow = workingPages[cursor].removeLast()
            if cursor + 1 >= workingPages.count {
                workingPages.append([])
            }
            workingPages[cursor + 1].insert(overflow, at: 0)
            cursor += 1
        }

        pages = normalizePages(workingPages)
        clampCurrentPage()
        openedFolderID = nil
        saveLayout()
        refreshRecentApps()
    }

    func renameFolder(folderID: UUID, newName: String) {
        guard let loc = locateFolder(id: folderID),
              case .folder(var folder) = pages[loc.page][loc.index] else {
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = trimmed.isEmpty ? "Untitled" : trimmed
        pages[loc.page][loc.index] = .folder(folder)
        saveLayout()
    }

    private func suggestedFolderName(app1: AppItem, app2: AppItem) -> String {
        if app1.category == app2.category {
            return app1.category.displayName
        }
        if app1.category != .other {
            return app1.category.displayName
        }
        return app2.category.displayName
    }

    private func locateEntry(id: String) -> (page: Int, index: Int)? {
        for (pIdx, page) in pages.enumerated() {
            if let iIdx = page.firstIndex(where: { $0.id == id }) {
                return (pIdx, iIdx)
            }
        }
        return nil
    }

    private func locateFolder(id: UUID) -> (page: Int, index: Int)? {
        for (pIdx, page) in pages.enumerated() {
            if let iIdx = page.firstIndex(where: {
                if case .folder(let f) = $0 { return f.id == id }
                return false
            }) {
                return (pIdx, iIdx)
            }
        }
        return nil
    }

    // MARK: - App Launch & Delete

    func launchApp(_ app: AppItem) {
        recordRecentApp(app)
        let rawURL = URL(fileURLWithPath: app.path)
        let appURL = rawURL.pathExtension.lowercased() == "app" ? rawURL : rawURL.resolvingSymlinksInPath()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        onRequestHide?(false)
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                NSLog("BerLaunchpad: Failed to launch %@: %@", app.path, error.localizedDescription)
            }
        }
    }

    // MARK: - Recent Apps Tracking

    func recordRecentApp(_ app: AppItem) {
        if let selfID = Bundle.main.bundleIdentifier, app.bundleIdentifier == selfID {
            return
        }
        var updated = settings.recentAppPaths.filter { $0 != app.path }
        updated.insert(app.path, at: 0)
        if updated.count > 16 {
            updated = Array(updated.prefix(16))
        }
        if settings.recentAppPaths != updated {
            settings.recentAppPaths = updated
            saveSettings()
        }
        refreshRecentApps()
    }

    func recordRecentApp(bundleIdentifier: String?, bundleURL: URL?) {
        if let selfID = Bundle.main.bundleIdentifier, bundleIdentifier == selfID {
            return
        }
        let installed = allApps
        if let url = bundleURL {
            let rawPath = url.path
            let resolvedPath = url.resolvingSymlinksInPath().path
            if let match = installed.first(where: {
                $0.path == rawPath || URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == resolvedPath
            }) {
                recordRecentApp(match)
                return
            }
        }
        if let bundleID = bundleIdentifier, !bundleID.isEmpty,
           let match = installed.first(where: { $0.bundleIdentifier == bundleID }) {
            recordRecentApp(match)
        }
    }

    func refreshRecentApps() {
        let installed = allApps
        let byPath = Dictionary(installed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let byResolvedPath = Dictionary(
            installed.map { (URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let byBundleID = Dictionary(
            installed.filter { !$0.bundleIdentifier.isEmpty }.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var resolvedList: [AppItem] = []
        var seenPaths = Set<String>()

        for path in settings.recentAppPaths {
            if let app = byPath[path] ?? byResolvedPath[URL(fileURLWithPath: path).resolvingSymlinksInPath().path],
               !seenPaths.contains(app.path) {
                resolvedList.append(app)
                seenPaths.insert(app.path)
            }
        }

        // Backfill from currently running regular apps if fewer than a full row
        if resolvedList.count < settings.columns {
            let selfBundleID = Bundle.main.bundleIdentifier
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.bundleIdentifier != selfBundleID
            }
            var didBackfill = false
            for runningApp in running {
                if resolvedList.count >= settings.columns { break }
                var matched: AppItem?
                if let url = runningApp.bundleURL {
                    let rp = url.resolvingSymlinksInPath().path
                    matched = byPath[url.path] ?? byResolvedPath[rp]
                }
                if matched == nil, let bid = runningApp.bundleIdentifier {
                    matched = byBundleID[bid]
                }
                if let app = matched, !seenPaths.contains(app.path) {
                    resolvedList.append(app)
                    seenPaths.insert(app.path)
                    didBackfill = true
                }
            }
            if didBackfill {
                settings.recentAppPaths = Array(resolvedList.map(\.path).prefix(16))
                saveSettings()
            }
        }

        recentApps = resolvedList
    }

    private func startWorkspaceObservation() {
        guard workspaceObservers.isEmpty else { return }
        let wsCenter = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        for name in names {
            let observer = wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                let bundleURL = app?.bundleURL
                Task { @MainActor in
                    self?.recordRecentApp(bundleIdentifier: bundleID, bundleURL: bundleURL)
                }
            }
            workspaceObservers.append(observer)
        }
    }

    func requestDelete(_ app: AppItem) {
        guard !app.isSystemApp else { return }
        appPendingDelete = app
    }

    func hideApp(_ app: AppItem) {
        if lastScannedApps.isEmpty {
            lastScannedApps = allApps
        } else if !lastScannedApps.contains(where: { $0.path == app.path }) {
            lastScannedApps.append(app)
        }
        if !settings.hiddenAppPaths.contains(app.path) {
            settings.hiddenAppPaths.append(app.path)
        }
        settings.recentAppPaths.removeAll { $0 == app.path }
        saveSettings()
        removeAppFromLayout(path: app.path)
        refreshHiddenAppsList()
    }

    func unhideApp(path: String) {
        settings.hiddenAppPaths.removeAll { $0 == path }
        saveSettings()
        let source = lastScannedApps.isEmpty ? AppScanner.scanInstalledApps() : lastScannedApps
        mergeScannedApps(source)
    }

    func unhideAllApps() {
        settings.hiddenAppPaths.removeAll()
        saveSettings()
        let source = lastScannedApps.isEmpty ? AppScanner.scanInstalledApps() : lastScannedApps
        mergeScannedApps(source)
    }

    func refreshHiddenAppsList(from scannedApps: [AppItem]? = nil) {
        let hiddenPaths = settings.hiddenAppPaths
        guard !hiddenPaths.isEmpty else {
            hiddenApps = []
            return
        }
        let catalog = scannedApps ?? lastScannedApps
        let byPath = Dictionary(catalog.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        hiddenApps = hiddenPaths.compactMap { path -> AppItem? in
            if let existing = byPath[path] {
                return existing
            }
            let rawName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            guard !rawName.isEmpty else { return nil }
            return AppItem(
                name: rawName,
                bundleIdentifier: "",
                path: path,
                category: .other,
                isSystemApp: path.hasPrefix("/System/")
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    struct DeleteErrorInfo: Equatable {
        let app: AppItem
        let message: String
        let isPermissionError: Bool
        let isAutomationError: Bool
    }

    private enum TrashAttemptResult {
        case success
        case cancelled
        case failure(message: String, isPermissionError: Bool, isAutomationError: Bool)
    }

    func executePendingDelete() {
        guard let app = appPendingDelete, !isDeletingApp else { return }
        appPendingDelete = nil
        deleteErrorInfo = nil
        isDeletingApp = true
        onDeleteFlowStarted?()

        let appPath = app.path
        let appName = app.name

        Task.detached(priority: .userInitiated) {
            let result = Self.moveItemToTrash(path: appPath, appName: appName)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isDeletingApp = false
                switch result {
                case .success:
                    self.settings.recentAppPaths.removeAll { $0 == appPath }
                    self.saveSettings()
                    self.removeAppFromLayout(path: appPath)
                    IconCache.shared.invalidate(path: appPath)
                case .cancelled:
                    break
                case .failure(let message, let isPerm, let isAuto):
                    self.deleteErrorInfo = DeleteErrorInfo(
                        app: app,
                        message: message,
                        isPermissionError: isPerm,
                        isAutomationError: isAuto
                    )
                }
                self.onDeleteFlowFinished?()
            }
        }
    }

    func openPrivacySettingsForDelete(isAutomationError: Bool) {
        let anchor = isAutomationError ? "Privacy_Automation" : "Privacy_AppBundles"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
        deleteErrorInfo = nil
        onRequestHide?(false)
    }

    nonisolated private static func moveItemToTrash(path: String, appName: String) -> TrashAttemptResult {
        let finderResult = moveToTrashViaFinder(path: path)
        switch finderResult {
        case .success:
            return .success
        case .cancelled:
            return .cancelled
        case .failure(let finderMsg, let finderPerm, let finderAuto):
            // Fallback to NSWorkspace.recycle (may work for user-writable bundles if App Management is allowed)
            let wsResult = moveToTrashViaWorkspace(url: URL(fileURLWithPath: path))
            switch wsResult {
            case .success:
                return .success
            case .cancelled:
                return .cancelled
            case .failure(let wsMsg, let wsPerm, _):
                let combinedPerm = finderPerm || wsPerm
                let message: String
                if combinedPerm {
                    message = "macOS blocked deleting “\(appName)” because Ber Launchpad lacks Finder Automation or App Management permission (or administrator auth was denied). You can grant permission in System Settings, or hide this app from Launchpad instead."
                } else {
                    let detail = finderMsg.isEmpty ? wsMsg : finderMsg
                    message = "Could not move “\(appName)” to the Trash: \(detail)"
                }
                return .failure(message: message, isPermissionError: combinedPerm, isAutomationError: finderAuto)
            }
        }
    }

    nonisolated private static func moveToTrashViaFinder(path: String) -> TrashAttemptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "on run argv\nset targetItem to POSIX file (item 1 of argv)\ntell application \"Finder\" to delete targetItem\nend run",
            path
        ]
        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(message: error.localizedDescription, isPermissionError: false, isAutomationError: false)
        }

        if process.terminationStatus == 0 {
            return .success
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = errText.lowercased()

        if errText.contains("-128") || lower.contains("user canceled") {
            return .cancelled
        }

        let isAutoDenied = errText.contains("-1743") || lower.contains("not authorized")
        let isPerm = isAutoDenied || errText.contains("-5000") || lower.contains("permission") || lower.contains("privilege")
        return .failure(message: errText, isPermissionError: isPerm, isAutomationError: isAutoDenied)
    }

    nonisolated private static func moveToTrashViaWorkspace(url: URL) -> TrashAttemptResult {
        let semaphore = DispatchSemaphore(value: 0)
        var capturedError: NSError?

        NSWorkspace.shared.recycle([url]) { _, error in
            capturedError = error as NSError?
            semaphore.signal()
        }
        semaphore.wait()

        guard let error = capturedError else {
            return .success
        }

        let isPerm = (error.domain == NSCocoaErrorDomain && (
            error.code == NSFileWriteNoPermissionError ||
            error.code == NSFileReadNoPermissionError
        )) || (error.domain == NSPOSIXErrorDomain && (
            error.code == EACCES || error.code == EPERM
        )) || error.localizedDescription.lowercased().contains("permission")

        return .failure(message: error.localizedDescription, isPermissionError: isPerm, isAutomationError: false)
    }

    func removeAppFromLayout(path: String) {
        var workingPages: [[GridEntry]] = []
        for page in pages {
            var newPage: [GridEntry] = []
            for entry in page {
                switch entry {
                case .app(let app):
                    if app.path != path {
                        newPage.append(.app(app))
                    }
                case .folder(var folder):
                    folder.apps.removeAll { $0.path == path }
                    if folder.apps.count == 1 {
                        newPage.append(.app(folder.apps[0]))
                        if openedFolderID == folder.id {
                            openedFolderID = nil
                        }
                    } else if folder.apps.isEmpty {
                        if openedFolderID == folder.id {
                            openedFolderID = nil
                        }
                    } else {
                        newPage.append(.folder(folder))
                    }
                }
            }
            if !newPage.isEmpty {
                workingPages.append(newPage)
            }
        }
        pages = normalizePages(workingPages)
        clampCurrentPage()
        saveLayout()
        refreshRecentApps()
    }

    // MARK: - Keyboard Navigation

    func moveSelection(dx: Int, dy: Int) {
        if !searchText.isEmpty {
            let count = filteredApps.count
            guard count > 0 else { return }
            let cols = settings.columns
            let current = selectedIndex ?? 0
            var next = current + dx + dy * cols
            next = min(max(0, next), count - 1)
            selectedIndex = next
            return
        }

        if let folder = openedFolder {
            let count = folder.apps.count
            guard count > 0 else { return }
            let cols = min(5, max(3, count))
            let current = selectedIndex ?? 0
            let next = min(max(0, current + dx + dy * cols), count - 1)
            selectedIndex = next
            return
        }

        guard currentPage < pages.count else { return }
        let pageItems = pages[currentPage]
        guard !pageItems.isEmpty else { return }

        guard let current = selectedIndex else {
            selectedIndex = 0
            return
        }

        let cols = settings.columns
        let col = current % cols
        let row = current / cols

        if dx < 0 && col == 0 {
            if currentPage > 0 {
                currentPage -= 1
                let newCount = pages[currentPage].count
                let targetIdx = min(row * cols + (cols - 1), max(0, newCount - 1))
                selectedIndex = targetIdx
            }
            return
        }
        if dx > 0 && (col == cols - 1 || current == pageItems.count - 1) {
            if currentPage < pages.count - 1 {
                currentPage += 1
                let newCount = pages[currentPage].count
                let targetIdx = min(row * cols, max(0, newCount - 1))
                selectedIndex = targetIdx
            }
            return
        }

        let candidate = current + dx + dy * cols
        if candidate >= 0 && candidate < pageItems.count {
            selectedIndex = candidate
        }
    }

    func activateSelected() {
        if !searchText.isEmpty {
            let matches = filteredApps
            guard !matches.isEmpty else { return }
            let idx = min(max(0, selectedIndex ?? 0), matches.count - 1)
            launchApp(matches[idx])
            return
        }

        if let folder = openedFolder {
            guard !folder.apps.isEmpty else { return }
            let idx = min(max(0, selectedIndex ?? 0), folder.apps.count - 1)
            launchApp(folder.apps[idx])
            return
        }

        guard currentPage < pages.count else { return }
        let items = pages[currentPage]
        guard let idx = selectedIndex, idx >= 0 && idx < items.count else { return }

        switch items[idx] {
        case .app(let app):
            launchApp(app)
        case .folder(let folder):
            openedFolderID = folder.id
            selectedIndex = 0
        }
    }

    // MARK: - Settings Updates & LaunchAgent

    func updateGridSize(columns: Int, rows: Int) {
        let clampedCols = min(max(columns, 5), 10)
        let clampedRows = min(max(rows, 4), 8)
        guard settings.columns != clampedCols || settings.rows != clampedRows else { return }
        settings.columns = clampedCols
        settings.rows = clampedRows
        saveSettings()
        reflowPagesForUpdatedGridSize()
        refreshRecentApps()
    }

    func setShowRecentApps(_ enabled: Bool) {
        settings.showRecentApps = enabled
        saveSettings()
        if enabled {
            refreshRecentApps()
        }
    }

    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        settings.hotkeyKeyCode = keyCode
        settings.hotkeyModifiers = modifiers
        saveSettings()
        onHotkeyChanged?(keyCode, modifiers)
    }

    func setDisableDefaultAppsOnShortcut(_ enabled: Bool) {
        settings.disableDefaultAppsOnShortcut = enabled
        saveSettings()
        onHotKeySettingsChanged?()
    }

    func setReplaceF4LaunchpadKey(_ enabled: Bool) {
        settings.replaceF4LaunchpadKey = enabled
        saveSettings()
        onHotKeySettingsChanged?()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        settings.launchAtLogin = enabled
        saveSettings()

        let fm = FileManager.default
        if enabled {
            let launchAgentsDir = launchAgentURL.deletingLastPathComponent()
            try? fm.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

            let execPath = Bundle.main.executablePath ?? "/Applications/Ber Launchpad.app/Contents/MacOS/BerLaunchpad"
            let plist: [String: Any] = [
                "Label": "com.ber.launchpad",
                "ProgramArguments": [execPath, "--background"],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: launchAgentURL, options: .atomic)
            }
        } else {
            try? fm.removeItem(at: launchAgentURL)
        }
    }

    // MARK: - Directory File Monitoring

    private func startDirectoryMonitoring() {
        stopDirectoryMonitoring()
        for dirURL in AppScanner.watchedDirectories {
            guard FileManager.default.fileExists(atPath: dirURL.path) else { continue }
            let fd = open(dirURL.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            directoryFileDescriptors.append(fd)

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend],
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.scheduleDebouncedRescan()
                }
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            directorySources.append(source)
        }
    }

    private func stopDirectoryMonitoring() {
        for source in directorySources {
            source.cancel()
        }
        directorySources.removeAll()
        directoryFileDescriptors.removeAll()
    }

    private func scheduleDebouncedRescan() {
        rescanWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.syncInstalledApps(initialIfNeeded: false)
            }
        }
        rescanWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }
}
