import Foundation

enum AppScanner {
    static let excludedBundleIdentifiers: Set<String> = [
        "com.ber.launchpad",
        "com.apple.launchpad.launcher"
    ]

    static var watchedDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
            home.appendingPathComponent("Applications/Chrome Apps.localized")
        ]
    }

    static func scanInstalledApps(in customRoots: [(url: URL, maxDepth: Int)]? = nil) -> [AppItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let searchRoots: [(url: URL, maxDepth: Int)] = customRoots ?? [
            (URL(fileURLWithPath: "/System/Applications"), 2),
            (URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"), 1),
            (URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications"), 1),
            (URL(fileURLWithPath: "/Applications"), 3),
            (home.appendingPathComponent("Applications"), 3)
        ]

        var seenResolvedPaths = Set<String>()
        var seenBundleIDsAndNames = Set<String>()
        var items: [AppItem] = []

        for root in searchRoots {
            guard fm.fileExists(atPath: root.url.path) else { continue }
            let appURLs = collectAppBundles(in: root.url, depth: 0, maxDepth: root.maxDepth, fileManager: fm)
            for appURL in appURLs {
                let resolved = appURL.resolvingSymlinksInPath().path
                guard !seenResolvedPaths.contains(resolved) else { continue }

                guard let item = parseAppBundle(at: appURL, resolvedPath: resolved, fileManager: fm) else {
                    continue
                }

                // Avoid duplicates between /Applications symlink and Cryptexes path
                let dedupKey = item.bundleIdentifier.isEmpty
                    ? item.name.lowercased()
                    : "\(item.bundleIdentifier.lowercased())::\(item.name.lowercased())"
                if seenBundleIDsAndNames.contains(dedupKey) && resolved.contains("Cryptexes") {
                    continue
                }

                seenResolvedPaths.insert(resolved)
                seenBundleIDsAndNames.insert(dedupKey)
                items.append(item)
            }
        }

        return items.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func collectAppBundles(
        in directory: URL,
        depth: Int,
        maxDepth: Int,
        fileManager: FileManager
    ) -> [URL] {
        guard depth < maxDepth else { return [] }
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for url in children {
            if url.pathExtension.lowercased() == "app" {
                results.append(url)
                continue
            }

            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if resourceValues?.isSymbolicLink == true {
                let resolvedURL = url.resolvingSymlinksInPath()
                if resolvedURL.pathExtension.lowercased() == "app",
                   fileManager.fileExists(atPath: resolvedURL.path) {
                    results.append(url)
                    continue
                }
            }

            // Descend into non-.app subdirectories (e.g., Utilities, Chrome Apps.localized, Adobe folders)
            let skippedBundleExtensions: Set<String> = [
                "framework", "bundle", "plugin", "kext", "qlgenerator",
                "mdimporter", "prefpane", "xpc", "appex"
            ]
            let skippedUtilitySubpaths: Set<String> = [
                "/Applications/Utilities/Adobe Genuine Service",
                "/Applications/Utilities/Adobe Installers"
            ]
            if resourceValues?.isDirectory == true,
               !skippedBundleExtensions.contains(url.pathExtension.lowercased()),
               !skippedUtilitySubpaths.contains(url.path) {
                results.append(
                    contentsOf: collectAppBundles(
                        in: url,
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        fileManager: fileManager
                    )
                )
            }
        }
        return results
    }

    private static func parseAppBundle(
        at url: URL,
        resolvedPath: String,
        fileManager: FileManager
    ) -> AppItem? {
        let bundleURL = url.pathExtension.lowercased() == "app" ? url : URL(fileURLWithPath: resolvedPath)
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let plist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] ?? [:]

        // Skip background-only helper apps
        if let bgOnly = plist["LSBackgroundOnly"] as? Bool, bgOnly {
            return nil
        }
        if let bgOnlyStr = plist["LSBackgroundOnly"] as? String,
           bgOnlyStr == "1" || bgOnlyStr.lowercased() == "true" {
            return nil
        }

        let bundleID = (plist["CFBundleIdentifier"] as? String) ?? ""
        if excludedBundleIdentifiers.contains(bundleID) {
            return nil
        }

        let filenameFallback = url.deletingPathExtension().lastPathComponent
        if filenameFallback == "Ber Launchpad" {
            return nil
        }

        let localizedDisplay = fileManager.displayName(atPath: url.path)
        let strippedLocalized = localizedDisplay.hasSuffix(".app")
            ? String(localizedDisplay.dropLast(4))
            : localizedDisplay

        let displayName: String
        if !strippedLocalized.isEmpty {
            displayName = strippedLocalized
        } else if let cfDisplay = plist["CFBundleDisplayName"] as? String, !cfDisplay.isEmpty {
            displayName = cfDisplay
        } else if let cfName = plist["CFBundleName"] as? String, !cfName.isEmpty {
            displayName = cfName
        } else {
            displayName = filenameFallback
        }

        let categoryType = plist["LSApplicationCategoryType"] as? String
        let pathToStore = url.path
        let isSystem = pathToStore.hasPrefix("/System/") ||
            resolvedPath.hasPrefix("/System/") ||
            bundleID == "com.apple.Safari"

        let category = AppCategory.classify(
            categoryType: categoryType,
            bundleIdentifier: bundleID,
            name: displayName,
            path: pathToStore
        )

        return AppItem(
            name: displayName,
            bundleIdentifier: bundleID,
            path: pathToStore,
            category: category,
            isSystemApp: isSystem
        )
    }
}
