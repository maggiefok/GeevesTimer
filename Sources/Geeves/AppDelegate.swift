import AppKit
import SwiftUI
import ServiceManagement

/// A borderless floating panel that can take typing without pulling Geeves to the front.
final class GeevesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the very first click on the play/stop button work, even when another app is in front.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    /// Called whenever the SwiftUI content changes size (pill ↔ card, note growing, toast appearing).
    var onContentResize: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        // Wait for SwiftUI to finish the update before measuring.
        DispatchQueue.main.async { [weak self] in self?.onContentResize?() }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: GeevesPanel!
    private var state: AppState!
    private var sync: SyncQueue!
    private var keyMonitor: Any?
    private let defaults = UserDefaults.standard

    /// The panel's top-right corner. The pill and card grow down and to the left from here.
    private var anchor = NSPoint.zero
    /// Last size SwiftUI reported, and the frame we last set ourselves (so our own resizes aren't mistaken for drags).
    private var contentSize = CGSize.zero
    private var programmaticFrame = NSRect.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()

        sync = SyncQueue()
        state = AppState(sync: sync)
        state.onWantsFocus = { [weak self] in self?.focusPanel() }
        state.onFinished = { [weak self] in self?.releaseFocus() }

        // Work out the top-right anchor before any content exists, since SwiftUI reports its size immediately.
        placeAnchor()

        panel = GeevesPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 70),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let root = RootView(
            state: state,
            sync: sync,
            menu: { [weak self] in self?.buildMenu() ?? NSMenu() }
        )
        let host = PanelHostingView(rootView: root)
        // We size the panel ourselves, anchored top-right, from the hosting view's own measurement.
        // (A GeometryReader preference reported 0×0 here, which left the stop card squashed into a tiny panel.)
        host.sizingOptions = [.intrinsicContentSize]
        host.onContentResize = { [weak self, weak host] in
            guard let self, let host else { return }
            self.resize(to: host.fittingSize)
        }
        panel.contentView = host

        resize(to: host.fittingSize)
        if contentSize.width <= 1 {
            // Nothing measurable yet: park a default-sized panel at the anchor so it never sits at the bottom-left.
            resize(to: CGSize(width: 220, height: 70))
        }
        panel.orderFrontRegardless()

        // Remember where you drag it. Our own resizes keep the same top-right corner, so they're ignored.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.frame != self.programmaticFrame else { return }
                self.rememberAnchor()
            }
        }

        installKeys()

        if state.screen == .search { focusPanel() }
        if sync.api == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showSettings() }
        } else {
            Task { await state.refreshClients() }
        }
    }

    // MARK: Position and size

    private func placeAnchor() {
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        if let x = defaults.object(forKey: "anchorX") as? Double, let y = defaults.object(forKey: "anchorY") as? Double,
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -4, dy: -4).contains(NSPoint(x: x - 20, y: y - 20)) }) {
            anchor = NSPoint(x: x, y: y)
        } else {
            anchor = NSPoint(x: visible.maxX - 12, y: visible.maxY - 8)
        }
    }

    private func rememberAnchor() {
        anchor = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        defaults.set(anchor.x, forKey: "anchorX")
        defaults.set(anchor.y, forKey: "anchorY")
    }

    private func resize(to size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        contentSize = size
        guard let panel else { return }
        var frame = NSRect(x: anchor.x - size.width, y: anchor.y - size.height, width: size.width, height: size.height)

        // Keep the whole pill or card on screen, e.g. when it has been dragged near a left or bottom edge.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.x - 1, y: anchor.y - 1)) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)

        if panel.frame != frame {
            programmaticFrame = frame
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: Focus

    private func focusPanel() {
        panel.makeKeyAndOrderFront(nil)
        if !panel.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Hand the keyboard back to whatever app you were in.
    private func releaseFocus() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        if NSApp.isActive { NSApp.deactivate() }
        panel.orderFrontRegardless()
    }

    // MARK: Keyboard

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let option = e.modifierFlags.contains(.option)
        let isReturn = e.keyCode == 36 || e.keyCode == 76

        switch state.screen {
        case .search:
            if e.keyCode == 53 { state.discard(); return true }
            // In the note: option-return adds a new line, plain return moves on to the clients.
            // In the search: return saves with the selected client.
            if isReturn && state.editingNote {
                if option { return false }
                state.finishNote()
                return true
            }
            if isReturn { state.activateSelected(); return true }
            // Tab (or shift-tab) hops between the search field and the note field.
            if e.keyCode == 48 { state.editingNote.toggle(); return true }
            if e.keyCode == 125 { state.move(1); return true }
            if e.keyCode == 126 { state.move(-1); return true }
            if cmd, let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
                state.pick(index: n - 1)
                return true
            }
            return false

        case .newClient:
            if e.keyCode == 53 { state.backToSearch(); return true }
            if isReturn { state.createClient(); return true }
            return false

        case .idle, .running:
            return false
        }
    }

    /// Accessory apps have no menu bar, but copy/paste shortcuts still need an Edit menu behind the scenes.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: Right-click menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        if !sync.items.isEmpty {
            let n = sync.items.count
            menu.addItem(ClosureMenuItem("\(n) \(n == 1 ? "entry" : "entries") waiting · Sync now") { [weak self] in
                Task { await self?.sync.flush() }
            })
        }
        if let err = sync.lastError ?? state.lastError {
            let item = NSMenuItem(title: "⚠︎ \(err)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }

        menu.addItem(ClosureMenuItem("Refresh clients") { [weak self] in
            Task { await self?.state.refreshClients() }
        })

        let roundItem = NSMenuItem(title: "Round time to", action: nil, keyEquivalent: "")
        let roundMenu = NSMenu()
        for (label, minutes) in [("Nearest 15 minutes", 15), ("Nearest 6 minutes", 6), ("Exact", 0)] {
            let item = ClosureMenuItem(label) { [weak self] in self?.state.roundMinutes = minutes }
            item.state = state.roundMinutes == minutes ? .on : .off
            roundMenu.addItem(item)
        }
        roundItem.submenu = roundMenu
        menu.addItem(roundItem)

        let login = ClosureMenuItem("Open at login") { [weak self] in self?.toggleLogin() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(ClosureMenuItem("Connect to Geeves…") { [weak self] in self?.showSettings() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Geeves") { NSApp.terminate(nil) })
        return menu
    }

    private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            state.showToast("Couldn't change Open at login: \(error.localizedDescription)", undo: nil)
        }
    }

    // MARK: Connect dialog

    private func showSettings() {
        let alert = NSAlert()
        alert.messageText = "Connect to Geeves"
        alert.informativeText = "Paste the web app URL from Apps Script (Deploy › Manage deployments) and the TIMER_KEY you set in Timer.gs."

        let urlField = NSTextField(string: defaults.string(forKey: "webAppURL") ?? "")
        urlField.placeholderString = "https://script.google.com/macros/s/…/exec"
        let keyField = NSTextField(string: defaults.string(forKey: "webAppKey") ?? "")
        keyField.placeholderString = "Key"

        let stack = NSStackView(views: [urlField, keyField])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 56)
        for f in [urlField, keyField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 380).isActive = true
        }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = urlField
        let answer = alert.runModal()
        NSApp.deactivate()
        guard answer == .alertFirstButtonReturn else { return }

        defaults.set(urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "webAppURL")
        defaults.set(keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "webAppKey")

        guard sync.api != nil else {
            state.showToast("Not connected. Both the URL and the key are needed.", undo: nil)
            return
        }
        Task {
            await state.refreshClients()
            if let err = state.lastError {
                state.showToast("Couldn't connect: \(err)", undo: nil)
            } else {
                state.showToast("Connected · \(state.clients.count) clients", undo: nil)
                await sync.flush()
            }
        }
    }
}
