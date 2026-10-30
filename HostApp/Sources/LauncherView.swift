// Launcher screen. Edit freely: in Xcode, open this file with the ZomUIPreview scheme selected and the canvas (Editor > Canvas)
// redraws as you type. Settings use the same UserDefaults keys and defaults as the Objective-C launch code in main.m, which reads
// them when PLAY is pressed, so everything shown here is exactly what the next launch will use.
import SwiftUI
@_silgen_name("zom_zink_probe") private func zomZinkProbe(_ out: UnsafeMutablePointer<CChar>, _ cap: Int) -> Int32
import os
import UIKit
import GameController
import UniformTypeIdentifiers

@objc(ZomLauncherModel)
public final class LauncherModel: NSObject, ObservableObject {
    @Published var log = "pziOS ready. The JVM starts once per launch; relaunch the app between runs.\n"
    @Published var running = false
    // Built-in JIT (wired by ZomJITHost in the game app; inert in the UI preview)
    @Published var jitAvailable = true
    @Published var hasPairing = false
    @Published var jitUnavailableReason = ""
    @Published var pairingStatus = "No pairing file"
    @Published var jitStatus = ""
    var onImportPairing: ((URL) -> Void)?
    var onPrepareJIT: (() -> Void)?
    var onResetDDI: (() -> Void)?
    @objc public func setLog(_ s: String) { log = s }
    @objc public func setRunning(_ r: Bool) { running = r }
    @objc public var isRunning: Bool { running }
}

@objc(ZomLauncherUI)
public final class LauncherUI: NSObject {
    /// mode: 0 hello (-Xint), 1 hello (JIT), 2 load natives, 3 play
    @objc public static func makeController(model: LauncherModel, onRun: @escaping (Int) -> Void) -> UIViewController {
        let host = UIHostingController(rootView: LauncherView(model: model, onRun: onRun))
        host.view.backgroundColor = .clear
        return host
    }
}

// MARK: - Look and feel

enum Theme {
    static let base = Color(white: 0.055)          // same value as LaunchScreen.storyboard, so launch -> home has no flash
    static let accent = Color.white
    static let surface = Color.white.opacity(0.07)
    static let dim = Color(white: 0.62)
    static let faint = Color(white: 0.42)
    static let success = Color(red: 0.40, green: 0.86, blue: 0.58)
    static let warning = Color(red: 1.00, green: 0.67, blue: 0.30)
    static let danger = Color(red: 1.00, green: 0.45, blue: 0.42)
    /// Card fill: a faint top-to-bottom gradient instead of a flat grey, so stacked panels read as separate surfaces.
    static var card: LinearGradient {
        LinearGradient(colors: [Color(white: 0.135), Color(white: 0.098)], startPoint: .top, endPoint: .bottom)
    }
    static var background: some View {
        ZStack {
            base
            RadialGradient(colors: [Color.white.opacity(0.055), .clear], center: .topLeading, startRadius: 0, endRadius: 640)
        }.ignoresSafeArea()
    }
}

/// Short haptic on the actions that change something, matching the system feel without a generator per tap.
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    static func tap() { light.impactOccurred() }
}

/// The press feedback used by every card and button: a small scale and dim, which reads as motion without a bounce.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The default Memory Limit comes from what iOS actually lets the app use (os_proc_available_memory, about 6.1 GB on an 8 GB iPhone), not from the
/// model's RAM. Measured footprints with pzGC and Balanced shrink: Low about 3.9 GB, Medium 4.4, High 4.9, Very High about 6.4; a tier is picked only
/// if it leaves about 1 GB spare. Keep the same numbers in default_heap_mode() in main.m.
private func defaultHeapMode() -> Int {
    let budget = Int(os_proc_available_memory() / 1_048_576)
    if budget <= 0 { let gb = ProcessInfo.processInfo.physicalMemory >> 30; return gb >= 11 ? 3 : gb >= 7 ? 2 : gb >= 5 ? 1 : 0 }   // simulator / unknown
    return budget >= 7400 ? 3 : budget >= 5800 ? 2 : budget >= 5000 ? 1 : 0
}

// MARK: - Device profile and scaling

/// Landscape layout scale. 1.0 is an iPhone Pro Max (440 pt tall); smaller phones shrink a little, iPads grow.
/// Sizes come from the screen, not model names, so phones and iPads released later lay out sensibly without a code change.
struct Metrics {
    let s: CGFloat
    init(size: CGSize) {
        let h = min(size.width, size.height)
        s = min(max(h / 440, 0.85), 1.8)
    }
    func v(_ x: CGFloat) -> CGFloat { x * s }
}

/// The Project Zomboid build, read from version.txt in the Zomboid home folder (Documents/home/Zomboid/version.txt), which the game writes each
/// time it starts. Its first line is "42.21.0 4a0e9546ec". The value is remembered with a fingerprint of the installed projectzomboid.jar, so if
/// the game files are replaced the old number is not shown until the new build has run once.
enum GameBuild {
    private static let versionKey = "zom.gameBuild", printKey = "zom.gameBuildJar"
    static var versionFile: URL { GameFiles.documents.appendingPathComponent("home/Zomboid/version.txt") }

    private static func jarFingerprint() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: GameFiles.jar.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int(mtime))"
    }

    static func loaded() -> String? {
        let defaults = UserDefaults.standard
        let fingerprint = jarFingerprint()
        if let text = try? String(contentsOf: versionFile, encoding: .utf8),
           let first = text.split(whereSeparator: \.isNewline).first,
           let version = first.split(separator: " ").first.map(String.init), version.first?.isNumber == true {
            defaults.set(version, forKey: versionKey)
            if let fingerprint { defaults.set(fingerprint, forKey: printKey) }     // this file belongs to the game files installed now
        }
        // the remembered version only counts if the installed jar is the one it was read for
        if let fingerprint, let stored = defaults.string(forKey: printKey), stored != fingerprint { return nil }
        return defaults.string(forKey: versionKey)
    }
}

/// Screen margins for the game UI, in one place for the launcher and the game start-up code.
/// Auto sizes them from this device's screen corners and safe area; Custom uses the region saved by the screen margin editor.
@objc(ZomMargins)
public final class ZomMargins: NSObject {
    struct Device { var radius: CGFloat; var inset: UIEdgeInsets; var width: CGFloat; var height: CGFloat; var orientation: UIInterfaceOrientation }
    static let scales: [Double] = [0, 0.5, 1.0, 1.6]          // Off, Small, Auto, Large
    static let customKey = "zom.customMargins"                 // [left, top, right, bottom] as fractions of the screen

    static func device() -> Device {
        var d = Device(radius: 0, inset: .zero, width: 956, height: 440, orientation: .landscapeRight)
        let probe = {
            let screen = UIScreen.main
            d.width = max(screen.bounds.width, screen.bounds.height)
            d.height = min(screen.bounds.width, screen.bounds.height)
            for scene in UIApplication.shared.connectedScenes {
                if let ws = scene as? UIWindowScene, let w = ws.windows.first { d.inset = w.safeAreaInsets; d.orientation = ws.interfaceOrientation; break }
            }
            let sel = NSSelectorFromString("_displayCornerRadius")
            if screen.responds(to: sel), let r = screen.value(forKey: "_displayCornerRadius") as? CGFloat { d.radius = r }
        }
        if Thread.isMainThread { probe() } else { DispatchQueue.main.sync(execute: probe) }
        if d.radius <= 0 { d.radius = max(d.inset.left, d.inset.right) * 0.9 }      // no radius available: estimate from the notch-side inset
        return d
    }

    /// Auto margins in points (left, top, right, bottom) for a device and a scale.
    static func autoPoints(_ d: Device, scale: Double) -> [CGFloat] {
        let k = CGFloat(scale)
        var l = d.radius * 0.67 * k, r = l
        let t = max(d.inset.top, d.radius * 0.22) * k
        let b = max(d.inset.bottom * 1.1, d.radius * 0.42) * k
        // the Dynamic Island / notch side also has to clear the island, which needs more than the corner alone
        let island = max(d.inset.left, d.inset.right)
        if island >= 40 {
            let clear = island * CGFloat(min(scale, 1.6))
            if d.orientation == .landscapeLeft { r = max(r, clear) } else { l = max(l, clear) }     // landscape-right puts the island on the left
        }
        return [l, t, r, b]
    }

    static func customFractions() -> [Double]? {
        guard let a = UserDefaults.standard.array(forKey: customKey) as? [Double], a.count == 4 else { return nil }
        return a
    }

