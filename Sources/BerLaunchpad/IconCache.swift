import AppKit
import Foundation

@MainActor
final class IconCache: ObservableObject {
    static let shared = IconCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlightPaths = Set<String>()
    @Published private(set) var loadedToken: Int = 0

    private init() {
        cache.countLimit = 600
    }

    func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        if !inFlightPaths.contains(path) {
            inFlightPaths.insert(path)
            Task.detached(priority: .userInitiated) {
                let rendered = Self.loadRenderedIcon(at: path)
                await MainActor.run {
                    self.cache.setObject(rendered, forKey: key)
                    self.inFlightPaths.remove(path)
                    self.loadedToken &+= 1
                }
            }
        }

        // Immediate lightweight placeholder from NSWorkspace while full bitmap caches
        let quickIcon = NSWorkspace.shared.icon(forFile: path)
        quickIcon.size = NSSize(width: 160, height: 160)
        return quickIcon
    }

    func preload(paths: [String]) {
        let missing = paths.filter { cache.object(forKey: $0 as NSString) == nil && !inFlightPaths.contains($0) }
        guard !missing.isEmpty else { return }
        for path in missing {
            inFlightPaths.insert(path)
        }
        Task.detached(priority: .utility) {
            for path in missing {
                let rendered = Self.loadRenderedIcon(at: path)
                await MainActor.run {
                    self.cache.setObject(rendered, forKey: path as NSString)
                    self.inFlightPaths.remove(path)
                }
            }
            await MainActor.run {
                self.loadedToken &+= 1
            }
        }
    }

    func invalidate(path: String) {
        cache.removeObject(forKey: path as NSString)
    }

    private nonisolated static func loadRenderedIcon(at path: String) -> NSImage {
        let targetSize = NSSize(width: 160, height: 160)
        let workspaceIcon = NSWorkspace.shared.icon(forFile: path)
        let rendered = NSImage(size: targetSize, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            workspaceIcon.draw(in: rect)
            return true
        }
        rendered.isTemplate = false
        return rendered
    }
}
