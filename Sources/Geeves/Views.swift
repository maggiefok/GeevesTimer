import SwiftUI
import AppKit

enum Theme {
    static let ink = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1A / 255)
    static let mid = Color(red: 0x6B / 255, green: 0x6A / 255, blue: 0x66 / 255)
    static let line = Color(red: 0xCF / 255, green: 0xCD / 255, blue: 0xC8 / 255)
    static let accent = Color(red: 0xC2 / 255, green: 0x41 / 255, blue: 0x0C / 255)
}

enum Fmt {
    static func range(_ e: TimeEntry) -> String {
        let day = DateFormatter()
        day.dateFormat = "EEE, MMM d"
        let time = DateFormatter()
        time.dateFormat = "h:mm a"
        return "\(day.string(from: e.start)) · \(time.string(from: e.start)) – \(time.string(from: e.end))"
    }

    static func hours(_ h: Double) -> String {
        String(format: "%g", h)
    }
}

// MARK: - Root

struct RootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var sync: SyncQueue
    let menu: () -> NSMenu

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            switch state.screen {
            case .idle, .running:
                PillView(state: state, sync: sync, menu: menu)
            case .search:
                Card(state: state) { SearchView(state: state, connected: sync.api != nil) }
            case .newClient:
                Card(state: state) { NewClientView(state: state) }
            }
            if let t = state.toast {
                ToastView(toast: t) { state.performUndo() }
            }
        }
        .padding(14) // room for the shadow
        .fixedSize()
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Pill

struct PillView: View {
    @ObservedObject var state: AppState
    @ObservedObject var sync: SyncQueue
    let menu: () -> NSMenu

    private var running: Bool { state.startedAt != nil }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                if running {
                    Circle().fill(Theme.accent).frame(width: 8, height: 8)
                }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(AppState.clock(state.startedAt.map { ctx.date.timeIntervalSince($0) } ?? 0))
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(running ? Theme.ink : Theme.mid)
                }
                if !sync.items.isEmpty {
                    Circle().stroke(Theme.accent, lineWidth: 1.5).frame(width: 7, height: 7)
                        .help("Entries waiting to sync")
                }
            }
            // Drag the timer by its numbers; right-click for the menu.
            .overlay(DragArea(menu: menu))

            Button { state.toggle() } label: {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .font(.system(size: running ? 13 : 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(running ? Theme.accent : Theme.ink))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(running ? "Stop timer" : "Start timer")
        }
        .padding(.leading, running ? 14 : 18)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        // The whole pill (apart from the play/stop button) drags the timer around.
        .background(ZStack {
            Capsule().fill(Color.white)
            DragArea(menu: menu).clipShape(Capsule())
        })
        .overlay(Capsule().stroke(running ? Theme.accent : Theme.ink, lineWidth: running ? 2 : 1.5))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}

struct DragArea: NSViewRepresentable {
    var menu: (() -> NSMenu)? = nil

    final class DragView: NSView {
        var menuProvider: (() -> NSMenu)?
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> DragView {
        let v = DragView()
        v.menuProvider = menu
        return v
    }

    func updateNSView(_ v: DragView, context: Context) {
        v.menuProvider = menu
    }
}

// MARK: - Card shell

struct Card<Content: View>: View {
    @ObservedObject var state: AppState
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if let e = state.entry {
                EntryHeader(entry: e, billed: state.billedHours(e))
                    .overlay(DragArea()) // drag the card by its header
                Divider()
            }
            content
        }
        .frame(width: 340)
        // Empty space in the card drags it too.
        .background(ZStack {
            Color.white
            DragArea()
        })
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.ink, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

struct EntryHeader: View {
    let entry: TimeEntry
    let billed: Double

    var body: some View {
        HStack(alignment: .center) {
            Text(Fmt.range(entry))
                .font(.system(size: 12))
                .foregroundColor(Theme.mid)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(AppState.format(entry.seconds))
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.ink)
                Text("\(Fmt.hours(billed)) h billed")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.mid)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct Footer: View {
    let left: String
    let right: String

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(left)
                Spacer()
                Text(right)
            }
            .font(.system(size: 12))
            .foregroundColor(Theme.mid)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @ObservedObject var state: AppState
    let connected: Bool

    private enum Field { case search, note }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(spacing: 0) {
            // Required note, written before picking a client. Goes in the Task column of the Time Log.
            let flagNote = state.noteNeeded && !state.hasNote
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "square.and.pencil").foregroundColor(flagNote ? .red : Theme.mid)
                TextField(flagNote ? "Add a note before choosing a client" : "What did you work on?",
                          text: $state.note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.ink)
                    .focused($focus, equals: .note)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.mid)
                TextField("Find a client or project", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.ink)
                    .focused($focus, equals: .search)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            let rows = state.results
            VStack(spacing: 2) {
                if rows.isEmpty {
                    Text(state.clients.isEmpty ? "Type a client name to add one" : "No matches")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.mid)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    ResultRowView(row: row, index: i, selected: i == state.selected)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.selected = i
                            state.pick(row)
                        }
                }
            }
            .padding(6)

            if !connected {
                Text("Not connected to Geeves yet, so entries wait on this Mac. Right-click the timer › Connect to Geeves.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.mid)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Footer(left: state.editingNote ? "return · choose client" : "tab · edit note", right: "esc · discard")
        }
        .onAppear { DispatchQueue.main.async { focus = state.editingNote ? .note : .search } }
        // Keep the keyboard (tab key) and mouse clicks in step about which field is active.
        .onChange(of: state.editingNote) { editing in focus = editing ? .note : .search }
        .onChange(of: focus) { f in
            if let f, (f == .note) != state.editingNote { state.editingNote = f == .note }
        }
    }
}

struct ResultRowView: View {
    let row: SearchRow
    let index: Int
    let selected: Bool

    var body: some View {
        HStack {
            switch row {
            case .client(let o):
                Text(o.label)
            case .newClient(let name):
                Text("+ New client “\(name)”")
                    .foregroundColor(selected ? .white : Theme.mid)
            }
            Spacer()
            Text(selected ? "return" : (index < 9 ? "⌘\(index + 1)" : ""))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(selected ? .white : Theme.mid)
        }
        .font(.system(size: 14))
        .foregroundColor(selected ? .white : Theme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.ink : Color.clear))
    }
}

// MARK: - New client

struct NewClientView: View {
    @ObservedObject var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New client")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.ink)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.system(size: 11)).foregroundColor(Theme.mid)
                    TextField("", text: $state.newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.ink)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.ink, lineWidth: 1.5))
                        .focused($focused)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Work type").font(.system(size: 11)).foregroundColor(Theme.mid)
                    if !state.workTypes.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(state.workTypes, id: \.self) { t in
                                Button { state.newType = t } label: {
                                    Text(t)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(state.newType == t ? .white : Theme.ink)
                                        .padding(.horizontal, 12)
                                        .frame(height: 28)
                                        .background(Capsule().fill(state.newType == t ? Theme.ink : Color.white))
                                        .overlay(Capsule().stroke(Theme.ink, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    TextField("or type a new one", text: $state.newType)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.ink)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
                }

                Text("Rates and invoice details get filled in on the sheet.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.mid)
            }
            .padding(16)
            Footer(left: "return · create + log time", right: "esc · back")
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let toast: Toast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
            Text(toast.text)
            if toast.undo != nil {
                Button("Undo", action: onUndo)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .underline()
            }
        }
        .font(.system(size: 13))
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.ink))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}
