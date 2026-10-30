// Editor for the on-screen touch controls. It saves to UserDefaults as you edit (debounced); the in-game overlay (glfw_ios.m)
// reads "zom.touchLayout" when the game starts.
import SwiftUI
import UIKit

// MARK: - Touch layout model

struct TouchItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case stick, aimstick, autoattack, key, mouse, keyboard, hide, mode, firemode, scroll, radial, padstick, padbtn, padtrig }     // pad*: virtual gamepad controls
    var id: String
    var kind: Kind
    var label: String
    var code: Int            // GLFW key code, or mouse button (0 left, 1 right, 2 middle)
    var x: Double            // centre, as a fraction of the screen
    var y: Double
    var size: Double         // points
    // Two-thumb options for key and mouse buttons (all off unless set):
    var dragAim: Bool? = nil         // dragging a finger held on the button also moves the cursor: attack or shove while aiming
    var fireMode: Int? = nil         // nil/0 held while pressed, 1 auto (re-pressed while held), 2 release (one press when the finger lifts)
    var holdLock: Bool? = nil        // a long press keeps the button held until the next tap (e.g. RC for hands-free aiming)
    var holdLockTime: Double? = nil  // seconds before that lock engages; nil = TouchItem.defaultHoldLockTime
    var target: String? = nil        // fire mode toggle: id of the button whose fire mode it cycles
    var slots: [RadialSlot]? = nil   // radial menu: its options, clockwise from the top (2-8)
    var tapSlot: Int? = nil          // radial menu: the option a quick tap sends; nil = a tap does nothing
    var radialShape: Int? = nil      // radial menu: nil/0 ring, 1 arc, 2 column, 3 row (arc, column and row open away from the nearest edge)
    var radialSpread: Double? = nil  // radial menu: spacing multiplier (0.6-1.6, nil = 1), for fitting a dense menu on a small screen
    static let defaultHoldLockTime = 0.5
    var locked: Bool { kind == .hide || kind == .mode }
    /// Half the width and height the control takes on screen (the scroll strip is a tall bar; everything else is round).
    var halfSize: CGSize { kind == .scroll ? CGSize(width: size * 0.3, height: size * 1.1) : CGSize(width: size / 2, height: size / 2) }
    var isStick: Bool { kind == .stick || kind == .aimstick || kind == .padstick }   // HIDE and PAD/TCH can't be removed, or you could lose the controls
}

struct TouchLayout: Codable, Equatable {
    var opacity: Double = 1
    var items: [TouchItem]
}

/// One option of a radial menu: a key, a mouse button, or one of the overlay's own controls.
struct RadialSlot: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case none, key, mouse, keyboard, hide, mode, firemode }
    var id = UUID().uuidString
    var kind: Kind = .none
    var code: Int = 0
    var label: String = ""
    var target: String? = nil        // firemode: the button it switches between Default and Release
}

/// Where a radial menu's options go when it opens. Same maths as radial_layout() in the overlay
/// (native/glfw-ios/glfw_ios.m), so the editor preview matches the game exactly. Keep the two in step.
enum RadialGeometry {
    static func layout(shape: Int, n: Int, center c: CGPoint, button btn: CGFloat, spread: Double, W: CGFloat, H: CGFloat) -> (points: [CGPoint], size: CGSize) {
        let s = max(0.6, min(1.6, spread <= 0 ? 1 : spread))
        let item = shape == 2 ? CGSize(width: 104, height: 38) : CGSize(width: 58, height: 58)
        guard n > 0 else { return ([], item) }
        let side: CGFloat = c.x > W / 2 ? -1 : 1
        var pts: [CGPoint] = []
        func around(_ r: Double, _ deg: Double) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: c.x + CGFloat(r * cos(a)), y: c.y + CGFloat(r * sin(a)))
        }
        switch shape {
        case 1:                                   // arc: away from the nearest edge, evenly spread over a half turn
            let dl = c.x, dr = W - c.x, dt = c.y, db = H - c.y, m = min(dl, dr, dt, db)
            let out: Double = m == dr ? 180 : m == dl ? 0 : m == dt ? 90 : -90
            let sign: Double = (out == 180 || out == 90) ? -1 : 1
            let r = max(80, 64 / (2 * sin(Double.pi / (2 * Double(n))))) * s
            for i in 0..<n { pts.append(around(r, out - 90 * sign + sign * 180 * (Double(i) + 0.5) / Double(n))) }
        case 2:                                   // column: a vertical list beside the button, towards the middle
            let gap = 6 * s
            let x = c.x + side * (btn / 2 + 12 + item.width / 2), total = CGFloat(n) * item.height + CGFloat(n - 1) * gap
            for i in 0..<n { pts.append(CGPoint(x: x, y: c.y - total / 2 + item.height / 2 + CGFloat(i) * (item.height + gap))) }
        case 3:                                   // row: a horizontal list beside the button
            let gap = 6 * s
            for i in 0..<n { pts.append(CGPoint(x: c.x + side * (btn / 2 + 8 + item.width / 2 + CGFloat(i) * (item.width + gap)), y: c.y)) }
        default:                                  // ring: clockwise from the top
            let r: Double = (n <= 4 ? 76 : n <= 6 ? 88 : 100) * s
            for i in 0..<n { pts.append(around(r, -90 + 360 * Double(i) / Double(n))) }
        }
        let m: CGFloat = 8                        // move the whole group onto the screen
        let x0 = pts.map { $0.x - item.width / 2 }.min() ?? 0, x1 = pts.map { $0.x + item.width / 2 }.max() ?? 0
        let y0 = pts.map { $0.y - item.height / 2 }.min() ?? 0, y1 = pts.map { $0.y + item.height / 2 }.max() ?? 0
        let dx: CGFloat = x0 < m ? m - x0 : (x1 > W - m ? (W - m) - x1 : 0)
        let dy: CGFloat = y0 < m ? m - y0 : (y1 > H - m ? (H - m) - y1 : 0)
        return (pts.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }, item)
    }
}