    /// Margins in game pixels: left, top, right, bottom. Level 0 off, 1 small, 2 auto, 3 large, 4 custom.
    @objc public static func gamePixels(level: Int) -> [NSNumber] {
        let d = device()
        // ZOMIOS_HEIGHT is set by main.m from the render resolution setting just before this runs; 720p is the fallback.
        let fromEnv = ProcessInfo.processInfo.environment["ZOMIOS_HEIGHT"].flatMap { Double($0) }
        let gameH = fromEnv.flatMap { $0 >= 360 && $0 <= 2160 ? $0 : nil } ?? 720
        let toPx = gameH / Double(max(d.height, 1))
        var pts: [Double]
        if level == 4, let f = customFractions() {
            pts = [f[0] * Double(d.width), f[1] * Double(d.height), f[2] * Double(d.width), f[3] * Double(d.height)]
        } else if level >= 1 {
            pts = autoPoints(d, scale: scales[min(level, 3)]).map(Double.init)
        } else {
            pts = [0, 0, 0, 0]
        }
        print(String(format: "device margins: corner radius %.1f pt, safe insets L%.0f T%.0f R%.0f B%.0f pt, screen %.0fx%.0f pt, level %d", d.radius, d.inset.left, d.inset.top, d.inset.right, d.inset.bottom, d.width, d.height, level))
        return pts.map { NSNumber(value: Int(($0 * toPx).rounded())) }
    }
}

@objc(ZomDevice)
public final class ZomDevice: NSObject {
    /// "iPhone17,2  iOS 27.0  landscape 956x440  class large phone  scale 1.00"
    @objc public static var summary: String {
        var sys = utsname(); uname(&sys)
        let id = withUnsafePointer(to: &sys.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        let b = UIScreen.main.bounds, h = min(b.width, b.height), w = max(b.width, b.height)
        let kind: String
        if UIDevice.current.userInterfaceIdiom == .pad { kind = h > 900 ? "iPad 13-inch class" : "iPad 11-inch class" }
        else { kind = h >= 429 ? "large phone (Pro Max / Plus)" : h >= 412 ? "regular phone (Air)" : "compact phone (standard / Pro)" }
        return String(format: "%@  iOS %@  landscape %.0fx%.0f  class %@  scale %.2f", id, UIDevice.current.systemVersion, w, h, kind, Metrics(size: CGSize(width: w, height: h)).s)
    }
}

// MARK: - Gamepad navigation

enum PadKey { case up, down, left, right, a, b, lb, rb }

/// Turns any connected gamepad into navigation events (d-pad / left stick to move, A select, B back, bumpers switch pages).
/// The first press only reveals the focus ring. Events stop while the game is starting so they never leak into it.
final class PadNav: ObservableObject {
    @Published private(set) var tick = 0
    @Published private(set) var active = false
    private(set) var last: PadKey = .a
    var enabled = true
    private var latch: [PadKey: Bool] = [:]

    init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.bind(c) }
        }
        GCController.controllers().forEach(bind)
    }

    private func bind(_ c: GCController) {
        guard let g = c.extendedGamepad else { return }
        func key(_ b: GCControllerButtonInput, _ k: PadKey) { b.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.send(k) } } }
        key(g.dpad.up, .up); key(g.dpad.down, .down); key(g.dpad.left, .left); key(g.dpad.right, .right)
        key(g.buttonA, .a); key(g.buttonB, .b); key(g.leftShoulder, .lb); key(g.rightShoulder, .rb)
        g.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in      // one event per push, re-armed when the stick returns to centre
            self?.edge(.right, x > 0.6); self?.edge(.left, x < -0.6); self?.edge(.up, y > 0.6); self?.edge(.down, y < -0.6)
        }
    }
    private func edge(_ k: PadKey, _ on: Bool) {
        let was = latch[k] ?? false
        latch[k] = on
        if on && !was { send(k) }
    }
    private func send(_ k: PadKey) {
        DispatchQueue.main.async { [self] in
            guard enabled else { return }
            if !active { active = true; return }
            last = k; tick += 1
        }
    }
}

// MARK: - Small building blocks

/// Compact segmented control: tappable pills, one filled, in a sunken track.
struct Pills: View {
    let options: [String]
    @Binding var selection: Int
    let m: Metrics
    var body: some View {
        HStack(spacing: m.v(2)) {
            ForEach(options.indices, id: \.self) { i in
                Button {
                    Haptics.tap()
                    withAnimation(.easeOut(duration: 0.14)) { selection = i }
                } label: {
                    Text(options[i]).font(.system(size: m.v(12), weight: .semibold)).lineLimit(1).minimumScaleFactor(0.65)
                        .padding(.horizontal, m.v(10)).frame(height: m.v(26))
                        .foregroundStyle(selection == i ? Color.black : Color.white.opacity(0.82))
                        .background(selection == i ? Theme.accent : Color.clear, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(m.v(2))
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}

struct Switch: View {
    @Binding var isOn: Bool
    let m: Metrics
    var body: some View {
        Button { Haptics.tap(); isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.accent : Color.white.opacity(0.16)).frame(width: m.v(44), height: m.v(26))
                Circle().fill(isOn ? Color.black : Color.white).frame(width: m.v(20), height: m.v(20)).padding(m.v(3))
            }.animation(.easeOut(duration: 0.14), value: isOn)
        }.buttonStyle(.plain)
    }
}

/// Small uppercase badge, used for BETA, "ready", the connected controller and so on.
struct Badge: View {
    let text: String
    var tint: Color = .white
    let m: Metrics
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: m.v(9), weight: .bold)).tracking(m.v(0.6)).lineLimit(1)
            .padding(.horizontal, m.v(7)).frame(height: m.v(17))
            .foregroundStyle(tint)
            .background(tint.opacity(0.13), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 1))
    }
}

private extension View {
    /// Focus ring used by touch-free (gamepad) navigation.
    func padRing(_ on: Bool, radius: CGFloat = 10) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.accent, lineWidth: on ? 2 : 0).padding(-3))
    }
}

