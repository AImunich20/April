// Island.swift — เรียกใช้ April แบบ Dynamic Island: พื้นที่ดำขยายออกจากรอยบากจอ แสดงแอนิเมชันอย่างเดียว ไม่มีตัวอักษร
//
//   เรียก (คีย์ลัด HotKey.swift / คำว่า "April" WakeWord.swift) -> "ติ๊ง" -> เกาะขยายออกจากรอยบาก -> ฟังทันที
//   -> คิด -> ตอบด้วยเสียง -> รอฟังคำถามต่อ -> เงียบ = หดกลับเข้ารอยบาก
//   หูซ้าย = ลูกแก้วอนุภาค · หูขวา = สถานะ (ฟัง: วงตามเสียงไมค์ · คิด: วงหมุน · พูด: แท่งอีควอไลเซอร์ · ผิดพลาด: จุดแดง)
//   แถบใต้รอยบาก = คลื่นเสียง (ฟัง: เสียงไมค์จริง · พูด: จังหวะคำ · คิด: แสงวิ่ง)
//   แตะเกาะ = เริ่ม/หยุดฟัง หรือพูดแทรก · แตะ 2 ครั้ง / Esc = ปิด · คำตอบเต็มดูย้อนหลังได้ในแท็บ "งาน"
// จอที่ไม่มีรอยบาก: เกาะเป็นแคปซูลดำห้อยจากกลางขอบบนจอ
// หน้าต่างเป็น NSPanel แบบ non-activating ระดับ statusBar: ไม่ดึงโฟกัสจากแอปที่ใช้อยู่ ทับแถบเมนูได้ ทุก Space/แอปเต็มจอ

import AppKit
import Observation
import SwiftUI

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }      // ให้ Esc ปิดได้
}

@MainActor @Observable
final class IslandState {
    var expanded = false
    var notch = CGSize(width: 0, height: 32)       // ขนาดรอยบาก (กว้าง 0 = จอไม่มีรอยบาก)
}

@MainActor
enum Island {
    static let state = IslandState()
    private static var panel: IslandPanel?
    private static var hiding = false
    static let ear: CGFloat = 74                   // ความกว้างของ "หู" แต่ละข้างรอยบาก
    static let strip: CGFloat = 40                 // แถบคลื่นเสียงใต้รอยบาก

    static var visible: Bool { panel?.isVisible ?? false }

    /// คีย์ลัด/คำปลุก: ยังไม่เปิด = เปิดแล้วฟัง · เปิดอยู่แต่ไม่ได้ฟัง = ฟังใหม่ · กำลังคุยอยู่ = ปิด
    static func summon(_ app: AppState) {
        if visible, !hiding, app.talk.convo || app.talk.busy {
            hide(app)
            return
        }
        show(app)
        app.talk.wake()
    }

    private static var screen: NSScreen? { NSScreen.screens.first }   // จอที่มีแถบเมนู

    /// รอยบากของจอ (กว้าง/สูง) — ไม่มีรอยบาก = กว้าง 0 สูงเท่าแถบเมนู
    private static func measure(_ s: NSScreen) -> CGSize {
        let top = s.safeAreaInsets.top
        if top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return CGSize(width: s.frame.width - l.width - r.width, height: top)
        }
        return CGSize(width: 0, height: max(24, s.frame.maxY - s.visibleFrame.maxY))
    }

    private static func frame(_ s: NSScreen, expanded: Bool) -> NSRect {
        let notch = measure(s)
        let base = max(notch.width, 120)
        let w = expanded ? base + ear * 2 : base
        let h = expanded ? notch.height + strip : notch.height
        return NSRect(x: s.frame.midX - w / 2, y: s.frame.maxY - h, width: w, height: h)
    }

    static func show(_ app: AppState) {
        guard let s = screen else { return }
        let p = panel ?? make(app)
        state.notch = measure(s)
        hiding = false
        if !p.isVisible {
            app.talk.appear()
            p.setFrame(frame(s, expanded: false), display: false)
            p.orderFrontRegardless()
        }
        p.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.35, 1)   // เด้งเล็กน้อยแบบ Dynamic Island
            p.animator().setFrame(frame(s, expanded: true), display: true)
        }
        state.expanded = true
    }

    static func hide(_ app: AppState) {
        guard let p = panel, p.isVisible, !hiding, let s = screen else { return }
        hiding = true
        state.expanded = false
        app.talk.disappear()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(frame(s, expanded: false), display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                if hiding { p.orderOut(nil) }
                hiding = false
            }
        })
    }

    private static func make(_ app: AppState) -> IslandPanel {
        let p = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar                       // ทับแถบเมนูรอบรอยบาก
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: IslandView(onClose: { Island.hide(app) })
            .environment(app.talk).environment(state))
        panel = p
        return p
    }
}

// MARK: - หน้าตาเกาะ

