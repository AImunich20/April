// SiriPanel.swift — เรียกใช้ April แบบ Siri: แผงลอยเล็กมุมขวาบนของจอ
//   เรียกด้วยคีย์ลัด (HotKey.swift) หรือคำว่า "April" (WakeWord.swift) -> เสียง "ติ๊ง" -> ฟังทันที
//   -> แสดงคำที่พูด/คำตอบ + อ่านออกเสียง -> รอฟังคำถามต่อ -> เงียบ = ซ่อนตัวเอง
//   พิมพ์ถามแทนพูดได้ในช่องด้านล่าง (แบบ "Type to Siri") · แตะลูกแก้ว = เริ่ม/หยุดฟัง หรือพูดแทรก · Esc = ปิด
// แผงเป็น NSPanel แบบ non-activating: ไม่ดึงโฟกัสจากแอปที่ใช้อยู่ ลอยอยู่บนทุก Space รวมถึงแอปเต็มจอ

import AppKit
import SwiftUI

final class SiriNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }      // ให้พิมพ์ในช่องถามได้
}

@MainActor
enum SiriPanel {
    private static var panel: SiriNSPanel?
    private static var delegate: Delegate?

    final class Delegate: NSObject, NSWindowDelegate {
        func windowDidResize(_ notification: Notification) {
            guard let w = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated { SiriPanel.anchor(w) }
        }
    }

    static var visible: Bool { panel?.isVisible ?? false }

    /// คีย์ลัด/คำปลุก: ยังไม่เปิด = เปิดแล้วฟัง · เปิดอยู่แต่ไม่ได้ฟัง = ฟังใหม่ · กำลังคุยอยู่ = ปิด
    static func summon(_ app: AppState) {
        if visible, app.talk.convo || app.talk.busy {
            hide(app)
            return
        }
        show(app)
        app.talk.wake()
    }

    static func show(_ app: AppState) {
        let p = panel ?? make(app)
        if !p.isVisible { app.talk.appear() }
        anchor(p)
        p.orderFrontRegardless()
        p.makeKey()
    }

    static func hide(_ app: AppState) {
        guard let p = panel, p.isVisible else { return }
        p.orderOut(nil)
        app.talk.disappear()
    }

    static func anchor(_ w: NSWindow) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let f = w.frame
        w.setFrameOrigin(NSPoint(x: screen.maxX - f.width - 14, y: screen.maxY - f.height - 14))
    }

    private static func make(_ app: AppState) -> SiriNSPanel {
        let p = SiriNSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: SiriView(onClose: { SiriPanel.hide(app) })
            .environment(app.talk).environment(app.hotkey))
        host.sizingOptions = [.preferredContentSize]    // แผงสูงตามเนื้อหา (คำตอบยาว = แผงยาวลง)
        p.contentView = host
        let d = Delegate()
        p.delegate = d
        delegate = d
        panel = p
        return p
    }
}

struct SiriView: View {
    @Environment(TalkModel.self) private var talk
    @Environment(HotKey.self) private var hotkey
    let onClose: () -> Void

    /// ว่างจริง (ไม่ฟัง ไม่คิด ไม่พูด ไม่ได้พิมพ์ค้าง) -> ซ่อนตัวเองหลังผ่านไปครู่หนึ่ง
    private var idle: Bool {
        !talk.convo && !talk.busy && talk.input.isEmpty && [.idle, .error].contains(talk.state)
    }

    var body: some View {
        @Bindable var talk = talk
        let lastMe = talk.turns.last(where: \.me)?.text
        let answer = talk.turns.last.flatMap { $0.me ? nil : $0.text } ?? ""
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                OrbView()
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
                    .onTapGesture { talk.tap() }
                    .help("แตะเพื่อเริ่ม/หยุดฟัง")
                VStack(alignment: .leading, spacing: 2) {
                    Text("April").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    Text(talk.detail ?? talk.state.label).font(.system(size: 12))
                        .foregroundStyle(talk.state == .error ? Color.red : .secondary).lineLimit(2)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain).help("ปิด (Esc)")
            }

            if !talk.caption.isEmpty || lastMe != nil {
                Text("“\(talk.caption.isEmpty ? lastMe ?? "" : talk.caption)”")
                    .font(.system(size: 13.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(3)
            }

            if !answer.isEmpty {
                ScrollView {
                    Text(markdown(answer)).font(.system(size: 14)).foregroundStyle(.primary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField("พิมพ์ถาม April…", text: $talk.input)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .onSubmit { talk.submitTyped() }
                if talk.busy || talk.state == .speaking {
                    Button { talk.interrupt() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 9)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(.secondary, in: Circle())
                    }
                    .buttonStyle(.plain).help("หยุด")
                } else {
                    Text(hotkey.choice.label).font(.system(size: 10.5, design: .rounded)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .padding(16)
        .frame(width: 380)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 22)))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.14)))
        .background {
            Button("") { talk.interrupt(); onClose() }
                .keyboardShortcut(.escape, modifiers: []).opacity(0).frame(width: 0, height: 0)
        }
        .task(id: "\(idle)-\(talk.state.rawValue)-\(talk.turns.count)") {
            guard idle else { return }
            try? await Task.sleep(for: .seconds(talk.state == .error ? 10 : 8))
            if !Task.isCancelled && idle { onClose() }
        }
    }
}

/// พื้นกระจกฝ้าแบบเดียวกับแผงของระบบ (เบลอสิ่งที่อยู่หลังหน้าต่าง)
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - ลูกแก้ว: กลุ่มอนุภาคที่เปลี่ยนรูปตามเสียง (ย่อจาก HUD ของ Envy) — สีเปลี่ยนตามสถานะ