// MARK: - Home

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    var onRun: (Int) -> Void
    @StateObject private var pad = PadNav()
    @StateObject private var pads = PadMonitor()
    @State private var showSettings = false
    @State private var showSetup = false
    @State private var showGCNotice = false
    /// 0 PLAY, 1 Settings, 2 Game Files, 3 Mods, 4 Setup guide (the tiles are a 2x2 grid under PLAY).
    @State private var focus = 0
    /// Terminal-style spinner words, shuffled once per launch.
    @State private var words = ThinkingLine.words.shuffled()
    @AppStorage("zom.jitMethod") private var jitMethod = 0
    @AppStorage("zom.heapLimit") private var heap = defaultHeapMode()
    @AppStorage("zom.virtualPad") private var virtualPad = false
    @AppStorage("zom.touchPresetName") private var touchPreset = ""
    @AppStorage("zom.padPresetName") private var padPreset = ""
    @State private var build = GameBuild.loaded()

    private var installed: Bool { GameFiles.installed }
    private var librariesDiffer: Bool { installed && NativeCheck.manifest != nil && !(NativeCheck.last?.differ.isEmpty ?? true) }
    private var jitReady: Bool { jitMethod == 0 || model.hasPairing }
    private var ready: Bool { installed && jitReady }

    private var gameValue: String {
        guard installed else { return "Not installed" }
        return build.map { "Build \($0)" } ?? "Installed"
    }
    private var jitValue: String {
        jitMethod == 1 ? (model.hasPairing ? "Built-in · ready" : "Built-in · no pairing") : "Manual · StikDebug"
    }
    private var jitTint: Color {
        jitMethod == 1 ? (model.hasPairing ? Theme.success : Theme.warning) : Theme.dim
    }
    private var padValue: String {
        guard let name = pads.name else { return "None" }
        if let b = pads.battery { return "\(name) · \(b)%" }
        return name
    }
    private var heapValue: String {
        let i = min(max(heap, 0), 3)
        return ["Low", "Medium", "High", "Very High"][i] + " · " + ["1.5 GB", "2 GB", "2.5 GB", "4 GB"][i]
    }
    /// Which on-screen layout the game will use, and the saved layout it was loaded or saved as (empty after an edit).
    private var layoutValue: String {
        let name = virtualPad ? padPreset : touchPreset
        return (virtualPad ? "Gamepad" : "Touch") + (name.isEmpty ? "" : " · " + name)
    }
    private var versionText: String {
        let i = Bundle.main.infoDictionary ?? [:]
        let v = i["CFBundleShortVersionString"] as? String ?? ""
        let label = i["PZReleaseLabel"] as? String ?? ""
        return "pziOS " + v + (label.isEmpty ? "" : " (\(label))")
    }

    var body: some View {
        GeometryReader { geo in
            let m = Metrics(size: geo.size)
            let wide = geo.size.width >= 780
            ZStack {
                Theme.background
                VStack(spacing: 0) {
                    if wide {
                        HStack(alignment: .top, spacing: m.v(22)) {
                            brandColumn(m).frame(maxWidth: .infinity)
                            statusColumn(m).frame(width: min(m.v(380), geo.size.width * 0.42))
                        }
                        .padding(.horizontal, m.v(26)).padding(.top, m.v(24))
                        .frame(maxHeight: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: m.v(12)) { brandColumn(m); statusColumn(m) }
                                .padding(.horizontal, m.v(20)).padding(.top, m.v(16)).padding(.bottom, m.v(8))
                        }
                        .frame(maxHeight: .infinity)
                    }
                    bottomBar(m)
                }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .fullScreenCover(isPresented: $showSettings, onDismiss: { pads.refresh() }) { SettingsView(model: model, pad: pad) }
        .fullScreenCover(isPresented: $showSetup, onDismiss: { build = GameBuild.loaded() }) { SetupView(model: model, pad: pad) }
        .alert("Garbage collector switched back", isPresented: $showGCNotice) {
            Button("OK") { UserDefaults.standard.set(false, forKey: "zom.gcReverted") }
        } message: { Text("That garbage collector didn't start on this device, so pziOS went back to the Parallel garbage collector. Close the app and open it again, then press Play. (The game's engine can only be started once per launch.)") }
        .onAppear {
            // A garbage collector that stopped the JVM from starting also ends the app, so that is only noticed now: an unconfirmed trial means it
            // never booted. Switch back to Parallel and say so, instead of silently doing it on the next Play.
            let d = UserDefaults.standard
            if d.integer(forKey: "zom.gc") != 0 && d.bool(forKey: "zom.gcTrial") && !d.bool(forKey: "zom.gcOK") {
                d.set(0, forKey: "zom.gc"); d.set(false, forKey: "zom.gcTrial"); d.set(true, forKey: "zom.gcReverted")
            }
            if d.bool(forKey: "zom.ramDonorHeap") && d.bool(forKey: "zom.ramDonorTrial") && !d.bool(forKey: "zom.ramDonorOK") {
                d.set(false, forKey: "zom.ramDonorHeap"); d.set(false, forKey: "zom.ramDonorTrial")
            }
            TouchLayoutStore.ensureSaved()
            build = GameBuild.loaded()
            pads.start()
            if !GameFiles.installed { showSetup = true }
            if d.bool(forKey: "zom.gcReverted") { showGCNotice = true }
        }
        .onDisappear { pads.stop() }
        .onChange(of: model.running) { _, r in
            pad.enabled = !r
            if !r && UserDefaults.standard.bool(forKey: "zom.gcReverted") { showGCNotice = true }       // the JVM stopped on a ZGC trial
        }
        .onChange(of: showSettings) { _, open in if !open { focus = 1 } }
        .onChange(of: pad.tick) { _, _ in
            guard !showSettings, !showSetup, !model.running else { return }
            switch (pad.last, focus) {
            case (.up, 1), (.up, 2): focus = 0
            case (.up, 3): focus = 1
            case (.up, 4): focus = 2
            case (.down, 0): focus = 1
            case (.down, 1): focus = 3
            case (.down, 2): focus = 4
            case (.left, 2), (.right, 1): focus = 1
            case (.right, 2), (.left, 1): focus = 2
            case (.right, 3), (.left, 4): focus = 3
            case (.left, 3), (.right, 4): focus = 4
            case (.a, 0): play()
            case (.a, 1): showSettings = true
            case (.a, 2): gameFiles()
            case (.a, 3): FolderLink.open("home/Zomboid/mods")
            case (.a, 4): showSetup = true
            default: break
            }
        }
    }

    // MARK: columns

    private func brandColumn(_ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: m.v(9)) {
                Text("pziOS").font(.system(size: m.v(44), weight: .black)).tracking(m.v(-1))
                Badge(text: "beta", tint: Theme.warning, m: m)
                Spacer(minLength: 0)
                if pads.name != nil { Badge(text: "controller", tint: Theme.success, m: m) }
            }
            Text("Project Zomboid on iPhone and iPad")
                .font(.system(size: m.v(13), weight: .medium)).foregroundStyle(Theme.dim).padding(.top, m.v(1))

            playButton(m).padding(.top, m.v(18))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: m.v(9)), GridItem(.flexible(), spacing: m.v(9))], spacing: m.v(9)) {
                TileButton(title: "Settings", subtitle: "Graphics, memory, JIT", icon: "gearshape.fill",
                           m: m, focused: pad.active && focus == 1, disabled: model.running) { Haptics.tap(); showSettings = true }
                TileButton(title: "Game Files", subtitle: gameValue, icon: "folder.fill",
                           m: m, focused: pad.active && focus == 2, disabled: model.running) { Haptics.tap(); gameFiles() }
                TileButton(title: "Mods", subtitle: "Open the mods folder", icon: "square.stack.3d.up.fill",
                           m: m, focused: pad.active && focus == 3, disabled: model.running) { Haptics.tap(); FolderLink.open("home/Zomboid/mods") }
                TileButton(title: "Setup Guide", subtitle: ready ? "Everything is set" : "Finish setting up", icon: "checkmark.seal.fill",
                           m: m, focused: pad.active && focus == 4, disabled: model.running) { Haptics.tap(); showSetup = true }
            }
            .padding(.top, m.v(12))
            Spacer(minLength: 0)
        }
    }

    private func statusColumn(_ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: m.v(8)) {
            HStack {
                Text("STATUS").font(.system(size: m.v(10), weight: .bold)).tracking(m.v(1.1)).foregroundStyle(Theme.faint)
                Spacer()
                Badge(text: ready ? "ready" : "setup needed", tint: ready ? Theme.success : Theme.warning, m: m)
            }
            VStack(spacing: 0) {
                StatusRow(icon: "folder.fill", title: "Game files", value: gameValue, tint: installed ? Theme.success : Theme.warning, m: m)
                Divider().overlay(Color.white.opacity(0.07))
                StatusRow(icon: "bolt.fill", title: "JIT", value: jitValue, tint: jitTint, m: m)
                Divider().overlay(Color.white.opacity(0.07))
                StatusRow(icon: "gamecontroller.fill", title: "Controller", value: padValue, tint: pads.name == nil ? Theme.faint : Theme.success, m: m)
                Divider().overlay(Color.white.opacity(0.07))
                StatusRow(icon: "memorychip", title: "Memory", value: heapValue, tint: Theme.dim, m: m)
                Divider().overlay(Color.white.opacity(0.07))
                StatusRow(icon: "rectangle.3.group", title: "Layout", value: layoutValue, tint: Theme.dim, m: m)
            }
            .padding(.horizontal, m.v(12))
            .background(Theme.card, in: RoundedRectangle(cornerRadius: m.v(14)))
            .overlay(RoundedRectangle(cornerRadius: m.v(14)).stroke(Color.white.opacity(0.07), lineWidth: 1))

            if librariesDiffer {
                banner(icon: "exclamationmark.triangle.fill", tint: Theme.warning, m: m,
                       text: "The game's libraries differ from this app's. Open the setup guide for what to do.")
            } else if !installed {
                banner(icon: "tray.and.arrow.down.fill", tint: Theme.warning, m: m,
                       text: "Import the game on your Mac or with SteamCMD, then choose the zip here.")
            }
            Spacer(minLength: 0)
        }
    }

    private func playButton(_ m: Metrics) -> some View {
        Button { Haptics.tap(); play() } label: {
            HStack(spacing: m.v(10)) {
                if model.running { ProgressView().tint(Color.black) }
                else { Image(systemName: "play.fill").font(.system(size: m.v(15), weight: .bold)) }
                Text(model.running ? "STARTING" : "PLAY").tracking(m.v(3))
            }
            .font(.system(size: m.v(20), weight: .heavy))
            .frame(maxWidth: .infinity).frame(height: m.v(54))
            .foregroundStyle(model.running ? Color(white: 0.45) : .black)
            .background(LinearGradient(colors: model.running ? [Color(white: 0.34), Color(white: 0.27)] : [.white, Color(white: 0.86)],
                                       startPoint: .top, endPoint: .bottom), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(model.running ? 0.08 : 0.30), lineWidth: 1))
            .shadow(color: Color.white.opacity(model.running ? 0 : 0.15), radius: m.v(14), y: m.v(4))
            .overlay(Capsule().stroke(Theme.accent, lineWidth: pad.active && focus == 0 && !model.running ? 2 : 0).padding(-4))
        }
        .buttonStyle(PressStyle())
        .disabled(model.running)
        .animation(.easeInOut(duration: 0.2), value: model.running)
    }

    private func bottomBar(_ m: Metrics) -> some View {
        VStack(spacing: m.v(3)) {
            ThinkingLine(words: words, active: model.running, m: m)
            HStack(spacing: m.v(6)) {
                Text(versionText)
                Text("·").foregroundStyle(Theme.faint)
                Text(build.map { "Project Zomboid \($0)" } ?? "Project Zomboid")
                Text("·").foregroundStyle(Theme.faint)
                Text(jitMethod == 1 ? "Built-in JIT" : "Manual JIT")
                if !installed {
                    Text("·").foregroundStyle(Theme.faint)
                    Text("game files not installed").foregroundStyle(Theme.warning)
                }
                Spacer(minLength: 0)
                if pad.active { Text("D-pad move · A select · B back").foregroundStyle(Theme.faint) }
            }
            .font(.system(size: m.v(10), weight: .medium))
            .foregroundStyle(Theme.dim.opacity(0.75))
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, m.v(24)).padding(.top, m.v(6)).padding(.bottom, m.v(10))
    }

    private func banner(icon: String, tint: Color, m: Metrics, text: String) -> some View {
        HStack(alignment: .top, spacing: m.v(8)) {
            Image(systemName: icon).font(.system(size: m.v(11), weight: .semibold))
            Text(text).font(.system(size: m.v(11))).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(m.v(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: m.v(12)))
        .overlay(RoundedRectangle(cornerRadius: m.v(12)).stroke(tint.opacity(0.22), lineWidth: 1))
    }

    /// PLAY: straight into the game when the game files are there, otherwise into the setup guide.
    private func play() { if GameFiles.installed { onRun(3) } else { showSetup = true } }
    /// Game Files: the setup guide while the files are missing, afterwards a shortcut to the folder in the Files app.
    private func gameFiles() { if GameFiles.installed { FolderLink.open("game") } else { showSetup = true } }
}

