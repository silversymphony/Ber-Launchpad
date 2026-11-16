import CoreGraphics
import Foundation

@MainActor
enum ScenarioTester {
    private static var failures: [String] = []
    private static var passedCount = 0

    static func runAll() -> Int32 {
        failures.removeAll()
        passedCount = 0

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BerLaunchpadTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        print("=== Ber Launchpad Multi-Scenario Verification Suite ===")

        runTest("Test 1: Merge 2 apps into folder on full 50-item page & extract back to same page beside partner") {
            let dir = tempRoot.appendingPathComponent("t1", isDirectory: true)
            let store = makeStore(dir: dir, rows: 5, columns: 10, iconSize: 110)
            let apps = makeApps(count: 55)
            store.pages = [Array(apps.prefix(50)).map { .app($0) }, Array(apps.dropFirst(50)).map { .app($0) }]
            store.currentPage = 0

            let targetApp = apps[12]
            let draggedApp = apps[32]
            store.mergeEntries(draggedID: GridEntry.app(draggedApp).id, ontoTargetID: GridEntry.app(targetApp).id)

            try assertEqual(store.pages[0].count, 49, "Page 0 should shrink from 50 to 49 entries after merge")
            try assertEqual(totalAppCount(in: store.pages), 55, "Total app count should remain 55 after merge")
            guard case .folder(let createdFolder) = store.pages[0][12] else {
                throw failureError("Expected folder at Page 0 index 12")
            }
            try assertEqual(createdFolder.apps.map(\.path), [targetApp.path, draggedApp.path], "Folder should contain target and dragged apps")

            // Simulate opening the folder and dragging draggedApp out onto the backdrop (atIndex: nil)
            store.openedFolderID = createdFolder.id
            store.extractAppFromFolder(folderID: createdFolder.id, appPath: draggedApp.path, toPage: store.currentPage, atIndex: nil)

            try assertTrue(store.openedFolderID == nil, "Folder overlay should close after 2-app folder dissolves")
            try assertEqual(store.pages[0].count, 50, "Page 0 should return to 50 entries")
            try assertEqual(totalAppCount(in: store.pages), 55, "Zero apps should be lost after extraction")
            try assertEqual(store.currentPage, 0, "Should stay on currentPage 0")
            try assertEqual(store.pages[0][12].asApp?.path, targetApp.path, "Dissolved partner app stays at index 12")
            try assertEqual(store.pages[0][13].asApp?.path, draggedApp.path, "Extracted app should appear immediately beside partner at index 13, not hidden at end of page")
        }

        runTest("Test 2: Extract from 3-app folder on full 50-item page keeps extracted app beside folder & ripples 51st item") {
            let dir = tempRoot.appendingPathComponent("t2", isDirectory: true)
            let store = makeStore(dir: dir, rows: 5, columns: 10, iconSize: 110)
            let apps = makeApps(count: 60)
            let folderApps = [apps[5], apps[6], apps[7]]
            let folder = FolderItem(name: "TestCategory", apps: folderApps)

            // Build full 50-item Page 0 containing the folder at index 10 + 49 other apps
            var page0: [GridEntry] = []
            for i in 0..<49 {
                if i == 10 {
                    page0.append(.folder(folder))
                }
                page0.append(.app(apps[10 + i]))
            }
            let trailingPage0App = apps[58] // apps[10 + 48] = apps[58]
            let page1App = apps[59]
            store.pages = [page0, [.app(page1App)]]
            store.currentPage = 0
            try assertEqual(store.pages[0].count, 50, "Setup Page 0 has 50 items")

            store.extractAppFromFolder(folderID: folder.id, appPath: apps[7].path, toPage: store.currentPage, atIndex: nil)

            try assertEqual(store.pages[0].count, 50, "Page 0 stays at itemsPerPage (50)")
            guard case .folder(let updatedFolder) = store.pages[0][10] else {
                throw failureError("Folder should remain at index 10 with 2 apps")
            }
            try assertEqual(updatedFolder.apps.count, 2, "Folder should have 2 apps left")
            try assertEqual(store.pages[0][11].asApp?.path, apps[7].path, "Extracted app should be right next to folder at index 11")
            try assertEqual(store.pages[1].first?.asApp?.path, trailingPage0App.path, "Only 51st trailing app from Page 0 should ripple to Page 1 index 0")
            try assertEqual(store.pages[1][1].asApp?.path, page1App.path, "Existing Page 1 item should shift to index 1")
            try assertTrue(allUniqueAppPaths(in: store.pages).count == totalAppCount(in: store.pages), "No duplicate apps")
        }

        runTest("Test 3: Extract app from folder to explicit main-grid target index") {
            let dir = tempRoot.appendingPathComponent("t3", isDirectory: true)
            let store = makeStore(dir: dir, rows: 5, columns: 7)
            let apps = makeApps(count: 15)
            let folder = FolderItem(name: "Group", apps: [apps[0], apps[1], apps[2]])
            store.pages = [[.folder(folder)] + apps[3..<15].map { .app($0) }]
            store.currentPage = 0

            store.extractAppFromFolder(folderID: folder.id, appPath: apps[2].path, toPage: 0, atIndex: 5)
            try assertEqual(store.pages[0][5].asApp?.path, apps[2].path, "Extracted app should land at explicit index 5")
            try assertEqual(totalAppCount(in: store.pages), 15, "All 15 apps preserved")
        }

        runTest("Test 4: Reorder inside folder & auto-dissolve 1-app folder on app deletion") {
            let dir = tempRoot.appendingPathComponent("t4", isDirectory: true)
            let store = makeStore(dir: dir, rows: 5, columns: 7)
            let apps = makeApps(count: 4)
            let folder = FolderItem(name: "Tools", apps: [apps[0], apps[1]])
            store.pages = [[.folder(folder), .app(apps[2]), .app(apps[3])]]
            store.openedFolderID = folder.id

            store.moveAppInsideFolder(folderID: folder.id, appPath: apps[1].path, toIndex: 0)
            try assertEqual(store.pages[0][0].asFolder?.apps.map(\.path), [apps[1].path, apps[0].path], "Inside folder order updated")

            store.removeAppFromLayout(path: apps[0].path)
            try assertTrue(store.openedFolderID == nil, "Opened folder closes when reduced to 1 app")
            try assertEqual(store.pages[0][0].asApp?.path, apps[1].path, "1-app folder auto-dissolves into remaining app")
            try assertEqual(totalAppCount(in: store.pages), 3, "3 remaining apps")
        }

        runTest("Test 5: Same-page reorder, cross-page move, and trailing new page creation") {
            let dir = tempRoot.appendingPathComponent("t5", isDirectory: true)
            let store = makeStore(dir: dir, rows: 4, columns: 5) // 20 per page
            let apps = makeApps(count: 25)
            store.pages = [Array(apps.prefix(20)).map { .app($0) }, Array(apps.dropFirst(20)).map { .app($0) }]

            // Same-page forward move: index 2 -> index 6 (right side)
            store.moveEntry(entryID: GridEntry.app(apps[2]).id, toPage: 0, atIndex: 6)
            try assertEqual(store.pages[0][5].asApp?.path, apps[2].path, "Forward move adjusts index correctly")

            // Same-page backward move: index 10 -> index 1
            store.moveEntry(entryID: GridEntry.app(apps[10]).id, toPage: 0, atIndex: 1)
            try assertEqual(store.pages[0][1].asApp?.path, apps[10].path, "Backward move places item at target index")

            // Cross-page move into full Page 0 from Page 1 -> triggers overflow ripple back to Page 1
            store.moveEntry(entryID: GridEntry.app(apps[24]).id, toPage: 0, atIndex: 0)
            try assertEqual(store.pages[0][0].asApp?.path, apps[24].path, "Cross-page move places item at Page 0 index 0")
            try assertEqual(store.pages[0].count, 20, "Page 0 respects 20-item limit")
            try assertEqual(totalAppCount(in: store.pages), 25, "All 25 apps preserved")

            // Move to new trailing page
            store.moveEntry(entryID: GridEntry.app(apps[24]).id, toPage: store.pages.count, atIndex: 0)
            try assertEqual(store.pages.count, 3, "Trailing page created")
            try assertEqual(store.pages[2][0].asApp?.path, apps[24].path, "Moved app sits on new Page 2")
            try assertEqual(totalAppCount(in: store.pages), 25, "All 25 apps preserved")
        }

        runTest("Test 6: Folder rename & JSON layout/settings persistence round-trip") {
            let dir = tempRoot.appendingPathComponent("t6", isDirectory: true)
            let store1 = makeStore(dir: dir, rows: 5, columns: 10, iconSize: 110)
            let apps = makeApps(count: 6)
            let folder = FolderItem(name: "Orig", apps: [apps[0], apps[1]])
            store1.pages = [[.folder(folder), .app(apps[2]), .app(apps[3])]]
            store1.renameFolder(folderID: folder.id, newName: "  Creative Suite  ")
            store1.saveSettings()

            let store2 = LaunchpadStore(supportDirectory: dir)
            store2.loadSettings()
            let loaded = store2.loadLayout()
            try assertTrue(loaded, "Persisted layout.json should load cleanly")
            try assertEqual(store2.settings.iconSize, 110, "Persisted iconSize should round-trip")
            try assertEqual(store2.pages[0][0].asFolder?.name, "Creative Suite", "Renamed folder name persisted cleanly")

            store2.renameFolder(folderID: folder.id, newName: "   ")
            try assertEqual(store2.pages[0][0].asFolder?.name, "Untitled", "Blank folder name falls back to Untitled")
        }

        runTest("Test 7: Search finds apps inside folders and on top-level pages (case/diacritic insensitive)") {
            let dir = tempRoot.appendingPathComponent("t7", isDirectory: true)
            let store = makeStore(dir: dir)
            let nested = AppItem(name: "MINI_KEYBOARD", bundleIdentifier: "com.test.mk", path: "/Apps/MINI_KEYBOARD.app", category: .other, isSystemApp: false)
            let top = AppItem(name: "Café Notes", bundleIdentifier: "com.test.cn", path: "/Apps/CafeNotes.app", category: .productivity, isSystemApp: false)
            store.pages = [[.folder(FolderItem(name: "Other", apps: [nested])), .app(top)]]

            store.searchText = "mini_key"
            try assertEqual(store.filteredApps.map(\.path), [nested.path], "Search finds app nested inside folder")

            store.searchText = "cafe"
            try assertEqual(store.filteredApps.map(\.path), [top.path], "Search matches diacritic-folded text")
        }

        runTest("Test 8: Recent apps ordering, deduplication, and cap at 16") {
            let dir = tempRoot.appendingPathComponent("t8", isDirectory: true)
            let store = makeStore(dir: dir)
            let apps = makeApps(count: 20)
            store.pages = [apps.map { .app($0) }]
            for app in apps {
                store.recordRecentApp(app)
            }
            try assertEqual(store.settings.recentAppPaths.count, 16, "Recent paths capped at 16")
            try assertEqual(store.settings.recentAppPaths.first, apps[19].path, "Most recently launched app is first")

            store.recordRecentApp(apps[10])
            try assertEqual(store.settings.recentAppPaths.first, apps[10].path, "Re-launching app promotes it to first")
            try assertEqual(store.settings.recentAppPaths.filter { $0 == apps[10].path }.count, 1, "No duplicates in recent list")
        }

        runTest("Test 9: Responsive layout geometry ensures bottom-row text never clips at iconSize=110 across screen sizes") {
            let screens: [CGSize] = [
                CGSize(width: 1280, height: 800),
                CGSize(width: 1440, height: 900),
                CGSize(width: 1512, height: 982),
                CGSize(width: 1680, height: 1050),
                CGSize(width: 1728, height: 1117),
                CGSize(width: 1920, height: 1080),
                CGSize(width: 2560, height: 1440),
                CGSize(width: 3024, height: 1890)
            ]

            for screen in screens {
                for hasRecent in [true, false] {
                    for iconSize in [78.0, 96.0, 110.0] {
                        for grid in [(10, 5), (7, 5), (8, 6), (10, 8)] {
                            var s = AppSettings.default
                            s.columns = grid.0
                            s.rows = grid.1
                            s.iconSize = iconSize
                            s.showRecentApps = hasRecent

                            let m = LaunchpadLayoutMetrics.compute(
                                screenSize: screen,
                                settings: s,
                                hasRecentApps: hasRecent
                            )
                            try assertTrue(
                                m.fitsWithoutClipping,
                                "Overflow/clipping detected for screen=\(Int(screen.width))x\(Int(screen.height)), grid=\(grid.0)x\(grid.1), requestedIcon=\(iconSize), hasRecent=\(hasRecent), effectiveIcon=\(m.effectiveIconSize), contentH=\(m.totalGridContentHeight), availH=\(m.availableGridHeight), tileW=\(m.tileWidth)"
                            )
                            try assertTrue(
                                m.effectiveIconSize <= iconSize && m.effectiveIconSize >= 24,
                                "Invalid effectiveIconSize \(m.effectiveIconSize)"
                            )
                        }
                    }
                }
            }

            // Explicitly verify full 110pt icons render without clipping on user's displays (1728x1117 & 1920x1080)
            var fullSizeSettings = AppSettings.default
            fullSizeSettings.columns = 10
            fullSizeSettings.rows = 5
            fullSizeSettings.iconSize = 110
            fullSizeSettings.showRecentApps = true
            for userScreen in [CGSize(width: 1728, height: 1117), CGSize(width: 1920, height: 1080)] {
                let m = LaunchpadLayoutMetrics.compute(screenSize: userScreen, settings: fullSizeSettings, hasRecentApps: true)
                try assertEqual(m.effectiveIconSize, 110.0, "User screen \(Int(userScreen.width))x\(Int(userScreen.height)) should preserve full 110pt icons")
                try assertTrue(m.fitsWithoutClipping, "User screen \(Int(userScreen.width))x\(Int(userScreen.height)) should fit all rows + labels without clipping")
            }
        }

        runTest("Test 10: Real user layout.json integrity check (no corrupted or duplicate entries)") {
            let userLayoutURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("BerLaunchpad/layout.json")
            if FileManager.default.fileExists(atPath: userLayoutURL.path) {
                let data = try Data(contentsOf: userLayoutURL)
                let decoded = try JSONDecoder().decode([[GridEntry]].self, from: data)
                let allPaths = allAppPaths(in: decoded)
                let unique = Set(allPaths)
                try assertEqual(allPaths.count, unique.count, "User layout.json should not contain duplicate app paths")
            }
        }

        runTest("Test 11: AppScanner detects symlinked app bundles without .app extension (Adobe Creative Cloud)") {
            let fm = FileManager.default
            let rootDir = tempRoot.appendingPathComponent("t11_apps", isDirectory: true)
            let realTargetBundle = tempRoot.appendingPathComponent("t11_targets/Creative Cloud.app", isDirectory: true)
            let plistDir = realTargetBundle.appendingPathComponent("Contents", isDirectory: true)
            try fm.createDirectory(at: plistDir, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "CFBundleIdentifier": "com.adobe.acc.AdobeCreativeCloud",
                "CFBundleName": "Creative Cloud"
            ]
            let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try plistData.write(to: plistDir.appendingPathComponent("Info.plist"))

            let subfolder = rootDir.appendingPathComponent("Adobe Creative Cloud", isDirectory: true)
            try fm.createDirectory(at: subfolder, withIntermediateDirectories: true)
            let symlinkPath = subfolder.appendingPathComponent("Adobe Creative Cloud")
            try fm.createSymbolicLink(at: symlinkPath, withDestinationURL: realTargetBundle)

            let scannedSynthetic = AppScanner.scanInstalledApps(in: [(rootDir, 2)])
            try assertEqual(scannedSynthetic.count, 1, "Should detect synthetic symlinked app without .app extension")
            try assertEqual(scannedSynthetic[0].name, "Adobe Creative Cloud", "Synthetic symlink app should keep symlink display name")
            try assertEqual(scannedSynthetic[0].bundleIdentifier, "com.adobe.acc.AdobeCreativeCloud", "Should read bundle ID from symlink target Info.plist")
            try assertEqual(scannedSynthetic[0].category, .graphicsAndMedia, "Should classify Creative Cloud under Graphics & Media")

            let realCCPath = "/Applications/Adobe Creative Cloud/Adobe Creative Cloud"
            if fm.fileExists(atPath: realCCPath) {
                let systemScanned = AppScanner.scanInstalledApps()
                try assertTrue(
                    systemScanned.contains(where: { $0.path == realCCPath || $0.name == "Adobe Creative Cloud" }),
                    "System scan should include Adobe Creative Cloud from /Applications"
                )
                let depth3ExpectedPaths = [
                    "/Applications/Autodesk/AutoCAD 2024/AutoCAD 2024.app",
                    "/Applications/BorisFX/Continuum 2024 Adobe/Particle Illusion.app",
                    "/Applications/BorisFX/Continuum 2024 Adobe/Title Studio.app",
                    "/Applications/Imagenomic/Portraiture 4 Plug-in for Lightroom/Portraiture4.app"
                ]
                for expectedPath in depth3ExpectedPaths where fm.fileExists(atPath: expectedPath) {
                    try assertTrue(
                        systemScanned.contains(where: { $0.path == expectedPath }),
                        "System depth-3 scan should include \(expectedPath)"
                    )
                }
            }
        }

        print("=== Summary: \(passedCount) passed, \(failures.count) failed ===")
        if !failures.isEmpty {
            for msg in failures {
                fputs("FAIL: \(msg)\n", stderr)
            }
            return 1
        }
        return 0
    }

