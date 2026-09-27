// Jot — a floating scratchpad for thoughts/questions while reviewing AI output.
//
// Global gestures (Copper-style double taps of a lone modifier):
//   ⇧⇧  capture the current selection and jump into its note (↩ saves & returns, esc skips)
//   ⌘⌘  jot in the widget (annotates the capture you just made, else a new note); again to leave
//   ⌃⌃  paste checked items (or all) at your cursor
// In the widget: ↩ save (cursor stays for the next note), esc back to your app,
//   ⌘↩ paste, ⌘⇧C copy, ⌘⇧⌫ clear, ⌘⇧A select all/none.
// Paste hands focus back to the app you were in first, so it lands at that app's cursor.

import AppKit
import ServiceManagement
import SwiftUI

func log(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Jot.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Model

struct Item: Codable, Identifiable, Equatable {
    var id = UUID()
    var quote: String?
    var note: String
    var app: String?
    var created = Date()
    /// nil = the default list (shown as "Inbox" once named sections exist).
    var section: UUID?
}

struct Section: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
}

/// Everything a bulk removal can take away, so undo can put it back.
struct Snapshot: Equatable {
    var items: [Item]
    var sections: [Section]
    var active: UUID?
}

final class Store: ObservableObject {
    @Published var items: [Item] = [] { didSet { changed() } }
    @Published var sections: [Section] = [] { didSet { changed() } }
    /// The section being viewed and written to; nil = Inbox. Captures and notes land here
    /// until you switch.
    @Published var active: UUID? { didSet { changed() } }
    @Published var selected: Set<UUID> = []
    /// Composer state: `editing` is the item the draft annotates (nil = new note).
    @Published var editing: UUID?
    @Published var draft = ""
    @Published var focusRequest = 0
    /// Set when ⇧⇧ opened the composer: saving the note returns you to your app.
    var releaseOnSubmit = false
    @Published var flashID: UUID?
    @Published var trusted = Keys.trusted
    /// State before the last bulk removal, offered as a short-lived undo.
    @Published var undo: Snapshot?

    var onChange: (() -> Void)?
    private var lastCapture: (id: UUID, at: Date)?
    private var loading = true

    private struct Saved: Codable {
        var items: [Item]
        var sections: [Section]
        var active: UUID?
    }