// MARK: - Status / tile components

private struct StatusRow: View {
    let icon: String, title: String, value: String
    var tint: Color = .white
    let m: Metrics
    var body: some View {
        HStack(spacing: m.v(9)) {
            Image(systemName: icon).font(.system(size: m.v(12), weight: .semibold))
                .foregroundStyle(tint.opacity(0.9)).frame(width: m.v(18))
            Text(title).font(.system(size: m.v(12), weight: .medium)).foregroundStyle(Theme.dim)
            Spacer(minLength: m.v(8))
            Text(value).font(.system(size: m.v(12), weight: .semibold)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(height: m.v(30))
    }
}

private struct TileButton: View {
    let title: String, subtitle: String, icon: String
    let m: Metrics
    let focused: Bool
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: m.v(9)) {
                Image(systemName: icon).font(.system(size: m.v(14), weight: .semibold)).frame(width: m.v(18))
                VStack(alignment: .leading, spacing: m.v(1)) {
                    Text(title).font(.system(size: m.v(12.5), weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: m.v(10))).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, m.v(11))
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: m.v(48))
            .background(Theme.card, in: RoundedRectangle(cornerRadius: m.v(12)))
            .overlay(RoundedRectangle(cornerRadius: m.v(12)).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: m.v(12)).stroke(Theme.accent, lineWidth: focused ? 2 : 0).padding(-3))
        }
        .buttonStyle(PressStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

private struct SectionHeader: View {
    let title: String
    let m: Metrics
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: m.v(9.5), weight: .bold)).tracking(m.v(1.1))
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, m.v(8)).padding(.horizontal, m.v(4))
    }
}

/// Opens a folder inside the app's Documents in the Files app (creating it first), so mods and game files can be dropped in.
enum FolderLink {
    static func open(_ relative: String) {
        var base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(base, &buf) != nil { base = String(cString: buf) }            // Files wants /private/var/..., not /var/...
        let path = (base as NSString).appendingPathComponent(relative)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "shareddocuments://" + encoded) else { return }
        UIApplication.shared.open(url)
    }
}

/// "✻ Pondering…" style status: the glyph animates and the word changes every few seconds, like a terminal spinner.
/// The timeline only runs while the game is starting, so an idle launcher costs nothing.
private struct ThinkingLine: View {
    static let words = ["Pondering", "Cogitating", "Noodling", "Simmering", "Percolating", "Ruminating", "Marinating", "Brewing", "Conjuring",
                        "Mulling", "Churning", "Musing", "Scheming", "Tinkering", "Wrangling", "Hatching", "Spelunking", "Shambling", "Lurching", "Reanimating"]
    private static let glyphs = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    let words: [String]
    let active: Bool
    let m: Metrics

