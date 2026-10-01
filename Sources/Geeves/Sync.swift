import Foundation

enum GeevesError: LocalizedError {
    case http(Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Geeves returned HTTP \(code)"
        case .message(let m): return m
        }
    }
}

/// Talks to the Timer.gs web app in the Geeves sheet.
struct GeevesAPI {
    let url: URL
    let key: String

    struct Reply: Decodable {
        let ok: Bool
        let error: String?
        let clients: [ClientOption]?
    }

    func clients() async throws -> [ClientOption] {
        try await post(["action": "clients"]).clients ?? []
    }

    func send(_ body: [String: Any]) async throws {
        _ = try await post(body)
    }

    private func post(_ body: [String: Any]) async throws -> Reply {
        var b = body
        b["key"] = key
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "POST"
        // text/plain keeps Apps Script happy; the script parses the JSON itself.
        req.setValue("text/plain;charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: b)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw GeevesError.http(code) }

        let reply: Reply
        do {
            reply = try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw GeevesError.message("Unexpected reply. Check the web app URL, and that it's deployed with access set to Anyone.")
        }
        if !reply.ok { throw GeevesError.message(reply.error ?? "Unknown error from Geeves") }
        return reply
    }
}

enum QueueKind: Codable {
    case time(TimeEntry, hours: Double)
    case client(ClientOption)
}

struct QueueItem: Codable, Identifiable {
    var id = UUID()
    var kind: QueueKind
    var notBefore: Date
}

/// Everything headed to the sheet waits here first, saved on the Mac,
/// so nothing is lost if you're offline or the sheet is slow.
@MainActor
final class SyncQueue: ObservableObject {
    @Published private(set) var items: [QueueItem] = []
    @Published var lastError: String?

    private var flushing = false
    private var inFlight = Set<UUID>()
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    var api: GeevesAPI? {
        guard let s = defaults.string(forKey: "webAppURL"),
              let u = URL(string: s), u.scheme?.hasPrefix("http") == true,
              let k = defaults.string(forKey: "webAppKey"), !k.isEmpty
        else { return nil }
        return GeevesAPI(url: u, key: k)
    }

    init() {
        if let d = defaults.data(forKey: "queue"), let q = try? JSONDecoder().decode([QueueItem].self, from: d) {
            items = q
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.flush() }
        }
        Task { await flush() }
    }

    var pendingClients: [ClientOption] {
        items.compactMap { item in
            if case .client(let c) = item.kind { return c }
            return nil
        }
    }

    @discardableResult
    func enqueue(_ kind: QueueKind, delay: TimeInterval = 0) -> UUID {
        let item = QueueItem(kind: kind, notBefore: Date().addingTimeInterval(delay))
        items.append(item)
        persist()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.2) { [weak self] in
            Task { await self?.flush() }
        }
        return item.id
    }

    /// Pulls an item back if it hasn't gone out yet. Returns false if it's already sent.
    func cancel(_ id: UUID) -> Bool {
        guard !inFlight.contains(id), let i = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: i)
        persist()
        return true
    }

    func flush() async {
        guard !flushing, let api else { return }
        flushing = true
        defer { flushing = false }

        while let item = items.first, item.notBefore <= Date() {
            inFlight.insert(item.id)
            do {
                try await api.send(body(for: item))
                items.removeAll { $0.id == item.id }
                persist()
                lastError = nil
                inFlight.remove(item.id)
            } catch {
                inFlight.remove(item.id)
                lastError = error.localizedDescription
                return // try again on the next 30s tick
            }
        }
    }

    private func body(for item: QueueItem) -> [String: Any] {
        switch item.kind {
        case .time(let e, let hours):
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.dateFormat = "yyyy-MM-dd"
            return [
                "action": "addTime",
                "id": item.id.uuidString,
                "date": day.string(from: e.start),
                "client": e.client,
                "workType": e.workType,
                "task": e.note,
                "hours": hours
            ]
        case .client(let c):
            return ["action": "addClient", "id": item.id.uuidString, "client": c.client, "workType": c.workType]
        }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(items) { defaults.set(d, forKey: "queue") }
    }
}