/// A radial menu's options drawn where they open in game, shown in the editor while the radial is selected.
private struct RadialPreview: View {
    let item: TouchItem
    let W: CGFloat, H: CGFloat
    var body: some View {
        let slots = Array((item.slots ?? []).prefix(8))
        let g = RadialGeometry.layout(shape: item.radialShape ?? 0, n: slots.count, center: CGPoint(x: item.x * W, y: item.y * H),
                                      button: item.size, spread: item.radialSpread ?? 1, W: W, H: H)
        let corner = min(g.size.width, g.size.height) / 2
        ZStack {
            ForEach(Array(slots.enumerated()), id: \.element.id) { n, sl in
                ZStack {
                    RoundedRectangle(cornerRadius: corner).fill(Color(white: 0.1).opacity(0.78))
                    RoundedRectangle(cornerRadius: corner).stroke(Color.white.opacity(0.6), lineWidth: 2)
                    Text(sl.label.isEmpty ? (sl.kind == .none ? "—" : "?") : sl.label)
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(.white).minimumScaleFactor(0.55).lineLimit(1).padding(4)
                }
                .frame(width: g.size.width, height: g.size.height)
                .opacity(sl.kind == .none ? 0.45 : 1)
                .position(g.points[n])
            }
        }
        .frame(width: W, height: H)
    }
}

/// A named copy of a layout the player saved to come back to later (one list for keyboard and mouse, one for the virtual gamepad).
struct TouchPreset: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var layout: TouchLayout
}

enum TouchPresetStore {
    private static func key(_ pad: Bool) -> String { pad ? "zom.padPresets" : "zom.touchPresets" }
    static func load(pad: Bool) -> [TouchPreset] {
        guard let s = UserDefaults.standard.string(forKey: key(pad)), let d = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TouchPreset].self, from: d)) ?? []
    }
    static func save(_ list: [TouchPreset], pad: Bool) {
        if let d = try? JSONEncoder().encode(list), let s = String(data: d, encoding: .utf8) { UserDefaults.standard.set(s, forKey: key(pad)) }
    }
}

enum TouchLayoutStore {
    static let key = "zom.touchLayout"
    static let padKey = "zom.padLayout"      // the virtual gamepad's own layout

    static func load(pad: Bool = false) -> TouchLayout {
        if let s = UserDefaults.standard.string(forKey: pad ? padKey : key), let d = s.data(using: .utf8),
           var l = try? JSONDecoder().decode(TouchLayout.self, from: d) {
            l.items.removeAll { $0.kind == .autoattack }       // a test build once had an auto-attack button; the aim stick's Auto mode replaced it
            if !l.items.isEmpty { return l }
        }
        return pad ? padDefaultLayout : defaultLayout
    }
    static func save(_ l: TouchLayout, pad: Bool = false) {
        if let d = try? JSONEncoder().encode(l), let s = String(data: d, encoding: .utf8) { UserDefaults.standard.set(s, forKey: pad ? padKey : key) }
    }
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    static let migratedKey = "zom.aimstickMigrated"

    /// The aiming stick: a second joystick on the right that aims the character (holds the aim button and points the cursor around the player).
    static var aimStickItem: TouchItem {
        TouchItem(id: "aimstick", kind: .aimstick, label: "", code: 0, x: (956.0 - 20 - 75) / 956.0, y: (440.0 - 14 - 75) / 440.0, size: 130)
    }

    /// The default layout (positions worked out for a 956x440 pt screen).
    static var defaultLayout: TouchLayout {
        let W = 956.0, H = 440.0, L = 20.0, R = 20.0, B = 14.0, T = 10.0
        func item(_ id: String, _ kind: TouchItem.Kind, _ label: String, _ code: Int, _ px: Double, _ py: Double, _ size: Double) -> TouchItem {
            TouchItem(id: id, kind: kind, label: label, code: code, x: px / W, y: py / H, size: size)
        }
        let shift = 150.0       // the action buttons move left to leave the right edge to the aiming stick
        return TouchLayout(items: [
            item("stick", .stick, "", 0, L + 70, H - B - 70, 130),
            aimStickItem,
            item("atk", .mouse, "ATK", 0, W - R - 40 - shift, H - B - 44, 62),
            item("aim", .mouse, "AIM", 1, W - R - 112 - shift, H - B - 36, 62),
            item("e", .key, "E", 69, W - R - 40 - shift, H - B - 116, 62),
            item("run", .key, "RUN", 340, W - R - 112 - shift, H - B - 108, 62),
            item("spc", .key, "SPC", 32, W - R - 184 - shift, H - B - 44, 62),
            item("ctrl", .key, "CTRL", 341, W - R - 184 - shift, H - B - 116, 62),
            item("tab", .key, "TAB", 258, W - R - 28 - 3 * 52, T + 26, 44),
            item("esc", .key, "ESC", 256, W - R - 28 - 2 * 52, T + 26, 44),
            item("kb", .keyboard, "KB", 0, W - R - 28 - 52, T + 26, 44),
            item("hide", .hide, "HIDE", 0, W - R - 28, T + 26, 44),
            item("mode", .mode, "PAD", 0, W - R - 28 - 4 * 52, T + 26, 44),
        ])
    }

