// VisionLab.swift — หน้าต่าง "ทดสอบการมองเห็น": แบบแอปกล้อง — ภาพสดเต็มจอพร้อมกรอบสีอ่อนรอบสิ่งที่ตรวจเจอ
// + แผงพิมพ์คุยกับ April ด้านข้าง (POST /chat แบบเดียวกับทุกช่องทาง บทสนทนา "vision-test-…")
//   ทุกครั้งที่ April มอง (look) จะมีแฟลชแบบชัตเตอร์ และภาพตอนนั้นติดไปกับคำตอบในแชท — เทียบได้ว่า April เห็นอะไรแล้วตอบอะไร
//   เปิดหน้าต่างนี้ = กล้องเปิดค้างไว้ (แม้โหมดการมองเห็นจะเป็น "ปิด") ปิดหน้าต่าง = กลับไปตามโหมดเดิม
// เปิดได้จากแท็บการมองเห็น, เมนู April และ menu bar

import AppKit
import SwiftUI

struct LabMessage: Identifiable {
    let id = UUID()
    let me: Bool
    var text: String
    var tools: [String] = []
    var snapshot: CGImage?
    var failed = false
}

@MainActor @Observable
final class VisionLab {
    var messages: [LabMessage] = []
    var input = ""
    var showBoxes = true
    private(set) var busy = false
    private(set) var flashAt = 0.0
    private var session = VisionLab.newSession()
    private var task: Task<Void, Never>?
    private let backend: Backend
    private let vision: VisionModel

    static let suggestions = ["เห็นอะไรบ้าง", "ผมถืออะไรอยู่", "ในภาพมีกี่คน", "อ่านข้อความในภาพให้หน่อย", "บอกเมื่อผมยกมือ"]

    init(backend: Backend, vision: VisionModel) {
        self.backend = backend
        self.vision = vision
    }

    private static func newSession() -> String { "vision-test-" + UUID().uuidString.prefix(8).lowercased() }

    func send(_ preset: String? = nil) {
        let text = (preset ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        if preset == nil { input = "" }
        messages.append(LabMessage(me: true, text: text))
        messages.append(LabMessage(me: false, text: ""))
        busy = true
        let api = backend.api, session = session
        task = Task {
            var streamed = "", final = "", problem: String?
            do {
                for try await ev in api.chat(text, session: session) {
                    switch ev.str("type") {
                    case "token":
                        streamed += ev.str("text") ?? ""
                        update { $0.text = streamed }
                    case "revision":
                        streamed = ""
                    case "tool_call":
                        let name = ev.str("name") ?? ""
                        update { $0.tools.append(name) }
                        if name == "look" {
                            flashAt = Date.now.timeIntervalSinceReferenceDate
                            let shot = vision.preview
                            update { $0.snapshot = shot }
                        }
                    case "error":
                        problem = ev.str("message")
                    case "done":
                        if let t = ev.str("text"), !t.isEmpty { final = t }
                    default: break
                    }
                }
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
            }
            let answer = final.isEmpty ? streamed : final
            update {
                if Task.isCancelled { $0.text = answer.isEmpty ? "หยุดแล้ว" : answer }
                else if let problem, answer.isEmpty { $0.text = "มีปัญหา: \(problem)"; $0.failed = true }
                else { $0.text = answer.isEmpty ? "(ไม่มีคำตอบ)" : answer }
            }
            busy = false
        }
    }

    func stop() { task?.cancel() }

    func clear() {
        stop()
        messages = []
        session = VisionLab.newSession()
    }

    private func update(_ f: (inout LabMessage) -> Void) {
        guard let i = messages.indices.last else { return }
        f(&messages[i])
    }
}

// MARK: - หน้าต่าง

struct VisionLabView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("ทดสอบการมองเห็น").font(Theme.serif(24)).foregroundStyle(Theme.ink)
                    Spacer()
                    Toggle("แสดงกรอบ", isOn: Binding(get: { app.lab.showBoxes }, set: { app.lab.showBoxes = $0 }))
                        .toggleStyle(.switch).controlSize(.small)
                }
                LabFeed(vision: app.vision, lab: app.lab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                LabSeenBar(vision: app.vision)
                if app.vision.mode == .off {
                    Text("โหมดการมองเห็นเป็น “ปิด” — กล้องเปิดชั่วคราวเฉพาะตอนที่หน้าต่างนี้เปิดอยู่")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
                if let p = app.vision.problem { Text(p).font(.system(size: 11.5)).foregroundStyle(Theme.warn) }
            }
            .padding(18)
            Rectangle().fill(Theme.line).frame(width: 1)
            LabChat(lab: app.lab).frame(width: 380)
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Theme.canvas)
        .onAppear { app.vision.testers += 1; app.vision.viewers += 1 }
        .onDisappear { app.vision.testers = max(0, app.vision.testers - 1); app.vision.viewers = max(0, app.vision.viewers - 1) }
    }
}

