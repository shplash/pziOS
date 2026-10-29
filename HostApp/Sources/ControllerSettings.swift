// Settings for a real (physical) controller: what each logical game input reads from, a stick deadzone, and whether the
// on-screen controls hide while a controller is connected. The launcher hands the result to the GLFW layer
// (pad_config_load in glfw_ios.m) as JSON in ZOMIOS_PAD_CONFIG when the game starts, so changes apply on the next start.
// Ported from Zomdroid's external controller configuration (MIT, see licenses/Zomdroid-MIT.txt).
import Foundation
import GameController

/// A physical button, in the order the GLFW layer numbers them: GLFW's standard buttons (A, B, X, Y, LB, RB, Back, Start,
/// Guide, L3, R3, d-pad up/right/down/left) and then the two triggers, which are axes but count as buttons at half press
/// so a face button can be told to act as LT or RT.
enum PadSource: Int, CaseIterable, Codable {
    case a, b, x, y, lb, rb, back, start, guide, l3, r3
    case dpadUp, dpadRight, dpadDown, dpadLeft
    case leftTrigger, rightTrigger

    var title: String {
        rawValue <= 14 ? PadCatalog.buttons[rawValue].0 : PadCatalog.triggers[rawValue - 15].0
    }
}

/// A physical axis, in GLFW's axis order: left stick x/y, right stick x/y, then the two triggers.
enum PadAxisSource: Int, CaseIterable, Codable {
    case lx, ly, rx, ry, lt, rt

    var title: String {
        ["Left stick X", "Left stick Y", "Right stick X", "Right stick Y", "Left trigger", "Right trigger"][rawValue]
    }
}

/// One logical input the game reads: a GLFW joystick button (0...14) or axis (0...5).
enum PadOutput: Identifiable {
    case button(Int)
    case axis(Int)

    var id: String { switch self { case .button(let i): return "b\(i)"; case .axis(let i): return "a\(i)" } }

    var title: String {
        switch self {
        case .button(let i): return PadCatalog.buttons[min(max(i, 0), 14)].0
        case .axis(let i): return ["Left stick X", "Left stick Y", "Right stick X", "Right stick Y", "Left trigger", "Right trigger"][min(max(i, 0), 5)]
        }
    }

    /// All the rows of the mapping editor, buttons first.
    static var all: [PadOutput] {
        (0..<15).map { PadOutput.button($0) } + (0..<6).map { PadOutput.axis($0) }
    }
}

struct ControllerSettings: Codable, Equatable {
    static let key = "zom.controllerConfig"

    var overlayAutoHide = true              // hide the on-screen controls while a controller is connected
    var deadZone: Double = 0.15             // 0...0.95, applied radially to both sticks
    var buttons: [Int] = Array(0..<15)      // logical GLFW button -> physical PadSource
    var axes: [Int] = Array(0..<6)          // logical GLFW axis -> physical PadAxisSource

    // The stored JSON is also the wire format glfw_ios.m reads, so the names are short and fixed.
    private enum CodingKeys: String, CodingKey {
        case overlay = "overlay"
        case deadZone = "deadzone"
        case buttons, axes
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overlayAutoHide = try c.decodeIfPresent(Bool.self, forKey: .overlay) ?? true
        deadZone = try c.decodeIfPresent(Double.self, forKey: .deadZone) ?? 0.15
        buttons = try c.decodeIfPresent([Int].self, forKey: .buttons) ?? Array(0..<15)
        axes = try c.decodeIfPresent([Int].self, forKey: .axes) ?? Array(0..<6)
    }

    /// Brings a saved (or hand-edited) configuration back into range; the GLFW layer also clamps, this keeps the UI honest.
    var normalized: ControllerSettings {
        var c = self
        c.deadZone = min(max(c.deadZone, 0), 0.95)
        c.buttons = (0..<15).map { i in
            let v = i < buttons.count ? buttons[i] : i
            return (0...16).contains(v) ? v : i
        }
        c.axes = (0..<6).map { i in
            let v = i < axes.count ? axes[i] : i
            return (0...5).contains(v) ? v : i
        }
        return c
    }

    static func load() -> ControllerSettings {
        guard let s = UserDefaults.standard.string(forKey: key), let d = s.data(using: .utf8),
              let c = try? JSONDecoder().decode(ControllerSettings.self, from: d) else { return ControllerSettings() }
        return c.normalized
    }

