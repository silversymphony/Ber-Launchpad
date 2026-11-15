import Carbon
import Foundation

enum AppCategory: String, Codable, CaseIterable, Hashable {
    case utilitiesAndSystem
    case productivity
    case developer
    case graphicsAndMedia
    case internetAndSocial
    case games
    case other

    var displayName: String {
        switch self {
        case .utilitiesAndSystem: return "Utilities & System"
        case .productivity: return "Productivity & Office"
        case .developer: return "Developer Tools"
        case .graphicsAndMedia: return "Graphics & Media"
        case .internetAndSocial: return "Internet & Social"
        case .games: return "Games"
        case .other: return "Other"
        }
    }

    var sortOrder: Int {
        switch self {
        case .internetAndSocial: return 0
        case .productivity: return 1
        case .graphicsAndMedia: return 2
        case .developer: return 3
        case .utilitiesAndSystem: return 4
        case .games: return 5
        case .other: return 6
        }
    }

    static func classify(
        categoryType: String?,
        bundleIdentifier: String,
        name: String,
        path: String
    ) -> AppCategory {
        let lowerCat = (categoryType ?? "").lowercased()
        let lowerBundle = bundleIdentifier.lowercased()
        let lowerName = name.lowercased()
        let lowerPath = path.lowercased()

        // 1. Explicit Apple LSApplicationCategoryType
        if lowerCat.contains("developer-tools") { return .developer }
        if lowerCat.contains("games") { return .games }
        if lowerCat.contains("graphics-design") || lowerCat.contains("photography") ||
            lowerCat.contains("video") || lowerCat.contains("music") ||
            lowerCat.contains("entertainment") {
            return .graphicsAndMedia
        }
        if lowerCat.contains("social-networking") || lowerCat.contains("news") {
            return .internetAndSocial
        }
        if lowerCat.contains("productivity") || lowerCat.contains("business") ||
            lowerCat.contains("finance") || lowerCat.contains("education") ||
            lowerCat.contains("reference") || lowerCat.contains("medical") {
            return .productivity
        }
        if lowerCat.contains("utilities") { return .utilitiesAndSystem }

        // 2. Developer tools heuristics
        let devKeywords = [
            "xcode", "vscode", "visual studio", "cursor", "antigravity", "intellij",
            "pycharm", "webstorm", "clion", "goland", "android studio", "terminal",
            "iterm", "warp", "ghostty", "alacritty", "kitty", "docker", "orbstack",
            "postman", "insomnia", "proxyman", "charles", "wireshark", "git",
            "sourcetree", "tower", "fork", "arduino", "sublime", "nova", "zed",
            "tableplus", "dbeaver", "sequel", "simulators", "instruments", "simulator",
            "homebrew", "swift", "python", "copilot", "claude"
        ]
        if devKeywords.contains(where: { lowerName.contains($0) || lowerBundle.contains($0) }) {
            return .developer
        }

        // 3. Games heuristics
        let gameKeywords = [
            "game", "steam", "epic games", "battle.net", "riot", "league of legends",
            "minecraft", "roblox", "chess", "ryujinx", "dolphin", "openemu",
            "retroarch", "crossover", "whisky", "gog galaxy", "origin", "ea app"
        ]
        if gameKeywords.contains(where: { lowerName.contains($0) || lowerBundle.contains($0) }) {
            return .games
        }

        // 4. Graphics, Photo, Audio, Video & Media heuristics
        let mediaKeywords = [
            "photoshop", "illustrator", "premiere", "after effects", "lightroom",
            "figma", "sketch", "affinity", "canva", "blender", "cinema 4d",
            "davinci", "final cut", "motion", "compressor", "logic pro", "garageband",
            "capcut", "audacity", "audirvana", "spotify", "apple music", "music",
            "podcasts", "tv", "quicktime", "vlc", "iina", "infuse", "plex", "obs",
            "handbrake", "pixelmator", "procreate", "photos", "photo booth",
            "image capture", "preview", "screenflow", "cleanshot", "shottr",
            "4k video", "blackmagic", "autopano", "imovie", "keyshot"
        ]
        if mediaKeywords.contains(where: { lowerName.contains($0) || lowerBundle.contains($0) }) {
            return .graphicsAndMedia
        }

        // 5. Internet, Browsers & Social Communication
        let internetKeywords = [
            "safari", "chrome", "firefox", "arc", "brave", "edge", "opera", "vivaldi",
            "orion", "tor browser", "zen browser", "mail", "spark", "thunderbird",
            "outlook", "messages", "facetime", "zoom", "teams", "slack", "discord",
            "telegram", "whatsapp", "messenger", "zalo", "viber", "wechat", "line",
            "skype", "signal", "webex", "google meet", "chatgpt", "perplexity",
            "transmission", "qbittorrent", "cyberduck", "filezilla", "transmit"
        ]
        if lowerPath.contains("chrome apps") ||
            internetKeywords.contains(where: { lowerName.contains($0) || lowerBundle.contains($0) }) {
            return .internetAndSocial
        }

        // 6. Productivity & Office
        let productivityKeywords = [
            "notes", "reminders", "calendar", "contacts", "freeform", "journal",
            "pages", "numbers", "keynote", "word", "excel", "powerpoint", "onenote",
            "notion", "obsidian", "bear", "craft", "raycast", "alfred", "things",
            "todoist", "ticktick", "omnifocus", "linear", "jira", "trello", "asana",
            "stocks", "books", "dictionary", "translate", "calculator", "weather",
            "clock", "maps", "home", "shortcuts", "automator", "acrobat", "pdf",
            "goodnotes", "notability", "anki", "1password", "bitwarden", "keepass",
            "passwords", "dropbox", "google drive", "onedrive"
        ]
        if productivityKeywords.contains(where: { lowerName.contains($0) || lowerBundle.contains($0) }) {
            return .productivity
        }

        // 7. Utilities & System
        let utilitiesKeywords = [
            "utility", "utilities", "finder", "system settings", "system preferences",
            "system information", "activity monitor", "console", "disk utility",
            "keychain", "migration assistant", "terminal", "voiceover", "grapher",
            "colorSync", "colorsync", "audio midi", "airport", "bluetooth",
            "screen sharing", "screenshot", "time machine", "cleanmymac", "betterzip",
            "keka", "the unarchiver", "appcleaner", "bartender", "rectangle", "magnet",
            "karabiner", "bettertouchtool", "alt-tab", "alttab", "amphetamine",
            "istat", "coconutbattery", "onyx", "3utools", "driver", "uninstaller",
            "remote desktop", "tailscale", "wireguard", "tunnelblick", "cloudflare",
            "find my", "siri", "textedit", "font book", "stickies", "voice memos",
            "chess", "disk speed", "coolmuster"
        ]
        if lowerPath.contains("/system/applications/utilities") ||
            lowerPath.hasPrefix("/system/") ||
            utilitiesKeywords.contains(where: { lowerName.contains($0) || lowerBundle.contains($0) }) {
            return .utilitiesAndSystem
        }

        return .other
    }
}

