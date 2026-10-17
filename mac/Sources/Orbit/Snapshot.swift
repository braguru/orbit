import AppKit

/// Development aid: ORBIT_SNAPSHOT_DIR=/some/folder makes the app save a picture of its window for
/// each page, then quit. An app can always picture its own views, so this needs no screen-recording permission.
enum Snapshot {
    static var folder: String? { ProcessInfo.processInfo.environment["ORBIT_SNAPSHOT_DIR"] }
    /// ORBIT_SNAPSHOT_DEVICE=<id> (or several, comma-separated) selects devices on the Devices page, to picture the inspector.
    static var devices: Set<String> {
        Set((ProcessInfo.processInfo.environment["ORBIT_SNAPSHOT_DEVICE"] ?? "").split(separator: ",").map(String.init))
    }

    /// ORBIT_SNAPSHOT_SIZE=960x700 sets the window's size first, to picture a narrow or short window.
    @MainActor
    static func resizeWindow() {
        let parts = (ProcessInfo.processInfo.environment["ORBIT_SNAPSHOT_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }) else { return }
        window.setFrameAutosaveName("")  // a test size mustn't become the size the installed app opens at
        window.setContentSize(NSSize(width: parts[0], height: parts[1]))
    }

    /// Scrolls every scroll view in the window to its end, to picture what's below the fold.
    @MainActor
    static func scrollToEnd(fraction: Double = 1) {
        func visit(_ v: NSView) {
            if let s = v as? NSScrollView, let doc = s.documentView {
                let end = doc.isFlipped ? max(0, doc.bounds.height - s.contentView.bounds.height) * fraction : 0
                s.contentView.scroll(to: NSPoint(x: 0, y: end))
                s.reflectScrolledClipView(s.contentView)
            }
            v.subviews.forEach(visit)
        }
        NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 })?.contentView.map(visit)
    }

    @MainActor
    static func window(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
