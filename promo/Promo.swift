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

enum Surface: String { case terminal = "Terminal", browser = "Browser", editor = "Editor" }

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

// Browser chat
let browserQuestion = "Advisory locks or SELECT … FOR UPDATE for claiming jobs?"
let browserParas = [
    "Both work. Advisory locks are lighter: no row is touched, so there's no bloat from constant updates.",
    "Advisory locks are released automatically if the session disconnects, so a crashed worker never strands a job.",
    "FOR UPDATE SKIP LOCKED is simpler to reason about if jobs already live in a table.",
]
let browserSel = "Advisory locks are released automatically if the session disconnects"
let browserNote = "true with pgbouncer transaction pooling?"

// Code editor diff
let editorLines: [(String, Character)] = [
    ("def deliver(event):", " "),
    ("    for attempt in range(5):", " "),
    ("        try:", " "),
    ("            return post(event)", " "),
    ("        except Timeout:", " "),
    ("            log.warning(\"retrying\", attempt=attempt)", "+"),
    ("            time.sleep(2 ** attempt)", "+"),
    ("    raise DeliveryFailed(event)", " "),
]
let editorSel = "time.sleep(2 ** attempt)"
let editorNote = "no jitter, and it blocks the worker"
let thought = "overall: ask for a rollout plan"

struct DemoItem: Equatable {
    var quote: String?
    var note: String
    var app: String?
    var age = "now"
}

struct SceneState {
    var surface = Surface.terminal
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

let duration = 20.5

/// One select → ⇧⇧ → type note → ↩ beat starting at `t0`, captured from `surface`.
func captureBeat(_ s: inout SceneState, _ t: Double, t0: Double, index: Int, surface: Surface, sel: String, note: String) {
    if t >= t0 && t < t0 + 3.2 { s.highlight = (sel, p(t, t0, t0 + 0.6)) }
    if let k = keycaps(t, t0 + 0.7, t0 + 1.4, ["⇧", "⇧"], "capture from \(surface.rawValue.lowercased())") { s.keys = k }
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
    s.surface = t < 4.2 ? .terminal : t < 8.1 ? .browser : t < 14.3 ? .editor : .terminal

    captureBeat(&s, t, t0: 0.8, index: 0, surface: .terminal, sel: termSel, note: termNote)
    captureBeat(&s, t, t0: 4.6, index: 1, surface: .browser, sel: browserSel, note: browserNote)
    captureBeat(&s, t, t0: 8.5, index: 2, surface: .editor, sel: editorSel, note: editorNote)

    // ⌘⌘ a free-standing thought
    if let k = keycaps(t, 11.9, 12.6, ["⌘", "⌘"], "jot a thought") { s.keys = k }
    if t >= 12.1 && t < 13.75 {
        s.composerFocused = true
        s.composerText = typed(thought, t, 12.4, 13.4)
    }
    if let k = keycaps(t, 13.5, 14.0, ["↩"], "save") { s.keys = k }
    if t >= 13.75 {
        s.items.append(DemoItem(quote: nil, note: thought, app: nil))
        if t < 14.4 { s.flashIndex = 3 }
    }

    // Back in the agent: ⌃⌃ pastes everything at the prompt and clears Jot
    if t >= 14.3 { s.termFocused = true }
    if let k = keycaps(t, 14.8, 15.6, ["⌃", "⌃"], "paste into the agent") { s.keys = k }
    if t >= 15.05 {
        s.termInput = render(s.items)
        s.items = []
        s.flashIndex = nil
        if t < 15.8 { s.menuSymbol = "checkmark.circle.fill" }
    }
    s.endCard = p(t, 17.3, 17.9)
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

struct BrowserWindow: View {
    var s: SceneState
    var body: some View {
        WindowChrome(title: "") {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left").foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    HStack {
                        Image(systemName: "lock.fill").font(.system(size: 10))
                        Text("chat.example.com")
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.94)))
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
                .background(Color(white: 0.965))
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        Text(browserQuestion).font(.system(size: 15))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.93)))
                    }
                    ForEach(browserParas, id: \.self) { para in
                        Text(highlighted(para, s.highlight)).font(.system(size: 15)).lineSpacing(4)
                            .foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(28)
            }
        }
    }
}

struct EditorWindow: View {
    var s: SceneState
    var body: some View {
        WindowChrome(title: "retry.py — api") { VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("retry.py").font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.white)
                Spacer()
            }
            .background(Color(white: 0.95))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(editorLines.enumerated()), id: \.offset) { i, line in
                    HStack(spacing: 14) {
                        Text("\(i + 12)").foregroundStyle(.tertiary).frame(width: 26, alignment: .trailing)
                        Text(line.1 == "+" ? "+" : " ").foregroundStyle(.green)
                        Text(highlighted(line.0, s.highlight)).foregroundStyle(ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .background(line.1 == "+" ? Color.green.opacity(0.10) : .clear)
                }
            }
            .font(.system(size: 14, design: .monospaced))
            .padding(.vertical, 16)
            Spacer(minLength: 0)
        } }
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
                Text("Jot").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).frame(height: 24).background(Color(white: 0.955))
            Divider()
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

    @ViewBuilder private var list: some View {
        if s.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing jotted yet").font(.system(size: 13, weight: .semibold))
                ForEach(["⇧⇧  capture selection", "⌘⌘  note / annotate capture", "⌃⌃  paste at your cursor"], id: \.self) {
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
                    Text(s.composerTarget == nil ? "Jot a thought…  (⌘⌘)" : "Add a note…").foregroundStyle(.tertiary)
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
                Text("Collect thoughts while you review AI output —\nin every agent, browser and editor.")
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
                Text("Three gestures. No setup, no account. Free & open source · macOS 14+").font(.system(size: 16)).foregroundStyle(ink.opacity(0.6))
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
                case .browser: BrowserWindow(s: s)
                case .editor: EditorWindow(s: s)
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
        writePNG(image(Scene(s: state(at: 10.3), icon: icon), scale: 2), out.appendingPathComponent("hero.png"))
        writePNG(image(WidgetMock(s: state(at: 14.2)).frame(width: 360, height: 560).padding(40)
            .background(Wallpaper()), scale: 2), out.appendingPathComponent("widget.png"))
        for t in [2.5, 6.4, 10.3, 12.9, 15.5, 19] {
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
