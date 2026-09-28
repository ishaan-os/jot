// Renders Jot's README media (demo.gif, demo.mp4, hero.png, widget.png) from a scripted
// SwiftUI mock scene — no screen recording, nothing from a real desktop.
//
//   swiftc -O -swift-version 5 promo/Promo.swift -o promo/bin/promo && promo/bin/promo assets
//
// The widget here is a pixel-level lookalike of main.swift's WidgetView built from plain
// shapes, because ImageRenderer can't draw AppKit-backed controls (TextField, Toggle, …).

import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Script

let W: CGFloat = 1280, H: CGFloat = 800
let selectionBlue = Color(red: 0.70, green: 0.84, blue: 1.0)
let accent = Color(red: 0.0, green: 0.48, blue: 1.0)
let ink = Color(red: 0.13, green: 0.14, blue: 0.16)

enum Surface: String { case terminal = "Terminal", doc = "Docs", pr = "Browser" }

let sectionName = "rate-limit review"
let newCommand = "/new \(sectionName)"

// Terminal agent session
let termLines = [
    "> add rate limiting to the public API",
    "",
    "● I'll add a token-bucket limiter as middleware.",
    "● Limit: 100 req/min per API key, stored in process memory.",
    "● Updated api/middleware.py and api/app.py",
    "✓ 14 tests passed",
]
let termSel = "stored in process memory."
let termNote = "won't hold across instances — redis?"

// Design doc
let docBlocks: [(heading: Bool, text: String)] = [
    (true, "Overview"),
    (false, "Public API requests are limited per API key to protect shared infrastructure from noisy clients."),
    (true, "Behavior"),
    (false, "Each key gets 100 requests per minute. Limits reset at the top of every minute."),
    (false, "Requests over the limit receive a 429 response and are not queued."),
]
let docSel = "Limits reset at the top of every minute."
let docNote = "fixed window → bursts at :00; sliding?"

// Pull request diff: (marker, old line, new line, code)
let diffLines: [(Character, Int?, Int?, String)] = [
    (" ", 10, 10, "def rate_limit(handler):"),
    (" ", 11, 11, "    def wrapped(request):"),
    ("-", 12, nil, "        return handler(request)"),
    ("+", nil, 12, "        bucket = buckets[request.api_key]"),
    ("+", nil, 13, "        if not bucket.take():"),
    ("+", nil, 14, "            return Response(status=429)"),
    ("+", nil, 15, "        return handler(request)"),
    (" ", 13, 16, "    return wrapped"),
]
let prSel = "return Response(status=429)"
let prNote = "missing Retry-After header"
let thought = "ask for a load test before merge"

struct DemoItem: Equatable {
    var quote: String?
    var note: String
    var app: String?
    var age = "now"
}

struct SceneState {
    var surface = Surface.terminal
    var section: String?
    var items: [DemoItem] = []
    var flashIndex: Int?
    var highlight: (sentence: String, progress: Double)?
    var composerTarget: String?
    var composerText = ""
    var composerFocused = false
    var termInput = ""
    var termFocused = false
    var keys: (caps: [String], label: String, opacity: Double)?
    var caretOn = true
    var menuSymbol = "text.quote"
    var endCard = 0.0
}

/// Progress of t through [a, b], clamped to 0…1.
func p(_ t: Double, _ a: Double, _ b: Double) -> Double { min(max((t - a) / (b - a), 0), 1) }
func typed(_ s: String, _ t: Double, _ a: Double, _ b: Double) -> String {
    String(s.prefix(Int((Double(s.count) * p(t, a, b)).rounded())))
}
func keycaps(_ t: Double, _ a: Double, _ b: Double, _ caps: [String], _ label: String) -> (caps: [String], label: String, opacity: Double)? {
    guard t >= a, t <= b else { return nil }
    return (caps, label, min(p(t, a, a + 0.12), 1 - p(t, b - 0.2, b)))
}

let duration = 23.0

/// One select → ⇧⇧ → type note → ↩ beat starting at `t0`.
func captureBeat(_ s: inout SceneState, _ t: Double, t0: Double, index: Int, surface: Surface, sel: String,
                 note: String, label: String) {
    if t >= t0 && t < t0 + 3.2 { s.highlight = (sel, p(t, t0, t0 + 0.6)) }
    if let k = keycaps(t, t0 + 0.7, t0 + 1.4, ["⇧", "⇧"], label) { s.keys = k }
    guard t >= t0 + 0.8 else { return }
    let done = t >= t0 + 2.8
    s.items.append(DemoItem(quote: sel, note: done ? note : "", app: surface.rawValue))
    if t < t0 + 1.6 || (done && t < t0 + 3.4) { s.flashIndex = index }
    if !done {
        s.composerTarget = sel
        s.composerFocused = true
        s.composerText = typed(note, t, t0 + 1.1, t0 + 2.5)
    }
    if let k = keycaps(t, t0 + 2.6, t0 + 3.1, ["↩"], "save — keep reviewing") { s.keys = k }
}

