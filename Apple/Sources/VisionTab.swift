// VisionTab.swift — แท็บ "การมองเห็น" ของศูนย์ควบคุม: ภาพสดพร้อม HUD (กรอบตรวจจับ, การเคลื่อนไหว, ฉาก),
// โหมดกล้อง, สิ่งที่สั่งให้เฝ้าดู, เหตุการณ์ล่าสุด, ค่าการแจ้ง/ความเป็นส่วนตัว และโมเดลตรวจวัตถุเพิ่ม (Core ML)
// ข้อมูลกล้องมาจาก VisionModel (Vision.swift) · เหตุการณ์/สิ่งที่เฝ้าดูมาจาก GET /api/vision

import AppKit
import SwiftUI

struct VisionTab: View {
    @Environment(AppState.self) private var app
    let model: SystemModel

    var body: some View {
        @Bindable var vision = app.vision
        let info = model.visionInfo
        let settings = info.obj("settings")
        TabScroll {
            HStack(alignment: .top, spacing: 12) {
                VisionHUD(vision: app.vision).frame(maxWidth: .infinity)
                VStack(spacing: 12) {
                    Card(title: "ตาของ April", trailing: AnyView(StatusDot(ok: vision.running ? true : vision.mode == .off ? false : nil))) {
                        Picker("", selection: $vision.mode) {
                            ForEach(VisionMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Text(vision.mode.detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        if vision.cameras.count > 1 {
                            Picker("กล้อง", selection: $vision.cameraID) {
                                Text("ตามค่าของระบบ").tag("")
                                ForEach(vision.cameras, id: \.id) { Text($0.name).tag($0.id) }
                            }
                        }
                        KV(k: "กล้อง", v: vision.running ? "เปิดอยู่" : vision.starting ? "กำลังเปิด…" : "ปิด")
                        if vision.keepOn { KV(k: "เฝ้าดู", v: "\(Int(info.num("watching") ?? Double(info.arr("watches").count))) อย่าง — กล้องเปิดค้างไว้") }
                        if let p = vision.problem { Text(p).font(.system(size: 11.5)).foregroundStyle(Theme.warn) }
                        HStack {
                            if vision.mode == .demand {
                                Button(vision.hold ? "หยุดภาพสด" : "เปิดดูภาพสด") { vision.hold.toggle() }.buttonStyle(AccentButtonStyle())
                            }
                            Button("สิทธิ์กล้อง…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                            }
                            .buttonStyle(QuietButtonStyle())
                        }
                    }
                    Card(title: "เห็นอะไรอยู่") {
                        KV(k: "คน / ใบหน้า", v: "\(vision.detections.filter { $0.kind == .person }.count) / \(vision.detections.filter { $0.kind == .face }.count)")
                        KV(k: "สัตว์", v: list(vision.detections.filter { $0.kind == .animal }.map(\.label)))
                        KV(k: "วัตถุ", v: list(vision.detections.filter { $0.kind == .object }.map(\.label)))
                        KV(k: "ฉาก", v: list(vision.scene))
                        KV(k: "การเคลื่อนไหว", v: "\(Int(vision.motion * 100))%")
                    }
                }
                .frame(width: 330)
            }

            HStack(alignment: .top, spacing: 12) {
                Card(title: "สิ่งที่สั่งให้เฝ้าดู") {
                    let watches = info.arr("watches")
                    if watches.isEmpty {
                        Text("ยังไม่มี — เรียก April แล้วพูด เช่น “บอกด้วยถ้าแมวขึ้นโต๊ะ” หรือ “ถ้ามีคนเข้ามาให้บอก”")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    ForEach(Array(watches.enumerated()), id: \.offset) { _, w in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "scope").foregroundStyle(Theme.accent).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(w.str("target") ?? "").font(.system(size: 13)).foregroundStyle(Theme.ink)
                                Text("เหลือ \(Int(w.num("minutes_left") ?? 0)) นาที · \(w.bool("repeat") == true ? "แจ้งทุกครั้ง" : "แจ้งครั้งเดียว") · เจอ \(Int(w.num("hits") ?? 0)) ครั้ง")
                                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button { model.unwatch(Int(w.num("id") ?? 0)) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).foregroundStyle(Theme.muted)
                        }
                    }
                }
                Card(title: "เหตุการณ์ล่าสุด") {
                    let events = info.arr("events")
                    if events.isEmpty {
                        Text(vision.mode == .always ? "ยังไม่มีเหตุการณ์" : "บันทึกเหตุการณ์เฉพาะโหมด “เปิดตลอด” หรือระหว่างเฝ้าดู")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    ForEach(Array(events.prefix(12).enumerated()), id: \.offset) { _, e in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(e.str("kind"))).foregroundStyle(Theme.accent).frame(width: 16).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.str("text") ?? "").font(.system(size: 12.5)).foregroundStyle(Theme.ink)
                                if let n = e.str("note"), !n.isEmpty { Text(n).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                            }
                            Spacer()
                            Text(Fmt.ago(e.num("at"))).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Card(title: "การแจ้งและความเป็นส่วนตัว") {
                    Toggle("แจ้งและพูดเมื่อมีเหตุการณ์ (ขยับตอนไม่มีคน, เห็นสัตว์, ทักทายตอนกลับมา)", isOn: Binding(
                        get: { settings.bool("alerts") ?? true }, set: { model.saveEnv(["APRIL_VISION_ALERTS": $0 ? "true" : "false"]) }))
                        .toggleStyle(.switch).controlSize(.small)
                    Toggle("ส่งภาพกล้องให้โมเดล cloud ได้ เมื่อถาม April ว่าเห็นอะไร", isOn: Binding(
                        get: { settings.bool("cloud") ?? true }, set: { model.saveEnv(["APRIL_VISION_CLOUD": $0 ? "true" : "false"]) }))
                        .toggleStyle(.switch).controlSize(.small)
                    Picker("โมเดลที่เฝ้าดูเบื้องหลัง", selection: Binding(
                        get: { settings.str("model") ?? "local" }, set: { model.saveEnv(["APRIL_VISION_MODEL": $0]) })) {
                        ForEach(info.arr("models").isEmpty ? [["id": "local", "label": "ในเครื่อง"] as JSON] : info.arr("models"), id: \.description) { m in
                            Text((m.str("label") ?? m.str("id") ?? "") + (m.bool("local") == true ? " — ภาพไม่ออกนอกเครื่อง" : "")).tag(m.str("id") ?? "")
                        }
                    }
                    .frame(maxWidth: 460)
                    Text("ภาพอยู่ในหน่วยความจำเท่านั้น ไม่บันทึกลงดิสก์ ไม่เก็บในประวัติแชท · ตรวจจับคน/สัตว์/การเคลื่อนไหวทำบนเครื่องนี้ทั้งหมด · ไฟเขียวข้างกล้องติดทุกครั้งที่กล้องเปิด")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Card(title: "ตรวจจับวัตถุเพิ่ม (Core ML / YOLO)", trailing: AnyView(Pill(text: vision.customModel ?? "ไม่มี",
                                                                                       color: vision.customModel == nil ? Theme.muted : Theme.accent))) {
                    Text("ในตัวมี: คน ใบหน้า แมว สุนัข และป้ายฉาก ~1,300 แบบ (Apple Vision) — อยากให้ตีกรอบวัตถุได้ทุกชนิด (แก้ว มือถือ ขวด กุญแจ …) วางโมเดล Core ML แบบ object detection ไว้ในโฟลเดอร์ แล้วกดโหลดใหม่")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Text("pip install ultralytics && yolo export model=yolo11n.pt format=coreml nms=True")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("เปิดโฟลเดอร์โมเดล") {
                            if let d = vision.customDir {
                                try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(d)
                            }
                        }
                        .buttonStyle(QuietButtonStyle())
                        Button("โหลดใหม่") { vision.reloadCustomModel() }.buttonStyle(QuietButtonStyle())
                    }
                }
            }
        }
        .onAppear { app.vision.viewers += 1; app.vision.refreshCameras() }
        .onDisappear { app.vision.viewers = max(0, app.vision.viewers - 1); app.vision.hold = false }
    }

    private func list(_ items: [String]) -> String {
        let unique = items.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? "–" : unique.prefix(8).joined(separator: ", ")
    }

    private func icon(_ kind: String?) -> String {
        switch kind ?? "" {
        case "person_arrived": "person.badge.plus"
        case "person_left": "person.badge.minus"
        case "motion": "figure.walk.motion"
        case "animal_appeared": "pawprint"
        case "watch_hit": "scope"
        default: "eye"
        }
    }
}

// MARK: - ภาพสด + HUD

private let hudYellow = Color(hex: 0xffd60a)
private let hudAmber = Color(hex: 0xff9f0a)

struct VisionHUD: View {
    let vision: VisionModel
    private static let epoch = Date.now

    var body: some View {
        let aspect = vision.preview.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 16 / 9
        ZStack {
            Color.black
            if let img = vision.preview {
                Image(decorative: img, scale: 1).resizable().saturation(0.75).brightness(-0.04)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: vision.mode == .off ? "eye.slash" : "eye").font(.system(size: 34, weight: .light))
                        .foregroundStyle(hudYellow.opacity(0.7))
                    Text(placeholder).font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                }
                .padding(30)
            }
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !vision.running)) { tl in
                Canvas { g, size in draw(&g, size, t: tl.date.timeIntervalSince(VisionHUD.epoch)) }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(vision.running ? hudYellow.opacity(0.5) : Theme.line))
    }

    private var placeholder: String {
        switch vision.mode {
        case .off: "การมองเห็นปิดอยู่"
        case .demand: vision.starting ? "กำลังเปิดกล้อง…" : "กล้องปิดอยู่จนกว่า April ต้องมอง\nกด “เปิดดูภาพสด” เพื่อทดสอบ"
        case .always: vision.starting ? "กำลังเปิดกล้อง…" : (vision.problem ?? "กำลังรอกล้อง…")
        }
    }

    private func mono(_ s: String, _ size: CGFloat = 10, _ color: Color = hudYellow) -> Text {
        Text(s).font(.system(size: size, weight: .semibold, design: .monospaced)).foregroundColor(color)
    }

    private func draw(_ g: inout GraphicsContext, _ size: CGSize, t: Double) {
        guard vision.running else { return }
        let w = size.width, h = size.height

        // เส้นสแกนไล่ลง
        let y = (t * 0.35).truncatingRemainder(dividingBy: 1) * h
        g.fill(Path(CGRect(x: 0, y: y - 30, width: w, height: 30)),
               with: .linearGradient(Gradient(colors: [hudYellow.opacity(0), hudYellow.opacity(0.10)]),
                                     startPoint: CGPoint(x: 0, y: y - 30), endPoint: CGPoint(x: 0, y: y)))
        g.fill(Path(CGRect(x: 0, y: y, width: w, height: 1)), with: .color(hudYellow.opacity(0.35)))

        // กรอบสิ่งที่ตรวจเจอ: วงเล็บมุม + ป้าย
        for d in vision.detections {
            let r = CGRect(x: d.box.minX * w, y: (1 - d.box.maxY) * h, width: d.box.width * w, height: d.box.height * h)
            let color: Color = d.kind == .animal ? hudAmber : d.kind == .object ? .white : hudYellow
            let c = min(18, r.width / 4, r.height / 4)
            var p = Path()
            for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                     (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
                p.move(to: CGPoint(x: corner.x + c * dx, y: corner.y))
                p.addLine(to: corner)
                p.addLine(to: CGPoint(x: corner.x, y: corner.y + c * dy))
            }
            g.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: d.kind == .face ? 1.5 : 2.2, lineCap: .square))
            if d.kind != .face {
                g.stroke(Path(r), with: .color(color.opacity(0.18)), lineWidth: 1)
                let label = g.resolve(mono("\(d.label.uppercased()) \(Int(d.confidence * 100))%", 9.5, .black))
                let ls = label.measure(in: size)
                let tag = CGRect(x: r.minX, y: max(0, r.minY - ls.height - 4), width: ls.width + 8, height: ls.height + 4)
                g.fill(Path(roundedRect: tag, cornerRadius: 3), with: .color(color))
                g.draw(label, at: CGPoint(x: tag.minX + 4, y: tag.minY + 2), anchor: .topLeading)
            }
        }