    // MARK: - Helpers

    private static func runTest(_ name: String, body: () throws -> Void) {
        do {
            try body()
            passedCount += 1
            print("[PASS] \(name)")
        } catch {
            failures.append("\(name): \(error.localizedDescription)")
            print("[FAIL] \(name) -> \(error.localizedDescription)")
        }
    }

    private static func makeStore(dir: URL, rows: Int = 5, columns: Int = 7, iconSize: Double = 78) -> LaunchpadStore {
        let store = LaunchpadStore(supportDirectory: dir)
        var s = AppSettings.default
        s.rows = rows
        s.columns = columns
        s.iconSize = iconSize
        s.showRecentApps = true
        store.settings = s
        return store
    }

    private static func makeApps(count: Int) -> [AppItem] {
        (0..<count).map { idx in
            AppItem(
                name: String(format: "App %03d", idx),
                bundleIdentifier: "com.ber.testapp.\(idx)",
                path: "/Applications/TestApp\(idx).app",
                category: AppCategory.allCases[idx % AppCategory.allCases.count],
                isSystemApp: false
            )
        }
    }

    private static func allAppPaths(in pages: [[GridEntry]]) -> [String] {
        var result: [String] = []
        for page in pages {
            for entry in page {
                switch entry {
                case .app(let app):
                    result.append(app.path)
                case .folder(let folder):
                    result.append(contentsOf: folder.apps.map(\.path))
                }
            }
        }
        return result
    }

    private static func allUniqueAppPaths(in pages: [[GridEntry]]) -> Set<String> {
        Set(allAppPaths(in: pages))
    }

    private static func totalAppCount(in pages: [[GridEntry]]) -> Int {
        allAppPaths(in: pages).count
    }

    private static func failureError(_ message: String) -> NSError {
        NSError(domain: "BerLaunchpadScenarioTester", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func assertTrue(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw failureError(message)
        }
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
        if actual != expected {
            throw failureError("\(message) (expected: \(expected), actual: \(actual))")
        }
    }
}