    private static let dir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private let url = dir.appendingPathComponent("state.json")

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            items = saved.items
            sections = saved.sections
            active = saved.sections.contains { $0.id == saved.active } ? saved.active : nil
        } else if let data = try? Data(contentsOf: Self.dir.appendingPathComponent("items.json")),
                  let legacy = try? JSONDecoder().decode([Item].self, from: data) {
            items = legacy
        }
        loading = false
        save()
    }

    private func changed() {
        guard !loading else { return }
        save()
        onChange?()
    }

    private func save() {
        let saved = Saved(items: items, sections: sections, active: active)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Sections

    /// Items in the active section.
    var current: [Item] { items.filter { $0.section == active } }

    var activeName: String? { sections.first { $0.id == active }?.name }

    func count(in section: UUID?) -> Int { items.filter { $0.section == section }.count }

    func switchTo(_ id: UUID?) {
        guard id != active else { return }
        active = id
        selected = []
        if let e = editing, !current.contains(where: { $0.id == e }) { cancelDraft() }
    }

    /// ⌘[ / ⌘]: steps through Inbox and the named sections, wrapping around.
    func cycle(_ step: Int) {
        let order: [UUID?] = [nil] + sections.map(\.id)
        guard order.count > 1, let i = order.firstIndex(of: active) else { return }
        switchTo(order[(i + step + order.count) % order.count])
    }

    func addSection(_ name: String) {
        let s = Section(name: name)
        sections.append(s)
        switchTo(s.id)
    }

    func rename(_ id: UUID, to name: String) {
        if let i = sections.firstIndex(where: { $0.id == id }) { sections[i].name = name }
    }

    /// Deletes a section and its notes (undoable for a few seconds).
    func deleteSection(_ id: UUID) {
        let before = snapshot
        items.removeAll { $0.section == id }
        sections.removeAll { $0.id == id }
        if active == id { switchTo(nil) }
        offerUndo(before)
    }

    // MARK: Items

    func capture(_ quote: String, app: String?) {
        let item = Item(quote: quote, note: "", app: app, section: active)
        items.append(item)
        lastCapture = (item.id, Date())
        flash(item.id)
    }

    func flash(_ id: UUID) {
        flashID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.flashID == id { self?.flashID = nil }
        }
    }

    /// ⌘⌘: annotate a capture made in the last two minutes that has no note yet, else start a new note.
    func beginNote() {
        if let last = lastCapture, Date().timeIntervalSince(last.at) < 120,
           let item = current.first(where: { $0.id == last.id }), item.note.isEmpty {
            edit(item)
        } else {
            editing = nil
            draft = ""
        }
        focusRequest += 1
    }

    func edit(_ item: Item) {
        releaseOnSubmit = false
        editing = item.id
        draft = item.note
        focusRequest += 1
    }

    func commitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editing, let i = items.firstIndex(where: { $0.id == id }) {
            items[i].note = text
            flash(id)
        } else if !text.isEmpty {
            let item = Item(quote: nil, note: text, app: nil, section: active)
            items.append(item)
            flash(item.id)
        }
        cancelDraft()
    }

    func cancelDraft() {
        releaseOnSubmit = false
        editing = nil
        draft = ""
        lastCapture = nil
    }

    /// Checked items if any are checked, otherwise everything in the active section.
    var targets: [Item] {
        selected.isEmpty ? current : current.filter { selected.contains($0.id) }
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selected.subtract(ids)
        if let e = editing, ids.contains(e) { cancelDraft() }
    }

    /// Removes several items at once, keeping an undo for a few seconds.
    func removeBulk(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = snapshot
        remove(ids)
        offerUndo(before)
    }

    private var snapshot: Snapshot { Snapshot(items: items, sections: sections, active: active) }

    private func offerUndo(_ before: Snapshot) {
        undo = before
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.undo == before { self?.undo = nil }
        }
    }

    func undoRemove() {
        guard let before = undo else { return }
        items = before.items
        sections = before.sections
        active = before.active
        undo = nil
    }

    func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func toggleAll() {
        let ids = Set(current.map(\.id))
        selected = selected == ids ? [] : ids
    }

    // MARK: Slash commands

    struct Suggestion: Identifiable {
        var id: String { completion }
        let label: String
        let detail: String
        let completion: String
    }

    enum CommandResult { case done(String?), copy, paste, failed(String) }

    private static let commands: [(name: String, arg: String, help: String, needsSection: Bool)] = [
        ("new", "name", "start a section and write to it", false),
        ("go", "name", "switch section", false),
        ("rename", "name", "rename this section", true),
        ("delete", "", "delete this section and its notes", true),
        ("clear", "", "clear notes here", false),
        ("copy", "", "copy notes to the clipboard", false),
        ("paste", "", "paste notes at your cursor", false),
    ]

    private var isCommand: Bool { editing == nil && draft.hasPrefix("/") }

    /// What typing "/…" in the composer could complete to.
    var suggestions: [Suggestion] {
        guard isCommand else { return [] }
        let body = draft.dropFirst().lowercased()
        if let space = body.firstIndex(of: " ") {
            guard ["go", "switch"].contains(body[..<space]) else { return [] }
            let arg = body[body.index(after: space)...].trimmingCharacters(in: .whitespaces)
            let names = ["Inbox"] + sections.map(\.name)
            return names.filter { arg.isEmpty || $0.lowercased().hasPrefix(arg) }
                .map { Suggestion(label: $0, detail: "", completion: "/go \($0)") }
        }
        return Self.commands.filter { $0.name.hasPrefix(body) && (!$0.needsSection || active != nil) }
            .map { Suggestion(label: "/\($0.name)" + ($0.arg.isEmpty ? "" : " ‹\($0.arg)›"), detail: $0.help,
                              completion: "/\($0.name)" + ($0.arg.isEmpty ? "" : " ")) }
    }

    /// ⇥ in the composer: complete to the first suggestion.
    func autocomplete() -> Bool {
        guard let first = suggestions.first, first.completion != draft else { return false }
        draft = first.completion
        return true
    }

    /// Exact name first, then prefix; "inbox" means the default list. Outer nil = no match.
    private func section(matching name: String) -> UUID?? {
        let n = name.lowercased()
        if let exact = sections.first(where: { $0.name.lowercased() == n }) { return .some(exact.id) }
        if "inbox".hasPrefix(n) { return .some(nil) }
        return sections.first { $0.name.lowercased().hasPrefix(n) }.map { .some($0.id) }
    }

    /// Runs the composer's "/command"; clears the draft unless it failed.
    func runCommand() -> CommandResult {
        let parts = draft.dropFirst().trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        let cmd = parts.first.map { $0.lowercased() } ?? ""
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let result: CommandResult
        switch cmd {
        case "new":
            guard !arg.isEmpty else { return .failed("Name it: /new ‹name›") }
            if let existing = sections.first(where: { $0.name.lowercased() == arg.lowercased() }) {
                switchTo(existing.id)
            } else {
                addSection(arg)
            }
            result = .done("Writing to \(activeName ?? "Inbox")")
        case "go", "switch":
            if arg.isEmpty {
                cycle(1)
            } else if let id = section(matching: arg) {
                switchTo(id)
            } else {
                return .failed("No section “\(arg)” — /new \(arg)?")
            }
            result = .done("Writing to \(activeName ?? "Inbox")")
        case "rename":
            guard let id = active else { return .failed("Inbox can't be renamed") }
            guard !arg.isEmpty else { return .failed("Name it: /rename ‹name›") }
            rename(id, to: arg)
            result = .done(nil)
        case "delete":
            guard let id = active else { return .failed("Inbox can't be deleted") }
            deleteSection(id)
            result = .done(nil)
        case "clear":
            removeBulk(Set(current.map(\.id)))
            result = .done(nil)
        case "copy": result = .copy
        case "paste": result = .paste
        default: return .failed("Unknown command /\(cmd)")
        }
        draft = ""
        return result
    }

    static func render(_ items: [Item]) -> String {
        items.map { item in
            var parts: [String] = []
            if let q = item.quote {
                parts.append(q.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }.joined(separator: "\n"))
            }
            if !item.note.isEmpty { parts.append(item.note) }
            return parts.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

// MARK: - Keyboard / clipboard plumbing

enum Keys {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func promptForAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        promptForAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Reads the selection via Accessibility without touching the clipboard. Works in native
    /// text views; many terminals/Electron apps don't expose it, hence the ⌘C fallback.
    static func axSelectedText() -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                            kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement,
                                            kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    static func sendCommand(_ key: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    static func restore(_ pb: NSPasteboard, _ snap: Snapshot) {
        pb.clearContents()
        let items = snap.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Accessibility first; otherwise sends ⌘C, reads what was copied, and restores the old clipboard.
    static func copySelection(_ completion: @escaping (String?) -> Void) {
        if let text = axSelectedText() {
            log("capture: via accessibility (\(text.count) chars)")
            return completion(text)
        }
        let pb = NSPasteboard.general
        let snap = snapshot(pb)
        let start = pb.changeCount
        sendCommand(8) // kVK_ANSI_C
        var tries = 0
        func poll() {
            if pb.changeCount != start {
                let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
                restore(pb, snap)
                log("capture: via ⌘C (\(text?.count ?? 0) chars)")
                completion(text?.isEmpty == false ? text : nil)
            } else if tries >= 25 {
                log("capture: ⌘C copied nothing (no selection?)")
                completion(nil)
            } else {
                tries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
            }
        }
        poll()
    }

    static func setClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// Detects a lone modifier tapped twice (press+release with nothing else in between).
final class DoubleTap {
    enum Mod { case shift, command, control }

    private let onTap: (Mod) -> Void
    private var monitors: [Any] = []
    private var down: (mod: Mod, at: TimeInterval)?
    private var lastTap: (mod: Mod, at: TimeInterval)?

    init(onTap: @escaping (Mod) -> Void) { self.onTap = onTap }

    func install() {
        monitors.forEach(NSEvent.removeMonitor)
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] in self?.handle($0) },
            NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] in self?.handle($0); return $0 },
        ].compactMap { $0 }
    }

    private func handle(_ e: NSEvent) {
        let now = e.timestamp
        guard e.type == .flagsChanged else {
            down = nil
            lastTap = nil
            return
        }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        let mods: [UInt: Mod] = [NSEvent.ModifierFlags.shift.rawValue: .shift,
                                 NSEvent.ModifierFlags.command.rawValue: .command,
                                 NSEvent.ModifierFlags.control.rawValue: .control]
        if let mod = mods[flags.rawValue] {
            down = (mod, now)
        } else if flags.isEmpty, let d = down {
            down = nil
            guard now - d.at < 0.3 else { lastTap = nil; return }
            if let l = lastTap, l.mod == d.mod, now - l.at < 0.4 {
                lastTap = nil
                log("double-tap: \(d.mod)")
                onTap(d.mod)
            } else {
                lastTap = (d.mod, now)
            }
        } else {
            down = nil
            lastTap = nil
        }
    }
}