        // มุมบนซ้าย: สถานะ
        let blink = sin(t * 4) > 0 ? 1.0 : 0.35
        g.fill(Path(ellipseIn: CGRect(x: 14, y: 15, width: 7, height: 7)), with: .color(Color(hex: 0xff5f57).opacity(blink)))
        g.draw(mono("APRIL VISION · LIVE", 10.5), at: CGPoint(x: 27, y: 12), anchor: .topLeading)
        let people = vision.detections.filter { $0.kind == .person }.count
        g.draw(mono("PERSONS \(people)  ·  \(vision.present ? "OWNER PRESENT" : "NO ONE")", 9.5, hudYellow.opacity(0.75)),
               at: CGPoint(x: 27, y: 28), anchor: .topLeading)

        // มุมบนขวา: แถบการเคลื่อนไหว
        let m = CGFloat(min(1, vision.motion * 4))
        let bar = CGRect(x: w - 124, y: 16, width: 100, height: 6)
        g.stroke(Path(roundedRect: bar, cornerRadius: 3), with: .color(hudYellow.opacity(0.5)), lineWidth: 1)
        g.fill(Path(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: max(2, bar.width * m), height: bar.height), cornerRadius: 3),
               with: .color(m > 0.5 ? hudAmber : hudYellow))
        g.draw(mono("MOTION", 9), at: CGPoint(x: bar.minX, y: bar.maxY + 4), anchor: .topLeading)

        // ล่าง: ป้ายฉาก
        if !vision.scene.isEmpty {
            g.draw(mono("SCENE  " + vision.scene.prefix(5).map { $0.uppercased() }.joined(separator: " · "), 9.5, hudYellow.opacity(0.85)),
                   at: CGPoint(x: 14, y: h - 12), anchor: .bottomLeading)
        }
        if let cm = vision.customModel {
            g.draw(mono("MODEL \(cm.uppercased())", 9, hudYellow.opacity(0.6)), at: CGPoint(x: w - 14, y: h - 12), anchor: .bottomTrailing)
        }

        // วงเล็บกรอบภาพทั้งภาพ
        var frame = Path()
        let k: CGFloat = 22, inset: CGFloat = 6
        for (x, y, dx, dy) in [(inset, inset, 1.0, 1.0), (w - inset, inset, -1.0, 1.0), (inset, h - inset, 1.0, -1.0), (w - inset, h - inset, -1.0, -1.0)] {
            frame.move(to: CGPoint(x: x + k * dx, y: y))
            frame.addLine(to: CGPoint(x: x, y: y))
            frame.addLine(to: CGPoint(x: x, y: y + k * dy))
        }
        g.stroke(frame, with: .color(hudYellow.opacity(0.55)), lineWidth: 1.5)
    }
}