func state(at t: Double) -> SceneState {
    var s = SceneState()
    s.caretOn = Int(t * 2.2) % 2 == 0
    s.surface = t < 6.6 ? .terminal : t < 10.6 ? .doc : t < 17.0 ? .pr : .terminal

    // ⌘⌘ → /new: everything from here on lands in the new section
    if let k = keycaps(t, 0.5, 1.2, ["⌘", "⌘"], "open the note field") { s.keys = k }
    if t >= 0.7 && t < 2.35 {
        s.composerFocused = true
        s.composerText = typed(newCommand, t, 0.9, 2.0)
    }
    if let k = keycaps(t, 2.1, 2.7, ["↩"], "start a section") { s.keys = k }
    if t >= 2.35 { s.section = sectionName }

    captureBeat(&s, t, t0: 3.0, index: 0, surface: .terminal, sel: termSel, note: termNote, label: "capture from the agent")
    captureBeat(&s, t, t0: 7.0, index: 1, surface: .doc, sel: docSel, note: docNote, label: "capture from the doc")
    captureBeat(&s, t, t0: 11.0, index: 2, surface: .pr, sel: prSel, note: prNote, label: "capture from the diff")

    // ⌘⌘ a free-standing thought
    if let k = keycaps(t, 14.7, 15.4, ["⌘", "⌘"], "jot a thought") { s.keys = k }
    if t >= 14.9 && t < 16.55 {
        s.composerFocused = true
        s.composerText = typed(thought, t, 15.2, 16.2)
    }
    if let k = keycaps(t, 16.3, 16.8, ["↩"], "save") { s.keys = k }
    if t >= 16.55 {
        s.items.append(DemoItem(quote: nil, note: thought, app: nil))
        if t < 17.2 { s.flashIndex = 3 }
    }

    // Back in the agent: ⌃⌃ pastes this section at the prompt and clears it
    if t >= 17.0 { s.termFocused = true }
    if let k = keycaps(t, 17.5, 18.3, ["⌃", "⌃"], "paste into the agent") { s.keys = k }
    if t >= 17.75 {
        s.termInput = render(s.items)
        s.items = []
        s.flashIndex = nil
        if t < 18.5 { s.menuSymbol = "checkmark.circle.fill" }
    }
    s.endCard = p(t, 20.0, 20.6)
    return s
}

func render(_ items: [DemoItem]) -> String {
    items.map { item in
        var parts: [String] = []
        if let q = item.quote { parts.append("> " + q) }
        if !item.note.isEmpty { parts.append(item.note) }
        return parts.joined(separator: "\n")
    }.joined(separator: "\n\n")
}

/// `text` with the first `progress` of `sel` given a selection background.
func highlighted(_ text: String, _ h: (sentence: String, progress: Double)?,
                 color: Color = selectionBlue) -> AttributedString {
    var a = AttributedString(text)
    if let h, let r = a.range(of: h.sentence) {
        let end = a.index(r.lowerBound, offsetByCharacters: Int(Double(h.sentence.count) * h.progress))
        a[r.lowerBound..<end].backgroundColor = color
    }
    return a
}

// MARK: - Scene views

struct Caret: View {
    var on: Bool
    var body: some View { Rectangle().fill(accent).frame(width: 1.5, height: 16).opacity(on ? 1 : 0) }
}

struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1.0, green: 0.86, blue: 0.62), Color(red: 0.98, green: 0.55, blue: 0.36)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 1.0, green: 0.96, blue: 0.84).opacity(0.9), .clear],
                           center: UnitPoint(x: 0.15, y: 0.1), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.90, green: 0.33, blue: 0.30).opacity(0.7), .clear],
                           center: UnitPoint(x: 0.9, y: 0.95), startRadius: 0, endRadius: 560)
        }
    }
}

struct MenuBar: View {
    var app: String
    var count: Int
    var symbol: String
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
            Text(app).font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "Window"], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                if count > 0 { Text("\(count)").font(.system(size: 12, weight: .semibold)) }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.25)))
            Image(systemName: "wifi").font(.system(size: 13))
            Image(systemName: "battery.75percent").font(.system(size: 15))
            Text("Sun 9:41 AM").font(.system(size: 13))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(.white.opacity(0.45))
    }
}

struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                     Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
        }
    }
}

struct WindowChrome<Content: View>: View {
    var title: String
    var dark = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack { TrafficLights(); Spacer() }
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dark ? Color(white: 0.7) : .secondary)
            }
            .padding(.horizontal, 14).frame(height: 38)
            .background(dark ? Color(white: 0.16) : Color(white: 0.965))
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(dark ? Color(red: 0.09, green: 0.10, blue: 0.12) : .white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 16)
    }
}

struct TerminalWindow: View {
    var s: SceneState
    let green = Color(red: 0.45, green: 0.85, blue: 0.55)
    let fg = Color(white: 0.88)

    var body: some View {
        WindowChrome(title: "agent — ~/api", dark: true) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(termLines, id: \.self) { line in
                    Text(highlighted(line, s.highlight, color: Color(red: 0.22, green: 0.38, blue: 0.62)))
                        .foregroundStyle(line.hasPrefix("✓") ? green : line.hasPrefix(">") ? Color(white: 0.6) : fg)
                }
                Spacer(minLength: 0)
                Rectangle().fill(Color(white: 0.25)).frame(height: 1)
                HStack(alignment: .top, spacing: 8) {
                    Text(">").foregroundStyle(green)
                    if s.termInput.isEmpty {
                        if s.termFocused { Rectangle().fill(fg).frame(width: 8, height: 16).opacity(s.caretOn ? 1 : 0) }
                    } else {
                        Text(s.termInput).foregroundStyle(fg).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 14, design: .monospaced))
            .padding(22)
        }
    }
}

struct DocWindow: View {
    var s: SceneState
    var body: some View {
        WindowChrome(title: "Rate limiting — design") {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    ForEach(["bold", "italic", "underline", "list.bullet", "link"], id: \.self) {
                        Image(systemName: $0).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Share").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Capsule().fill(accent))
                }
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(Color(white: 0.975))
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Rate limiting").font(.system(size: 28, weight: .bold)).foregroundStyle(ink)
                    Text("Draft · edited just now").font(.system(size: 12)).foregroundStyle(.tertiary)
                    ForEach(Array(docBlocks.enumerated()), id: \.offset) { _, block in
                        if block.heading {
                            Text(block.text).font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                                .padding(.top, 6)
                        } else {
                            Text(highlighted(block.text, s.highlight)).font(.system(size: 15)).lineSpacing(5)
                                .foregroundStyle(ink.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 56).padding(.vertical, 36)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Rectangle().fill(.white).shadow(color: .black.opacity(0.12), radius: 3, y: 1))
                .padding([.horizontal, .top], 32)
            }
            .background(Color(white: 0.94))
        }
    }
}

struct PRWindow: View {
    var s: SceneState
    let red = Color(red: 1.0, green: 0.92, blue: 0.93), redMark = Color(red: 0.8, green: 0.2, blue: 0.25)
    let green = Color(red: 0.90, green: 0.98, blue: 0.91), greenMark = Color(red: 0.13, green: 0.6, blue: 0.3)

    var body: some View {
        WindowChrome(title: "") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left").foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    HStack {
                        Image(systemName: "lock.fill").font(.system(size: 10))
                        Text("code.example.com/acme/api/pull/412")
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.94)))
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
                .background(Color(white: 0.965))
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Add rate limiting to public API").font(.system(size: 22, weight: .semibold))
                        Text("#412").font(.system(size: 22)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Label("Open", systemImage: "arrow.triangle.pull").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(greenMark))
                        Text("agent wants to merge 2 commits · Files changed 2  +38 −4")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(ink)
                .padding(.horizontal, 24).padding(.vertical, 18)
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "chevron.down").font(.system(size: 10))
                        Text("api/middleware.py").font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Spacer()
                        Text("+4 −1").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(white: 0.97))
                    Divider()
                    ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 0) {
                            Text(line.1.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                            Text(line.2.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                            Text(String(line.0)).frame(width: 24)
                                .foregroundStyle(line.0 == "+" ? greenMark : line.0 == "-" ? redMark : .clear)
                            Text(highlighted(line.3, s.highlight)).foregroundStyle(ink)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.vertical, 3)
                        .background(line.0 == "+" ? green : line.0 == "-" ? red : .white)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.85)))
                .padding(.horizontal, 24)
                Spacer(minLength: 0)
            }
        }
    }
}