/// สี่เหลี่ยมขอบบนตรง (ชิดขอบจอ) มุมล่างมน + มุมบน "ไหล่" โค้งเข้าแบบรอยบาก
struct IslandShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let s: CGFloat = 6, rad = min(radius, r.height / 2, r.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + s, y: r.minY + s), control: CGPoint(x: r.minX + s, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + s + rad, y: r.maxY), control: CGPoint(x: r.minX + s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s - rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - s, y: r.maxY - rad), control: CGPoint(x: r.maxX - s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - s, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @Environment(TalkModel.self) private var talk
    @Environment(IslandState.self) private var island
    let onClose: () -> Void

    /// ว่างจริง (ไม่ฟัง ไม่คิด ไม่พูด) -> หดกลับเข้ารอยบาก
    private var idle: Bool { !talk.convo && !talk.busy && [.idle, .error].contains(talk.state) }

    var body: some View {
        let topH = island.notch.height
        ZStack(alignment: .top) {
            IslandShape(radius: island.expanded ? 20 : 10).fill(.black)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    OrbView().frame(width: topH + 6, height: topH + 6).padding(.leading, 16)
                    Spacer(minLength: 0)
                    StateGlyph().frame(width: topH - 6, height: topH - 6).padding(.trailing, 20)
                }
                .frame(height: topH)
                Waveform().padding(.horizontal, 24).padding(.vertical, 8)
            }
            .opacity(island.expanded ? 1 : 0)
            .animation(.easeOut(duration: 0.2).delay(island.expanded ? 0.12 : 0), value: island.expanded)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { talk.interrupt(); onClose() }
        .onTapGesture { talk.tap() }
        .background {
            Button("") { talk.interrupt(); onClose() }
                .keyboardShortcut(.escape, modifiers: []).opacity(0).frame(width: 0, height: 0)
        }
        .onChange(of: talk.state) { _, s in
            if s == .error, let d = talk.detail { AppState.shared.system.error = d }   // ไม่มีตัวอักษรบนเกาะ -> แจ้งในศูนย์ควบคุม
        }
        .task(id: "\(idle)-\(talk.state.rawValue)-\(talk.turns.count)") {
            guard idle else { return }
            try? await Task.sleep(for: .seconds(talk.state == .error ? 2.5 : 1.4))
            if !Task.isCancelled && idle { onClose() }
        }
    }
}

private let yellow: [Double] = [255, 214, 10]
private let amber: [Double] = [255, 159, 10]
private let red: [Double] = [255, 95, 87]

private func rgb(_ v: [Double], _ a: Double) -> Color {
    Color(.sRGB, red: v[0] / 255, green: v[1] / 255, blue: v[2] / 255, opacity: max(0, min(1, a)))
}

/// หูขวา: สัญลักษณ์สถานะ (ไม่มีตัวอักษร)
struct StateGlyph: View {
    @Environment(TalkModel.self) private var talk
    private static let epoch = Date.now

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { g, size in
                let t = tl.date.timeIntervalSince(StateGlyph.epoch)
                let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) / 2
                switch talk.state {
                case .listening:
                    let lv = min(1, Double(talk.level) * 4)
                    for i in 0..<3 {
                        let k = (t * 0.9 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        let rr = r * (0.35 + k * 0.65) * (0.8 + lv * 0.3)
                        g.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                                 with: .color(rgb(yellow, (1 - k) * (0.5 + lv))), lineWidth: 1.6)
                    }
                    let core = r * (0.28 + lv * 0.25)
                    g.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2)), with: .color(rgb(yellow, 1)))
                case .thinking, .hearing:
                    var arc = Path()
                    arc.addArc(center: c, radius: r * 0.75, startAngle: .radians(t * 5), endAngle: .radians(t * 5 + 4.2), clockwise: false)
                    g.stroke(arc, with: .color(rgb(amber, 1)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    var inner = Path()
                    inner.addArc(center: c, radius: r * 0.42, startAngle: .radians(-t * 7), endAngle: .radians(-t * 7 + 2.4), clockwise: false)
                    g.stroke(inner, with: .color(rgb(yellow, 0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                case .speaking:
                    let pulse = max(0, 1 - (Date.now.timeIntervalSinceReferenceDate - talk.pulseAt) * 4)
                    for i in 0..<4 {
                        let h = r * (0.35 + 0.65 * abs(sin(t * (7 + Double(i) * 1.7) + Double(i))) * (0.6 + pulse * 0.4))
                        let x = c.x - r * 0.75 + Double(i) * r * 0.5
                        g.fill(Path(roundedRect: CGRect(x: x - 2, y: c.y - h, width: 4, height: h * 2), cornerRadius: 2),
                               with: .color(rgb(yellow, 1)))
                    }
                case .error:
                    let a = 0.55 + 0.45 * sin(t * 6)
                    g.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.4, y: c.y - r * 0.4, width: r * 0.8, height: r * 0.8)), with: .color(rgb(red, a)))
                case .idle:
                    g.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(rgb(yellow, 0.5)))
                }
            }
        }
    }
}