    var body: some View {
        if active {
            TimelineView(.periodic(from: .now, by: 0.12)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let glyph = Self.glyphs[Int(t / 0.12) % Self.glyphs.count]
                let word = words[Int(t / 3.0) % words.count]
                Text("\(glyph) \(word)…")
                    .font(.system(size: m.v(13), weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(height: m.v(18))
            }
        } else {
            Color.clear.frame(height: m.v(18))
        }
    }
}

// MARK: - Settings

private enum Tab: Int, CaseIterable {
    case display, graphics, performance, controls, jit, tools, log
    var title: String { ["Display", "Graphics", "Performance", "Controls", "JIT", "Tools", "Log"][rawValue] }
    var subtitle: String {
        ["Resolution, screen margins and how the game fills the display.",
         "Textures and the graphics backend.",
         "Memory limits, garbage collection and the JIT compiler.",
         "The on-screen layout and real controllers.",
         "How the game gets permission to run JIT.",
         "Developer options and diagnostics.",
         "This run's output, ready to share."][rawValue]
    }
    var icon: String {
        [UIDevice.current.userInterfaceIdiom == .pad ? "ipad.landscape" : "iphone.landscape",
         "paintbrush.pointed.fill", "gauge.with.dots.needle.33percent", "gamecontroller.fill",
         "bolt.fill", "wrench.and.screwdriver.fill", "text.alignleft"][rawValue]
    }
    var developerOnly: Bool { self == .tools || self == .log }
    var section: String {
        switch self {
        case .display, .graphics, .performance: return "Game"
        case .controls: return "Input"
        case .jit: return "Setup"
        case .tools, .log: return "Developer"
        }
    }
}

private enum Editor: String, Identifiable, Equatable { case touch, pad, margins, setup, controller; var id: String { rawValue } }

/// One line on a settings page. Pages are plain data, so the same rows drive touch, the focus ring and gamepad input.
struct Row: Identifiable {
    enum Kind {
        case choice([String], Binding<Int>)
        case toggle(Binding<Bool>)
        case action(destructive: Bool, () -> Void)
        case slider(ClosedRange<Double>, Binding<Double>, String)
        case info
        case warning
        case progress(Double, String)
    }
    let id: String
    let title: String
    let kind: Kind
    var group: String? = nil                 // renders a section header above this row
    var detail: String? = nil
    var locked = false                      // greyed out and not selectable (set by low memory mode)
    var focusable: Bool {
        switch kind { case .info, .warning, .progress: return false; default: return true }
    }
}

struct SettingsView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var pad: PadNav
    @Environment(\.dismiss) private var dismiss

    @AppStorage("zom.textureShrink") private var shrink = 1            // 0 off, 1 balanced, 2 strong
    @AppStorage("zom.heapLimit") private var heap = defaultHeapMode()   // 0 low, 1 medium, 2 high, 3 very high (12 GB+ devices only)
    @AppStorage("zom.uiMargin") private var uiMargin = 2                // 0 off, 1 small, 2 auto (sized from the device), 3 large, 4 custom
    @AppStorage("zom.hiResTexturePacks") private var hiRes = false
    @AppStorage("zom.astc") private var astc = true                     // ASTC texture compression in the GL layer
    @AppStorage("zom.devTools") private var devTools = false            // reveals the Tools and Log tabs
    @AppStorage("zom.gc") private var gc = 0                            // 0 Parallel, 1 ZGC (cannot start on iOS), 2 SGC (generational Shenandoah), 3 Tuned Parallel
    @AppStorage("zom.jitCompiler") private var jitCompiler = 0          // 0 C1 only, 1 C1 + C2 gentle, 2 C1 + C2 full
    @AppStorage("zom.framePool") private var framePool = false          // experimental: per-frame autorelease pool on the render thread
    @State private var zinkResult = ""                                   // result text of the Zink probe
    @State private var zinkRunning = false
    @AppStorage("zom.donorHeapGB") private var donorHeapGB = 1          // Increased Memory Limit: 0 = the Memory Limit tier, 1...4 = 3...6 GB (default 3 GB)
    @AppStorage("zom.padStyle") private var padStyle = 0                  // virtual gamepad labels: 0 Xbox, 1 PlayStation
    @AppStorage("zom.virtualPad") private var virtualPad = false          // on-screen controls act as a game controller instead of keyboard and mouse
    @AppStorage("zom.touchIcons") private var touchIcons = true            // SF Symbols on the on-screen controls instead of text
    @AppStorage("zom.drivingAuto") private var drivingAuto = true          // switch to the driving layout while in a vehicle
    @AppStorage("zom.ramDonorHeap") private var ramDonorHeap = false      // experimental: Java heap in memory held by the donor extension
    @AppStorage("zom.twoFingerZoom") private var twoFingerZoom = true       // two-finger scroll on empty screen (the game's zoom)
    @AppStorage("zom.zinkBackend") private var zinkBackend = false      // experimental: run the game on Mesa Zink + MoltenVK (OpenGL 4.5)
    @AppStorage("zom.zinkLog") private var zinkLog = false              // with the Zink backend: write performance and device details to jvm.log
    @AppStorage("zom.zombieBuddy") private var zombieBuddy = false       // developer: start the game with -javaagent:ZombieBuddy.jar
    @AppStorage("zom.memLog") private var memLog = false                 // developer: write the memory footprint to jvm.log every 5 s
    @AppStorage("zom.fpsCounter") private var fpsCounter = false         // developer: draw the frame rate in the corner of the game screen
    @AppStorage("zom.simAspect") private var simAspect = 0              // developer: 0 off, 1 4:3, 2 3:2, 3 16:10, 4 16:9
    @AppStorage("zom.renderRes") private var renderRes = UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1              // 0 540p, 1 720p, 2 900p, 3 1080p
    @AppStorage("zom.jitMethod") private var jitMethod = 0              // 0 manual (run the script in StikDebug), 1 built-in StikJIT
    @StateObject private var pads = PadMonitor()
    @State private var controllerConfig = ControllerSettings.load()
    @State private var tab = Tab.display
    @State private var focus = 0
    @State private var importingPairing = false
    @State private var editor: Editor?
    @State private var confirmDev = false
    @State private var query = ""                                        // settings search, across every page

    private static let sections = ["Game", "Input", "Setup", "Developer"]
    private var tabs: [Tab] { Tab.allCases.filter { devTools || !$0.developerOnly } }

    // Each description explains what the *selected* value does, not the setting in general.
    private var shrinkDetail: String {
        ["Off: Textures load at full size. Best quality, but uses the most graphics memory and can run out.",
         "Balanced: Halves textures larger than 512 px. Keeps good quality and saves a lot of memory.",
         "Strong: Halves every texture over 256 px. Lowest memory use, with softer textures."][min(max(shrink, 0), 2)]
    }
    /// The pills read Off, Auto, Small, Large, Custom; the stored value keeps its original numbering (0 off, 1 small, 2 auto, 3 large, 4 custom).
    private var marginOrderBinding: Binding<Int> {
        let order = [0, 2, 1, 3, 4]
        return Binding(get: { order.firstIndex(of: uiMargin) ?? 1 }, set: { uiMargin = order[min(max($0, 0), order.count - 1)] })
    }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var uiMarginDetail: String {
        ["Off: The game UI uses the whole screen, including the area under the rounded corners" + (isPad ? "." : " and Dynamic Island."),
         "Small: Half of Auto. Keeps game windows and menus a little in from the edges.",
         isPad ? "Auto: Sized to this iPad's screen corners and safe area. Recommended." : "Auto: Sized to this iPhone's screen corners and safe area, with extra room on the Dynamic Island side. Recommended.",
         "Large: Larger than Auto, for when corners or a case still cut things off.",
         "Custom: Uses the region you set in the screen margins editor."][min(max(uiMargin, 0), 4)]
            + " The speed controls and moodle icons are drawn by the engine at fixed positions and are not moved."
    }
    /// High Definition Textures needs the 2x packs; a slim import leaves them out, so the option is unavailable (and off) until they are imported.
    private var hiResBinding: Binding<Bool> {
        Binding(get: { GameFiles.has2xPacks && hiRes }, set: { if GameFiles.has2xPacks { hiRes = $0 } })
    }
    private var hiResDetail: String {
        !GameFiles.has2xPacks ? "Unavailable: the 2x texture packs aren't in the imported game files. Import the game again from a complete copy to use this."
        : hiRes ? "On: Loads the 2x texture packs. Sharper world art, but needs much more memory."
              : "Off: Uses the lighter 1x world art."
    }
    /// Very High (a 4 GB heap) is offered on every device. It is the default only on devices with 12 GB of memory or more, such as the iPad Pro.
    private var heapOptions: [String] { ["Low", "Medium", "High", "Very High"] }
    /// Increased Memory Limit choices: the first is the current Memory Limit tier stated in GB (1.5, 2, 2.5 or 4), then 3 to 6 GB.
    private var increasedLimitOptions: [String] {
        let tierGB = ["1.5 GB", "2 GB", "2.5 GB", "4 GB"][min(max(heap, 0), 3)]
        return [tierGB + (heap == 3 ? " (Limit)" : ""), "3 GB", "4 GB", "5 GB", "6 GB"]
    }
    private var heapBinding: Binding<Int> {
        Binding(get: { min(max(heap, 0), heapOptions.count - 1) }, set: { heap = $0 })
    }
    private var heapDetail: String {
        ["Low: 1.5 GB Java heap. Saves memory, but expect hitches and stutter in busy areas.",
         "Medium: 2 GB Java heap. Balanced for 6 GB devices; may hitch in big crowds.",
         "High: 2.5 GB Java heap. Smoothest on 8 GB devices.",
         "Very High: 4 GB Java heap. Made for devices with 12 GB of memory or more, with room for large mod lists and the SGC collector."][min(max(heap, 0), heapOptions.count - 1)]
    }
    /// The pills read Parallel / pzGC / SGC / pzSGC; the stored values are 0, 3, 2 and 4 (1 was ZGC, which cannot start on iOS).
    private var gcBinding: Binding<Int> {
        let order = [0, 3, 2, 4]
        return Binding(get: { order.firstIndex(of: gc) ?? 0 }, set: { gc = order[min(max($0, 0), order.count - 1)] })
    }
    private var gcDetail: String {
        switch gc {
        case 4: return "pzSGC: SGC that cleans up early, so memory never fills up, even while the world loads. Uses more memory than SGC."
                    + (heap < 2 ? " Your Memory Limit is too low for this." : "")
                    + " Experimental: if it can't start, pziOS switches back to Parallel by itself."
        case 2: return "SGC: The smoothest. Collects garbage while the game keeps running, so pauses stay well under a millisecond instead of 20 ms hitches."
                    + (heap < 1 ? " Your Memory Limit is too low for this." : "")
                    + " Experimental: if it can't start, pziOS switches back to Parallel by itself."
        case 3: return "pzGC: Parallel with a small young generation so each pause is short, about one frame, survivors promoted earlier and parallel reference processing. Pauses come more often than SGC's but far shorter than plain Parallel's long ones, and it needs no extra memory."
        default: return "Parallel: The default. Cleans up in short pauses, about 20 ms every few seconds, with a longer one if memory runs low."
        }
    }
    private var jitCompilerDetail: String {
        ["C1 only: The fast, light compiler alone. Smallest code, lowest CPU use and a steady start. Recommended.",
         "C1 + C2, gentle: Adds the optimizing compiler, but only for code that runs very often (about 4 times the usual threshold). It compiles less and fills the code cache more slowly. Experimental.",
         "C1 + C2, full: Java's standard tiered mode. The fastest peak speed in long sessions, but the code cache fills quickly and its cleanup can cause one long pause (about 0.7 s). Experimental."][min(max(jitCompiler, 0), 2)]
    }
    private var renderResDetail: String {
        ["540p: The lightest on the GPU and the coolest, with a softer image. The game UI looks larger and less of the world is on screen.",
         "720p: The default. A balance of sharpness and speed.",
         "900p: A sharper image and more of the world on screen, with a smaller UI. Uses more GPU and runs warmer.",
         "1080p: The sharpest, showing the most of the world with the smallest UI. The heaviest on the GPU and memory, about 2.25 times the pixels of 720p."][min(max(renderRes, 0), 3)]
            + " Applies the next time the game starts."
    }
    private var astcDetail: String {
        astc ? "On: Large textures are compressed on the GPU to save memory. The first launch builds a cache and loads slower."
             : "Off: Textures stay uncompressed. Faster first launch, but uses more graphics memory."
    }
    private var controllerStatus: String {
        guard let name = pads.name else { return "No controller connected. Connect one with Bluetooth or a cable; the launcher sees it at once." }
        if let b = pads.battery { return "\(name) · battery \(b)%" }
        return name
    }
    /// Deadzone lives in the controller configuration (the same JSON the GLFW layer reads), so this slider and the Controller screen agree.
    private var deadZoneBinding: Binding<Double> {
        Binding(get: { controllerConfig.deadZone },
                set: { controllerConfig.deadZone = $0; controllerConfig.save() })
    }

    private var rows: [Row] { rows(for: tab) }

    /// The rows of any page, whether or not it is the one on screen; the search field uses them all.
    private func rows(for t: Tab) -> [Row] {
        switch t {
        case .graphics:
            return [
                Row(id: "shrink", title: "Texture Compression", kind: .choice(["Off", "Balanced", "Strong"], $shrink), group: "Textures", detail: shrinkDetail),
                Row(id: "hires", title: "High Definition Textures", kind: .toggle(hiResBinding), detail: hiResDetail),
            ]
        case .display:
            return [
                Row(id: "res", title: "Render Resolution", kind: .choice(["540p", "720p", "900p", "1080p"], $renderRes), group: "Screen", detail: renderResDetail),
                Row(id: "margin", title: "UI Margins", kind: .choice(["Off", "Auto", "Small", "Large", "Custom"], marginOrderBinding), group: "Game UI", detail: uiMarginDetail),
                Row(id: "marginEdit", title: "Edit screen margins", kind: .action(destructive: false) { editor = .margins },
                    detail: "Drag the screen edges to set exactly which part of the screen the game UI may use. Saving switches UI Margins to Custom."),
            ]
        case .performance:
            return [
                Row(id: "heap", title: "Memory Limit", kind: .choice(heapOptions, heapBinding), group: "Memory", detail: heapDetail),
                Row(id: "extramem", title: "Increased Memory", kind: .toggle($ramDonorHeap),
                    detail: "Holds the game's Java memory in helper processes, so iOS doesn't count it against the app. Uses private iOS features and may stop working. Applies on the next start."),
            ] + (ramDonorHeap ? [
                Row(id: "donorheapsize", title: "Increased Memory Limit", kind: .choice(increasedLimitOptions, $donorHeapGB),
                    detail: "Java memory size while Increased Memory is on. The first choice is your normal Memory Limit. The device's own RAM is the real limit. Applies on the next start."),
            ] : []) + [
                Row(id: "gc", title: "Collector", kind: .choice(["Parallel", "pzGC", "SGC", "pzSGC"], gcBinding), group: "Garbage collector", detail: gcDetail),
                Row(id: "astc", title: "ASTC Compression", kind: .toggle($astc), group: "Graphics", detail: astcDetail),
                Row(id: "jitc", title: "JIT Compiler", kind: .choice(["C1", "C1+C2 gentle", "C1+C2 full"], $jitCompiler), group: "Java", detail: jitCompilerDetail),
            ]
        case .controls:
            return [
                Row(id: "vpad", title: "Virtual Gamepad", kind: .toggle($virtualPad), group: "On-screen",
                    detail: virtualPad ? "On: The on-screen controls act as a game controller (two sticks, A/B/X/Y, D-pad, bumpers, triggers). Use the game's controller mode. Applies on the next start."
                                       : "Off: The on-screen controls send keyboard and mouse input. Turn on to use them as a game controller. Applies on the next start."),
                Row(id: "icons", title: "Icons on Controls", kind: .toggle($touchIcons),
                    detail: touchIcons ? "On: Each on-screen control draws an icon instead of its text, where it has one (the PAD/TCH button and the fire-mode toggle keep their words, because that text is their state). Applies on the next start."
                                       : "Off: Every control shows its text label. Applies on the next start."),
                Row(id: "driveauto", title: "Switch in a Vehicle", kind: .toggle($drivingAuto),
                    detail: drivingAuto ? "On: The touch layout switches to the driving layout by itself when you get into a vehicle, and back when you get out. The game's Lua writes a small marker for it (pziOSDrive.lua); a DRIVE button or radial option still switches by hand. Applies on the next start."
                                        : "Off: The layouts never switch by themselves. Add a DRIVE toggle to a touch layout (or use the one in its radial menu) to switch by hand. Applies on the next start."),
            ] + (virtualPad ? [
                Row(id: "padstyle", title: "Gamepad Buttons", kind: .choice(["Xbox", "PlayStation"], Binding(get: { padStyle }, set: { padStyle = $0; PadCatalog.setStyle($0) })),
                    detail: padStyle == 1 ? "PlayStation: Buttons are labelled like a DualSense (✕ ○ □ △, L1/R1, L2/R2, Create, Options). They send the same input as the Xbox names."
                                          : "Xbox: Buttons are labelled like an Xbox controller (A B X Y, LB/RB, LT/RT, Back, Start). Switch to PlayStation to use DualSense names."),
            ] : [
                Row(id: "twofinger", title: "Two-Finger Zoom", kind: .toggle($twoFingerZoom),
                    detail: "Two fingers landing together on empty screen scroll the game's zoom. Turn off if it triggers by accident. Applies on the next start."),
            ]) + [
                Row(id: virtualPad ? "padedit" : "touch", title: virtualPad ? "Edit gamepad layout" : "Edit touch layout",
                    kind: .action(destructive: false) { editor = virtualPad ? .pad : .touch }, group: "Layout",
                    detail: virtualPad ? "Drag the gamepad controls, change what each one does, resize them, or add your own."
                                       : "Drag the on-screen buttons and joystick, change which key each one sends, resize them, or add your own. Presets (Default, Claw, Claw V, Pro, Max, Minimal) are a quick start, and the editor shows the safe area and the game's UI margins so controls land exactly where you put them."),
                Row(id: "ctrlstatus", title: controllerStatus, kind: .info, group: "Real controller"),
                Row(id: "deadzone", title: "Stick deadzone", kind: .slider(0...0.95, deadZoneBinding, String(format: "%.0f%%", controllerConfig.deadZone * 100)),
                    detail: "How far a stick must move before the game sees it. Raise it if your character drifts with the sticks at rest."),
                Row(id: "ctrl", title: "Remap and test controller", kind: .action(destructive: false) { editor = .controller },
                    detail: "Press a control to bind it, swap A/B for Nintendo-style pads, turn off the automatic hiding of the on-screen controls, and watch what every button reports."),
                Row(id: "n", title: "The on-screen controls hide while a controller (unless you turn that off above), or a keyboard and mouse together, are connected. Changes apply next time the game starts.", kind: .info),
            ]
        case .jit:
            var r = [Row(id: "setup", title: "Setup guide", kind: .action(destructive: false) { editor = .setup }, group: "Guide",
                         detail: "Game files, Developer Mode and JIT in one place."),
                     Row(id: "method", title: "JIT Mode", kind: .choice(["Manual", "Built-in"], $jitMethod), group: "Method",
                         detail: jitMethod == 0 ? "Manual: After pressing Play, run the pziOS script in StikDebug."
                                                : "Built-in: Attaches automatically. Needs a pairing file, LocalDevVPN connected and Developer Mode on.")]
            if jitMethod == 1 {
                if model.jitAvailable {
                    r += [Row(id: "pair", title: model.pairingStatus, kind: .info, group: "Built-in attach"),
                          Row(id: "import", title: "Import pairing file", kind: .action(destructive: false) { importingPairing = true }),
                          Row(id: "prep", title: "Prepare JIT", kind: .action(destructive: false) { model.onPrepareJIT?() })]
                    if !model.jitStatus.isEmpty { r.append(Row(id: "st", title: model.jitStatus, kind: .info)) }
                    r.append(Row(id: "reset", title: "Reset Developer Disk Image", kind: .action(destructive: true) { model.onResetDDI?() }))
                } else {
                    r.append(Row(id: "na", title: model.jitUnavailableReason, kind: .warning))
                }
            }
            return r
        case .tools:
            return [Row(id: "w", title: "These options can stop the game starting. Leave them alone unless you are testing something.", kind: .info, group: "Developer use only"),
                    Row(id: "aspect", title: "Simulate Aspect Ratio", kind: .choice(["Off", "4:3", "3:2", "16:10", "16:9"], $simAspect), group: "Display",
                        detail: "Makes the game think the screen has another shape, stretched over this one, to check its menus and HUD for iPad screens. 4:3 is an iPad Pro 13\". Set UI Margins to Off while testing."),
                    Row(id: "framepool", title: "Frame Autorelease Pool (Experimental)", kind: .toggle($framePool), group: "Graphics",
                        detail: "Frees the graphics layer's per-frame temporary objects at the end of each frame. In testing it removed a steady memory climb (about 170 MB less after 2 to 3 minutes). Applies the next time the game starts."),
                    Row(id: "zinkbackend", title: "Graphics Backend: Zink (Experimental)", kind: .toggle($zinkBackend),
                        detail: "Runs the game on Mesa Zink over MoltenVK (desktop OpenGL 4.5) instead of the normal graphics layer, for mods that need it, such as Viewpoint. Experimental: slower than the normal path and uses more memory. Applies on the next start."),
                    Row(id: "zinklog", title: "Zink Detailed Log", kind: .toggle($zinkLog),
                        detail: "With the Zink backend on, writes frame timing, draw and pipeline counts and graphics limits to the log every few seconds (Log tab, or jvm.log). Please attach it when reporting performance. Applies on the next start."),
                    Row(id: "zinkprobe", title: zinkRunning ? "Zink Probe: running…" : "Zink Probe", kind: .action(destructive: false) {
                        guard !zinkRunning else { return }
                        zinkRunning = true; zinkResult = ""
                        DispatchQueue.global(qos: .userInitiated).async {
                            var buf = [CChar](repeating: 0, count: 16384)
                            _ = zomZinkProbe(&buf, buf.count)
                            let text = String(cString: buf)
                            try? text.write(to: GameFiles.documents.appendingPathComponent("zink-probe.txt"), atomically: true, encoding: .utf8)
                            DispatchQueue.main.async { zinkResult = text; zinkRunning = false }
                        }
                    }, detail: "Loads Mesa Zink (OpenGL on Vulkan) over MoltenVK, creates an OpenGL 4.5 context and tests the features the Viewpoint mod needs. Takes a few seconds. The report is also saved as zink-probe.txt in the app's folder."),
                    Row(id: "zinkproberes", title: zinkResult.isEmpty ? "Zink Probe result appears here." : zinkResult, kind: .info, group: "Diagnostics"),
                    Row(id: "memlog", title: "Log Memory Use", kind: .toggle($memLog),
                        detail: "Writes the app's memory footprint to jvm.log every 5 seconds, split into Java heap, graphics and native memory."),
                    Row(id: "fps", title: "Show FPS", kind: .toggle($fpsCounter),
                        detail: "Draws the frame rate and frame time in the corner of the game screen, counted at the buffer swap. Handy for seeing what a setting changed; leave it off for normal play. Applies on the next start."),
                    Row(id: "zombiebuddy", title: "ZombieBuddy", kind: .toggle($zombieBuddy), group: "Mods",
                        detail: "Adds -javaagent:ZombieBuddy.jar when the game starts. Put ZombieBuddy.jar in the game folder (Files, pziOS, game); if it isn't there the setting is skipped. Applies on the next start."),
                    Row(id: "resetargs", title: "Reset launch arguments to the default", kind: .action(destructive: true) {
                        try? FileManager.default.removeItem(at: GameFiles.documents.appendingPathComponent("launch.args")) },
                        detail: "Deletes Documents/launch.args. The built-in default is written again the next time the game starts.")]
        case .log:
            return []
        }
    }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Rows of every page whose title, description or group matches the search, tagged with the page they came from.
    private var searchResults: [Row] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var out: [Row] = []
        for t in tabs {
            for r in rows(for: t) {
                let text = ([r.title, r.detail ?? "", r.group ?? "", t.title, t.subtitle]).joined(separator: " ").lowercased()
                guard text.contains(q) else { continue }
                out.append(Row(id: "s.\(t.title).\(r.id)", title: r.title, kind: r.kind,
                               group: t.title + (r.group.map { " · \($0)" } ?? ""), detail: r.detail, locked: r.locked))
            }
        }
        return out
    }