struct Pill: View {
    var title: String
    var prominent = false
    var body: some View {
        Text(title).font(.system(size: 11, weight: .medium))
            .foregroundStyle(prominent ? .white : ink)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(prominent ? accent : .white)
                .shadow(color: .black.opacity(prominent ? 0 : 0.18), radius: 0.5, y: 0.5))
    }
}

struct WidgetMock: View {
    var s: SceneState

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack { Circle().fill(Color(white: 0.8)).frame(width: 10, height: 10); Spacer() }
                Text(s.section.map { "Jot · \($0)" } ?? "Jot").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).frame(height: 24).background(Color(white: 0.955))
            Divider()
            if let section = s.section {
                HStack(spacing: 4) {
                    tab("Inbox", on: false)
                    tab(section + (s.items.isEmpty ? "" : "  \(s.items.count)"), on: true)
                    Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 2)
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                Divider()
            }
            list.frame(maxHeight: .infinity, alignment: .top)
            Divider()
            composer
            Divider()
            footer
        }
        .background(Color(white: 0.985))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.28), radius: 26, y: 14)
    }

    private func tab(_ title: String, on: Bool) -> some View {
        Text(title).font(.system(size: 11, weight: on ? .semibold : .regular)).foregroundStyle(ink)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(on ? accent.opacity(0.18) : .clear))
    }

    @ViewBuilder private var list: some View {
        if s.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.section.map { "Nothing in \($0) yet" } ?? "Nothing jotted yet").font(.system(size: 13, weight: .semibold))
                ForEach(["⇧⇧  capture selection", "⌘⌘  note / annotate capture", "⌃⌃  paste at your cursor",
                         s.section == nil ? "/new  start a named section" : "⇧⇥  switch section"], id: \.self) {
                    Text($0).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(s.items.enumerated()), id: \.offset) { i, item in
                    row(item, flashing: s.flashIndex == i, editing: item.quote != nil && item.quote == s.composerTarget)
                    Divider()
                }
            }
        }
    }

    private func row(_ item: DemoItem, flashing: Bool, editing: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                if let q = item.quote {
                    HStack(spacing: 6) {
                        Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 2)
                        Text(q).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                    }.fixedSize(horizontal: false, vertical: true)
                }
                if !item.note.isEmpty { Text(item.note).font(.system(size: 13)).foregroundStyle(ink) }
                Text([item.app, item.age].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(flashing ? accent.opacity(0.22) : editing ? accent.opacity(0.12) : .clear)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Mirrors the real composer's /command suggestions while the command name is being typed.
            if s.composerText.hasPrefix("/") && !s.composerText.contains(" ") {
                HStack(spacing: 8) {
                    Text("/new ‹name›").font(.system(size: 11, design: .monospaced)).foregroundStyle(ink)
                    Text("start a section and write to it").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("⇥").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            if let target = s.composerTarget {
                HStack {
                    Text("↳ note on: \(target)").lineLimit(1)
                    Spacer()
                    Image(systemName: "xmark.circle.fill")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                if s.composerText.isEmpty {
                    if s.composerFocused { Caret(on: s.caretOn) }
                    Text(s.composerTarget != nil ? "Add a note…"
                         : "Jot \(s.section.map { "in \($0)" } ?? "a thought")…   / for commands").foregroundStyle(.tertiary)
                } else {
                    Text(s.composerText).foregroundStyle(ink)
                    if s.composerFocused { Caret(on: s.caretOn) }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(s.composerFocused ? accent.opacity(0.05) : .clear)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Pill(title: "All")
            Text("\(s.items.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "trash").font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white).shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5))
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(accent).frame(width: 13, height: 13)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                Text("Clear after").font(.system(size: 11))
            }
            Pill(title: "Copy")
            Pill(title: "Paste", prominent: true)
        }
        .padding(8)
    }
}

struct Keycaps: View {
    var caps: [String]
    var label: String
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Array(caps.enumerated()), id: \.offset) { _, c in
                    Text(c).font(.system(size: 34, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.78)))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.15)))
                }
            }
            Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.6)))
        }
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }
}

