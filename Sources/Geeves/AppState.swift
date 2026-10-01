import Foundation
import SwiftUI

struct ClientOption: Codable, Hashable, Identifiable {
    var client: String
    var workType: String

    var id: String { "\(client)|\(workType)" }
    var label: String { workType.isEmpty ? client : "\(client) · \(workType)" }
}

struct TimeEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date
    var client = ""
    var workType = ""
    var note = ""

    var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

enum Screen {
    case idle, running, search, newClient, note
}

enum SearchRow: Identifiable, Equatable {
    case client(ClientOption)
    case newClient(String)

    var id: String {
        switch self {
        case .client(let o): return o.id
        case .newClient(let n): return "new|\(n)"
        }
    }
}

struct Toast: Identifiable {
    let id = UUID()
    var text: String
    var undo: (() -> Void)?
}

@MainActor
final class AppState: ObservableObject {
    @Published var screen: Screen = .idle
    @Published var startedAt: Date?
    @Published var entry: TimeEntry?
    @Published var query = "" { didSet { selected = 0 } }
    @Published var selected = 0
    @Published var chosen: ClientOption?
    @Published var note = ""
    @Published var newName = ""
    @Published var newType = ""
    @Published var clients: [ClientOption] = []
    @Published var toast: Toast?
    @Published var lastError: String?

    let sync: SyncQueue
    /// Called when the card needs keyboard focus (after Stop).
    var onWantsFocus: () -> Void = {}
    /// Called when the card closes, so focus goes back to the app you were in.
    var onFinished: () -> Void = {}

    private var recent: [String]
    private var toastTimer: Timer?
    private let defaults = UserDefaults.standard

    init(sync: SyncQueue) {
        self.sync = sync
        recent = defaults.stringArray(forKey: "recent") ?? []
        if let d = defaults.data(forKey: "clients"), let c = try? JSONDecoder().decode([ClientOption].self, from: d) {
            clients = c
        }
        // Survive quits and restarts: a running timer, or a stopped one not yet assigned.
        if let t = defaults.object(forKey: "startedAt") as? Date {
            startedAt = t
            screen = .running
        }
        if let d = defaults.data(forKey: "openEntry"), let e = try? JSONDecoder().decode(TimeEntry.self, from: d) {
            entry = e
            screen = .search
        }
    }

    // MARK: Settings

    /// 15 = round to the nearest quarter hour, 6 = tenth of an hour, 0 = exact.
    var roundMinutes: Int {
        get { defaults.object(forKey: "roundMinutes") as? Int ?? 15 }
        set { defaults.set(newValue, forKey: "roundMinutes"); objectWillChange.send() }
    }

    func billedHours(_ e: TimeEntry) -> Double {
        let minutes = e.seconds / 60
        guard roundMinutes > 0 else { return (minutes / 60 * 100).rounded() / 100 }
        let step = Double(roundMinutes)
        let steps = max(1, (minutes / step).rounded()) // never bill less than one step
        return (steps * step / 60 * 100).rounded() / 100
    }

    // MARK: Timer

    func toggle() {
        startedAt == nil ? start() : stop()
    }

    func start() {
        guard entry == nil else { screen = .search; onWantsFocus(); return }
        dismissToast()
        let now = Date()
        startedAt = now
        defaults.set(now, forKey: "startedAt")
        screen = .running
    }

    func stop() {
        guard let s = startedAt else { return }
        startedAt = nil
        defaults.removeObject(forKey: "startedAt")
        openEntry(TimeEntry(start: s, end: Date()))
        Task { await refreshClients() }
    }

    private func openEntry(_ e: TimeEntry) {
        entry = e
        saveOpenEntry()
        query = ""
        selected = 0
        chosen = nil
        note = ""
        screen = .search
        onWantsFocus()
    }

    private func saveOpenEntry() {
        if let e = entry, let d = try? JSONEncoder().encode(e) {
            defaults.set(d, forKey: "openEntry")
        } else {
            defaults.removeObject(forKey: "openEntry")
        }
    }

    private var restingScreen: Screen { startedAt == nil ? .idle : .running }

    // MARK: Search