    private var displayedRows: [Row] { searching ? searchResults : rows }
    private var focusable: [Row] { displayedRows.filter { $0.focusable && !$0.locked } }

    var body: some View {
        GeometryReader { geo in
            let m = Metrics(size: geo.size)
            ZStack {
                Theme.background
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        sidebar(m).frame(width: m.v(196))
                        Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1).padding(.vertical, m.v(12))
                        content(m)
                    }
                    .frame(maxHeight: .infinity)
                    footer(m)
                }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .fileImporter(isPresented: $importingPairing, allowedContentTypes: [.propertyList, .data, .item]) { result in
            if case .success(let url) = result { model.onImportPairing?(url) }
        }
        .fullScreenCover(item: $editor) { e in
            switch e {
            case .touch: TouchLayoutEditor()
            case .pad: TouchLayoutEditor(pad: true)
            case .margins: ScreenMarginEditor()
            case .setup: SetupView(model: model, pad: pad)
            case .controller: ControllerEditor()
            }
        }
        .alert("Developer Tools", isPresented: $confirmDev) {
            Button("Enable") { devTools = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text("For developer use only. Shows the Tools and Log tabs. Not needed for normal play.") }
        .onAppear {
            let d = UserDefaults.standard
            if d.object(forKey: "zom.jitCompiler") == nil && d.bool(forKey: "zom.c2") { jitCompiler = 2 }      // the old C2 switch becomes "C1 + C2 full"
            pads.start()
        }
        .onDisappear { pads.stop() }
        .onChange(of: editor) { _, e in
            guard e == nil else { return }
            controllerConfig = ControllerSettings.load()      // the Controller screen may have changed the mapping or deadzone
            pads.refresh()
        }
        .onChange(of: tab) { _, _ in focus = 0; query = "" }
        .onChange(of: query) { _, _ in focus = 0 }
        .onChange(of: devTools) { _, on in if !on && tab.developerOnly { tab = .performance } }
        .onChange(of: pad.tick) { _, _ in handle(pad.last) }
    }