// MARK: - ภาพสด + กรอบสีอ่อน

enum LabColor {
    static func of(_ k: Detection.Kind) -> Color {
        switch k {
        case .person: Color(hex: 0xfff3b0)        // เหลืองอ่อน
        case .face: Color(hex: 0xb9fbc0)          // เขียวมิ้นต์
        case .animal: Color(hex: 0xffd6a5)        // พีช
        case .object: Color(hex: 0xa0e7ff)        // ฟ้าอ่อน
        }
    }

    static func name(_ d: Detection) -> String {
        switch d.kind {
        case .person: "คน"
        case .face: "ใบหน้า"
        case .animal: ["cat": "แมว", "dog": "สุนัข"][d.label] ?? d.label
        case .object: d.label
        }
    }
}

struct LabFeed: View {
    let vision: VisionModel
    let lab: VisionLab
    @ViewState private var flash = 0.0

    var body: some View {
        let aspect = vision.preview.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 16 / 9
        ZStack {
            Color.black
            if let img = vision.preview {
                Image(decorative: img, scale: 1).resizable()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent.opacity(0.7))
                    Text(vision.starting ? "กำลังเปิดกล้อง…" : vision.problem == nil ? "กำลังรอภาพจากกล้อง…" : "เปิดกล้องไม่ได้")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            if lab.showBoxes {
                Canvas { g, size in
                    for d in vision.detections {
                        let r = CGRect(x: d.box.minX * size.width, y: (1 - d.box.maxY) * size.height,
                                       width: d.box.width * size.width, height: d.box.height * size.height)
                        let c = LabColor.of(d.kind)
                        let shape = Path(roundedRect: r, cornerRadius: min(12, r.width / 6))
                        g.fill(shape, with: .color(c.opacity(0.12)))
                        g.stroke(shape, with: .color(c.opacity(0.9)), lineWidth: 2)
                        let text = g.resolve(Text("\(LabColor.name(d)) \(Int(d.confidence * 100))%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(Color(hex: 0x1a1a1a)))
                        let ts = text.measure(in: size)
                        let inside = r.minY < ts.height + 8
                        let tag = CGRect(x: r.minX + 6, y: inside ? r.minY + 6 : r.minY - ts.height - 8, width: ts.width + 12, height: ts.height + 4)
                        g.fill(Path(roundedRect: tag, cornerRadius: tag.height / 2), with: .color(c.opacity(0.95)))
                        g.draw(text, at: CGPoint(x: tag.midX, y: tag.midY))
                    }
                }
            }
            Color.white.opacity(flash).allowsHitTesting(false)          // แฟลชตอน April มอง
            VStack {
                HStack(spacing: 6) {
                    Circle().fill(vision.running ? Color(hex: 0xff5f57) : Theme.muted).frame(width: 7, height: 7)
                    Text(lookingNow ? "April กำลังมอง…" : vision.running ? "LIVE" : "OFF")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.45), in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
            .padding(12)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: lab.flashAt) { _, _ in
            flash = 0.75
            withAnimation(.easeOut(duration: 0.45)) { flash = 0 }
        }
    }

    private var lookingNow: Bool { lab.busy && lab.messages.last?.tools.last == "look" && (lab.messages.last?.text.isEmpty ?? false) }
}

/// แถบใต้ภาพ: สิ่งที่เห็นตอนนี้เป็นชิปสีเดียวกับกรอบ
struct LabSeenBar: View {
    let vision: VisionModel

    var body: some View {
        let groups = Dictionary(grouping: vision.detections) { "\($0.kind.rawValue)|\(LabColor.name($0))" }
            .sorted { $0.key < $1.key }
        HStack(spacing: 8) {
            if groups.isEmpty {
                Text(vision.running ? "ยังไม่เห็นคน สัตว์ หรือวัตถุที่รู้จัก" : "กล้องปิดอยู่").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(groups, id: \.key) { _, items in
                let d = items[0]
                HStack(spacing: 5) {
                    Circle().fill(LabColor.of(d.kind)).frame(width: 8, height: 8)
                    Text(items.count > 1 ? "\(LabColor.name(d)) ×\(items.count)" : LabColor.name(d)).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(LabColor.of(d.kind).opacity(0.14), in: Capsule())
            }
            Spacer(minLength: 0)
            if !vision.scene.isEmpty {
                Text(vision.scene.prefix(4).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Text("ขยับ \(Int(vision.motion * 100))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - แชท

struct LabChat: View {
    @Bindable var lab: VisionLab

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("คุยกับ April").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button { lab.clear() } label: { Label("เริ่มใหม่", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).foregroundStyle(Theme.muted).disabled(lab.messages.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Rectangle().fill(Theme.line).frame(height: 1)

            LabScroll(lab: lab)

            HScroll {
                HStack(spacing: 6) {
                    ForEach(VisionLab.suggestions, id: \.self) { s in
                        Button(s) { lab.send(s) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Theme.accentSoft, in: Capsule())
                            .disabled(lab.busy)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            HStack(spacing: 8) {
                TextField("พิมพ์สั่ง April… เช่น “ดูซิว่าผมใส่เสื้อสีอะไร”", text: $lab.input, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line))
                    .onSubmit { lab.send() }
                Button { lab.busy ? lab.stop() : lab.send() } label: {
                    Image(systemName: lab.busy ? "stop.fill" : "arrow.up").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.onAccent).frame(width: 34, height: 34)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!lab.busy && lab.input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .background(Theme.sidebar)
    }
}

/// รายการข้อความ (build พรีวิวไม่ใช้ ScrollView — ImageRenderer วาดไม่ได้)
struct LabScroll: View {
    let lab: VisionLab

    var body: some View {
        #if APRIL_PREVIEW
        list.frame(maxHeight: .infinity, alignment: .top)
        #else
        ScrollViewReader { proxy in
            ScrollView { list }
                .onChange(of: lab.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: lab.messages.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        #endif
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            if lab.messages.isEmpty {
                Text("พิมพ์ถาม April เกี่ยวกับสิ่งที่อยู่หน้ากล้อง — ทุกครั้งที่ April มอง ภาพตอนนั้นจะติดมากับคำตอบ")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 8)
            }
            ForEach(lab.messages) { m in LabBubble(m: m, busy: lab.busy && m.id == lab.messages.last?.id) }
            Color.clear.frame(height: 1).id("end")
        }
        .padding(16)
    }
}

struct LabBubble: View {
    let m: LabMessage
    let busy: Bool

    var body: some View {
        HStack {
            if m.me { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                if !m.tools.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(m.tools.enumerated()), id: \.offset) { _, t in
                            Label(t == "look" ? "มองกล้อง" : ToolsTab.labels[t] ?? t, systemImage: t == "look" ? "eye" : "wrench.adjustable")
                                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.accentSoft, in: Capsule())
                        }
                    }
                }
                if let shot = m.snapshot {
                    Image(decorative: shot, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 240).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .bottomLeading) {
                            Text("ภาพที่ April มอง").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.5), in: Capsule()).padding(6)
                        }
                }
                if m.text.isEmpty && busy {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("กำลังคิด…").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                } else {
                    Text(markdown(m.text)).font(.system(size: 13)).textSelection(.enabled)
                        .foregroundStyle(m.me ? Theme.onAccent : m.failed ? Theme.danger : Theme.ink)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(m.me ? Theme.accent : Theme.bubble, in: RoundedRectangle(cornerRadius: 14))
            if !m.me { Spacer(minLength: 40) }
        }
    }
}