    var results: [SearchRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let rank: (ClientOption) -> Int = { [recent] o in recent.firstIndex(of: o.id) ?? Int.max }
        var list = clients.sorted { (rank($0), $0.label.lowercased()) < (rank($1), $1.label.lowercased()) }
        if !q.isEmpty {
            list = list.filter { $0.label.localizedCaseInsensitiveContains(q) }
        }
        var rows = list.prefix(6).map { SearchRow.client($0) }
        if !q.isEmpty && !clients.contains(where: { $0.client.caseInsensitiveCompare(q) == .orderedSame }) {
            rows.append(.newClient(q))
        }
        return rows
    }

    var workTypes: [String] {
        var seen = Set<String>()
        return clients.map(\.workType).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func move(_ delta: Int) {
        let n = results.count
        guard n > 0 else { return }
        selected = (selected + delta + n) % n
    }

    func activateSelected(addNote: Bool) {
        let rows = results
        guard rows.indices.contains(selected) else { return }
        pick(rows[selected], addNote: addNote)
    }

    func pick(index: Int) {
        let rows = results
        guard rows.indices.contains(index) else { return }
        selected = index
        pick(rows[index], addNote: false)
    }

    func pick(_ row: SearchRow, addNote: Bool) {
        switch row {
        case .client(let o):
            if addNote {
                chosen = o
                screen = .note
                onWantsFocus()
            } else {
                commit(o)
            }
        case .newClient(let name):
            newName = name
            newType = workTypes.first ?? ""
            screen = .newClient
            onWantsFocus()
        }
    }

    func backToSearch() {
        chosen = nil
        screen = .search
        onWantsFocus()
    }

    func saveNote() {
        if let o = chosen { commit(o) }
    }

    func createClient() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let opt = ClientOption(client: name, workType: newType.trimmingCharacters(in: .whitespaces))
        if !clients.contains(opt) {
            clients.append(opt)
            cacheClients()
        }
        sync.enqueue(.client(opt))
        commit(opt)
    }

    // MARK: Save / discard

    func commit(_ o: ClientOption) {
        guard var e = entry else { return }
        e.client = o.client
        e.workType = o.workType
        e.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let hours = billedHours(e)
        bumpRecent(o.id)

        entry = nil
        saveOpenEntry()
        chosen = nil
        note = ""
        screen = restingScreen
        onFinished()

        // Sent after a short pause so Undo can simply pull it back.
        let itemID = sync.enqueue(.time(e, hours: hours), delay: 6)
        let saved = e
        showToast("\(Self.format(e.seconds)) to \(o.label)") { [weak self] in
            guard let self else { return }
            if self.sync.cancel(itemID) {
                self.openEntry(saved)
                self.note = saved.note
            } else {
                self.showToast("Already sent to Geeves. Fix it in the Time Log.", undo: nil)
            }
        }
    }

    func discard() {
        guard let e = entry else { return }
        entry = nil
        saveOpenEntry()
        screen = restingScreen
        onFinished()
        showToast("Discarded \(Self.format(e.seconds))") { [weak self] in
            self?.openEntry(e)
        }
    }

    // MARK: Toast

    func showToast(_ text: String, undo: (() -> Void)?) {
        toastTimer?.invalidate()
        toast = Toast(text: text, undo: undo)
        toastTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.toast = nil }
        }
    }

    func dismissToast() {
        toastTimer?.invalidate()
        toast = nil
    }

    func performUndo() {
        let undo = toast?.undo
        dismissToast()
        undo?()
    }

    // MARK: Clients

    func refreshClients() async {
        guard let api = sync.api else { return }
        do {
            var list = try await api.clients()
            for c in sync.pendingClients where !list.contains(c) { list.append(c) }
            clients = list
            cacheClients()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func cacheClients() {
        if let d = try? JSONEncoder().encode(clients) { defaults.set(d, forKey: "clients") }
    }

    private func bumpRecent(_ id: String) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        recent = Array(recent.prefix(20))
        defaults.set(recent, forKey: "recent")
    }

    // MARK: Formatting

    nonisolated static func format(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        return m < 60 ? "\(m)m" : "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }

    nonisolated static func clock(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}