// MARK: - Widget

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Jot has no Edit menu, so ⌘V/⌘C/⌘X/⌘A/⌘Z would never reach the text field. Dictation
    /// tools like Wispr Flow insert text by posting ⌘V, so route these by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let editing: [String: Selector] = ["v": #selector(NSText.paste(_:)), "c": #selector(NSText.copy(_:)),
                                           "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
                                           "z": Selector(("undo:"))]
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers, let action = editing[key],
           NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct RowView: View {
    let item: Item
    let checked: Bool
    let editing: Bool
    let flashing: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                if let q = item.quote {
                    HStack(spacing: 6) {
                        Rectangle().fill(.secondary.opacity(0.5)).frame(width: 2)
                        Text(q).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }.fixedSize(horizontal: false, vertical: true)
                }
                if !item.note.isEmpty { Text(item.note).lineLimit(6) }
                Text([item.app, Self.ago.localizedString(for: item.created, relativeTo: Date())]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)
            .help("Click to add or edit a note")
            Button(action: onDelete) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(background)
        .animation(.easeOut(duration: 0.4), value: flashing)
        .onHover { hover = $0 }
    }

    private var background: Color {
        if flashing { return Color.accentColor.opacity(0.22) }
        if editing { return Color.accentColor.opacity(0.12) }
        return checked ? Color.accentColor.opacity(0.06) : .clear
    }

    static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

