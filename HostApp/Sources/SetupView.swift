// Setup guide: game files, JIT and a ready check. It uses the same layout as Settings (steps on the left, rows on the right, Done at the bottom)
// and the same controls, including gamepad navigation. It opens by itself when the game files are missing, and from the Game Files button, PLAY
// (when something is missing) and Settings > JIT.
import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var pad: PadNav
    @Environment(\.dismiss) private var dismiss
    @StateObject private var importer = GameImporter()
    @AppStorage("zom.jitMethod") private var jitMethod = 0
    @AppStorage("zom.devModeConfirmed") private var devModeConfirmed = false
    @State private var step = Step.files
    @State private var focus = 0
    // One file picker for both jobs: two .fileImporter modifiers on one view only present the last one (the game picker never opened on iPad).
    private enum Pick { case game, pairing }
    @State private var showPicker = false
    @State private var pickTarget = Pick.game
    @State private var gameInstalled = GameFiles.installed
    @State private var build = GameBuild.loaded()

    enum Step: Int, CaseIterable {
        case files, jit, ready
        var title: String { ["Game files", "JIT", "Ready"][rawValue] }
        var icon: String { ["folder", "bolt", "checkmark.seal"][rawValue] }
    }

    private var jitReady: Bool { jitMethod == 0 ? devModeConfirmed : (devModeConfirmed && model.hasPairing) }
    private var allReady: Bool { gameInstalled && jitReady }
    private func done(_ s: Step) -> Bool { [gameInstalled, jitReady, allReady][s.rawValue] }

    // MARK: rows

    private var rows: [Row] {
        switch step {
        case .files:
            var r = [Row(id: "status", title: gameInstalled ? "Project Zomboid is installed" + (build.map { " (build \($0))" } ?? "") + "." : "The game files are not installed yet.", kind: .info, group: "Game files")]
            if gameInstalled, NativeCheck.manifest != nil, let c = NativeCheck.last { let m = NativeCheck.message(c); r.append(Row(id: "natives", title: m.text, kind: m.warning ? .warning : .info)) }
            switch importer.state {
            case .scanning, .copying:
                r.append(Row(id: "progress", title: "", kind: .progress(importer.progress, importer.detail)))
                r.append(Row(id: "cancel", title: "Cancel import", kind: .action(destructive: true) { importer.cancel() }))
            case .done(let text): r.append(Row(id: "result", title: text, kind: .info))
            case .failed(let text): r.append(Row(id: "result", title: text, kind: .warning))
            case .idle: break
            }
            if !importer.busy {
                r.append(Row(id: "choose", title: gameInstalled ? "Import again..." : "Choose zip or folder...", kind: .action(destructive: false) { pickTarget = .game; showPicker = true },
                             detail: "On your Mac, right-click Project Zomboid and choose Compress, then AirDrop the zip to this device and choose it here. A folder works too. The app finds projectzomboid.jar and the game data and copies only what it needs. Mac libraries and the Mac's bundled Java are never copied."))
                r.append(Row(id: "open", title: "Open Game Files folder", kind: .action(destructive: false) { FolderLink.open("game") }))
            }
            return r
        case .jit:
            var r = [Row(id: "dev", title: devModeConfirmed ? "Developer Mode confirmed" : "Confirm Developer Mode is on",
                         kind: devModeConfirmed ? .info : .action(destructive: false) { Haptics.tap(); devModeConfirmed = true }, group: "Device",
                         detail: "Turn it on in Settings > Privacy & Security > Developer Mode, then restart the device. iOS only allows JIT while a debugger is attached, and that needs Developer Mode."),
                     Row(id: "method", title: "JIT Mode", kind: .choice(["Manual", "Built-in"], $jitMethod), group: "Method",
                         detail: jitMethod == 0 ? "Manual: After pressing Play, run the pziOS script in the StikDebug app."
                                                : "Built-in: Attaches automatically. Needs LocalDevVPN connected and a pairing file for this device.")]
            if jitMethod == 1 {
                if model.jitAvailable {
                    r.append(Row(id: "pair", title: model.pairingStatus, kind: model.hasPairing ? .info : .warning, group: "Pairing"))
                    r.append(Row(id: "import", title: model.hasPairing ? "Replace pairing file..." : "Import pairing file...", kind: .action(destructive: false) { pickTarget = .pairing; showPicker = true }))
                    r.append(Row(id: "test", title: "Test JIT", kind: .action(destructive: false) { model.onPrepareJIT?() }))
                    if !model.jitStatus.isEmpty { r.append(Row(id: "status", title: model.jitStatus, kind: .info)) }
                } else {
                    r.append(Row(id: "na", title: model.jitUnavailableReason, kind: .warning))
                }
            }
            return r
        case .ready:
            return [Row(id: "ready", title: allReady ? "Everything is set. Press Done, then Play." : (gameInstalled ? "Finish the JIT step first." : "Import the game files first."),
                        kind: allReady ? .info : .warning)]
        }
    }
    private var focusable: [Row] { rows.filter(\.focusable) }

    // MARK: layout

    var body: some View {
        GeometryReader { geo in
            let m = Metrics(size: geo.size)
            ZStack {
                Theme.background
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        sidebar(m).frame(width: m.v(168))
                        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1).padding(.vertical, m.v(10))
                        ScrollView {
                            VStack(spacing: m.v(16)) {
                                ForEach(rows) { row in
                                    RowView(row: row, m: m, focused: pad.active && row.focusable && focusable.indices.contains(focus) && focusable[focus].id == row.id)
                                }
                            }
                            .frame(maxWidth: m.v(680))
                            .padding(.horizontal, m.v(16)).padding(.top, m.v(34)).padding(.bottom, m.v(12))
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    Button { dismiss() } label: {
                        Text(allReady ? "Done" : "Close").font(.system(size: m.v(15), weight: .semibold)).frame(width: m.v(180), height: m.v(38))
                            .background(allReady ? Theme.accent : Color.white.opacity(0.12), in: Capsule()).foregroundStyle(allReady ? Color.black : .white)
                    }.buttonStyle(.plain).padding(.top, m.v(10)).padding(.bottom, m.v(24)).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: pickTarget == .pairing ? [.propertyList, .data, .item] : [.zip, .folder]) { result in
            guard case .success(let url) = result else { return }
            switch pickTarget {
            case .game: importer.start(from: url)
            case .pairing: model.onImportPairing?(url)
            }
        }
        .onChange(of: importer.state) { _, st in
            if case .done = st { gameInstalled = GameFiles.installed; build = GameBuild.loaded() }
        }
        .onChange(of: step) { _, _ in focus = 0 }
        .onChange(of: pad.tick) { _, _ in handle(pad.last) }
        .onAppear { gameInstalled = GameFiles.installed; build = GameBuild.loaded() }
    }

    private func sidebar(_ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: m.v(4)) {
            Text("Setup").font(.system(size: m.v(20), weight: .bold)).padding(.bottom, m.v(8))
            ForEach(Step.allCases, id: \.rawValue) { s in
                Button { step = s } label: {
                    Label(s.title, systemImage: done(s) ? "checkmark.circle.fill" : s.icon).font(.system(size: m.v(15), weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, m.v(10)).frame(height: m.v(38))
                        .background(step == s ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(step == s ? Theme.accent : .white)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, m.v(18)).padding(.trailing, m.v(12)).padding(.top, m.v(34)).padding(.bottom, m.v(12))
    }

    // MARK: gamepad

    private func handle(_ k: PadKey) {
        switch k {
        case .b: dismiss(); return
        case .lb: step = Step(rawValue: (step.rawValue + Step.allCases.count - 1) % Step.allCases.count) ?? step; return
        case .rb: step = Step(rawValue: (step.rawValue + 1) % Step.allCases.count) ?? step; return
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
        case (.a, .choice(let o, let b)): b.wrappedValue = (b.wrappedValue + 1) % o.count
        case (.a, .toggle(let b)): b.wrappedValue.toggle()
        case (.a, .action(_, let f)): f()
        default: break
        }
    }
}

#Preview("Setup", traits: .fixedLayout(width: 956, height: 440)) { SetupView(model: LauncherModel(), pad: PadNav()) }
