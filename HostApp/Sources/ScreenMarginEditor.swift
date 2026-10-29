// Screen margin editor: the whole screen is the canvas. Drag the four edges to set which region the game UI may use; everything outside is kept
// clear (rounded corners, Dynamic Island, a case). The dashed outline is what Auto would pick for this device. Changes save as the Custom option.
import SwiftUI
import UIKit

struct ScreenMarginEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("zom.uiMargin") private var level = 2
    @State private var f: [Double]                  // left, top, right, bottom as fractions of the screen
    @State private var panelOffset = CGSize.zero
    @State private var panelDrag = CGSize.zero
    @State private var saveItem: DispatchWorkItem?
    private let device = ZomMargins.device()

    init() {
        let d = ZomMargins.device()
        _f = State(initialValue: ZomMargins.customFractions() ?? ScreenMarginEditor.fractions(ZomMargins.autoPoints(d, scale: 1), d))
    }

    private static func fractions(_ p: [CGFloat], _ d: ZomMargins.Device) -> [Double] {
        [Double(p[0] / d.width), Double(p[1] / d.height), Double(p[2] / d.width), Double(p[3] / d.height)]
    }
    private var auto: [Double] { Self.fractions(ZomMargins.autoPoints(device, scale: 1), device) }

    /// Sizes are shown in game pixels, which depends on the render resolution the game will run at (720p by default).
    private func gamePx(_ i: Int) -> Int {
        let heights = [540.0, 720.0, 900.0, 1080.0]
        let stored = UserDefaults.standard.object(forKey: "zom.renderRes") == nil
            ? (UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1)
            : UserDefaults.standard.integer(forKey: "zom.renderRes")
        let toPx = heights[min(max(stored, 0), 3)] / Double(device.height)
        return Int(((i % 2 == 0 ? Double(device.width) : Double(device.height)) * f[i] * toPx).rounded())
    }

    private func region(_ f: [Double], _ W: CGFloat, _ H: CGFloat) -> CGRect {
        CGRect(x: f[0] * W, y: f[1] * H, width: W * (1 - f[0] - f[2]), height: H * (1 - f[1] - f[3]))
    }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let rect = region(f, W, H)
            ZStack {
                Color(white: 0.04)
                hudMock(rect)
                // dimmed: everything the UI may not use
                Path { p in p.addRect(CGRect(x: 0, y: 0, width: W, height: H)); p.addRoundedRect(in: rect, cornerSize: CGSize(width: 20, height: 20)) }
                    .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                RoundedRectangle(cornerRadius: 20).path(in: region(auto, W, H))
                    .stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                RoundedRectangle(cornerRadius: 20).path(in: rect).stroke(Color.white, lineWidth: 2.5)

                handle(at: CGPoint(x: rect.minX, y: H / 2), axis: .horizontal, index: 0, W: W, H: H)
                handle(at: CGPoint(x: rect.maxX, y: H / 2), axis: .horizontal, index: 2, W: W, H: H)
                handle(at: CGPoint(x: W / 2, y: rect.minY), axis: .vertical, index: 1, W: W, H: H)
                handle(at: CGPoint(x: W / 2, y: rect.maxY), axis: .vertical, index: 3, W: W, H: H)

                panel.frame(width: min(330, W * 0.4))
                    .offset(x: panelOffset.width + panelDrag.width, y: panelOffset.height + panelDrag.height)
            }
            .coordinateSpace(name: "canvas")
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .onChange(of: f) { _, new in
            level = 4                                                   // editing switches UI Margins to Custom
            saveItem?.cancel()
            let work = DispatchWorkItem { UserDefaults.standard.set(new, forKey: ZomMargins.customKey) }
            saveItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        .onDisappear { saveItem?.cancel(); if level == 4 { UserDefaults.standard.set(f, forKey: ZomMargins.customKey) } }
    }

    // MARK: handles

    private func handle(at p: CGPoint, axis: Axis, index: Int, W: CGFloat, H: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.white).frame(width: 34, height: 34)
            Image(systemName: axis == .horizontal ? "arrow.left.and.right" : "arrow.up.and.down").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
        }
        .contentShape(Circle().inset(by: -10))
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas")).onChanged { v in
            var n = f
            switch index {
            case 0: n[0] = min(max(v.location.x / W, 0), min(0.35, 1 - f[2] - 0.3))
            case 2: n[2] = min(max((W - v.location.x) / W, 0), min(0.35, 1 - f[0] - 0.3))
            case 1: n[1] = min(max(v.location.y / H, 0), min(0.3, 1 - f[3] - 0.3))
            default: n[3] = min(max((H - v.location.y) / H, 0), min(0.3, 1 - f[1] - 0.3))
            }
            if n != f { f = n }
        })
        .position(p)
    }

    // MARK: preview of the HUD inside the region

    private func hudMock(_ r: CGRect) -> some View {
        ZStack {
            // left column (hand slots, inventory, health...)
            VStack(spacing: 10) { ForEach(0..<9, id: \.self) { _ in Circle().stroke(Color.white.opacity(0.3), lineWidth: 1.5).frame(width: 26, height: 26) } }
                .position(x: r.minX + 30, y: r.minY + 40 + 9 * 18)
            // speed bar, top right
            RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.3), lineWidth: 1.5).frame(width: 190, height: 30)
                .position(x: r.maxX - 100, y: r.minY + 20)
            // moodles
            VStack(spacing: 10) { ForEach(0..<4, id: \.self) { _ in Circle().stroke(Color.white.opacity(0.3), lineWidth: 1.5).frame(width: 24, height: 24) } }
                .position(x: r.maxX - 20, y: r.minY + 110)
            // prompts, bottom
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.3), lineWidth: 1.5).frame(width: 90, height: 16)
                RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.3), lineWidth: 1.5).frame(width: 90, height: 16)
            }.position(x: r.minX + 62, y: r.maxY - 34)
            RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.3), lineWidth: 1.5).frame(width: 110, height: 16)
                .position(x: r.maxX - 70, y: r.maxY - 26)
            Text("HUD preview").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.3)).position(x: r.midX, y: r.minY + 14)
        }
    }

    // MARK: panel

    private var panel: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Screen Margins").font(.system(size: 15, weight: .bold))
                Spacer()
                Image(systemName: "line.3.horizontal").foregroundStyle(.white.opacity(0.4))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { panelDrag = $0.translation }.onEnded { v in
                panelOffset.width += v.translation.width; panelOffset.height += v.translation.height; panelDrag = .zero
            })

            Text("Left \(gamePx(0))  ·  Top \(gamePx(1))  ·  Right \(gamePx(2))  ·  Bottom \(gamePx(3))")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.7)
            Text("Game pixels. The white outline is where the game UI may go; the dashed line is what Auto picks for this device.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button { f = auto } label: { pill("Use Auto", system: "wand.and.stars") }
                Button { f = [0, 0, 0, 0] } label: { pill("Full screen", system: "arrow.up.left.and.arrow.down.right") }
            }
            Button { dismiss() } label: { pill("Done", system: "checkmark", filled: true) }
        }
        .padding(14)
        .background(Color(white: 0.11).opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func pill(_ title: String, system: String, filled: Bool = false) -> some View {
        Label(title, systemImage: system).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 32)
            .background(filled ? Color.white : Color.white.opacity(0.12), in: Capsule()).foregroundStyle(filled ? Color.black : .white)
    }
}

#Preview("Margin editor", traits: .fixedLayout(width: 956, height: 440)) { ScreenMarginEditor() }