struct WidgetView: View {
    @ObservedObject var store: Store
    let done: () -> Void
    let copy: () -> Void
    let paste: () -> Void
    /// Makes the panel key so the composer can take typing.
    let focus: () -> Void
    @AppStorage("clearAfter") private var clearAfter = true
    @FocusState private var composerFocused: Bool
    @State private var status: String?

    var body: some View {
        VStack(spacing: 0) {
            if !store.trusted { permissionBanner }
            sectionBar
            list
            Divider()
            composer
            Divider()
            footer
        }
        .frame(minWidth: 300, minHeight: 200)
        .onChange(of: store.focusRequest) { composerFocused = true }
    }

    private var permissionBanner: some View {
        Button(action: Keys.openAccessibilitySettings) {
            Label("Allow Accessibility so ⇧⇧ and Paste work →", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(Color.yellow.opacity(0.25))
        }.buttonStyle(.plain)
    }

    /// Only shown once a named section exists; until then Jot is a single list.
    @ViewBuilder private var sectionBar: some View {
        if !store.sections.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    tab(nil, "Inbox")
                    ForEach(store.sections) { section in
                        tab(section.id, section.name).contextMenu {
                            Button("Rename…") {
                                store.switchTo(section.id)
                                startCommand("/rename \(section.name)")
                            }
                            Button("Delete Section and Notes", role: .destructive) { store.deleteSection(section.id) }
                        }
                    }
                    Button { startCommand("/new ") } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("New section (/new)")
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            Divider()
        }
    }