    /// The default virtual gamepad (positions worked out for a 956x440 pt screen): sticks at the bottom corners, D-pad and A/B/X/Y between them,
    /// shoulder and trigger buttons on the top corners, Back and Start at the top centre.
    static var padDefaultLayout: TouchLayout {
        let W = 956.0, H = 440.0, L = 20.0, R = 20.0, B = 14.0, T = 10.0
        func item(_ id: String, _ kind: TouchItem.Kind, _ label: String, _ code: Int, _ px: Double, _ py: Double, _ size: Double) -> TouchItem {
            TouchItem(id: id, kind: kind, label: label, code: code, x: px / W, y: py / H, size: size)
        }
        func pb(_ c: Int) -> String { PadCatalog.buttons[c].2 }        // face labels in the chosen style (Xbox / PlayStation)
        func pt(_ c: Int) -> String { PadCatalog.triggers[c].2 }
        let dx = L + 250, dy = H - B - 70            // D-pad centre
        let bx = W - R - 290, by = H - B - 70        // A/B/X/Y centre
        return TouchLayout(items: [
            item("ls", .padstick, "", 0, L + 70, H - B - 70, 130),
            item("rs", .padstick, "", 1, W - R - 75, H - B - 75, 130),
            item("du", .padbtn, pb(11), 11, dx, dy - 46, 44), item("dd", .padbtn, pb(13), 13, dx, dy + 46, 44),
            item("dl", .padbtn, pb(14), 14, dx - 46, dy, 44), item("dr", .padbtn, pb(12), 12, dx + 46, dy, 44),
            item("ba", .padbtn, pb(0), 0, bx, by + 46, 52), item("bb", .padbtn, pb(1), 1, bx + 46, by, 52),
            item("bx", .padbtn, pb(2), 2, bx - 46, by, 52), item("by", .padbtn, pb(3), 3, bx, by - 46, 52),
            item("lt", .padtrig, pt(0), 0, L + 34, T + 30, 54), item("lb", .padbtn, pb(4), 4, L + 100, T + 30, 54),
            item("rt", .padtrig, pt(1), 1, W - R - 212, T + 30, 54), item("rb", .padbtn, pb(5), 5, W - R - 146, T + 30, 54),
            item("back", .padbtn, pb(6), 6, W / 2 - 40, T + 26, 44), item("start", .padbtn, pb(7), 7, W / 2 + 40, T + 26, 44),
            item("l3", .padbtn, pb(9), 9, L + 70, H - B - 168, 40), item("r3", .padbtn, pb(10), 10, W - R - 75, H - B - 173, 40),
            item("hide", .hide, "HIDE", 0, W - R - 28, T + 26, 44),
            item("mode", .mode, "PAD", 0, W - R - 80, T + 26, 44),
        ])
    }

    /// Run when the launcher opens, so the game always has a saved layout to read: the default if there is none, and for a layout saved before the
    /// aiming stick existed, the stick is added once (move it or delete it in the editor).
    static func ensureSaved() {
        let d = UserDefaults.standard
        if d.string(forKey: padKey) == nil { save(padDefaultLayout, pad: true) }
        if d.string(forKey: key) == nil { save(defaultLayout); d.set(true, forKey: migratedKey); return }
        guard !d.bool(forKey: migratedKey) else { return }
        var l = load()
        if !l.items.contains(where: { $0.kind == .aimstick }) { l.items.append(aimStickItem); save(l) }
        d.set(true, forKey: migratedKey)
    }
}

// MARK: - Key catalogue

enum KeyCatalog {
    static let letters: [(String, Int)] = (0..<26).map { (String(UnicodeScalar(65 + $0)!), 65 + $0) }
    static let numbers: [(String, Int)] = (0..<10).map { (String($0), 48 + $0) }
    static let modifiers: [(String, Int)] = [("Shift", 340), ("Ctrl", 341), ("Alt", 342)]
    static let special: [(String, Int)] = [("Space", 32), ("Tab", 258), ("Esc", 256), ("Enter", 257), ("Backspace", 259),
                                           ("Up", 265), ("Down", 264), ("Left", 263), ("Right", 262)]
    static let function: [(String, Int)] = (1...12).map { ("F\($0)", 289 + $0) }
    static let punctuation: [(String, Int)] = [(",", 44), (".", 46), ("/", 47), (";", 59), ("'", 39), ("[", 91), ("]", 93), ("-", 45), ("=", 61), ("`", 96)]
    static let groups: [(String, [(String, Int)])] = [("Letters", letters), ("Numbers", numbers), ("Modifiers", modifiers),
                                                      ("Special", special), ("Function", function), ("Punctuation", punctuation)]
    static let mouse: [(String, Int)] = [("Left click", 0), ("Right click", 1), ("Middle click", 2)]

    static func name(key code: Int) -> String {
        for (_, list) in groups { if let n = list.first(where: { $0.1 == code }) { return n.0 } }
        return "Key \(code)"
    }
    /// Short text for a button face.
    static func shortLabel(key code: Int) -> String {
        let n = name(key: code)
        let map = ["Space": "SPC", "Shift": "SHF", "Backspace": "BKSP", "Enter": "ENT", "Up": "↑", "Down": "↓", "Left": "←", "Right": "→"]
        return (map[n] ?? n).uppercased()
    }
}