    func save() {
        let c = normalized
        guard let d = try? JSONEncoder().encode(c), let s = String(data: d, encoding: .utf8) else { return }
        UserDefaults.standard.set(s, forKey: ControllerSettings.key)
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    func source(for output: PadOutput) -> PadSource? {
        guard case .button(let i) = output else { return nil }
        return PadSource(rawValue: buttons[min(max(i, 0), 14)])
    }

    func axisSource(for output: PadOutput) -> PadAxisSource? {
        guard case .axis(let i) = output else { return nil }
        return PadAxisSource(rawValue: axes[min(max(i, 0), 5)])
    }

    mutating func bind(_ source: PadSource, to output: PadOutput) {
        guard case .button(let i) = output else { return }
        buttons[min(max(i, 0), 14)] = source.rawValue
    }

    mutating func bind(_ source: PadAxisSource, to output: PadOutput) {
        guard case .axis(let i) = output else { return }
        axes[min(max(i, 0), 5)] = source.rawValue
    }

    /// Swaps A and B, which is what most people want for a Nintendo-style pad (GameController reports their face buttons
    /// in the Xbox arrangement, so A sits where B normally is).
    mutating func swapAB() { buttons.swapAt(0, 1) }
}

/// One reading of a controller, in the physical order the mapping talks about: 17 buttons (15 GLFW ones plus the two
/// triggers) and 6 axes (sticks -1...1, triggers 0...1).
struct PadSnapshot: Equatable {
    var buttons = [Bool](repeating: false, count: 17)
    var axes: [Double] = [0, 0, 0, 0, 0, 0]

    static func read(_ g: GCExtendedGamepad) -> PadSnapshot {
        var s = PadSnapshot()
        s.buttons[0] = g.buttonA.isPressed
        s.buttons[1] = g.buttonB.isPressed
        s.buttons[2] = g.buttonX.isPressed
        s.buttons[3] = g.buttonY.isPressed
        s.buttons[4] = g.leftShoulder.isPressed
        s.buttons[5] = g.rightShoulder.isPressed
        s.buttons[6] = g.buttonOptions?.isPressed ?? false
        s.buttons[7] = g.buttonMenu.isPressed
        s.buttons[8] = g.buttonHome?.isPressed ?? false
        s.buttons[9] = g.leftThumbstickButton?.isPressed ?? false
        s.buttons[10] = g.rightThumbstickButton?.isPressed ?? false
        s.buttons[11] = g.dpad.up.isPressed
        s.buttons[12] = g.dpad.right.isPressed
        s.buttons[13] = g.dpad.down.isPressed
        s.buttons[14] = g.dpad.left.isPressed
        s.buttons[15] = g.leftTrigger.value > 0.5
        s.buttons[16] = g.rightTrigger.value > 0.5
        s.axes[0] = Double(g.leftThumbstick.xAxis.value)
        s.axes[1] = -Double(g.leftThumbstick.yAxis.value)      // GLFW: +Y is down
        s.axes[2] = Double(g.rightThumbstick.xAxis.value)
        s.axes[3] = -Double(g.rightThumbstick.yAxis.value)
        s.axes[4] = Double(g.leftTrigger.value)
        s.axes[5] = Double(g.rightTrigger.value)
        return s
    }

    /// Names of the buttons that are down, for the live preview.
    var pressedTitles: [String] {
        (0..<17).compactMap { buttons[$0] ? PadSource(rawValue: $0)?.title : nil }
    }
}

enum PadReader {
    static var connected: [GCController] { GCController.controllers() }
    static var primary: GCController? { connected.first { $0.extendedGamepad != nil } }

    static func snapshot(_ controller: GCController?) -> PadSnapshot {
        guard let g = controller?.extendedGamepad else { return PadSnapshot() }
        return PadSnapshot.read(g)
    }

    static func name(_ controller: GCController) -> String {
        let vendor = controller.vendorName ?? "Controller"
        return controller.extendedGamepad == nil ? "\(vendor) (not a gamepad)" : vendor
    }
}


/// Watches the connected controller for the launcher (name and battery), so the home screen and the Controller section can
/// show what is plugged in without polling GameController from a view body. Started and stopped by the screens that show it.
final class PadMonitor: ObservableObject {
    @Published private(set) var name: String?
    @Published private(set) var battery: Int?          // percentage, when the pad reports one
    private var timer: Timer?

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        let pad = PadReader.primary
        name = pad.map { PadReader.name($0) }
        if let b = pad?.battery, b.batteryState != .unknown, b.batteryLevel >= 0 {
            battery = Int((b.batteryLevel * 100).rounded())
        } else {
            battery = nil
        }
    }

    deinit { timer?.invalidate() }
}