/// แถบคลื่นเสียงใต้รอยบาก
struct Waveform: View {
    @Environment(TalkModel.self) private var talk
    private static let epoch = Date.now
    private static let bars = 44

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { g, size in
                let t = tl.date.timeIntervalSince(Waveform.epoch)
                let n = Waveform.bars, gap = size.width / Double(n), mid = size.height / 2
                let levels = talk.levels
                let pulse = max(0, 1 - (Date.now.timeIntervalSinceReferenceDate - talk.pulseAt) * 3)
                for i in 0..<n {
                    let d = abs(Double(i) - Double(n - 1) / 2) / (Double(n) / 2)        // 0 กลาง -> 1 ขอบ
                    let v: Double, color: [Double], alpha: Double
                    switch talk.state {
                    case .listening:
                        let idx = min(levels.count - 1, Int(d * Double(levels.count - 1)))
                        v = 0.08 + Double(levels[levels.count - 1 - idx]) * 0.92
                        color = yellow; alpha = 0.45 + v * 0.55
                    case .speaking:
                        v = (0.2 + 0.8 * abs(sin(Double(i) * 0.5 + t * 9) * sin(Double(i) * 0.17 - t * 4))) * (0.6 + pulse * 0.4) * (1 - d * 0.5)
                        color = yellow; alpha = 0.5 + v * 0.5
                    case .thinking, .hearing:
                        let head = (t * 0.8).truncatingRemainder(dividingBy: 1) * Double(n)
                        let near = max(0, 1 - abs(Double(i) - head) / 6)
                        v = 0.08 + near * 0.35
                        color = amber; alpha = 0.25 + near * 0.75
                    case .error:
                        v = 0.06; color = red; alpha = 0.6
                    case .idle:
                        v = 0.05 + 0.03 * sin(Double(i) * 0.4 + t * 2); color = yellow; alpha = 0.3
                    }
                    let h = max(2, v * size.height)
                    let x = Double(i) * gap + gap / 2
                    g.fill(Path(roundedRect: CGRect(x: x - 1.5, y: mid - h / 2, width: 3, height: h), cornerRadius: 1.5),
                           with: .color(rgb(color, alpha)))
                }
            }
        }
    }
}

// MARK: - ลูกแก้ว: กลุ่มอนุภาคที่เปลี่ยนรูปตามเสียง (ย่อจาก HUD ของ Envy) — โทนเหลือง

final class OrbFace {
    private var energy = 0.1, spin = 0.0, morph = 0.0, pulse = 0.0, seenPulse = 0.0, last = 0.0
    private var main: [Double] = yellow, hot: [Double] = [255, 245, 200]

    private static let points: [(x: Double, y: Double, z: Double, s: Double)] = (0..<320).map { i in
        let y = 1 - Double(i) / 319 * 2, r = (1 - y * y).squareRoot(), a = Double(i) * 2.399963
        return (cos(a) * r, y, sin(a) * r, Double.random(in: 0..<1))
    }
    private static let palette: [TalkState: ([Double], [Double])] = [
        .idle: (yellow, [255, 245, 200]), .speaking: (yellow, [255, 250, 225]), .listening: (yellow, [255, 250, 225]),
        .thinking: (amber, [255, 225, 170]), .hearing: (amber, [255, 225, 170]), .error: (red, [255, 205, 195]),
    ]

    private func mix(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }

    func draw(_ g: inout GraphicsContext, size: CGSize, t: Double, state: TalkState, level: Float, pulseAt: Double) {
        let dt = last == 0 ? 0 : min(0.05, max(0, t - last))
        last = t
        let ctr = CGPoint(x: size.width / 2, y: size.height / 2), R = min(size.width, size.height) * 0.34
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
        let glowR = R * (1.4 + energy * 0.3)
        g.fill(Path(ellipseIn: CGRect(x: ctr.x - glowR, y: ctr.y - glowR, width: glowR * 2, height: glowR * 2)),
               with: .radialGradient(Gradient(colors: [rgb(main, 0.3 + energy * 0.25), rgb(main, 0)]),
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
            let s = (0.6 + front * 1.2) * (0.7 + pt.s * 0.6) * max(0.6, R / 26)
            let px = ctr.x + x1 * R * persp, py = ctr.y + y2 * R * persp
            dots[Int(front * 6)].addEllipse(in: CGRect(x: px - s / 2, y: py - s / 2, width: s, height: s))
        }
        for b in 0..<6 { g.fill(dots[b], with: .color(rgb(b >= 4 ? hot : main, 0.25 + Double(b) / 6 * 0.7))) }
        let coreR = R * (0.5 + energy * 0.35)
        g.fill(Path(ellipseIn: CGRect(x: ctr.x - coreR, y: ctr.y - coreR, width: coreR * 2, height: coreR * 2)),
               with: .radialGradient(Gradient(colors: [rgb(hot, 0.6 + energy * 0.3), rgb(main, 0)]),
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