/// Names of the standard gamepad buttons (GLFW gamepad order) in the two labelling styles; style 0 = Xbox, 1 = PlayStation (DualSense).
enum PadCatalog {
    static let styleKey = "zom.padStyle"
    static var style: Int { UserDefaults.standard.integer(forKey: styleKey) == 1 ? 1 : 0 }
    // index = GLFW button: (menu name, face label) for Xbox, then for PlayStation
    private static let xbox: [(String, String)] = [("A", "A"), ("B", "B"), ("X", "X"), ("Y", "Y"), ("Left bumper (LB)", "LB"), ("Right bumper (RB)", "RB"),
        ("Back", "BACK"), ("Start", "STRT"), ("Guide", "GUIDE"), ("Left stick click (L3)", "L3"), ("Right stick click (R3)", "R3"),
        ("D-pad up", "↑"), ("D-pad right", "→"), ("D-pad down", "↓"), ("D-pad left", "←")]
    private static let playstation: [(String, String)] = [("Cross (✕)", "✕"), ("Circle (○)", "○"), ("Square (□)", "□"), ("Triangle (△)", "△"),
        ("L1", "L1"), ("R1", "R1"), ("Create", "CRT"), ("Options", "OPT"), ("PS button", "PS"), ("Left stick click (L3)", "L3"), ("Right stick click (R3)", "R3"),
        ("D-pad up", "↑"), ("D-pad right", "→"), ("D-pad down", "↓"), ("D-pad left", "←")]
    private static let triggersXbox: [(String, String)] = [("Left trigger (LT)", "LT"), ("Right trigger (RT)", "RT")]
    private static let triggersPS: [(String, String)] = [("L2", "L2"), ("R2", "R2")]
    static var buttons: [(String, Int, String)] { (style == 1 ? playstation : xbox).enumerated().map { ($0.element.0, $0.offset, $0.element.1) } }
    static var triggers: [(String, Int, String)] { (style == 1 ? triggersPS : triggersXbox).enumerated().map { ($0.element.0, $0.offset, $0.element.1) } }
    static func name(for item: TouchItem) -> String {
        if item.kind == .padtrig { return triggers.first { $0.1 == item.code }?.0 ?? "Trigger" }
        return buttons.first { $0.1 == item.code }?.0 ?? "Button"
    }
    static func label(for item: TouchItem) -> String {
        item.kind == .padtrig ? (triggers.first { $0.1 == item.code }?.2 ?? item.label) : (buttons.first { $0.1 == item.code }?.2 ?? item.label)
    }
    /// Sets the style and renames the buttons of the saved gamepad layout to match (positions and everything else stay).
    static func setStyle(_ v: Int) {
        UserDefaults.standard.set(v == 1 ? 1 : 0, forKey: styleKey)
        var l = TouchLayoutStore.load(pad: true)
        for i in l.items.indices where l.items[i].kind == .padbtn || l.items[i].kind == .padtrig { l.items[i].label = label(for: l.items[i]) }
        TouchLayoutStore.save(l, pad: true)
    }
}

// MARK: - Touch layout editor

struct TouchLayoutEditor: View {
    var pad = false            // true: edit the virtual gamepad layout instead of the keyboard and mouse one
    @Environment(\.dismiss) private var dismiss
    @State private var layout: TouchLayout
    init(pad: Bool = false) { self.pad = pad; _layout = State(initialValue: TouchLayoutStore.load(pad: pad)) }
    @State private var selected: String?
    @State private var panelOffset = CGSize.zero
    @State private var panelDrag = CGSize.zero
    @State private var saveItem: DispatchWorkItem?
    @AppStorage("zom.aimAttackMode") private var aimAttackMode = 0          // aim joystick: 0 no attack, 1 one attack on release, 2 auto-attack while pushed
    @AppStorage("zom.mouseSens") private var mouseSens = 1.0       // cursor speed of PAD mode (1.0 = one point of cursor per point of finger); applies on the next start
    @AppStorage("zom.dragAimSens") private var dragAimSens = 1.0   // cursor speed for drag-to-aim on buttons that have it switched on
    @AppStorage("zom.scrollSpeed") private var scrollSpeed = 1.0   // scroll strip: wheel notches per 16 pt of finger travel
    @AppStorage("zom.scrollInvert") private var scrollInvert = false
    @State private var presets: [TouchPreset] = []
    @State private var naming = false
    @State private var newName = ""

