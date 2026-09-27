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
}

final class Store: ObservableObject {
    @Published var items: [Item] = [] {
        didSet { save(); onCountChange?(items.count) }
    }
    @Published var selected: Set<UUID> = []
    /// Composer state: `editing` is the item the draft annotates (nil = new note).
    @Published var editing: UUID?
    @Published var draft = ""
    @Published var focusRequest = 0
    /// Set when ⇧⇧ opened the composer: saving the note returns you to your app.
    var releaseOnSubmit = false
    @Published var flashID: UUID?
    @Published var trusted = Keys.trusted
    /// Items as they were before the last bulk removal, offered as a short-lived undo.
    @Published var undo: [Item]?

    var onCountChange: ((Int) -> Void)?
    private var lastCapture: (id: UUID, at: Date)?

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("items.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
    }

    func capture(_ quote: String, app: String?) {
        let item = Item(quote: quote, note: "", app: app)
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
           let item = items.first(where: { $0.id == last.id }), item.note.isEmpty {
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
            let item = Item(quote: nil, note: text, app: nil)
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

    /// Checked items if any are checked, otherwise everything.
    var targets: [Item] {
        selected.isEmpty ? items : items.filter { selected.contains($0.id) }
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selected.subtract(ids)
        if let e = editing, ids.contains(e) { cancelDraft() }
    }

    /// Removes several items at once, keeping an undo for a few seconds.
    func removeBulk(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = items
        remove(ids)
        undo = before
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.undo == before { self?.undo = nil }
        }
    }

    func undoRemove() {
        guard let before = undo else { return }
        items = before
        undo = nil
    }

    func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func toggleAll() {
        selected = selected.count == items.count ? [] : Set(items.map(\.id))
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
    @AppStorage("clearAfter") private var clearAfter = true
    @FocusState private var composerFocused: Bool
    @State private var status: String?

    var body: some View {
        VStack(spacing: 0) {
            if !store.trusted { permissionBanner }
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

    @ViewBuilder private var list: some View {
        if store.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing jotted yet").font(.headline)
                Group {
                    Text("⇧⇧  capture selection")
                    Text("⌘⌘  note / annotate capture")
                    Text("⌃⌃  paste at your cursor")
                }.font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.items) { item in
                            RowView(item: item, checked: store.selected.contains(item.id),
                                    editing: store.editing == item.id, flashing: store.flashID == item.id,
                                    onToggle: { store.toggle(item.id) },
                                    onEdit: { store.edit(item) },
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
            if let id = store.editing, let item = store.items.first(where: { $0.id == id }) {
                HStack(spacing: 4) {
                    Text("↳ note on: \(item.quote ?? item.note)").lineLimit(1)
                    Spacer()
                    Button { store.editing = nil; store.draft = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            TextField(store.editing == nil ? "Jot a thought…  (⌘⌘)" : "Add a note…",
                      text: $store.draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...6)
                .focused($composerFocused)
                .onSubmit {
                    let release = store.releaseOnSubmit
                    store.commitDraft()
                    if release { done() } else { composerFocused = true }
                }
                .onExitCommand { store.cancelDraft(); done() }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            let all = !store.items.isEmpty && store.selected.count == store.items.count
            Button(all ? "None" : "All", action: store.toggleAll)
                .keyboardShortcut("a", modifiers: [.command, .shift])
            if store.undo != nil {
                Button("Undo") { store.undoRemove() }
            } else {
                Text(status ?? (store.selected.isEmpty ? "\(store.items.count)"
                                                       : "\(store.selected.count)/\(store.items.count)"))
                    .font(.caption).foregroundStyle(.secondary)
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
        .controlSize(.small).padding(8).disabled(store.items.isEmpty && store.undo == nil)
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
            paste: { [weak self] in self?.pasteItems() }))
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

        store.onCountChange = { [weak self] n in
            self?.statusItem.button?.title = n > 0 ? "\(n)" : ""
        }
        store.onCountChange?(store.items.count)
    }

    /// Left click toggles the widget, right click opens the menu.
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
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
