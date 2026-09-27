// Jot — a floating scratchpad for thoughts/questions while reviewing AI output.
//
// Hotkeys (global):
//   ⌃⌥C  capture current selection (+ optional note)
//   ⌃⌥N  add a note only
//   ⌃⌥V  paste checked items (or all) at the cursor, then clear them
//   ⌃⌥J  show / hide the widget

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// MARK: - Model

struct Item: Codable, Identifiable, Equatable {
    var id = UUID()
    var quote: String?
    var note: String
    var app: String?
    var created = Date()
}

final class Store: ObservableObject {
    @Published var items: [Item] = [] { didSet { save() } }
    @Published var selected: Set<UUID> = []

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

    func add(quote: String?, note: String, app: String?) {
        items.append(Item(quote: quote, note: note, app: app))
    }

    /// Checked items if any are checked, otherwise everything.
    var targets: [Item] {
        selected.isEmpty ? items : items.filter { selected.contains($0.id) }
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selected.subtract(ids)
    }

    func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
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

    /// The hotkey's ⌃⌥ are usually still held when it fires; wait for release so they
    /// don't mix into the synthetic ⌘C / ⌘V.
    static func afterModifiersReleased(_ then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(0.6)
        func check() {
            let held = CGEventSource.flagsState(.hidSystemState)
                .intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
            if held.isEmpty || Date() > deadline { then() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.015, execute: check) }
        }
        check()
    }

    static func sendCommand(_ key: Int) {
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: down)
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

    /// Sends ⌘C to the frontmost app, reads what it copied, then puts the old clipboard back.
    static func copySelection(_ completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let snap = snapshot(pb)
        let start = pb.changeCount
        sendCommand(kVK_ANSI_C)
        var tries = 0
        func poll() {
            if pb.changeCount != start {
                let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
                restore(pb, snap)
                completion(text?.isEmpty == false ? text : nil)
            } else if tries >= 25 {
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

enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef?] = []

    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKeys.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func register(_ key: Int, _ handler: @escaping () -> Void) {
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: OSType(0x4A4F_5421), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

// MARK: - Note popup

final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

struct NoteView: View {
    @State var quote: String?
    let app: String?
    let onSave: (String?, String) -> Void
    let onCancel: () -> Void
    @State private var note = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let q = quote {
                HStack(alignment: .top, spacing: 8) {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                    Text(q).font(.callout).foregroundStyle(.secondary).lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { quote = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("Drop the selection, keep note only")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            TextField(quote == nil ? "Note…" : "Add a note (optional)…", text: $note, axis: .vertical)
                .textFieldStyle(.plain).font(.title3).lineLimit(1...8)
                .focused($focused)
                .onSubmit(submit)
            HStack {
                Text(app.map { "from \($0)" } ?? "").lineLimit(1)
                Spacer()
                Text("↩ save   esc cancel")
            }
            .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onExitCommand(perform: onCancel)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func submit() {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if quote == nil && n.isEmpty { onCancel() } else { onSave(quote, n) }
    }
}

// MARK: - Widget

struct RowView: View {
    let item: Item
    let checked: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(checked ? Color.accentColor : .secondary)
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
            Button(action: onDelete) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(checked ? Color.accentColor.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hover = $0 }
    }

    static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

struct WidgetView: View {
    @ObservedObject var store: Store
    let copy: (_ clear: Bool) -> Void
    @State private var flash: String?

    var body: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing jotted yet").font(.headline)
                    Group {
                        Text("⌃⌥C  capture selection + note")
                        Text("⌃⌥N  note only")
                        Text("⌃⌥V  paste at cursor & clear")
                        Text("⌃⌥J  show / hide this")
                    }.font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.items) { item in
                            RowView(item: item, checked: store.selected.contains(item.id),
                                    onToggle: { store.toggle(item.id) },
                                    onDelete: { store.remove([item.id]) })
                            Divider()
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                let all = !store.items.isEmpty && store.selected.count == store.items.count
                Button(all ? "None" : "All") {
                    store.selected = all ? [] : Set(store.items.map(\.id))
                }.disabled(store.items.isEmpty)
                Text(flash ?? (store.selected.isEmpty ? "\(store.items.count) items"
                                                      : "\(store.selected.count) of \(store.items.count)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { run(clear: false) }
                Button("Copy & Clear") { run(clear: true) }.buttonStyle(.borderedProminent)
            }
            .controlSize(.small).padding(8).disabled(store.items.isEmpty)
        }
        .frame(minWidth: 280, minHeight: 160)
    }

    private func run(clear: Bool) {
        copy(clear)
        flash = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { flash = nil }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var widget: NSPanel!
    var popup: KeyPanel?
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        buildWidget()
        buildMenu()
        HotKeys.install()
        HotKeys.register(kVK_ANSI_C) { [weak self] in self?.capture(withSelection: true) }
        HotKeys.register(kVK_ANSI_N) { [weak self] in self?.capture(withSelection: false) }
        HotKeys.register(kVK_ANSI_V) { [weak self] in self?.pasteAndClear() }
        HotKeys.register(kVK_ANSI_J) { [weak self] in self?.toggleWidget() }
        if !Keys.trusted { Keys.promptForAccess() }
        widget.orderFrontRegardless()
    }

    private func buildWidget() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Jot"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: WidgetView(store: store) { [weak self] clear in
            self?.copy(clear: clear)
        })
        if !panel.setFrameUsingName("JotWidget"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 360, y: screen.maxY - 440))
        }
        panel.setFrameAutosaveName("JotWidget")
        widget = panel
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Jot")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show / Hide  (⌃⌥J)", action: #selector(toggleWidget), keyEquivalent: "")
        menu.addItem(withTitle: "New Note  (⌃⌥N)", action: #selector(newNote), keyEquivalent: "")
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(withTitle: "Accessibility Permission…", action: #selector(openAccessibility), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Jot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu
    }

    @objc func toggleWidget() {
        if widget.isVisible { widget.orderOut(nil) } else { widget.orderFrontRegardless() }
    }

    @objc func newNote() { capture(withSelection: false) }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch { NSSound.beep() }
        sender.state = svc.status == .enabled ? .on : .off
    }

    @objc func openAccessibility() {
        Keys.promptForAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func capture(withSelection: Bool) {
        guard popup == nil else { return }
        let source = NSWorkspace.shared.frontmostApplication
        let appName = source?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : source?.localizedName
        guard withSelection else { return showPopup(quote: nil, app: appName, returnTo: source) }
        guard Keys.trusted else {
            Keys.promptForAccess()
            return showPopup(quote: nil, app: appName, returnTo: source)
        }
        Keys.afterModifiersReleased {
            Keys.copySelection { text in self.showPopup(quote: text, app: appName, returnTo: source) }
        }
    }

    private func showPopup(quote: String?, app: String?, returnTo source: NSRunningApplication?) {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        var closed = false
        let close = { [weak self, weak panel] in
            guard !closed else { return }
            closed = true
            panel?.orderOut(nil)
            self?.popup = nil
            if let source, source.bundleIdentifier != Bundle.main.bundleIdentifier {
                NSApp.yieldActivation(to: source)
                source.activate()
            }
        }
        panel.onCancel = close
        let view = NoteView(quote: quote, app: app, onSave: { [weak self] q, n in
            self?.store.add(quote: q, note: n, app: app)
            close()
        }, onCancel: close)
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let f = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - f.height * 0.22))

        popup = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func copy(clear: Bool) {
        let items = store.targets
        guard !items.isEmpty else { return NSSound.beep() }
        Keys.setClipboard(Store.render(items))
        if clear { store.remove(Set(items.map(\.id))) }
    }

    private func pasteAndClear() {
        let items = store.targets
        guard !items.isEmpty else { return NSSound.beep() }
        Keys.setClipboard(Store.render(items))
        // Without Accessibility we can't send ⌘V; leave it on the clipboard and keep the items.
        guard Keys.trusted else { return Keys.promptForAccess() }
        Keys.afterModifiersReleased {
            Keys.sendCommand(kVK_ANSI_V)
            self.store.remove(Set(items.map(\.id)))
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