    private func tab(_ id: UUID?, _ name: String) -> some View {
        let on = store.active == id
        let n = store.count(in: id)
        return HStack(spacing: 4) {
            Text(name).lineLimit(1)
            if n > 0 { Text("\(n)").foregroundStyle(.secondary) }
        }
        .font(.caption.weight(on ? .semibold : .regular))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(on ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Capsule())
        .onTapGesture { store.switchTo(id) }
        .help(on ? "Writing here" : "Switch here (⇧⇥ cycles)")
    }

    private func startCommand(_ text: String) {
        store.editing = nil
        store.draft = text
        store.focusRequest += 1
        focus()
    }

    @ViewBuilder private var list: some View {
        if store.current.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.activeName.map { "Nothing in \($0) yet" } ?? "Nothing jotted yet").font(.headline)
                Group {
                    Text("⇧⇧  capture selection")
                    Text("⌘⌘  note / annotate capture")
                    Text("⌃⌃  paste at your cursor")
                    Text(store.sections.isEmpty ? "/new  start a named section" : "⇧⇥  switch section")
                }.font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.current) { item in
                            RowView(item: item, checked: store.selected.contains(item.id),
                                    editing: store.editing == item.id, flashing: store.flashID == item.id,
                                    onToggle: { store.toggle(item.id) },
                                    onEdit: { store.edit(item); focus() },
                                    onDelete: { store.remove([item.id]) })
                                .id(item.id)
                            Divider()
                        }
                    }
                }
                .onChange(of: store.flashID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.suggestions) { s in
                HStack(spacing: 8) {
                    Text(s.label).font(.system(.caption, design: .monospaced))
                    Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { store.draft = s.completion; store.focusRequest += 1 }
            }
            if let id = store.editing, let item = store.items.first(where: { $0.id == id }) {
                HStack(spacing: 4) {
                    Text("↳ note on: \(item.quote ?? item.note)").lineLimit(1)
                    Spacer()
                    Button { store.editing = nil; store.draft = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            TextField(store.editing != nil ? "Add a note…"
                      : "Jot \(store.activeName.map { "in \($0)" } ?? "a thought")…   / for commands",
                      text: $store.draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...6)
                .focused($composerFocused)
                .onSubmit {
                    if store.editing == nil && store.draft.hasPrefix("/") { return runCommand() }
                    let release = store.releaseOnSubmit
                    store.commitDraft()
                    if release { done() } else { composerFocused = true }
                }
                .onExitCommand { store.cancelDraft(); done() }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func runCommand() {
        switch store.runCommand() {
        case .done(let message):
            if let message { flash(message) }
            composerFocused = true
        case .copy:
            copy()
            flash("Copied ✓")
            composerFocused = true
        case .paste:
            paste()
        case .failed(let message):
            flash(message)
            composerFocused = true
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            let n = store.current.count
            let all = n > 0 && store.selected.count == n
            Button(all ? "None" : "All", action: store.toggleAll)
                .keyboardShortcut("a", modifiers: [.command, .shift])
            if store.undo != nil {
                Button("Undo") { store.undoRemove() }
            } else {
                Text(status ?? (store.selected.isEmpty ? "\(n)" : "\(store.selected.count)/\(n)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { store.removeBulk(Set(store.targets.map(\.id))) } label: { Image(systemName: "trash") }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .help(store.selected.isEmpty ? "Clear all (⌘⇧⌫)" : "Clear checked (⌘⇧⌫)")
            Toggle("Clear after", isOn: $clearAfter).toggleStyle(.checkbox).font(.caption)
                .help("Remove items once copied or pasted")
            Button("Copy") { copy(); flash("Copied ✓") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy to clipboard (⌘⇧C)")
            Button("Paste", action: paste).buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Paste at your cursor (⌃⌃ anywhere, ⌘↩ here)")
        }
        .controlSize(.small).padding(8).disabled(store.current.isEmpty && store.undo == nil)
    }

    private func flash(_ text: String) {
        status = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { status = nil }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store()
    var widget: WidgetPanel!
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    lazy var taps = DoubleTap { [weak self] mod in
        switch mod {
        case .shift: self?.captureSelection()
        case .command: self?.beginNote()
        case .control: self?.pasteItems()
        }
    }
    /// True while the widget is open only because ⌘⌘ summoned it from the menu bar.
    private var summoned = false
    /// The app to reactivate when you leave the composer.
    private var returnTo: NSRunningApplication?

    private var clearAfter: Bool { UserDefaults.standard.object(forKey: "clearAfter") as? Bool ?? true }

    func applicationDidFinishLaunching(_ note: Notification) {
        log("launch: trusted=\(Keys.trusted)")
        buildWidget()
        buildStatusItem()
        taps.install()
        // Inside the widget: ⇧⇥ cycles sections, ⇥ completes a /command.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.widget.isKeyWindow, e.keyCode == 48 else { return e }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .shift, !self.store.sections.isEmpty { self.store.cycle(1); return nil }
            if mods.isEmpty, self.store.autocomplete() { return nil }
            return e
        }
        if !Keys.trusted { Keys.promptForAccess() }
        // Access gets revoked on every rebuild (ad-hoc signature); watch it so the banner
        // stays honest, and reinstall monitors when granted since they go deaf without it.
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, self.store.trusted != Keys.trusted else { return }
            self.store.trusted = Keys.trusted
            log("trust changed: \(Keys.trusted)")
            if Keys.trusted { self.taps.install() }
        }
        if UserDefaults.standard.object(forKey: "widgetVisible") as? Bool ?? true {
            widget.orderFrontRegardless()
        }
    }

    // MARK: Widget

    private func buildWidget() {
        let panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.title = "Jot"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: WidgetView(
            store: store,
            done: { [weak self] in self?.releaseFocus() },
            copy: { [weak self] in self?.copyItems() },
            paste: { [weak self] in self?.pasteItems() },
            focus: { [weak self] in self?.widget.makeKey() }))
        if !panel.setFrameUsingName("JotWidget"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 380, y: screen.maxY - 460))
        }
        panel.setFrameAutosaveName("JotWidget")
        widget = panel
    }

    /// The close button tucks Jot into the menu bar instead of quitting.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        setWidgetVisible(false)
        return false
    }

    private func setWidgetVisible(_ visible: Bool) {
        summoned = false
        if visible { widget.orderFrontRegardless() } else { widget.orderOut(nil) }
        UserDefaults.standard.set(visible, forKey: "widgetVisible")
    }

    @objc func toggleWidget() { setWidgetVisible(!widget.isVisible) }

    /// Hands the keyboard back to the app you were in (the panel never activated Jot,
    /// so ordering it out returns key focus without switching apps).
    /// Typing in the widget activates Jot (dictation tools only insert into the frontmost app's
    /// focused field); remember who was frontmost so we can hand focus back.
    func windowDidBecomeKey(_ notification: Notification) {
        guard !NSApp.isActive else { return }
        let front = NSWorkspace.shared.frontmostApplication
        returnTo = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidResignActive(_ notification: Notification) { returnTo = nil }

    /// Hands the keyboard back to the app you were in.
    private func releaseFocus() {
        guard widget.isKeyWindow else { return }
        widget.orderOut(nil)
        if summoned { summoned = false } else { widget.orderFrontRegardless() }
        if let app = returnTo {
            returnTo = nil
            NSApp.yieldActivation(to: app)
            app.activate()
        }
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Jot")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        menu = NSMenu()
        menu.addItem(withTitle: "Show / Hide Widget", action: #selector(toggleWidget), keyEquivalent: "")
        menu.addItem(withTitle: "Paste at Cursor  (⌃⌃)", action: #selector(pasteFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copyFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Clear", action: #selector(clearFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(withTitle: "Accessibility Permission…", action: #selector(openAccessibility), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Jot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }

        store.onChange = { [weak self] in self?.storeChanged() }
        storeChanged()
    }

    /// Menu-bar count and widget title follow the active section.
    private func storeChanged() {
        let n = store.current.count
        statusItem.button?.title = n > 0 ? "\(n)" : ""
        widget.title = store.activeName.map { "Jot · \($0)" } ?? "Jot"
    }

    private static let sectionItemTag = 7

    /// Lists sections at the top of the menu (✓ = where you're writing) once any exist.
    private func refreshSectionsMenu() {
        menu.items.filter { $0.tag == Self.sectionItemTag }.forEach(menu.removeItem)
        guard !store.sections.isEmpty else { return }
        let entries: [(UUID?, String)] = [(nil, "Inbox")] + store.sections.map { ($0.id, $0.name) }
        var items = entries.map { id, name -> NSMenuItem in
            let item = NSMenuItem(title: "\(name)  (\(store.count(in: id)))", action: #selector(switchSection(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = store.active == id ? .on : .off
            return item
        }
        items.append(.separator())
        for (i, item) in items.enumerated() {
            item.tag = Self.sectionItemTag
            menu.insertItem(item, at: i)
        }
    }

    @objc private func switchSection(_ sender: NSMenuItem) { store.switchTo(sender.representedObject as? UUID) }

    /// Left click toggles the widget, right click opens the menu.
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            refreshSectionsMenu()
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleWidget()
        }
    }

    private func pulseStatus(_ symbol: String) {
        let button = statusItem.button
        button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Jot")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            button?.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Jot")
        }
    }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch { NSSound.beep() }
        sender.state = svc.status == .enabled ? .on : .off
    }

    @objc func openAccessibility() { Keys.openAccessibilitySettings() }

    // MARK: Actions

    private func captureSelection() {
        guard !widget.isKeyWindow else { return }
        guard Keys.trusted else {
            log("capture: blocked, Accessibility not granted")
            pulseStatus("exclamationmark.triangle")
            return Keys.openAccessibilitySettings()
        }
        let source = NSWorkspace.shared.frontmostApplication?.localizedName
        Keys.copySelection { [weak self] text in
            guard let self else { return }
            guard let text else { return self.pulseStatus("minus.circle") }
            self.store.capture(text, app: source)
            self.pulseStatus("checkmark.circle.fill")
            // Straight into annotating it; ↩ saves and hands focus back, esc skips the note.
            self.beginNote()
            self.store.releaseOnSubmit = true
        }
    }

    private func beginNote() {
        if widget.isKeyWindow { return releaseFocus() }
        if !widget.isVisible {
            summoned = true
            widget.orderFrontRegardless()
        }
        store.beginNote()
        widget.makeKey()
    }

    private func copyItems() {
        let items = store.targets
        guard !items.isEmpty else { return NSSound.beep() }
        Keys.setClipboard(Store.render(items))
        if clearAfter { store.removeBulk(Set(items.map(\.id))) }
    }

    private func pasteItems() {
        let items = store.targets
        guard !items.isEmpty else { return NSSound.beep() }
        Keys.setClipboard(Store.render(items))
        // Without Accessibility we can't send ⌘V; leave it on the clipboard and keep the items.
        guard Keys.trusted else { return Keys.openAccessibilitySettings() }
        let wasTyping = widget.isKeyWindow
        releaseFocus()
        // Give the app we hand focus back to a moment to become active before ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasTyping ? 0.3 : 0.08)) {
            Keys.sendCommand(9) // kVK_ANSI_V
            log("paste: \(items.count) items")
            if self.clearAfter { self.store.removeBulk(Set(items.map(\.id))) }
        }
    }

    @objc private func copyFromMenu() { copyItems() }

    @objc private func clearFromMenu() { store.removeBulk(Set(store.targets.map(\.id))) }

    @objc private func pasteFromMenu() {
        // Let the menu finish closing so ⌘V lands in the app underneath.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.pasteItems() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
