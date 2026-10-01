import AppKit

// Geeves runs as an "accessory" app: no Dock icon, just the floating timer.
@main
enum GeevesMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        _ = delegate
    }
}
