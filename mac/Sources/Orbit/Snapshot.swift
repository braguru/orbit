import AppKit

/// Development aid: ORBIT_SNAPSHOT_DIR=/some/folder makes the app save a picture of its window for
/// each page, then quit. An app can always picture its own views, so this needs no screen-recording permission.
enum Snapshot {
    static var folder: String? { ProcessInfo.processInfo.environment["ORBIT_SNAPSHOT_DIR"] }

    @MainActor
    static func window(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