struct EndCard: View {
    let icon: NSImage
    var body: some View {
        ZStack {
            Wallpaper()
            VStack(spacing: 22) {
                Image(nsImage: icon).resizable().frame(width: 180, height: 180)
                Text("Jot").font(.system(size: 64, weight: .bold)).foregroundStyle(ink)
                Text("Collect thoughts while you review AI output —\nin your agent, your docs and your PRs.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(ink.opacity(0.8))
                HStack(spacing: 28) {
                    ForEach([("⇧⇧", "capture"), ("⌘⌘", "note"), ("⌃⌃", "paste & clear")], id: \.0) { k, v in
                        HStack(spacing: 8) {
                            Text(k).font(.system(size: 22, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.7)))
                            Text(v).font(.system(size: 20))
                        }
                    }
                }
                .foregroundStyle(ink)
                Text("Three gestures, a few /commands. No setup, no account. Free & open source · macOS 14+").font(.system(size: 16)).foregroundStyle(ink.opacity(0.6))
            }
        }
    }
}

struct Scene: View {
    var s: SceneState
    let icon: NSImage
    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            MenuBar(app: s.surface.rawValue, count: s.items.count, symbol: s.menuSymbol)
            Group {
                switch s.surface {
                case .terminal: TerminalWindow(s: s)
                case .doc: DocWindow(s: s)
                case .pr: PRWindow(s: s)
                }
            }
            .frame(width: 780, height: 700).offset(x: 50, y: 62)
            WidgetMock(s: s).frame(width: 360, height: 560).offset(x: 870, y: 100)
            if let k = s.keys {
                Keycaps(caps: k.caps, label: k.label).opacity(k.opacity)
                    .frame(width: 360, height: 120).offset(x: 870, y: 672)
            }
            EndCard(icon: icon).opacity(s.endCard)
        }
        .frame(width: W, height: H)
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Output

/// ImageRenderer draws blank without a window server session, so render through an
/// offscreen NSHostingView instead (which also means no blur; the wallpaper uses gradients).
@MainActor func image(_ view: some View, scale: CGFloat) -> CGImage {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * scale),
                               pixelsHigh: Int(host.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.cgImage!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    CGImageDestinationFinalize(d)
}

@MainActor func writeGIF(_ url: URL, icon: NSImage, fps: Double, scale: CGFloat) {
    let frames = Int(duration * fps)
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)!
    CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
    for i in 0..<frames {
        CGImageDestinationAddImage(d, image(Scene(s: state(at: Double(i) / fps), icon: icon), scale: scale), props)
    }
    CGImageDestinationFinalize(d)
}

@MainActor func writeMP4(_ url: URL, icon: NSImage, fps: Int32, scale: CGFloat) throws {
    try? FileManager.default.removeItem(at: url)
    let w = Int(W * scale), h = Int(H * scale)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: w,
        kCVPixelBufferHeightKey as String: h,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for i in 0..<Int(duration * Double(fps)) {
        let img = image(Scene(s: state(at: Double(i) / Double(fps)), icon: icon), scale: scale)
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        while !input.isReadyForMoreMediaData { usleep(1000) }
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if let e = writer.error { throw e }
}

_ = NSApplication.shared
MainActor.assumeIsolated {
    let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets")
    let icon = NSImage(contentsOf: out.appendingPathComponent("icon-1024.png"))!
    let only = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "all"

    if only == "all" || only == "stills" {
        writePNG(image(Scene(s: state(at: 13.3), icon: icon), scale: 2), out.appendingPathComponent("hero.png"))
        writePNG(image(WidgetMock(s: state(at: 17.0)).frame(width: 360, height: 560).padding(40)
            .background(Wallpaper()), scale: 2), out.appendingPathComponent("widget.png"))
        for t in [1.6, 4.6, 8.6, 13.3, 15.9, 18.3, 22] {
            try? FileManager.default.createDirectory(atPath: "promo/frames", withIntermediateDirectories: true)
            writePNG(image(Scene(s: state(at: t), icon: icon), scale: 1), URL(fileURLWithPath: "promo/frames/t\(t).png"))
        }
    }
    if only == "all" || only == "gif" { writeGIF(out.appendingPathComponent("demo.gif"), icon: icon, fps: 12, scale: 1) }
    // PNG sequence for encoding elsewhere (e.g. ffmpeg) when AVFoundation's H.264 encoder isn't available.
    if only == "frames" {
        let dir = URL(fileURLWithPath: CommandLine.arguments[3])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<Int(duration * 30) {
            writePNG(image(Scene(s: state(at: Double(i) / 30), icon: icon), scale: 1.5),
                     dir.appendingPathComponent(String(format: "%04d.png", i)))
        }
    }
    if only == "all" || only == "mp4" { do { try writeMP4(out.appendingPathComponent("demo.mp4"), icon: icon, fps: 30, scale: 1.5) } catch { print("mp4 failed:", error) } }
}