struct AppItem: Identifiable, Codable, Equatable, Hashable {
    var id: String { path }
    let name: String
    let bundleIdentifier: String
    let path: String
    let category: AppCategory
    let isSystemApp: Bool
}

struct FolderItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var apps: [AppItem]

    init(id: UUID = UUID(), name: String, apps: [AppItem]) {
        self.id = id
        self.name = name
        self.apps = apps
    }
}

enum GridEntry: Identifiable, Codable, Equatable, Hashable {
    case app(AppItem)
    case folder(FolderItem)

    var id: String {
        switch self {
        case .app(let app):
            return "app:\(app.path)"
        case .folder(let folder):
            return "folder:\(folder.id.uuidString)"
        }
    }

    var displayName: String {
        switch self {
        case .app(let app): return app.name
        case .folder(let folder): return folder.name
        }
    }

    var asApp: AppItem? {
        if case .app(let app) = self { return app }
        return nil
    }

    var asFolder: FolderItem? {
        if case .folder(let folder) = self { return folder }
        return nil
    }
}

enum LayoutPreset: String, CaseIterable, Identifiable {
    case categoryFolders
    case appleStandard
    case alphabetical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .categoryFolders: return "Category Folders (Default)"
        case .appleStandard: return "macOS Sequoia Default"
        case .alphabetical: return "Alphabetical A–Z"
        }
    }

    var subtitle: String {
        switch self {
        case .categoryFolders: return "Group all apps into smart category folders"
        case .appleStandard: return "System apps first, Utilities in \"Other\", user apps after"
        case .alphabetical: return "Flat grid sorted alphabetically across pages"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var columns: Int
    var rows: Int
    var iconSize: Double
    var backgroundOpacity: Double
    var hotkeyKeyCode: UInt32
    var hotkeyModifiers: UInt32
    var launchAtLogin: Bool
    var disableDefaultAppsOnShortcut: Bool
    var replaceF4LaunchpadKey: Bool
    var showRecentApps: Bool
    var recentAppPaths: [String]

    static let `default` = AppSettings(
        columns: 7,
        rows: 5,
        iconSize: 78,
        backgroundOpacity: 0.42,
        hotkeyKeyCode: 49, // Space
        hotkeyModifiers: UInt32(optionKey),
        launchAtLogin: false,
        disableDefaultAppsOnShortcut: true,
        replaceF4LaunchpadKey: true,
        showRecentApps: true,
        recentAppPaths: []
    )

    var itemsPerPage: Int {
        max(1, columns * rows)
    }

    init(
        columns: Int,
        rows: Int,
        iconSize: Double,
        backgroundOpacity: Double,
        hotkeyKeyCode: UInt32,
        hotkeyModifiers: UInt32,
        launchAtLogin: Bool,
        disableDefaultAppsOnShortcut: Bool = true,
        replaceF4LaunchpadKey: Bool = true,
        showRecentApps: Bool = true,
        recentAppPaths: [String] = []
    ) {
        self.columns = min(max(columns, 5), 10)
        self.rows = min(max(rows, 4), 8)
        self.iconSize = min(max(iconSize, 56), 110)
        self.backgroundOpacity = min(max(backgroundOpacity, 0.15), 0.78)
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.launchAtLogin = launchAtLogin
        self.disableDefaultAppsOnShortcut = disableDefaultAppsOnShortcut
        self.replaceF4LaunchpadKey = replaceF4LaunchpadKey
        self.showRecentApps = showRecentApps
        self.recentAppPaths = recentAppPaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let def = AppSettings.default
        let columns = try container.decodeIfPresent(Int.self, forKey: .columns) ?? def.columns
        let rows = try container.decodeIfPresent(Int.self, forKey: .rows) ?? def.rows
        let iconSize = try container.decodeIfPresent(Double.self, forKey: .iconSize) ?? def.iconSize
        let backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? def.backgroundOpacity
        let hotkeyKeyCode = try container.decodeIfPresent(UInt32.self, forKey: .hotkeyKeyCode) ?? def.hotkeyKeyCode
        let hotkeyModifiers = try container.decodeIfPresent(UInt32.self, forKey: .hotkeyModifiers) ?? def.hotkeyModifiers
        let launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? def.launchAtLogin
        let disableDefaultAppsOnShortcut = try container.decodeIfPresent(Bool.self, forKey: .disableDefaultAppsOnShortcut) ?? def.disableDefaultAppsOnShortcut
        let replaceF4LaunchpadKey = try container.decodeIfPresent(Bool.self, forKey: .replaceF4LaunchpadKey) ?? def.replaceF4LaunchpadKey
        let showRecentApps = try container.decodeIfPresent(Bool.self, forKey: .showRecentApps) ?? def.showRecentApps
        let recentAppPaths = try container.decodeIfPresent([String].self, forKey: .recentAppPaths) ?? def.recentAppPaths
        self.init(
            columns: columns,
            rows: rows,
            iconSize: iconSize,
            backgroundOpacity: backgroundOpacity,
            hotkeyKeyCode: hotkeyKeyCode,
            hotkeyModifiers: hotkeyModifiers,
            launchAtLogin: launchAtLogin,
            disableDefaultAppsOnShortcut: disableDefaultAppsOnShortcut,
            replaceF4LaunchpadKey: replaceF4LaunchpadKey,
            showRecentApps: showRecentApps,
            recentAppPaths: recentAppPaths
        )
    }
}
