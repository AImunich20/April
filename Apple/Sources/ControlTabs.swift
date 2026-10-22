// ControlTabs.swift — แท็บของศูนย์ควบคุม (หน้าตาแบบเดียวกับแท็บในหน้า "ระบบ" ของ Envy)

import AppKit
import SwiftUI

// MARK: - ภาพรวม

struct OverviewTab: View {
    @Environment(AppState.self) private var app
    let model: SystemModel

    var body: some View {
        let o = model.overview
        let r24 = o.obj("runs_24h")
        let done = r24.obj("done").num("count") ?? 0, failed = r24.obj("failed").num("count") ?? 0
        let cancelled = r24.obj("cancelled").num("count") ?? 0
        let ollama = o.obj("ollama"), cloud = o.obj("cloud")
        TabScroll {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                Stat(label: "งานที่กำลังทำ", value: Fmt.count(o.num("active_runs")), tone: Theme.accent)
                Stat(label: "งาน 24 ชม.", value: Fmt.count(done + failed + cancelled),
                     note: "สำเร็จ \(Int(done)) · ล้ม \(Int(failed)) · เฉลี่ย \(Fmt.seconds(r24.obj("done").num("avg_seconds")))")
                Stat(label: "เรียกโมเดล", value: Fmt.count(o.num("llm_calls")), note: "error \(Fmt.count(o.num("llm_errors")))")
                Stat(label: "Token", value: Fmt.count((o.obj("tokens").num("input") ?? 0) + (o.obj("tokens").num("output") ?? 0)),
                     note: "อ่าน \(Fmt.count(o.obj("tokens").num("input"))) · เขียน \(Fmt.count(o.obj("tokens").num("output")))")
                Stat(label: "ความจำ", value: Fmt.count(o.num("notes")), note: "\(Fmt.count(o.num("sessions"))) บทสนทนา")
                Stat(label: "ตัวเตือนที่รอ", value: Fmt.count(o.num("reminders_pending")))
                Stat(label: "เรียกเครื่องมือ", value: Fmt.count(o.num("tool_calls")), note: "ตั้งแต่เปิด")
                Stat(label: "เปิดมาแล้ว", value: Fmt.seconds(o.num("uptime_seconds")))
            }
            HStack(alignment: .top, spacing: 12) {
                Card(title: "Ollama (โมเดลในเครื่อง)", trailing: AnyView(StatusDot(ok: ollama.bool("online")))) {
                    KV(k: "สถานะ", v: ollama.bool("online") == true ? "ออนไลน์" : "ออฟไลน์ \(ollama.str("error") ?? "")")
                    KV(k: "ติดตั้งไว้", v: "\(Fmt.count(ollama.num("installed"))) โมเดล")
                    KV(k: "โหลดค้างใน RAM", v: ollama.strs("loaded").isEmpty ? "–" : ollama.strs("loaded").joined(separator: ", "))
                }
                Card(title: "เรียก April (Dynamic Island)", trailing: AnyView(
                    Button { app.summon() } label: { Label("เรียกตอนนี้", systemImage: "waveform.circle") }.buttonStyle(AccentButtonStyle()))) {
                    KV(k: "คีย์ลัด", v: app.hotkey.choice.label)
                    KV(k: "เรียกด้วยเสียง", v: app.wake.enabled ? (app.wake.listening ? "รอฟัง \"April\"" : "พัก") : "ปิด (เปิดในแท็บเสียง)")
                    KV(k: "โมเดลที่ใช้ตอบ", v: cloud.str("default") ?? "auto")
                }
            }
            Card(title: "ลำดับการเลือกโมเดล") {
                HStack(spacing: 6) {
                    Text("auto").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.muted).frame(width: 100, alignment: .leading)
                    ForEach(Array(cloud.strs("chain").enumerated()), id: \.offset) { i, m in
                        if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.muted) }
                        Pill(text: m, color: i == 0 ? Theme.accent : Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                if !cloud.strs("cooling").isEmpty {
                    KV(k: "พักไว้ชั่วคราว", v: cloud.strs("cooling").joined(separator: ", "))
                }
                Text("ใช้ cloud ตัวแรกที่ตั้งค่าครบ ถ้าล่ม/เกินโควตาจะสลับไปตัวถัดไปเองในคำขอเดียวกัน และโมเดลในเครื่องเป็นตัวสำรองสุดท้ายเสมอ")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            Card(title: "ประกาศล่าสุดจาก April") {
                if o.arr("announcements").isEmpty { Text("ยังไม่มี — ตัวเตือนและสรุปประจำวันจะแสดงที่นี่").font(.system(size: 12.5)).foregroundStyle(Theme.muted) }
                ForEach(Array(o.arr("announcements").enumerated()), id: \.offset) { i, a in
                    if i > 0 { Divider().overlay(Theme.line) }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: a.str("kind") == "briefing" ? "sun.max" : "alarm").foregroundStyle(Theme.accent).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(a.str("title") ?? "").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text(markdown(a.str("text") ?? "")).font(.system(size: 12.5)).foregroundStyle(Theme.ink).textSelection(.enabled)
                            Text(Fmt.ago(a.num("created"))).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - RAM

struct RAMTab: View {
    let model: SystemModel

    var body: some View {
        let p = model.power
        let mem = p.obj("memory")
        let total = mem.num("total") ?? 0, used = mem.num("used") ?? 0
        let modelsBytes = p.num("models_bytes") ?? 0
        let aprilBytes = p.arr("processes").filter { $0.str("name") != "Ollama" }.reduce(0) { $0 + ($1.num("rss") ?? 0) }
        TabScroll {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Text(total > 0 ? "\(Fmt.bytes(used)) / \(Fmt.bytes(total))" : "–")
                        .font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(Theme.ink).monospacedDigit()
                    Text("ใช้อยู่").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Spacer()
                    if let free = mem.num("free_percent") {
                        Pill(text: "ว่าง \(Int(free))% · แรงกดดัน\(mem.str("pressure") ?? "")",
                             color: free < 10 ? Theme.danger : free < 25 ? Theme.warn : Theme.accent)
                    }
                }
                GeometryReader { g in
                    let w = g.size.width
                    let seg = { (v: Double) in total > 0 ? max(0, CGFloat(v / total) * w) : 0 }
                    HStack(spacing: 2) {
                        Rectangle().fill(Theme.accent).frame(width: seg(modelsBytes))
                        Rectangle().fill(Theme.accent.opacity(0.45)).frame(width: seg(aprilBytes))
                        Rectangle().fill(Theme.muted.opacity(0.45)).frame(width: seg(max(0, used - modelsBytes - aprilBytes)))
                        Rectangle().fill(Theme.line)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .frame(height: 12)
                HStack(spacing: 14) {
                    legend(Theme.accent, "โมเดล AI \(Fmt.bytes(modelsBytes))")
                    legend(Theme.accent.opacity(0.45), "April \(Fmt.bytes(aprilBytes))")
                    legend(Theme.muted.opacity(0.45), "แอปอื่น")
                    legend(Theme.line, "ว่าง")
                }
            }

            Card(title: "เคลียร์ RAM", trailing: AnyView(
                Button { model.clearRAM() } label: { Label("เคลียร์ RAM ตอนนี้", systemImage: "wind") }
                    .buttonStyle(AccentButtonStyle()).disabled(model.busy)
            )) {
                Text("ปลดโมเดล AI ทุกตัวออกจาก RAM — คำถามถัดไปจะโหลดโมเดลใหม่ (ช้าขึ้นครั้งแรก 5–20 วิ) ข้อมูล ความจำ และบทสนทนาไม่หาย")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                if let r = model.lastClear {
                    Label(r, systemImage: "checkmark.circle.fill").font(.system(size: 12.5)).foregroundStyle(Theme.accent)
                }
            }

            Card(title: "โมเดลที่อยู่ใน RAM (\(p.arr("models").count))") {
                if p.arr("models").isEmpty {
                    Text("ไม่มีโมเดลค้างใน RAM").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                ForEach(Array(p.arr("models").enumerated()), id: \.offset) { i, m in
                    if i > 0 { Divider().overlay(Theme.line) }
                    HStack(spacing: 10) {
                        Image(systemName: m.bool("embedding") == true ? "text.magnifyingglass" : "cpu")
                            .foregroundStyle(Theme.accent).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.str("name") ?? "").font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.ink)
                            Text(RAMTab.expiry(m.str("expires_at"))).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text(Fmt.bytes(m.num("size"))).font(.system(size: 12.5)).foregroundStyle(Theme.ink).monospacedDigit()
                        Button("ปลด") { if let n = m.str("name") { model.unloadModel(n) } }
                            .buttonStyle(QuietButtonStyle()).disabled(model.busy)
                    }
                    .padding(.vertical, 3)
                }
            }

            Card(title: "Process ของ April") {
                ForEach(Array(p.arr("processes").enumerated()), id: \.offset) { _, pr in
                    KV(k: pr.str("name") ?? "", v: Fmt.bytes(pr.num("rss")))
                }
                Text("โมเดลบน GPU ของ Apple Silicon ไม่นับรวมใน process — ดูขนาดจริงในรายการโมเดลด้านบน")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            Text(t).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        }
    }

    static func expiry(_ iso: String?) -> String {
        guard let iso else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let left = d.timeIntervalSinceNow
        if left > 365 * 86_400 { return "ค้างตลอด" }
        if left <= 0 { return "กำลังปลด…" }
        return left < 60 ? "ปลดในอีก \(Int(left)) วินาที" : "ปลดในอีก \(Int(left / 60)) นาที"
    }
}

// MARK: - งาน

struct TasksTab: View {
    let model: SystemModel
    @ViewState private var filter = "all"

    var body: some View {
        let list = model.runs.filter { filter == "all" || $0.str("status") == filter }
        TabScroll {
            Picker("", selection: $filter) {
                Text("ทั้งหมด").tag("all"); Text("กำลังทำ").tag("running"); Text("สำเร็จ").tag("done")
                Text("ล้ม").tag("failed"); Text("หยุด").tag("cancelled")
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            Card {
                if list.isEmpty { Text("ไม่มีงาน — เรียก April แล้วสั่งงานได้เลย").foregroundStyle(Theme.muted) }
                ForEach(Array(list.enumerated()), id: \.offset) { i, t in
                    if i > 0 { Divider().overlay(Theme.line) }
                    HStack(alignment: .top, spacing: 12) {
                        StatusDot(ok: t.str("status") == "done" ? true : ["failed", "cancelled"].contains(t.str("status") ?? "") ? false : nil)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if t.num("voice") == 1 { Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(Theme.accent) }
                                Text(t.str("message") ?? "").font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(2)
                            }
                            HStack(spacing: 6) {
                                Pill(text: t.str("status") ?? "?", color: statusColor(t.str("status")))
                                Text("\(Fmt.seconds(t.num("duration_seconds"))) · \(Fmt.ago(t.num("started")))")
                                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                                if let m = t.str("model") { Pill(text: m) }
                                ForEach(Array(t.strs("tools").enumerated()), id: \.offset) { _, name in Pill(text: name, color: Theme.accent) }
                            }
                            if let a = t.str("answer"), !a.isEmpty {
                                Text(a).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2).textSelection(.enabled)
                            }
                            if let err = t.str("error"), !err.isEmpty {
                                Text(err).font(.system(size: 11.5)).foregroundStyle(Theme.danger).lineLimit(3).textSelection(.enabled)
                            }
                        }
                        Spacer()
                        if t.str("status") == "running", let id = t.str("id") {
                            Button("หยุด") { model.cancelRun(id) }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - ตั้งเวลา

struct ScheduledTab: View {
    let model: SystemModel
    @ViewState private var briefing = ""

    var body: some View {
        TabScroll {
            Card(title: "ตัวเตือน", trailing: AnyView(
                Picker("", selection: Binding(get: { model.reminderStatus }, set: { model.reminderStatus = $0; Task { await model.refresh() } })) {
                    Text("รอแจ้ง").tag("pending"); Text("แจ้งแล้ว").tag("sent"); Text("ทั้งหมด").tag("all")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize())) {
                if model.reminders.isEmpty {
                    Text("ไม่มีตัวเตือน — สั่ง April ได้ เช่น “เตือนประชุมพรุ่งนี้ 9 โมง”").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                ForEach(Array(model.reminders.enumerated()), id: \.offset) { _, r in
                    let pending = r.num("done") == 0
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "alarm").foregroundStyle(Theme.accent).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.str("text") ?? "").font(.system(size: 13)).foregroundStyle(Theme.ink)
                            HStack(spacing: 8) {
                                Text(Date(timeIntervalSince1970: r.num("due_at") ?? 0),
                                     format: .dateTime.weekday().day().month().year().hour().minute())
                                Pill(text: pending ? "รอแจ้ง" : "แจ้งแล้ว/ยกเลิก", color: pending ? Theme.accent : Theme.muted)
                            }
                            .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if pending {
                            Button("ยกเลิก") { model.cancelReminder(Int(r.num("id") ?? 0)) }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    Divider()
                }
            }
            Card(title: "สรุปประจำวัน", trailing: AnyView(
                Button { model.briefingNow() } label: { Label("สรุปตอนนี้", systemImage: "sun.max") }
                    .buttonStyle(QuietButtonStyle()).disabled(model.busy))) {
                Text("April ทักทาย บอกวันที่ ตัวเตือนที่ค้าง และสถานะเครื่องที่ควรรู้ — แจ้งขึ้นจอทุกวันตามเวลาที่ตั้ง")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                HStack {
                    TextField("เวลา เช่น 07:30 (ว่าง = ปิด)", text: $briefing).textFieldStyle(.roundedBorder).frame(width: 220)
                    Button("บันทึก") {
                        guard briefing.isEmpty || briefing.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil else {
                            model.error = "เวลาต้องเป็นแบบ 07:30"; return
                        }
                        model.saveEnv(["APRIL_BRIEFING_TIME": briefing])
                    }
                    .buttonStyle(AccentButtonStyle())
                    Spacer()
                    if let next = model.config.num("next_briefing") {
                        Text("ครั้งถัดไป \(Date(timeIntervalSince1970: next).formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .onAppear { briefing = model.env["APRIL_BRIEFING_TIME"] ?? "" }
    }
}

// MARK: - โมเดล

struct ModelsTab: View {
    let model: SystemModel
    @ViewState private var localModel = ""
    @ViewState private var defaultModel = "auto"

    var body: some View {
        let m = model.models
        let local = m.obj("local"), info = local.obj("info")
        let cloud = m.arr("cloud")
        TabScroll {
            Card(title: "โมเดลที่ใช้ตอบ") {
                HStack {
                    Picker("ค่าเริ่มต้น", selection: $defaultModel) {
                        Text("อัตโนมัติ (cloud ตัวแรกที่พร้อม แล้วสำรองด้วยโมเดลในเครื่อง)").tag("auto")
                        Text("โมเดลในเครื่องเท่านั้น").tag("local")
                        ForEach(Array(cloud.enumerated()), id: \.offset) { _, c in
                            Text(c.str("label") ?? "").tag(c.str("id") ?? "")
                        }
                    }
                    .frame(maxWidth: 520)
                    Button("บันทึก") { model.saveEnv(["APRIL_DEFAULT_MODEL": defaultModel]) }.buttonStyle(AccentButtonStyle())
                }
                Text("ลำดับ auto: \(m.strs("auto_order").joined(separator: " → ")) → โมเดลในเครื่อง")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }

            Card(title: "โมเดลในเครื่อง (ตัวเดียว)", trailing: AnyView(StatusDot(ok: m.obj("ollama").bool("online")))) {
                HStack(spacing: 10) {
                    StatusDot(ok: local.bool("loaded") == true ? true : local.bool("installed") == true ? nil : false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(local.str("model") ?? "–").font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.ink)
                        Text([info.str("parameter_size"), info.str("quantization_level"), info.num("size").map { Fmt.bytes($0) }]
                            .compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Pill(text: local.bool("loaded") == true ? "อยู่ใน RAM" : local.bool("installed") == true ? "ติดตั้งแล้ว" : "ยังไม่ได้ติดตั้ง",
                         color: local.bool("installed") == true ? Theme.accent : Theme.danger)
                    if let st = local["stats"] as? JSON {
                        Text("เรียก \(Fmt.count(st.num("calls"))) · เฉลี่ย \(Fmt.seconds(st.num("avg_seconds")))")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                }
                HStack {
                    TextField("ชื่อโมเดล Ollama", text: $localModel).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    let options = m.arr("unused").compactMap { $0.str("name") }
                    if !options.isEmpty {
                        Menu("เลือกจากที่ติดตั้ง") { ForEach(options, id: \.self) { n in Button(n) { localModel = n } } }.fixedSize()
                    }
                    Button("เปลี่ยน") { model.saveEnv(["APRIL_LOCAL_MODEL": localModel]) }
                        .buttonStyle(QuietButtonStyle()).disabled(localModel.isEmpty || localModel == local.str("model"))
                }
                if local.bool("installed") == false, let name = local.str("model") {
                    Text("ยังไม่มีโมเดลนี้ในเครื่อง — รัน ollama pull \(name) หรือเปิดแอปใหม่ให้ตัวติดตั้งดาวน์โหลดให้")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.warn)
                }
            }

            Card(title: "โมเดล cloud", trailing: AnyView(
                Button("ตรวจตอนนี้") { model.checkModels() }.buttonStyle(QuietButtonStyle()).disabled(model.busy))) {
                Text("พร้อมใช้ \(cloud.filter { $0.bool("ready") == true }.count) จาก \(cloud.count) ตัว — ตั้งคีย์ในการ์ดด้านล่าง")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                ForEach(Array(cloud.enumerated()), id: \.offset) { _, c in
                    let st = c.obj("stats")
                    HStack(spacing: 8) {
                        Pill(text: ModelsTab.stateLabel(c.str("state")), color: statusColor(c.str("state")))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.str("label") ?? "").font(.system(size: 12.5, weight: .medium))
                            Text(c.str("model").flatMap { $0.isEmpty ? nil : $0 } ?? "(ยังไม่ได้ตั้งชื่อโมเดล)")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if let e = c.obj("last").str("error"), !e.isEmpty {
                            Text(e).font(.system(size: 11)).foregroundStyle(Theme.danger).lineLimit(1).frame(maxWidth: 300, alignment: .trailing)
                        } else if !st.isEmpty {
                            Text("เรียก \(Fmt.count(st.num("calls"))) · เฉลี่ย \(Fmt.seconds(st.num("avg_seconds"))) · token \(Fmt.count(st.num("input_tokens")))→\(Fmt.count(st.num("output_tokens")))")
                                .font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
                        }
                    }
                }
            }

            CloudKeysCard(model: model)

            let extra = m.arr("unused")
            if !extra.isEmpty {
                Card(title: "ติดตั้งใน Ollama แต่ไม่ได้ใช้ (\(extra.count))") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(Array(extra.enumerated()), id: \.offset) { _, x in
                            Pill(text: "\(x.str("name") ?? "") · \(Fmt.bytes(x.num("size")))")
                        }
                    }
                }
            }
        }
        .onAppear {
            let env = model.env
            localModel = env["APRIL_LOCAL_MODEL"] ?? ""
            defaultModel = env["APRIL_DEFAULT_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
        }
        .onChange(of: model.models.obj("local").str("model")) { _, v in if localModel.isEmpty { localModel = v ?? "" } }
    }

    static func stateLabel(_ s: String?) -> String {
        switch s {
        case "online": "ใช้ได้"
        case "error": "ผิดพลาด"
        case "paused": "พักไว้"
        case "unset": "ยังไม่ตั้งค่า"
        default: "ยังไม่ได้ตรวจ"
        }
    }
}

/// คีย์ของผู้ให้บริการ cloud (เก็บใน .env ของเครื่องนี้)
struct CloudKeysCard: View {
    let model: SystemModel
    @ViewState private var values: [String: String] = [:]

    private static let fields: [(String, String, Bool, String?)] = [
        ("ANTHROPIC_API_KEY", "Claude (Anthropic) API key", true, "https://console.anthropic.com/settings/keys"),
        ("OLLAMA_API_KEY", "Ollama Cloud API key", true, "https://ollama.com/settings/keys"),
        ("OPENAI_API_KEY", "OpenAI API key", true, "https://platform.openai.com/api-keys"),
        ("APRIL_OPENAI_MODEL", "ชื่อโมเดล OpenAI", false, nil),
        ("GEMINI_API_KEY", "Gemini API key", true, "https://aistudio.google.com/apikey"),
        ("APRIL_GEMINI_MODEL", "ชื่อโมเดล Gemini", false, nil),
    ]

    var body: some View {
        let masked = model.config.obj("keys")
        Card(title: "คีย์ cloud") {
            Text("ไม่ใส่คีย์ = April ใช้โมเดลในเครื่องอย่างเดียว · ใส่แล้วข้อความที่ถามจะถูกส่งไปผู้ให้บริการนั้น · ช่องว่าง = คงค่าเดิม")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(Self.fields, id: \.0) { f in
                HStack {
                    let current = masked.str(f.0) ?? ""
                    if f.2 {
                        SecureField(current.isEmpty ? f.1 : "\(f.1) — ตอนนี้ \(current)", text: binding(f.0)).textFieldStyle(.roundedBorder)
                    } else {
                        TextField(f.1, text: binding(f.0)).textFieldStyle(.roundedBorder)
                    }
                    if let link = f.3, let u = URL(string: link) { Link("ขอคีย์", destination: u).font(.system(size: 12)) }
                }
            }
            HStack {
                Spacer()
                Button("ล้างคีย์ทั้งหมด") {
                    model.saveEnv(Dictionary(uniqueKeysWithValues: Self.fields.filter(\.2).map { ($0.0, "") }))
                }
                .buttonStyle(QuietButtonStyle())
                Button("บันทึก") {
                    let changed = values.filter { !$0.value.isEmpty || !(Self.fields.first { $0.0 == $0.0 }?.2 ?? true) }
                    model.saveEnv(changed.mapValues { $0.trimmingCharacters(in: .whitespaces) })
                    values = values.filter { k, _ in !(Self.fields.first { $0.0 == k }?.2 ?? false) }
                }
                .buttonStyle(AccentButtonStyle())
            }
        }
        .onAppear {
            let env = model.env
            values = ["APRIL_OPENAI_MODEL": env["APRIL_OPENAI_MODEL"] ?? "", "APRIL_GEMINI_MODEL": env["APRIL_GEMINI_MODEL"] ?? ""]
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
}

// MARK: - Log สด

struct LogsTab: View {
    @Bindable var model: SystemModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("กรอง (type / trace / ข้อความ)", text: $model.logFilter)
                    .textFieldStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                    .frame(maxWidth: 340)
                Picker("", selection: $model.logLevel) {
                    Text("ทุกระดับ").tag("all"); Text("info").tag("info"); Text("warning").tag("warning"); Text("error").tag("error")
                }
                .labelsHidden().frame(width: 120)
                Spacer()
                Button(model.logPaused ? "ต่อ" : "พัก") { model.logPaused.toggle() }.buttonStyle(QuietButtonStyle())
                Button("ล้าง") { model.events.removeAll() }.buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 28)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.filteredEvents.prefix(800).enumerated()), id: \.offset) { _, e in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Fmt.clock(e.num("ts"))).foregroundStyle(Theme.muted)
                            Text(e.str("type") ?? "").foregroundStyle(levelColor(e.str("level"))).frame(width: 190, alignment: .leading)
                                .lineLimit(1)
                            Text(String((e.str("trace_id") ?? "-").prefix(8))).foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading)
                            Text(Fmt.compactJSON(e["data"])).foregroundStyle(Theme.ink).lineLimit(2).textSelection(.enabled)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(.vertical, 3).padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .padding(.horizontal, 28).padding(.bottom, 20)
        }
        .task { await model.streamEvents() }
    }

    func levelColor(_ l: String?) -> Color {
        switch l { case "error": Theme.danger; case "warning": Theme.warn; default: Theme.accent }
    }
}

// MARK: - ความจำ

struct MemoryTab: View {
    @Bindable var model: SystemModel
    @ViewState private var newNote = ""

    var body: some View {
        let shown = model.notes.filter { model.memQuery.isEmpty || ($0.str("text") ?? "").localizedCaseInsensitiveContains(model.memQuery) }
        TabScroll {
            HStack(spacing: 8) {
                TextField("ค้นหาความจำ", text: $model.memQuery).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
            }
            Card(title: "จดเอง") {
                HStack {
                    TextField("เช่น บอสแพ้กุ้ง · ประชุมทีมทุกวันจันทร์ 10 โมง", text: $newNote).textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("จด", action: add).buttonStyle(AccentButtonStyle()).disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Card(title: "ความจำเรื่องเจ้านาย (\(shown.count))") {
                if shown.isEmpty { Text("ยังไม่มีความจำ — บอก April เรื่องของคุณได้เลย เช่น “จำไว้ว่าผมแพ้กุ้ง”").foregroundStyle(Theme.muted) }
                ForEach(Array(shown.enumerated()), id: \.offset) { i, n in
                    if i > 0 { Divider().overlay(Theme.line) }
                    HStack(alignment: .top, spacing: 10) {
                        Pill(text: "#\(n.str("id") ?? "")", color: Theme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(n.str("text") ?? "").font(.system(size: 13)).foregroundStyle(Theme.ink).textSelection(.enabled)
                            Text(Fmt.ago(n.num("created"))).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button { model.deleteNote(Int(n.num("id") ?? 0)) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(Theme.muted).help("ลบความจำนี้")
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func add() {
        let t = newNote.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.addNote(t)
        newNote = ""
    }
}

// MARK: - คาแรคเตอร์

struct PersonaTab: View {
    let model: SystemModel
    @ViewState private var draft: [String: String] = [:]
    @ViewState private var checklist = false
    @ViewState private var showPrompt = false

    private static let fields: [(String, String)] = [
        ("APRIL_NAME", "ชื่อผู้ช่วย"), ("APRIL_OWNER_NAME", "ชื่อที่ให้เรียกคุณ (ว่าง = บอส)"),
        ("APRIL_PARTICLE", "คำลงท้าย (ครับ / ค่ะ)"), ("APRIL_LANGUAGE", "ภาษาที่ตอบ"), ("APRIL_TIMEZONE", "เขตเวลา"),
    ]

    var body: some View {
        let p = model.persona
        TabScroll {
            Card(title: "ตัวตน") {
                Text("พ่อบ้าน AI แบบ JARVIS / FRIDAY — สุภาพ รู้ใจ ทำงานให้เสร็จด้วยเครื่องมือแทนการถามกลับ")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                ForEach(Self.fields, id: \.0) { f in
                    HStack {
                        Text(f.1).font(.system(size: 12.5)).foregroundStyle(Theme.muted).frame(width: 210, alignment: .leading)
                        TextField(placeholder(f.0, p), text: Binding(get: { draft[f.0] ?? "" }, set: { draft[f.0] = $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Toggle(isOn: $checklist) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("คิดก่อนตอบ ตรวจก่อนส่ง").font(.system(size: 12.5))
                        Text("คำขอที่มีเงื่อนไขชัด (จำนวน งบ รูปแบบ) จะถูกแตกเป็นเช็กลิสต์ ตรวจคำตอบ แล้วแก้ 1 ครั้งถ้าไม่ผ่าน — แม่นขึ้นแต่ช้าลง")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
                HStack {
                    Spacer()
                    Button("บันทึก") {
                        var v = draft.mapValues { $0.trimmingCharacters(in: .whitespaces) }
                        v["APRIL_CHECKLIST_ENABLED"] = checklist ? "true" : "false"
                        model.saveEnv(v)
                    }
                    .buttonStyle(AccentButtonStyle())
                }
            }
            Card(title: "System prompt ที่ใช้จริง", trailing: AnyView(
                Button(showPrompt ? "ซ่อน" : "แสดง") { showPrompt.toggle() }.buttonStyle(QuietButtonStyle()))) {
                Text("บุคลิก + กฎการทำงาน + ความจำเรื่องคุณ (เวลาปัจจุบันแนบท้ายคำถามแต่ละครั้ง ไม่อยู่ในนี้ เพื่อให้ prompt cache ทำงาน)")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                if showPrompt {
                    Text(p.str("system_prompt") ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .onAppear {
            let env = model.env
            draft = Dictionary(uniqueKeysWithValues: Self.fields.map { ($0.0, env[$0.0] ?? "") })
            checklist = env["APRIL_CHECKLIST_ENABLED"] == "true"
        }
    }

    private func placeholder(_ key: String, _ p: JSON) -> String {
        switch key {
        case "APRIL_NAME": p.str("name") ?? "April"
        case "APRIL_OWNER_NAME": "บอส"
        case "APRIL_PARTICLE": p.str("particle") ?? "ครับ"
        case "APRIL_LANGUAGE": p.str("language") ?? "ไทย"
        default: p.str("timezone") ?? "Asia/Bangkok"
        }
    }
}

// MARK: - เครื่องมือ

struct ToolsTab: View {
    let model: SystemModel
    @ViewState private var picked: String?
    @ViewState private var args: [String: String] = [:]

    static let labels = [
        "current_datetime": "ดูเวลา", "calculate": "คำนวณ", "web_search": "ค้นเว็บ", "read_webpage": "อ่านหน้าเว็บ",
        "remember": "จดความจำ", "recall": "ค้นความจำ", "forget": "ลบความจำ", "set_reminder": "ตั้งเตือน",
        "list_reminders": "ดูตัวเตือน", "cancel_reminder": "ยกเลิกเตือน", "system_status": "เช็กเครื่อง",
        "open_app": "เปิดแอป", "open_url": "เปิดเว็บ", "notify": "แจ้งเตือน",
    ]

    var body: some View {
        let all = model.tools.arr("tools")
        let tool = all.first { $0.str("name") == picked }
        TabScroll {
            HStack(alignment: .top, spacing: 12) {
                Card(title: "เครื่องมือในตัว (\(all.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(all.enumerated()), id: \.offset) { _, t in
                                let name = t.str("name") ?? ""
                                Button { picked = name; args = [:]; model.toolResult = nil } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(name).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                            if t.bool("action") == true { Pill(text: "สั่งงานเครื่อง", color: Theme.warn) }
                                        }
                                        Text(t.str("description") ?? "").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(picked == name ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: 380)
                }
                .frame(maxWidth: 380)
                Card(title: tool.map { "ทดลองรัน \($0.str("name") ?? "")" } ?? "ทดลองรัน") {
                    if let tool {
                        Text(tool.str("description") ?? "").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        let props = tool.obj("parameters").obj("properties")
                        let required = Set(tool.obj("parameters").strs("required"))
                        ForEach(props.keys.sorted(), id: \.self) { k in
                            let p = props[k] as? JSON ?? [:]
                            VStack(alignment: .leading, spacing: 3) {
                                Text(k + (required.contains(k) ? " *" : "") + " · " + (p.str("type") ?? "string"))
                                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                TextField(p.str("description") ?? "", text: Binding(get: { args[k] ?? "" }, set: { args[k] = $0 }))
                                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                            }
                        }
                        Button("รัน") { model.runTool(tool.str("name") ?? "", typed(props)) }.buttonStyle(AccentButtonStyle())
                        if let r = model.toolResult {
                            HStack {
                                Pill(text: r.bool("ok") == true ? "สำเร็จ" : "ผิดพลาด", color: r.bool("ok") == true ? Theme.accent : Theme.danger)
                                Text(String(format: "%.3f วิ", r.num("seconds") ?? 0)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            }
                            Text(r.str("result") ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        Text("เลือกเครื่องมือทางซ้าย แล้วใส่ค่าเพื่อทดลองรัน (ไม่ผ่านโมเดล)").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    }
                }
            }
            Card(title: "การเรียกเครื่องมือล่าสุด") {
                if model.tools.arr("recent_calls").isEmpty { Text("ยังไม่มี").font(.system(size: 12.5)).foregroundStyle(Theme.muted) }
                ForEach(Array(model.tools.arr("recent_calls").prefix(40).enumerated()), id: \.offset) { _, c in
                    HStack(spacing: 10) {
                        StatusDot(ok: c.bool("ok"))
                        Text(c.str("name") ?? "").font(.system(size: 12, design: .monospaced))
                        Text(Fmt.compactJSON(c["arguments"])).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                        Spacer()
                        Text(Fmt.ago(c.num("at"))).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    .help(c.str("preview") ?? "")
                }
            }
        }
    }

    private func typed(_ props: JSON) -> JSON {
        var out: JSON = [:]
        for (k, raw) in args where !raw.isEmpty {
            switch (props[k] as? JSON)?.str("type") ?? "string" {
            case "number": out[k] = Double(raw) ?? raw
            case "integer": out[k] = Int(raw) ?? raw
            case "boolean": out[k] = ["true", "1", "ใช่", "yes"].contains(raw.lowercased())
            case "array", "object": out[k] = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? raw
            default: out[k] = raw
            }
        }
        return out
    }
}

// MARK: - เสียง (เรียกแบบ Siri)

struct VoiceTab: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var talk = app.talk
        @Bindable var wake = app.wake
        @Bindable var hotkey = app.hotkey
        let voices = TalkModel.thaiVoices
        TabScroll {
            Card(title: "เรียก April แบบ Siri", trailing: AnyView(
                Button { app.summon() } label: { Label("ลองเรียก", systemImage: "waveform.circle") }.buttonStyle(AccentButtonStyle()))) {
                Text("กดคีย์ลัด หรือพูดว่า “April” — พื้นที่ดำจะขยายออกจากรอยบากจอแบบ Dynamic Island ฟังคำสั่ง ตอบด้วยเสียง รอฟังคำถามต่อสั้นๆ แล้วหดกลับเอง (ไม่มีตัวอักษร — คำตอบเต็มดูได้ในแท็บงาน)")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                Picker("คีย์ลัด", selection: $hotkey.choice) {
                    ForEach(HotKeyChoice.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 320)
                if let p = hotkey.problem { Text(p).font(.system(size: 11.5)).foregroundStyle(Theme.warn) }
                Toggle(isOn: $wake.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("เรียกด้วยเสียง “April”").font(.system(size: 12.5))
                        Text("ฟังไมค์ตลอดเวลา ถอดเสียงบนเครื่องนี้เท่านั้น (เครื่องที่ทำไม่ได้จะไม่เปิดให้ใช้ — เสียงในห้องไม่ออกนอกเครื่อง)")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
                if wake.enabled {
                    HStack(spacing: 6) {
                        StatusDot(ok: wake.listening ? true : nil)
                        Text(wake.listening ? "กำลังรอฟัง “April”" : "พักอยู่ (กำลังคุย หรือรอสิทธิ์)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                if let p = wake.problem { Text(p).font(.system(size: 11.5)).foregroundStyle(Theme.warn) }
            }
            Card(title: "เสียงพูด") {
                Picker("เสียง", selection: $talk.voiceID) {
                    if voices.isEmpty { Text("ไม่มีเสียงภาษาไทยในเครื่องนี้").tag("") }
                    if !voices.contains(where: { $0.identifier == talk.voiceID }) && !voices.isEmpty {
                        Text("อัตโนมัติ").tag(talk.voiceID)
                    }
                    ForEach(voices, id: \.identifier) { v in
                        Text(v.name + (v.quality == .premium ? " (พรีเมียม)" : v.quality == .enhanced ? " (คุณภาพสูง)" : "")).tag(v.identifier)
                    }
                }
                .frame(maxWidth: 420)
                HStack {
                    Text("ความเร็ว").font(.system(size: 12.5))
                    Slider(value: $talk.rate, in: 0.8...1.6, step: 0.05).frame(maxWidth: 260)
                    Text(String(format: "%.2f×", talk.rate)).monospacedDigit().font(.system(size: 12)).frame(width: 44)
                    Button("ลองฟัง") { talk.preview() }.buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button("เพิ่มเสียงไทย…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                Toggle("พูดแทรกด้วยเสียงได้ (ใส่หูฟังจะแม่นที่สุด)", isOn: $talk.bargeIn).toggleStyle(.switch).controlSize(.small)
            }
            Card(title: "สิทธิ์ของแอป") {
                HStack {
                    Text("ไมโครโฟน และ Speech Recognition — macOS ถามครั้งแรกที่ใช้").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("ไมโครโฟน…") { open("Privacy_Microphone") }.buttonStyle(QuietButtonStyle())
                    Button("Speech Recognition…") { open("Privacy_SpeechRecognition") }.buttonStyle(QuietButtonStyle())
                    Button("Dictation ภาษาไทย…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    private func open(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

// MARK: - การเชื่อมต่อ

struct ConnectionsTab: View {
    @Environment(AppState.self) private var app
    let model: SystemModel
    @ViewState private var host = "127.0.0.1"

    var body: some View {
        let c = model.config
        TabScroll {
            HStack(alignment: .top, spacing: 12) {
                Card(title: "API ของ April", trailing: AnyView(StatusDot(ok: app.backend.online))) {
                    KV(k: "ในเครื่องนี้", v: "http://127.0.0.1:\(Int(c.num("port") ?? 8100))")
                    KV(k: "เปิดให้", v: c.str("host") == "0.0.0.0" ? "เครื่องอื่นในเครือข่าย" : "เครื่องนี้เท่านั้น")
                    KV(k: "Token", v: c.bool("api_token_set") == true ? "ตั้งแล้ว" : "ไม่มี")
                    Text("POST /chat (SSE) · POST /chat/sync · /api/* — ดู README").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
                Card(title: "การสั่งงานเครื่อง") {
                    Toggle("ให้ April เปิดแอป/เว็บ และแจ้งเตือนได้", isOn: Binding(
                        get: { c.bool("allow_actions") ?? true },
                        set: { model.saveEnv(["APRIL_ALLOW_ACTIONS": $0 ? "true" : "false"]) }))
                        .toggleStyle(.switch).controlSize(.small)
                    Toggle("แจ้งเตือนขึ้นจอ Mac (ตัวเตือน/สรุปประจำวัน)", isOn: Binding(
                        get: { c.bool("notify_mac") ?? true },
                        set: { model.saveEnv(["APRIL_NOTIFY_MAC": $0 ? "true" : "false"]) }))
                        .toggleStyle(.switch).controlSize(.small)
                    Text("April ไม่มีเครื่องมือรันคำสั่ง shell — สั่งงานเครื่องได้เฉพาะคำสั่งที่กำหนดไว้แล้ว").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
            }
            Card(title: "ให้เครื่องอื่นเรียก April") {
                Picker("", selection: $host) {
                    Text("เครื่องนี้เท่านั้น").tag("127.0.0.1"); Text("เครื่องอื่นในเครือข่าย (ต้องมี token)").tag("0.0.0.0")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 460)
                HStack {
                    Button("บันทึก") {
                        var v = ["APRIL_HOST": host]
                        if host == "0.0.0.0" && c.bool("api_token_set") != true { v["APRIL_API_TOKEN"] = Self.newToken() }
                        model.saveEnv(v)
                    }
                    .buttonStyle(AccentButtonStyle()).disabled(host == (c.str("host") ?? "127.0.0.1"))
                    Button("ออก token ใหม่") { model.saveEnv(["APRIL_API_TOKEN": Self.newToken()], note: "ออก token ใหม่แล้ว — คัดลอกได้ด้านล่าง") }
                        .buttonStyle(QuietButtonStyle())
                    if c.bool("api_token_set") == true {
                        Button("คัดลอก token") { copyToClipboard(model.env["APRIL_API_TOKEN"] ?? "") }.buttonStyle(QuietButtonStyle())
                        Button("ลบ token") { model.saveEnv(["APRIL_API_TOKEN": "", "APRIL_HOST": "127.0.0.1"]) }.buttonStyle(QuietButtonStyle())
                    }
                }
                Text("เปิดให้เครื่องอื่นแล้ว ทุกคำขอต้องมี Authorization: Bearer <token> — แอปนี้ใส่ให้เอง").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            Card(title: "ไฟล์และข้อมูล") {
                KV(k: "โฟลเดอร์ข้อมูล", v: c.str("data_dir") ?? "–")
                HStack {
                    Button("เปิดโฟลเดอร์ข้อมูล") { reveal(c.str("data_dir")) }.buttonStyle(QuietButtonStyle())
                    Button("เปิดไฟล์ .env") { if let u = app.backend.envFile { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                        .buttonStyle(QuietButtonStyle())
                    Button("ไฟล์ log") { app.openLogs() }.buttonStyle(QuietButtonStyle())
                }
            }
        }
        .onAppear { host = c.str("host") ?? model.env["APRIL_HOST"] ?? "127.0.0.1" }
    }

    static func newToken() -> String {
        (0..<32).map { _ in String("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement()!) }.joined()
    }

    private func reveal(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

// MARK: - อัปเดต

struct UpdateTab: View {
    @Environment(AppState.self) private var app
    let model: SystemModel
    @ViewState private var confirm: Release?

    var body: some View {
        @Bindable var updater = app.updater
        TabScroll {
            Card {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("April \(updater.version)").font(Theme.serif(24)).foregroundStyle(Theme.ink)
                        Text("build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") · \(Bundle.main.object(forInfoDictionaryKey: "AprilCommit") as? String ?? "") · backend \(model.backendVersion ?? "–")")
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.muted)
                        Text("อัปเดตจาก GitHub Releases (\(Backend.repoSlug))").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                if let v = model.backendVersion, v != updater.version {
                    Label("backend เป็นรุ่น \(v) ไม่ตรงกับแอป — กด เริ่ม April ใหม่", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.warn)
                }
            }

            Card(title: updater.newest.map { "มีเวอร์ชันใหม่ April \($0.version)" } ?? "เป็นรุ่นล่าสุดแล้ว",
                 trailing: AnyView(HStack {
                     Button { Task { await updater.check(verbose: true) } } label: { Label("ตรวจตอนนี้", systemImage: "arrow.clockwise") }
                         .buttonStyle(QuietButtonStyle()).disabled(updater.working)
                     if let n = updater.newest {
                         Button { confirm = n } label: { Label("อัปเดตเลย", systemImage: "arrow.down.circle") }
                             .buttonStyle(AccentButtonStyle()).disabled(updater.working)
                     }
                 })) {
                if updater.working { ProgressView(value: updater.progress ?? 0).tint(Theme.accent) }
                if let m = updater.message { Text(m).font(.system(size: 12)).foregroundStyle(Theme.muted) }
                Picker("อัปเดตอัตโนมัติ", selection: $updater.mode) {
                    ForEach(AutoUpdateMode.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 460)
                Toggle("รับรุ่นทดสอบ (beta)", isOn: $updater.beta).toggleStyle(.switch).controlSize(.small)
                if updater.pinned {
                    HStack {
                        Label("ตรึงไว้ที่รุ่นนี้ — ไม่อัปเดตเอง", systemImage: "pin.fill").font(.system(size: 12.5)).foregroundStyle(Theme.warn)
                        Spacer()
                        Button("เลิกตรึง") { updater.pinned = false; Task { await updater.autoApply() } }.buttonStyle(QuietButtonStyle())
                    }
                }
                if let t = updater.lastCheck {
                    Text("ตรวจล่าสุด \(Fmt.ago(t.timeIntervalSince1970)) · ตรวจเองทุกชั่วโมง").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }

            Card(title: "ทุกรุ่น") {
                if updater.visible.isEmpty { Text("ยังไม่มีข้อมูลรุ่น — กด ตรวจตอนนี้").font(.system(size: 12.5)).foregroundStyle(Theme.muted) }
                ForEach(Array(updater.visible.enumerated()), id: \.offset) { i, r in
                    if i > 0 { Divider().overlay(Theme.line) }
                    ReleaseRow(release: r, confirm: $confirm)
                }
            }
        }
        .task { if updater.releases.isEmpty { await updater.check() } }
        .confirmationDialog(confirm.map { "ติดตั้ง April \($0.version)?" } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { r in
            Button(UpdatePolicy.newer(r.version, than: updater.version) ? "อัปเดตเลย" : "ย้อนกลับ") { Task { await updater.install(r) } }
        } message: { r in
            Text(UpdatePolicy.newer(r.version, than: updater.version)
                 ? "April จะปิดแล้วเปิดใหม่เป็นรุ่น \(r.version) — ข้อมูลและความจำอยู่ครบ"
                 : "ย้อนกลับเป็นรุ่น \(r.version) แล้วตรึงไว้ไม่ให้อัปเดตเองทับ (เลิกตรึงได้ทีหลัง) — ข้อมูลและความจำอยู่ครบ")
        }
    }
}

struct ReleaseRow: View {
    @Environment(AppState.self) private var app
    let release: Release
    @Binding var confirm: Release?
    @ViewState private var open = false

    var body: some View {
        let updater = app.updater
        let current = release.version == updater.version
        let newer = UpdatePolicy.newer(release.version, than: updater.version)
        let skipped = updater.skipped.contains(release.version)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { open.toggle() } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.muted).frame(width: 12)
                }
                .buttonStyle(.plain)
                Text(release.version).font(.system(size: 13, weight: current ? .semibold : .regular, design: .monospaced)).foregroundStyle(Theme.ink)
                if current { Pill(text: "ใช้อยู่", color: Theme.accent) }
                if release.prerelease { Pill(text: "beta", color: Theme.warn) }
                if skipped { Pill(text: "ข้ามแล้ว") }
                if newer, !skipped, UpdatePolicy.isPatch(release.version, of: updater.version) { Pill(text: "แพตช์", color: Theme.accent) }
                if let d = release.date { Text(d.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                Spacer()
                if !current {
                    if newer && !skipped { Button("ข้าม") { updater.skip(release) }.buttonStyle(.borderless).font(.system(size: 12)) }
                    Button(newer ? "อัปเดต" : "ย้อนกลับ") { confirm = release }
                        .buttonStyle(newer ? AnyButtonStyle(AccentButtonStyle()) : AnyButtonStyle(QuietButtonStyle()))
                        .disabled(updater.working || release.zip == nil)
                }
            }
            if open {
                Text(markdown(release.notes.isEmpty ? "(ไม่มีรายละเอียด)" : release.notes))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.ink).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20)
            }
        }
        .padding(.vertical, 3)
    }
}

/// เลือก ButtonStyle ตามเงื่อนไขได้
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
