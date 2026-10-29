// Editor for a real (physical) controller: remap every logical input by pressing the one you want, tune the stick
// deadzone, and watch what the controller actually reports. Zomdroid does the same thing from its Android input layer
// (MIT, see licenses/Zomdroid-MIT.txt); here the reading is polled, so the launcher's own gamepad navigation and the
// capture sheet never fight over GameController handlers.
import SwiftUI
import GameController
import Combine

struct ControllerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ControllerSettings.load()
    @State private var capture: CaptureTarget?
    @State private var frame = PadSnapshot()
    @State private var pads: [GCController] = []

    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.base.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        liveSection
                        optionsSection
                        mappingSection
                        footer
                    }
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .onReceive(tick) { _ in
            guard capture == nil else { return }        // the capture sheet has its own tick
            pads = PadReader.connected
            frame = PadReader.snapshot(PadReader.primary)
        }
        .sheet(item: $capture) { target in
            CaptureView(target: target.output) { result in
                switch result {
                case .button(let raw): if let s = PadSource(rawValue: raw) { settings.bind(s, to: target.output) }
                case .axis(let raw): if let s = PadAxisSource(rawValue: raw) { settings.bind(s, to: target.output) }
                }
                settings.save()
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Controller").font(.system(size: 18, weight: .bold))
                Text("Applies the next time the game starts.").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }
            Spacer()
            Button { dismiss() } label: {
                Text("Done").font(.system(size: 14, weight: .semibold)).frame(width: 110, height: 34)
                    .background(Theme.accent, in: Capsule()).foregroundStyle(.black)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 10)
    }

    // MARK: live input

    private var liveSection: some View {
        section("Connected") {
            if pads.isEmpty {
                Text("No controller connected. Connect one with Bluetooth or a cable; it is picked up without restarting.")
                    .font(.system(size: 12)).foregroundStyle(Theme.dim)
            } else {
                ForEach(Array(pads.enumerated()), id: \.offset) { entry in
                    let c = entry.element
                    HStack(spacing: 8) {
                        Image(systemName: "gamecontroller").font(.system(size: 13))
                        Text(PadReader.name(c)).font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 8)
                        Text(c.extendedGamepad != nil ? "Gamepad" : "Limited")
                            .font(.system(size: 11)).foregroundStyle(Theme.dim)
                    }
                }
                if PadReader.primary == nil {
                    Text("The game needs a controller with sticks and triggers (an extended gamepad).")
                        .font(.system(size: 11)).foregroundStyle(Color.orange)
                }
            }
            Divider().overlay(Color.white.opacity(0.1))
            axisBar("Left X", frame.axes[0], centered: true)
            axisBar("Left Y", frame.axes[1], centered: true)
            axisBar("Right X", frame.axes[2], centered: true)
            axisBar("Right Y", frame.axes[3], centered: true)
            axisBar("LT", frame.axes[4], centered: false)
            axisBar("RT", frame.axes[5], centered: false)
            HStack(alignment: .top, spacing: 8) {
                Text("Down").font(.system(size: 12)).frame(width: 96, alignment: .leading).foregroundStyle(Theme.dim)
                Text(frame.pressedTitles.isEmpty ? "—" : frame.pressedTitles.joined(separator: " · "))
                    .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func axisBar(_ label: String, _ value: Double, centered: Bool) -> some View {
        let filled = centered ? (value + 1) / 2 : value
        return HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).frame(width: 96, alignment: .leading).foregroundStyle(Theme.dim)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(Theme.accent.opacity(0.8))
                        .frame(width: max(2, g.size.width * CGFloat(min(max(filled, 0), 1))))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 6)
            Text(String(format: "%+.2f", value)).font(.system(size: 11, design: .monospaced))
                .frame(width: 52, alignment: .trailing).foregroundStyle(Theme.dim)
        }
    }

    // MARK: options

    private var optionsSection: some View {
        section("Settings") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Stick deadzone").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(String(format: "%.0f%%", settings.deadZone * 100))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim)
                }
                Slider(value: Binding(get: { settings.deadZone },
                                      set: { settings.deadZone = $0; settings.save() }), in: 0...0.95)
                    .tint(Theme.accent)
                Text("How far a stick must move before the game sees it. Raise it if your character drifts with the sticks at rest.")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: Binding(get: { settings.overlayAutoHide },
                                 set: { settings.overlayAutoHide = $0; settings.save() })) {
                Text("Hide on-screen controls while a controller is connected").font(.system(size: 13, weight: .medium))
            }.tint(Theme.accent)

            HStack {
                Text("Prefer a Nintendo-style pad?").font(.system(size: 13, weight: .medium))
                Spacer()
                Button {
                    settings.swapAB(); settings.save()
                } label: {
                    Text("Swap A/B").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }.buttonStyle(.plain)
            }
        }
    }

    // MARK: mapping

    private var mappingSection: some View {
        section("What each input does") {
            Text("Tap an input, then press the control you want it to read. A button can be told to act as a trigger, and either stick axis can read any axis.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
                ForEach(PadOutput.all) { output in
                    Button { capture = CaptureTarget(output: output) } label: {
                        HStack(spacing: 8) {
                            Text(output.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            Spacer(minLength: 8)
                            Text(currentLabel(output)).font(.system(size: 12)).lineLimit(1)
                                .foregroundStyle(Theme.dim)
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.dim.opacity(0.6))
                        }
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func currentLabel(_ output: PadOutput) -> String {
        switch output {
        case .button: return settings.source(for: output)?.title ?? "—"
        case .axis: return settings.axisSource(for: output)?.title ?? "—"
        }
    }

    private var footer: some View {
        Button {
            settings = ControllerSettings(); settings.save()
        } label: {
            Text("Reset controller settings").font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(Color.red.opacity(0.18), in: Capsule()).foregroundStyle(Color.red)
        }.buttonStyle(.plain)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.dim)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }
}

// MARK: - Capture sheet

private struct CaptureTarget: Identifiable {
    let output: PadOutput
    var id: String { output.id }
}

private enum CaptureResult { case button(Int); case axis(Int) }

/// Waits for the next control that moves and hands back its physical index. Nothing is installed on the controller, so a
/// capture that is cancelled or interrupted leaves the pad exactly as it was.
private struct CaptureView: View {
    let target: PadOutput
    let onBind: (CaptureResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var frame = PadSnapshot()
    @State private var baseline: PadSnapshot?
    @State private var done = false
    @State private var hint = "Press the control you want."

    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            Text(target.title).font(.system(size: 17, weight: .bold))
            Text(hint).font(.system(size: 12)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)

            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    VStack(spacing: 4) {
                        Capsule().fill(Color.white.opacity(0.12))
                            .frame(width: 10, height: 44)
                            .overlay(alignment: (i < 4 ? (frame.axes[i] >= 0 ? .top : .bottom) : .bottom)) {
                                Capsule().fill(Theme.accent)
                                    .frame(width: 10, height: max(2, 44 * CGFloat(barFraction(i))))
                            }
                        Text(["LX", "LY", "RX", "RY", "LT", "RT"][i]).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
                    }
                }
            }

            Text(frame.pressedTitles.isEmpty ? "—" : frame.pressedTitles.joined(separator: " · "))
                .font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(2)

            Button { dismiss() } label: {
                Text("Cancel").font(.system(size: 13, weight: .semibold)).frame(width: 120, height: 34)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }.buttonStyle(.plain)
        }
        .padding(22)
        .frame(maxWidth: 420)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 16))
        .onReceive(tick) { _ in detect() }
        .onAppear { if PadReader.primary == nil { hint = "No controller connected." } }
    }

    private func barFraction(_ i: Int) -> Double {
        let v = frame.axes[i]
        return i < 4 ? abs(v) : min(max(v, 0), 1)
    }

    private func detect() {
        guard !done else { return }
        guard let gamepad = PadReader.primary?.extendedGamepad else {
            hint = "No controller connected."; baseline = nil; return
        }
        frame = PadSnapshot.read(gamepad)
        // Whatever is already held when the sheet opens is ignored, so a trigger that rests above the threshold (or a thumb
        // resting on a button) cannot bind itself the moment the sheet appears.
        guard let base = baseline else { baseline = frame; return }
        switch target {
        case .button:
            // The first button that went from up to down, triggers included (they count as buttons at half press).
            if let i = (0..<17).first(where: { frame.buttons[$0] && !base.buttons[$0] }) { finish(.button(i)) }
        case .axis:
            // The axis that moved furthest past the threshold, so a resting trigger or a slightly-off stick is ignored.
            var best = -1
            var bestValue = 0.6
            for i in 0..<6 where abs(frame.axes[i]) > bestValue && abs(base.axes[i]) <= 0.6 {
                bestValue = abs(frame.axes[i]); best = i
            }
            if best >= 0 { finish(.axis(best)) }
        }
    }

    private func finish(_ result: CaptureResult) {
        done = true
        onBind(result)
        dismiss()
    }
}

#Preview("Controller", traits: .fixedLayout(width: 956, height: 440)) { ControllerEditor() }