    private var selectedIndex: Int? { layout.items.firstIndex { $0.id == selected } }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            ZStack {
                Color(white: 0.055).ignoresSafeArea()
                // the screen as the game will see it
                RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1).padding(6).ignoresSafeArea()
                Text("Drag controls where you want them. Tap one to edit.").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.35))
                    .position(x: W / 2, y: H - 14)

                ForEach($layout.items) { $item in
                    // gesture goes on before .position, so each control's touch area is the control itself, not the whole screen
                    Chip(item: $item, selected: selected == item.id, opacity: layout.opacity)
                        .contentShape(Capsule())      // a circle for round controls, the whole bar for the scroll strip
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas")).onChanged { v in
                            if selected != item.id { selected = item.id }
                            let r = item.halfSize
                            item.x = min(max(v.location.x, r.width), W - r.width) / W
                            item.y = min(max(v.location.y, r.height), H - r.height) / H
                        })
                        .position(x: item.x * W, y: item.y * H)
                }
                if let i = selectedIndex, layout.items[i].kind == .radial {      // how the selected radial opens in game
                    RadialPreview(item: layout.items[i], W: W, H: H).allowsHitTesting(false)
                }
                panel
                    .frame(width: min(360, W * 0.42))
                    .frame(maxHeight: H - 16)                  // never taller than the screen; the panel scrolls instead
                    .offset(x: panelOffset.width + panelDrag.width, y: panelOffset.height + panelDrag.height)
            }
            .coordinateSpace(name: "canvas")
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .onChange(of: layout) { _, l in      // debounced: encoding on every frame of a drag made the editor sluggish
            saveItem?.cancel()
            let work = DispatchWorkItem { TouchLayoutStore.save(l, pad: pad) }
            saveItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
        .onDisappear { saveItem?.cancel(); TouchLayoutStore.save(layout, pad: pad) }
        .onAppear { presets = TouchPresetStore.load(pad: pad) }
        .alert("Save layout", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") { saveCurrent(as: newName) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Saves the controls as they are now. Saving under an existing name replaces it.") }
    }

    private func saveCurrent(as name: String) {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        guard !n.isEmpty else { return }
        if let i = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { presets[i].layout = layout }
        else { presets.append(TouchPreset(name: n, layout: layout)) }
        TouchPresetStore.save(presets, pad: pad)
    }

    // MARK: panel

    // MARK: metrics — one set of sizes, so every row and button lines up

    private enum M {
        static let label: CGFloat = 104      // label column
        static let value: CGFloat = 44       // value column (right aligned, monospaced)
        static let row: CGFloat = 30
        static let control: CGFloat = 30
        static let gap: CGFloat = 8
        static let section: CGFloat = 12
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 10, weight: .bold)).tracking(0.8)
            .foregroundStyle(.white.opacity(0.42))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    /// label | control | value: the label and value columns are fixed, so sliders and pickers line up from row to row.
    private func row<Content: View>(_ label: String, value: String? = nil, @ViewBuilder _ control: () -> Content) -> some View {
        HStack(spacing: M.gap) {
            Text(label)
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: M.label, alignment: .leading)
            control().frame(maxWidth: .infinity)
            if let value {
                Text(value)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.62))
                    .frame(width: M.value, alignment: .trailing)
            }
        }
        .frame(height: M.row)
    }

    /// The capsule fields (menus, text field) all share one size, so they look like one family.
    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 12).frame(height: M.control)
            .background(Color.white.opacity(0.12), in: Capsule())
    }

    private func actionPill(_ title: String, system: String, filled: Bool = false) -> some View {
        Label(title, systemImage: system)
            .font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity).frame(height: 34)
            .background(filled ? Color.white : Color.white.opacity(0.12), in: Capsule())
            .foregroundStyle(filled ? Color.black : .white)
    }

    private func toggleRow(_ label: String, _ on: Binding<Bool>) -> some View {
        row(label) { HStack { Spacer(); Toggle("", isOn: on).labelsHidden().scaleEffect(0.8, anchor: .trailing) } }
    }

    // MARK: panel

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: M.section) {
                HStack {
                    Text(pad ? "Virtual Gamepad" : "Touch Controls").font(.system(size: 15, weight: .bold))
                    Spacer()
                    Image(systemName: "line.3.horizontal").foregroundStyle(.white.opacity(0.4))
                }
                .frame(height: M.control)
                .contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .named("canvas")).onChanged { panelDrag = $0.translation }.onEnded { v in
                    panelOffset.width += v.translation.width; panelOffset.height += v.translation.height; panelDrag = .zero
                })

                // Two even columns instead of four squeezed pills.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: M.gap), GridItem(.flexible(), spacing: M.gap)], spacing: M.gap) {
                    addMenu
                    Button { Haptics.tap(); layout = pad ? TouchLayoutStore.padDefaultLayout : TouchLayoutStore.defaultLayout; TouchLayoutStore.save(layout, pad: pad); selected = nil } label: { actionPill("Reset", system: "arrow.counterclockwise") }.buttonStyle(PressStyle())
                    savedMenu
                    Button { Haptics.tap(); dismiss() } label: { actionPill("Done", system: "checkmark", filled: true) }.buttonStyle(PressStyle())
                }

                VStack(alignment: .leading, spacing: M.gap) {
                    sectionTitle("Layout")
                    row("Opacity", value: String(format: "%.0f%%", layout.opacity * 100)) {
                        Slider(value: $layout.opacity, in: 0.05...1).tint(.white)      // 5% floor: still findable, and iOS ignores touches under 1%
                    }
                }

                if !pad {
                    VStack(alignment: .leading, spacing: M.gap) {
                        sectionTitle("Touch")
                        row("Sensitivity", value: String(format: "%.1fx", mouseSens)) {
                            Slider(value: $mouseSens, in: 0.2...4, step: 0.1).tint(.white)
                        }
                        if layout.items.contains(where: { $0.dragAim == true }) {
                            row("Drag speed", value: String(format: "%.1fx", dragAimSens)) {
                                Slider(value: $dragAimSens, in: 0.2...4, step: 0.1).tint(.white)
                            }
                        }
                        if layout.items.contains(where: { $0.kind == .aimstick }) {
                            row("Aim attack") {
                                Picker("", selection: $aimAttackMode) { Text("Off").tag(0); Text("Release").tag(1); Text("Auto").tag(2) }.pickerStyle(.segmented)
                            }
                        }
                        if layout.items.contains(where: { $0.kind == .scroll }) {
                            row("Scroll speed", value: String(format: "%.1fx", scrollSpeed)) {
                                Slider(value: $scrollSpeed, in: 0.3...3, step: 0.1).tint(.white)
                            }
                            toggleRow("Reverse scroll", $scrollInvert)
                        }
                    }
                }

                if let i = selectedIndex { inspector(i) }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .padding(14)
        .background(Color(white: 0.11).opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var addMenu: some View {
        Menu {
            if pad {
                Button("Gamepad button") { add(.padbtn, label: PadCatalog.buttons[0].2, code: 0) }
                Button("Trigger") { add(.padtrig, label: PadCatalog.triggers[0].2, code: 0, size: 54) }
                Button("Stick") { add(.padstick, label: "", code: 0, size: 130) }
            } else {
                Button("Key button") { add(.key, label: "E", code: 69) }
                Button("Mouse button") { add(.mouse, label: "CLK", code: 0) }
                if !layout.items.contains(where: { $0.kind == .stick }) { Button("Joystick") { add(.stick, label: "", code: 0, size: 130) } }
                if !layout.items.contains(where: { $0.kind == .aimstick }) { Button("Aim joystick") { add(.aimstick, label: "", code: 0, size: 130) } }
                if !layout.items.contains(where: { $0.kind == .scroll }) { Button("Scroll strip") { add(.scroll, label: "", code: 0, size: 70) } }   // slide up/down: mouse wheel at the cursor
                Button("Radial menu") {      // hold, slide to an option, let go; options are set by tapping it
                    add(.radial, label: "", code: 0, size: 58)
                    if let n = layout.items.indices.last { layout.items[n].slots = (0..<4).map { _ in RadialSlot() } }
                }
                Button("Fire mode toggle") {      // switches one chosen button between Default and Release
                    add(.firemode, label: "MODE", code: 0, size: 44)
                    if let n = layout.items.indices.last { layout.items[n].target = layout.items.first { $0.kind == .mouse && $0.code == 0 }?.id }
                }
                if !layout.items.contains(where: { $0.kind == .keyboard }) { Button("Keyboard toggle") { add(.keyboard, label: "KB", code: 0, size: 44) } }
            }
        } label: { actionPill("Add", system: "plus") }
    }

    private var savedMenu: some View {
        Menu {
            Button { newName = ""; naming = true } label: { Label("Save current layout…", systemImage: "square.and.arrow.down") }
            if !presets.isEmpty { Divider() }
            ForEach(presets) { p in
                Menu(p.name) {
                    Button { layout = p.layout; selected = nil } label: { Label("Load", systemImage: "arrow.down.doc") }
                    Button { if let n = presets.firstIndex(where: { $0.id == p.id }) { presets[n].layout = layout; TouchPresetStore.save(presets, pad: pad) } } label: { Label("Replace with current", systemImage: "square.and.arrow.down") }
                    Button(role: .destructive) { presets.removeAll { $0.id == p.id }; TouchPresetStore.save(presets, pad: pad) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        } label: { actionPill("Saved", system: "square.stack") }
    }

    @ViewBuilder private func inspector(_ i: Int) -> some View {
        let item = layout.items[i]
        VStack(alignment: .leading, spacing: M.gap) {
            sectionTitle(itemTitle(item))
            if item.kind == .padbtn || item.kind == .padtrig {
                row("Acts as") {
                    Menu {
                        ForEach(PadCatalog.buttons, id: \.1) { e in Button(e.0) { layout.items[i].kind = .padbtn; layout.items[i].code = e.1; layout.items[i].label = e.2 } }
                        ForEach(PadCatalog.triggers, id: \.1) { e in Button(e.0) { layout.items[i].kind = .padtrig; layout.items[i].code = e.1; layout.items[i].label = e.2 } }
                    } label: { field { Text(PadCatalog.name(for: item)) } }
                }
            }
            if item.kind == .padstick {
                row("Acts as") {
                    Picker("", selection: Binding(get: { layout.items[i].code }, set: { layout.items[i].code = $0 })) { Text("Left").tag(0); Text("Right").tag(1) }
                        .pickerStyle(.segmented).frame(width: 150)
                }
            }
            if item.kind == .key || item.kind == .mouse {
                row("Sends") {
                    Menu {
                        ForEach(KeyCatalog.groups, id: \.0) { group in
                            Menu(group.0) {
                                ForEach(group.1, id: \.1) { entry in
                                    Button(entry.0) { setOutput(i, kind: .key, code: entry.1, label: KeyCatalog.shortLabel(key: entry.1)) }
                                }
                            }
                        }
                        Menu("Mouse") {
                            ForEach(KeyCatalog.mouse, id: \.1) { entry in
                                Button(entry.0) { setOutput(i, kind: .mouse, code: entry.1, label: entry.0.prefix(1).uppercased() + "CLK") }
                            }
                        }
                    } label: { field { Text(item.kind == .mouse ? KeyCatalog.mouse.first { $0.1 == item.code }?.0 ?? "Mouse" : KeyCatalog.name(key: item.code)) } }
                }
                row("Label") {
                    TextField("Label", text: Binding(get: { layout.items[i].label }, set: { layout.items[i].label = String($0.prefix(5)).uppercased() }))
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .frame(width: 90, height: M.control)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                // Two-thumb play: e.g. attack = drag to aim + Release (hold to aim, lift to swing once), shove = drag to aim + Auto.
                toggleRow("Drag to aim", Binding(get: { layout.items[i].dragAim ?? false }, set: { layout.items[i].dragAim = $0 ? true : nil }))
                toggleRow("Long press", Binding(get: { layout.items[i].holdLock ?? false }, set: { layout.items[i].holdLock = $0 ? true : nil }))
                if item.holdLock == true {
                    let t = item.holdLockTime ?? TouchItem.defaultHoldLockTime
                    row("Lock after", value: String(format: "%.1fs", t)) {
                        Slider(value: Binding(get: { t }, set: { v in layout.items[i].holdLockTime = abs(v - TouchItem.defaultHoldLockTime) < 0.001 ? nil : v }), in: 0.2...2.0, step: 0.1).tint(.white)
                    }
                }
                row("Fire mode") {
                    Picker("", selection: Binding(get: { layout.items[i].fireMode ?? 0 }, set: { layout.items[i].fireMode = $0 == 0 ? nil : $0 })) {
                        Text("Default").tag(0); Text("Auto").tag(1); Text("Release").tag(2)
                    }.pickerStyle(.segmented)
                }
            }
            if item.kind == .firemode {
                row("Changes") {
                    Menu {
                        ForEach(layout.items.filter { $0.kind == .key || $0.kind == .mouse }) { b in
                            Button(buttonName(b)) { layout.items[i].target = b.id }
                        }
                    } label: { field { Text(layout.items.first { $0.id == item.target }.map(buttonName) ?? "Choose a button") } }
                }
                Text("Each tap in game switches that button between Default and Release.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if item.kind == .radial { radialEditor(i) }
            row("Size", value: String(format: "%.0f", item.size)) {
                Slider(value: Binding(get: { layout.items[i].size }, set: { layout.items[i].size = $0 }),
                       in: item.kind == .scroll ? 40.0...90.0 : (item.isStick ? 90.0 : 36.0)...(item.isStick ? 200.0 : 110.0))
                    .tint(.white)
            }
            if !item.locked {
                Button(role: .destructive) { layout.items.remove(at: i); selected = nil } label: {
                    Label("Delete control", systemImage: "trash")
                        .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 32)
                        .background(Color.red.opacity(0.18), in: Capsule()).foregroundStyle(Color.red)
                }.buttonStyle(PressStyle())
            }
        }
    }

    private func itemTitle(_ item: TouchItem) -> String {
        switch item.kind {
        case .stick: return "Joystick"
        case .aimstick: return "Aim joystick"
        case .scroll: return "Scroll strip"
        case .radial: return item.label.isEmpty ? "Radial menu" : "Radial menu (\(item.label))"
        case .firemode: return "Fire mode toggle"
        case .padstick: return item.code == 0 ? "Left stick" : "Right stick"
        default: return item.label.isEmpty ? "Control" : item.label
        }
    }

    // MARK: radial menu

    @ViewBuilder private func radialEditor(_ i: Int) -> some View {
        let slots = layout.items[i].slots ?? []
        row("Label") {
            TextField("None", text: Binding(get: { layout.items[i].label }, set: { layout.items[i].label = String($0.prefix(5)).uppercased() }))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .frame(width: 90, height: M.control)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        row("Options") {
            HStack(spacing: 6) {
                Text("\(slots.count)").font(.system(size: 13, weight: .semibold, design: .monospaced))
                Stepper("", value: Binding(get: { slots.count }, set: { setSlotCount(i, $0) }), in: 2...8).labelsHidden()
                Spacer(minLength: 0)
            }
        }
        row("Shape") {
            Picker("", selection: Binding(get: { layout.items[i].radialShape ?? 0 }, set: { layout.items[i].radialShape = $0 == 0 ? nil : $0 })) {
                Text("Ring").tag(0); Text("Arc").tag(1); Text("Column").tag(2); Text("Row").tag(3)
            }.pickerStyle(.segmented)
        }
        row("Spacing", value: String(format: "%.0f%%", (layout.items[i].radialSpread ?? 1) * 100)) {
            Slider(value: Binding(get: { layout.items[i].radialSpread ?? 1 }, set: { v in layout.items[i].radialSpread = abs(v - 1) < 0.001 ? nil : v }), in: 0.6...1.6, step: 0.05).tint(.white)
        }
        row("Tap sends") {
            Menu {
                Button("Nothing") { layout.items[i].tapSlot = nil }
                ForEach(Array(slots.enumerated()), id: \.element.id) { n, sl in
                    Button("\(n + 1). \(slotTitle(sl))") { layout.items[i].tapSlot = n }
                }
            } label: {
                field {
                    Text(layout.items[i].tapSlot.flatMap { n -> String? in slots.indices.contains(n) ? "\(n + 1). \(slotTitle(slots[n]))" : nil } ?? "Nothing")
                }
            }
        }
        ForEach(Array(slots.enumerated()), id: \.element.id) { n, sl in
            HStack(spacing: 6) {
                Text("\(n + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).frame(width: 14)
                TextField("Label", text: Binding(get: { slot(i, n)?.label ?? "" }, set: { v in editSlot(i, n) { $0.label = String(v.prefix(8)) } }))
                    .multilineTextAlignment(.center).font(.system(size: 12, weight: .semibold))
                    .frame(width: 74, height: M.control)
                    .background(Color.white.opacity(0.12), in: Capsule()).autocorrectionDisabled()
                Spacer(minLength: 4)
                slotMenu(i, n, sl)
            }
            .frame(height: M.row)
        }
        Text("In game: hold it, slide to an option and let go; letting go where you started sends nothing, and a quick tap sends the tap option. Arc, Column and Row open away from the nearest edge, and the whole menu is kept on screen.")
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func slotMenu(_ i: Int, _ n: Int, _ sl: RadialSlot) -> some View {
        let copyable = layout.items.filter { [.key, .mouse, .keyboard, .hide, .mode, .firemode].contains($0.kind) }
        Menu {
            if !copyable.isEmpty {
                Menu("Copy from button") {
                    ForEach(copyable) { b in Button(buttonTitle(b)) { editSlot(i, n) { $0 = slotFrom(b, id: $0.id) } } }
                }
            }
            ForEach(KeyCatalog.groups, id: \.0) { group in
                Menu(group.0) {
                    ForEach(group.1, id: \.1) { e in
                        Button(e.0) { editSlot(i, n) { $0.kind = .key; $0.code = e.1; $0.target = nil; $0.label = KeyCatalog.shortLabel(key: e.1) } }
                    }
                }
            }
            Menu("Mouse") {
                ForEach(KeyCatalog.mouse, id: \.1) { e in
                    Button(e.0) { editSlot(i, n) { $0.kind = .mouse; $0.code = e.1; $0.target = nil; $0.label = e.0.prefix(1).uppercased() + "CLK" } }
                }
            }
            Menu("Controls") {
                Button("Hide / show controls") { editSlot(i, n) { $0.kind = .hide; $0.target = nil; $0.label = "HIDE" } }
                Button("PAD / TCH mode") { editSlot(i, n) { $0.kind = .mode; $0.target = nil; $0.label = "PAD" } }
                Button("Keyboard") { editSlot(i, n) { $0.kind = .keyboard; $0.target = nil; $0.label = "KB" } }
                Menu("Fire mode toggle for") {
                    ForEach(layout.items.filter { $0.kind == .key || $0.kind == .mouse }) { b in
                        Button(buttonName(b)) { editSlot(i, n) { $0.kind = .firemode; $0.target = b.id; $0.label = "MODE" } }
                    }
                }
            }
            Divider()
            if n > 0 { Button { moveSlot(i, n) } label: { Label("Move up", systemImage: "arrow.up") } }
            Button(role: .destructive) { editSlot(i, n) { $0 = RadialSlot(id: $0.id) } } label: { Label("Clear", systemImage: "xmark") }
        } label: {
            field { Text(slotSends(sl)) }
        }
    }

    private func slot(_ i: Int, _ n: Int) -> RadialSlot? {
        guard layout.items.indices.contains(i), let a = layout.items[i].slots, a.indices.contains(n) else { return nil }
        return a[n]
    }
    private func editSlot(_ i: Int, _ n: Int, _ change: (inout RadialSlot) -> Void) {
        guard layout.items.indices.contains(i), var a = layout.items[i].slots, a.indices.contains(n) else { return }
        change(&a[n]); layout.items[i].slots = a
    }
    private func setSlotCount(_ i: Int, _ count: Int) {
        var a = layout.items[i].slots ?? []
        while a.count < count { a.append(RadialSlot()) }
        while a.count > count { a.removeLast() }
        layout.items[i].slots = a
        if let t = layout.items[i].tapSlot, t >= count { layout.items[i].tapSlot = nil }
    }
    private func moveSlot(_ i: Int, _ n: Int) {
        guard var a = layout.items[i].slots, n > 0, a.indices.contains(n) else { return }
        a.swapAt(n, n - 1); layout.items[i].slots = a
        if let t = layout.items[i].tapSlot { layout.items[i].tapSlot = t == n ? n - 1 : t == n - 1 ? n : t }
    }
    private func slotFrom(_ b: TouchItem, id: String) -> RadialSlot {
        switch b.kind {
        case .key: return RadialSlot(id: id, kind: .key, code: b.code, label: b.label)
        case .mouse: return RadialSlot(id: id, kind: .mouse, code: b.code, label: b.label)
        case .keyboard: return RadialSlot(id: id, kind: .keyboard, label: b.label.isEmpty ? "KB" : b.label)
        case .hide: return RadialSlot(id: id, kind: .hide, label: "HIDE")
        case .mode: return RadialSlot(id: id, kind: .mode, label: "PAD")
        case .firemode: return RadialSlot(id: id, kind: .firemode, label: "MODE", target: b.target)
        default: return RadialSlot(id: id)
        }
    }
    private func slotSends(_ sl: RadialSlot) -> String {
        switch sl.kind {
        case .none: return "Choose…"
        case .key: return KeyCatalog.name(key: sl.code)
        case .mouse: return KeyCatalog.mouse.first { $0.1 == sl.code }?.0 ?? "Mouse"
        case .hide: return "Hide / show"
        case .mode: return "PAD / TCH"
        case .keyboard: return "Keyboard"
        case .firemode: return "Fire mode: " + (layout.items.first { $0.id == sl.target }.map(buttonName) ?? "?")
        }
    }
    private func slotTitle(_ sl: RadialSlot) -> String { sl.label.isEmpty ? slotSends(sl) : sl.label }
    private func buttonTitle(_ b: TouchItem) -> String {
        switch b.kind {
        case .key, .mouse: return buttonName(b)
        case .keyboard: return "Keyboard toggle"
        case .hide: return "HIDE"
        case .mode: return "PAD / TCH"
        case .firemode: return "Fire mode toggle (\(layout.items.first { $0.id == b.target }.map(buttonName) ?? "?"))"
        default: return b.label
        }
    }

    private func setOutput(_ i: Int, kind: TouchItem.Kind, code: Int, label: String) {
        layout.items[i].kind = kind; layout.items[i].code = code; layout.items[i].label = String(label.prefix(5))
    }

    /// "HIT (A)" style name of a button, for the fire mode toggle's target picker.
    private func buttonName(_ b: TouchItem) -> String {
        let sends = b.kind == .mouse ? KeyCatalog.mouse.first { $0.1 == b.code }?.0 ?? "Mouse" : KeyCatalog.name(key: b.code)
        return b.label.isEmpty ? sends : "\(b.label) (\(sends))"
    }

    private func add(_ kind: TouchItem.Kind, label: String, code: Int, size: Double = 62) {
        let item = TouchItem(id: UUID().uuidString, kind: kind, label: label, code: code, x: 0.5, y: 0.78, size: size)
        layout.items.append(item); selected = item.id
    }
}

/// How one control looks in the editor; mirrors the in-game overlay.
private struct Chip: View {
    @Binding var item: TouchItem
    let selected: Bool
    let opacity: Double
    var body: some View {
        if item.kind == .scroll {
            ZStack {
                Capsule().fill(Color(white: 0.1).opacity(0.45))
                Capsule().stroke(Color.white.opacity(0.6), lineWidth: 2)
                VStack { Image(systemName: "chevron.up"); Spacer(); Image(systemName: "line.3.horizontal"); Spacer(); Image(systemName: "chevron.down") }
                    .font(.system(size: item.size * 0.2, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).padding(.vertical, item.size * 0.25)
            }
            .frame(width: item.size * 0.6, height: item.size * 2.2)
            .opacity(opacity)
            .overlay(Capsule().stroke(Color.white, lineWidth: selected ? 3 : 0).padding(-5))
        } else {
            roundChip
        }
    }

    private var roundChip: some View {
        ZStack {
            Circle().fill(item.kind == .aimstick ? Color(red: 0.35, green: 0.08, blue: 0.06).opacity(0.45) : Color(white: 0.1).opacity(0.45))
            Circle().stroke(item.kind == .aimstick ? Color(red: 1, green: 0.55, blue: 0.5).opacity(0.7) : Color.white.opacity(0.6), lineWidth: 2)
            if item.isStick {
                Circle().fill(item.kind == .aimstick ? Color(red: 1, green: 0.6, blue: 0.55).opacity(0.6) : Color.white.opacity(0.55)).frame(width: item.size * 0.38, height: item.size * 0.38)
                if item.kind == .aimstick { Image(systemName: "scope").font(.system(size: item.size * 0.2)).foregroundStyle(.white.opacity(0.8)) }
            } else {
                if item.kind == .radial && item.label.isEmpty {
                    Image(systemName: "circle.hexagongrid.fill").font(.system(size: item.size * 0.34, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Text(item.label).font(.system(size: item.size > 50 ? 15 : 12, weight: .bold)).foregroundStyle(.white).minimumScaleFactor(0.6).lineLimit(1)
                }
            }
        }
        .frame(width: item.size, height: item.size)
        .opacity(opacity)
        .overlay(Circle().stroke(Color.white, lineWidth: selected ? 3 : 0).padding(-5))
    }
}

#Preview("Touch editor", traits: .fixedLayout(width: 956, height: 440)) { TouchLayoutEditor() }