final class OrbFace {
    private var energy = 0.1, spin = 0.0, morph = 0.0, pulse = 0.0, seenPulse = 0.0, last = 0.0
    private var main: [Double] = [255, 170, 70], hot: [Double] = [255, 235, 200]

    private static let points: [(x: Double, y: Double, z: Double, s: Double)] = (0..<420).map { i in
        let y = 1 - Double(i) / 419 * 2, r = (1 - y * y).squareRoot(), a = Double(i) * 2.399963
        return (cos(a) * r, y, sin(a) * r, Double.random(in: 0..<1))
    }
    private static let palette: [TalkState: ([Double], [Double])] = [
        .idle: ([255, 170, 70], [255, 235, 200]), .speaking: ([255, 160, 90], [255, 245, 225]),
        .listening: ([70, 200, 255], [215, 245, 255]), .thinking: ([190, 120, 255], [235, 215, 255]),
        .hearing: ([190, 120, 255], [235, 215, 255]), .error: ([255, 85, 85], [255, 205, 195]),
    ]

    private func c(_ v: [Double], _ a: Double) -> Color {
        Color(.sRGB, red: v[0] / 255, green: v[1] / 255, blue: v[2] / 255, opacity: max(0, min(1, a)))
    }
    private func mix(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }

    func draw(_ g: inout GraphicsContext, size: CGSize, t: Double, state: TalkState, level: Float, pulseAt: Double) {
        let dt = last == 0 ? 0 : min(0.05, max(0, t - last))
        last = t
        let ctr = CGPoint(x: size.width / 2, y: size.height / 2), R = min(size.width, size.height) * 0.36
        let speaking = state == .speaking, listening = state == .listening, thinking = state == .thinking || state == .hearing
        if pulseAt > seenPulse { seenPulse = pulseAt; pulse = 1 }
        pulse *= pow(0.02, dt)
        let target = speaking ? 0.35 + 0.4 * abs(sin(t * 12)) * (0.5 + pulse) + 0.3 * pulse
            : listening ? 0.15 + Double(level) * 2.6 : thinking ? 0.5 : 0.12
        energy = mix(energy, min(1.2, target), 1 - pow(0.001, dt))
        spin += (thinking ? 2.4 : 0.8) * dt
        morph += (thinking ? 3 : 0.8 + energy * 2.4) * dt
        let p = OrbFace.palette[state] ?? OrbFace.palette[.idle]!, k = 1 - pow(0.02, dt)
        main = zip(main, p.0).map { mix($0, $1, k) }
        hot = zip(hot, p.1).map { mix($0, $1, k) }

        g.blendMode = .plusLighter
        let glowR = R * (1.45 + energy * 0.3)
        g.fill(Path(ellipseIn: CGRect(x: ctr.x - glowR, y: ctr.y - glowR, width: glowR * 2, height: glowR * 2)),
               with: .radialGradient(Gradient(colors: [c(main, 0.35 + energy * 0.25), c(main, 0)]),
                                     center: ctr, startRadius: 0, endRadius: glowR))
        let cy = cos(spin), sy = sin(spin), tilt = 0.4 * sin(t * 0.5), ct = cos(tilt), st = sin(tilt)
        let amp = 0.16 + energy * 0.38, freq = 2.6 + energy * 3
        var dots = [Path](repeating: Path(), count: 6)
        for pt in OrbFace.points {
            let f = sin(pt.x * 2.1 + morph * 1.3) * sin(pt.y * 2.7 - morph * 0.9) * 0.5
                + sin(pt.z * 3.3 + morph * 1.7 + pt.x * 1.5) * 0.3 + sin((pt.x + pt.y - pt.z) * freq + morph * 2.2) * 0.2
            let d = 1 + amp * f
            let x = pt.x * d, y = pt.y * d, z = pt.z * d
            let x1 = x * cy - z * sy, z1 = x * sy + z * cy
            let y2 = y * ct - z1 * st, z2 = y * st + z1 * ct
            let persp = 2.4 / (2.4 - z2)
            let front = max(0, min(0.999, (z2 + 1.4) / 2.8))
            let s = (0.6 + front * 1.3) * (0.7 + pt.s * 0.6) * max(0.7, R / 30)
            let px = ctr.x + x1 * R * persp, py = ctr.y + y2 * R * persp
            dots[Int(front * 6)].addEllipse(in: CGRect(x: px - s / 2, y: py - s / 2, width: s, height: s))
        }
        for b in 0..<6 { g.fill(dots[b], with: .color(c(b >= 4 ? hot : main, 0.25 + Double(b) / 6 * 0.7))) }
        let coreR = R * (0.55 + energy * 0.35)
        g.fill(Path(ellipseIn: CGRect(x: ctr.x - coreR, y: ctr.y - coreR, width: coreR * 2, height: coreR * 2)),
               with: .radialGradient(Gradient(colors: [c(hot, 0.6 + energy * 0.3), c(main, 0)]),
                                     center: ctr, startRadius: 0, endRadius: coreR))
    }
}

struct OrbView: View {
    @Environment(TalkModel.self) private var talk
    @ViewState private var face = OrbFace()
    private static let epoch = Date.now

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { g, size in
                face.draw(&g, size: size, t: tl.date.timeIntervalSince(OrbView.epoch), state: talk.state, level: talk.level,
                          pulseAt: talk.pulseAt - OrbView.epoch.timeIntervalSinceReferenceDate)
            }
        }
    }
}