    // MARK: sidebar

    private func sidebar(_ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.system(size: m.v(19), weight: .bold)).padding(.bottom, m.v(6)).padding(.leading, m.v(8))
            searchField(m)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: m.v(1)) {
                    ForEach(Self.sections, id: \.self) { section in
                        Text(section.uppercased()).font(.system(size: m.v(9), weight: .bold)).tracking(m.v(1))
                            .foregroundStyle(Theme.faint)
                            .padding(.leading, m.v(9)).padding(.top, m.v(10)).padding(.bottom, m.v(3))
                        ForEach(tabs.filter { $0.section == section }, id: \.rawValue) { t in tabButton(t, m) }
                    }
                }
                .padding(.bottom, m.v(6))
            }
            Button { Haptics.tap(); if devTools { devTools = false } else { confirmDev = true } } label: {
                Text("Developer Tools").font(.system(size: m.v(12), weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity).frame(height: m.v(32))
                    .background(devTools ? Color.white : Color.white.opacity(0.08), in: Capsule())          // white = on
                    .foregroundStyle(devTools ? Color.black : Theme.dim)
            }.buttonStyle(PressStyle())
        }
        .padding(.leading, m.v(16)).padding(.trailing, m.v(10)).padding(.top, m.v(24)).padding(.bottom, m.v(12))
    }

    /// Search across every page, so a setting is found without remembering which tab it is on.
    private func searchField(_ m: Metrics) -> some View {
        HStack(spacing: m.v(5)) {
            Image(systemName: "magnifyingglass").font(.system(size: m.v(10), weight: .semibold)).foregroundStyle(Theme.faint)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain).autocorrectionDisabled().textInputAutocapitalization(.never)
                .font(.system(size: m.v(11.5))).foregroundStyle(.white)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: m.v(11))).foregroundStyle(Theme.faint)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, m.v(8)).frame(height: m.v(28))
        .background(Color.white.opacity(0.08), in: Capsule())
        .padding(.horizontal, m.v(8)).padding(.bottom, m.v(4))
    }

    private func tabButton(_ t: Tab, _ m: Metrics) -> some View {
        Button { Haptics.tap(); withAnimation(.easeOut(duration: 0.16)) { tab = t } } label: {
            HStack(spacing: m.v(9)) {
                Image(systemName: t.icon).font(.system(size: m.v(12), weight: .semibold)).frame(width: m.v(18))
                Text(t.title).font(.system(size: m.v(13), weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, m.v(9)).frame(height: m.v(32))
            .background(tab == t ? Color.white.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: m.v(8)))
            .foregroundStyle(tab == t ? Color.white : Theme.dim)
        }.buttonStyle(PressStyle())
    }

    // MARK: content

    @ViewBuilder private func content(_ m: Metrics) -> some View {
        if tab == .log && !searching {
            VStack(alignment: .leading, spacing: m.v(8)) {
                header(m)
                HStack(spacing: m.v(10)) {
                    Text("Read-only. The same output is saved as jvm.log in the app's folder.")
                        .font(.system(size: m.v(10.5))).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    if let log = logFileURL {
                        ShareLink(item: log) {
                            Label("Share log", systemImage: "square.and.arrow.up").font(.system(size: m.v(11), weight: .semibold))
                                .padding(.horizontal, m.v(10)).frame(height: m.v(26))
                                .background(Color.white.opacity(0.12), in: Capsule())
                        }.buttonStyle(PressStyle())
                    }
                }
                LogView(text: model.log)
            }
            .padding(.horizontal, m.v(18)).padding(.top, m.v(24)).padding(.bottom, m.v(12))
            .padding(.trailing, m.v(10))
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: m.v(6)) {
                    header(m)
                    ForEach(displayedRows) { row in
                        RowView(row: row, m: m, focused: pad.active && row.focusable && focusable.indices.contains(focus) && focusable[focus].id == row.id)
                    }
                    if searching && displayedRows.isEmpty {
                        Text("Nothing on the settings pages matches that. Try a shorter word, such as “texture” or “memory”.")
                            .font(.system(size: m.v(11.5))).foregroundStyle(Theme.dim)
                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, m.v(6))
                    }
                }
                .frame(maxWidth: m.v(660))
                .padding(.horizontal, m.v(18)).padding(.bottom, m.v(16))
                .frame(maxWidth: .infinity)
            }
            .animation(.easeInOut(duration: 0.16), value: tab)
            .animation(.easeInOut(duration: 0.16), value: searching)
        }
    }

    private func header(_ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: m.v(2)) {
            Text(searching ? "Search" : tab.title).font(.system(size: m.v(22), weight: .bold))
            Text(searching ? (displayedRows.isEmpty ? "No setting matches “\(query)”."
                                                     : "\(displayedRows.count) setting\(displayedRows.count == 1 ? "" : "s") found, from every page.")
                           : tab.subtitle)
                .font(.system(size: m.v(11.5))).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, m.v(6))
        .padding(.top, m.v(2))
    }

    private func footer(_ m: Metrics) -> some View {
        HStack(spacing: m.v(12)) {
            if pad.active {
                Text("D-pad move · A select · LB/RB pages · B back")
                    .font(.system(size: m.v(10), weight: .medium)).foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 0)
            Button { Haptics.tap(); dismiss() } label: {
                Text("Done").font(.system(size: m.v(14), weight: .semibold)).frame(width: m.v(160), height: m.v(36))
                    .background(Theme.accent, in: Capsule()).foregroundStyle(.black)
            }.buttonStyle(PressStyle())
        }
        .padding(.horizontal, m.v(20)).padding(.top, m.v(8)).padding(.bottom, m.v(16))
    }

    /// This run's log, or the one kept from the previous run when this one has not written anything yet (main.m rotates
    /// jvm.log to jvm-last.log at every start), so a crash can still be attached to a bug report.
    private var logFileURL: URL? {
        let fm = FileManager.default
        let current = GameFiles.documents.appendingPathComponent("jvm.log")
        let last = GameFiles.documents.appendingPathComponent("jvm-last.log")
        if fm.fileExists(atPath: current.path) { return current }
        if fm.fileExists(atPath: last.path) { return last }
        return nil
    }

    private func handle(_ k: PadKey) {
        guard editor == nil else { return }        // an editor on top handles its own input; don't navigate behind it
        switch k {
        case .b: dismiss(); return
        case .lb: if let i = tabs.firstIndex(of: tab) { tab = tabs[(i + tabs.count - 1) % tabs.count] }; return
        case .rb: if let i = tabs.firstIndex(of: tab) { tab = tabs[(i + 1) % tabs.count] }; return
        default: break
        }
        let items = focusable
        guard !items.isEmpty else { return }
        focus = min(max(focus, 0), items.count - 1)
        switch (k, items[focus].kind) {
        case (.up, _): focus = max(0, focus - 1)
        case (.down, _): focus = min(items.count - 1, focus + 1)
        case (.left, .choice(_, let b)): b.wrappedValue = max(0, b.wrappedValue - 1)
        case (.right, .choice(let o, let b)): b.wrappedValue = min(o.count - 1, b.wrappedValue + 1)
        case (.left, .toggle(let b)): b.wrappedValue = false
        case (.right, .toggle(let b)): b.wrappedValue = true
        case (.left, .slider(let r, let v, _)): v.wrappedValue = max(r.lowerBound, v.wrappedValue - (r.upperBound - r.lowerBound) / 20)
        case (.right, .slider(let r, let v, _)): v.wrappedValue = min(r.upperBound, v.wrappedValue + (r.upperBound - r.lowerBound) / 20)
        case (.a, .choice(let o, let b)): b.wrappedValue = (b.wrappedValue + 1) % o.count
        case (.a, .toggle(let b)): b.wrappedValue.toggle()
        case (.a, .action(_, let f)): f()
        default: break
        }
    }
}

struct RowView: View {
    let row: Row
    let m: Metrics
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: m.v(1)) {
            if let group = row.group { SectionHeader(title: group, m: m) }
            card()
        }
    }

    @ViewBuilder private func card() -> some View {
        if case .action(let destructive, let f) = row.kind {
            // the whole card is the button, including the description, so tapping anywhere on it works
            Button(action: { Haptics.tap(); f() }) {
                shell {
                    HStack(spacing: m.v(10)) {
                        Text(row.title).font(.system(size: m.v(13.5), weight: .medium))
                            .foregroundStyle(destructive ? Theme.danger : .white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.system(size: m.v(10), weight: .semibold)).foregroundStyle(Theme.faint)
                    }
                }
            }.buttonStyle(PressStyle())
        } else {
            shell {
                switch row.kind {
                case .choice(let options, let sel):
                    HStack(spacing: m.v(8)) { title; Spacer(minLength: 8); Pills(options: options, selection: sel, m: m) }
                case .toggle(let on):
                    HStack(spacing: m.v(8)) { title; Spacer(minLength: 8); Switch(isOn: on, m: m) }
                case .slider(let range, let value, let text):
                    VStack(alignment: .leading, spacing: m.v(6)) {
                        HStack(spacing: 8) {
                            title
                            Spacer(minLength: 8)
                            Text(text).font(.system(size: m.v(11.5), weight: .semibold, design: .monospaced)).foregroundStyle(Theme.dim)
                        }
                        Slider(value: value, in: range).tint(Theme.accent)
                    }
                case .info:
                    Text(row.title).font(.system(size: m.v(11.5))).foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                case .warning:
                    HStack(alignment: .top, spacing: m.v(7)) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: m.v(10), weight: .semibold))
                        Text(row.title).font(.system(size: m.v(11.5))).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Theme.warning).frame(maxWidth: .infinity, alignment: .leading)
                case .progress(let value, let text):
                    VStack(alignment: .leading, spacing: m.v(6)) {
                        ProgressView(value: value).tint(Theme.accent)
                        Text(text).font(.system(size: m.v(10.5), design: .monospaced)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
                    }
                case .action:
                    EmptyView()
                }
            }
        }
    }

    private func shell<Content: View>(@ViewBuilder _ main: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: m.v(4)) {
            main()
            if let d = row.detail {
                Text(d).font(.system(size: m.v(10.5))).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, row.focusable ? m.v(12) : m.v(6))
        .padding(.vertical, row.focusable ? m.v(9) : m.v(2))
        .frame(minHeight: row.focusable ? m.v(42) : 0)
        .background(row.focusable ? AnyShapeStyle(Theme.card) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: m.v(11)))
        .overlay(RoundedRectangle(cornerRadius: m.v(11)).stroke(Color.white.opacity(row.focusable ? 0.07 : 0), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: m.v(11)))
        .padRing(focused, radius: m.v(11))
        .opacity(row.locked ? 0.4 : 1).allowsHitTesting(!row.locked)
    }
    private var title: some View { Text(row.title).font(.system(size: m.v(13.5), weight: .medium)) }
}

private struct LogView: View {
    let text: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(Color(white: 0.02), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

// Previews at each target size (landscape, points): iPhone 18 / 18 Pro, iPhone Air, iPhone 15 Plus, iPhone Pro Max, iPad 11", iPad 13".
#Preview("Home - Pro Max 956x440", traits: .fixedLayout(width: 956, height: 440)) { LauncherView(model: LauncherModel(), onRun: { _ in }) }
#Preview("Home - iPhone 18 874x402", traits: .fixedLayout(width: 874, height: 402)) { LauncherView(model: LauncherModel(), onRun: { _ in }) }
#Preview("Home - iPhone Air 912x420", traits: .fixedLayout(width: 912, height: 420)) { LauncherView(model: LauncherModel(), onRun: { _ in }) }
#Preview("Home - 15 Plus 932x430", traits: .fixedLayout(width: 932, height: 430)) { LauncherView(model: LauncherModel(), onRun: { _ in }) }
#Preview("Home - iPad 11 1194x834", traits: .fixedLayout(width: 1194, height: 834)) { LauncherView(model: LauncherModel(), onRun: { _ in }) }
#Preview("Home - iPad 13 1376x1032", traits: .fixedLayout(width: 1376, height: 1032)) { LauncherView(model: LauncherModel(), onRun: { _ in }) }
#Preview("Settings - Pro Max", traits: .fixedLayout(width: 956, height: 440)) { SettingsView(model: LauncherModel(), pad: PadNav()) }
#Preview("Settings - iPhone 18", traits: .fixedLayout(width: 874, height: 402)) { SettingsView(model: LauncherModel(), pad: PadNav()) }
#Preview("Settings - iPad 13", traits: .fixedLayout(width: 1376, height: 1032)) { SettingsView(model: LauncherModel(), pad: PadNav()) }
