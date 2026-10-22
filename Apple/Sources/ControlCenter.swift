// ControlCenter.swift — หน้าต่างหลักของแอป = ศูนย์ควบคุม (โครงและหน้าตาเดียวกับหน้า "ระบบ" ของ Envy)
//   ภาพรวม · RAM · งาน · ตั้งเวลา · โมเดล · Log · ความจำ · คาแรคเตอร์ · เครื่องมือ · เสียง · การเชื่อมต่อ · อัปเดต
// การใช้งาน April จริงไม่ได้อยู่ที่นี่ — เรียกแบบ Dynamic Island (⌥Space / "April") ดู Island.swift
// ข้อมูลมาจาก /api/* ของเซิร์ฟเวอร์ (april/control_api.py) · ค่าตั้งเขียนลง .env แล้วเริ่มเซิร์ฟเวอร์ใหม่

import AppKit
import SwiftUI

enum Fmt {
    static func count(_ v: Double?) -> String {
        guard let v else { return "–" }
        switch v {
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 10_000...: return String(format: "%.1fk", v / 1_000)
        default: return String(Int(v))
        }
    }
    static func seconds(_ v: Double?) -> String {
        guard let v else { return "–" }
        if v < 60 { return String(format: "%.1f วิ", v) }
        if v < 3600 { return "\(Int(v / 60)) นาที" }
        if v < 86_400 { return String(format: "%.1f ชม.", v / 3600) }
        return String(format: "%.1f วัน", v / 86_400)
    }
    static func ago(_ ts: Double?) -> String {
        guard let ts, ts > 0 else { return "–" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "th_TH")
        return f.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }
    static func clock(_ ts: Double?) -> String {
        guard let ts else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
    static func bytes(_ v: Double?) -> String {
        guard let v else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file)
    }
    static func compactJSON(_ v: Any?) -> String {
        guard let v, JSONSerialization.isValidJSONObject(v),
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.withoutEscapingSlashes]) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}

enum SysTab: String, CaseIterable, Identifiable {
    case overview = "ภาพรวม", ram = "RAM", tasks = "งาน", scheduled = "ตั้งเวลา", models = "โมเดล", logs = "Log",
         memory = "ความจำ", persona = "คาแรคเตอร์", tools = "เครื่องมือ", voice = "เสียง", connections = "การเชื่อมต่อ",
         update = "อัปเดต"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .ram: "memorychip"
        case .tasks: "list.bullet.rectangle"
        case .scheduled: "alarm"
        case .models: "cpu"
        case .logs: "terminal"
        case .memory: "brain"
        case .persona: "person.crop.circle.badge.checkmark"
        case .tools: "wrench.adjustable"
        case .voice: "waveform"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .update: "arrow.triangle.2.circlepath"
        }
    }
}

/// อ่าน/เขียน .env แบบคงบรรทัดอื่นและคอมเมนต์ไว้ (chmod 600 — มี API key)
struct EnvFile {
    let url: URL

    func read() -> [String: String] {
        var out: [String: String] = [:]
        for line in ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            out[String(t[..<eq])] = String(t[t.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return out
    }

    func write(_ values: [String: String]) throws {
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        var pending = values
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            let key = String(t[..<eq])
            if let v = pending.removeValue(forKey: key) { lines[i] = "\(key)=\(v)" }
        }
        if lines.last == "" { lines.removeLast() }
        lines += pending.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor @Observable
final class SystemModel {
    var tab: SysTab = .overview
    var error: String?
    var busy = false
    var overview: JSON = [:]
    var runs: [JSON] = []
    var models: JSON = [:]
    var power: JSON = [:]
    var lastClear: String?
    var events: [JSON] = []
    var logFilter = ""
    var logLevel = "all"
    var logPaused = false
    var notes: [JSON] = []
    var memQuery = ""
    var reminders: [JSON] = []
    var reminderStatus = "pending"
    var persona: JSON = [:]
    var config: JSON = [:]
    var tools: JSON = [:]
    var toolResult: JSON?
    var backendVersion: String?
    var saved: String?

    let backend: Backend
    init(backend: Backend) { self.backend = backend }
    var api: AprilAPI { backend.api }

    private func load(_ f: () async throws -> Void) async {
        do { try await f(); error = nil } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard backend.phase == .ready else { return }
        switch tab {
        case .overview: await load { overview = try await api.call("GET", "api/overview") }
        case .ram: await load { power = try await api.call("GET", "api/power") }
        case .tasks: await load { runs = try await api.call("GET", "api/runs", query: ["limit": "150"]).arr("runs") }
        case .scheduled:
            await load {
                reminders = try await api.call("GET", "api/reminders", query: ["status": reminderStatus]).arr("reminders")
                config = try await api.call("GET", "api/config")
            }
        case .models:
            await load {
                models = try await api.call("GET", "api/models")
                config = try await api.call("GET", "api/config")
            }
        case .logs: if events.isEmpty { await load { events = try await api.call("GET", "api/events", query: ["limit": "300"]).arr("events") } }
        case .memory: await load { notes = try await api.call("GET", "notes").arr("items") }
        case .persona:
            await load {
                persona = try await api.call("GET", "api/persona")
                config = try await api.call("GET", "api/config")
            }
        case .tools: await load { tools = try await api.call("GET", "api/tools") }
        case .voice: break
        case .connections: await load { config = try await api.call("GET", "api/config") }
        case .update: await load { backendVersion = try await api.call("GET", "api/version").str("version") }
        }
    }

    var interval: Double {
        switch tab {
        case .overview, .ram, .tasks: 3
        case .models: 10
        case .persona, .tools, .connections, .voice: 120   // แก้ไขอยู่ — ไม่รีเฟรชทับบ่อย
        case .update: 60
        default: 15
        }
    }

    func act(_ f: @escaping () async throws -> Void) {
        Task {
            busy = true
            defer { busy = false }
            await load(f)
            await refresh()
        }
    }

    // ---- actions
    func cancelRun(_ id: String) { act { try await self.api.call("POST", "api/runs/\(id)/cancel") } }
    func checkModels() { act { self.models = try await self.api.call("POST", "api/models/check", timeout: 90) } }
    func unloadModel(_ name: String) { act { try await self.api.call("POST", "api/power/unload", json: ["models": [name]]) } }
    func cancelReminder(_ id: Int) { act { try await self.api.call("DELETE", "api/reminders/\(id)") } }
    func addNote(_ text: String) { act { try await self.api.call("POST", "api/notes", json: ["text": text]) } }
    func deleteNote(_ id: Int) { act { try await self.api.call("DELETE", "notes/\(id)") } }
    func briefingNow() {
        act {
            let t = try await self.api.call("POST", "briefing", timeout: 300).str("text") ?? ""
            self.saved = t.isEmpty ? "สรุปไม่สำเร็จ" : "สรุปแล้ว — ดูในประกาศล่าสุดหน้าภาพรวม"
        }
    }

    func runTool(_ name: String, _ args: JSON) {
        toolResult = nil
        act { self.toolResult = try await self.api.call("POST", "api/tools/\(name)/run", json: ["arguments": args]) }
    }

    func clearRAM() {
        lastClear = nil
        act {
            let r = try await self.api.call("POST", "api/power/clear")
            let n = r.strs("unloaded").count
            var text = n == 0 ? "ไม่มีโมเดลที่ว่างให้ปลด" : "คืน RAM ~\(Fmt.bytes(r.num("bytes"))) · ปลด \(n) โมเดล"
            if let a = r.obj("before").num("free_percent"), let b = r.obj("after").num("free_percent") {
                text += " · RAM ว่าง \(Int(a))% → \(Int(b))%"
            }
            self.lastClear = text
        }
    }

    // ---- ค่าตั้ง (.env) — บันทึกแล้วเริ่มเซิร์ฟเวอร์ใหม่
    var env: [String: String] { backend.envFile.map { EnvFile(url: $0).read() } ?? [:] }

    func saveEnv(_ values: [String: String], note: String = "บันทึกแล้ว — เริ่ม April ใหม่ให้แล้ว") {
        guard let url = backend.envFile else { error = "ไม่พบไฟล์ .env ของ April"; return }
        do {
            try EnvFile(url: url).write(values)
            saved = note
            Task {
                busy = true
                await backend.restart()
                busy = false
                await refresh()
            }
        } catch {
            self.error = "บันทึกไม่ได้: \(error.localizedDescription)"
        }
    }

    // ---- log สด: ย้อนหลัง 300 รายการ + SSE ต่อท้าย
    func streamEvents() async {
        while !Task.isCancelled {
            var req = URLRequest(url: backend.baseURL.appendingPathComponent("api/events/stream"))
            req.timeoutInterval = 3600
            backend.authorize(&req)
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:"), !logPaused else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let ev = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? JSON else { continue }
                    events.insert(ev, at: 0)
                    if events.count > 1500 { events.removeLast(events.count - 1500) }
                }
            } catch {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    var filteredEvents: [JSON] {
        events.filter { e in
            (logLevel == "all" || e.str("level") == logLevel)
                && (logFilter.isEmpty || "\(e.str("type") ?? "") \(e.str("trace_id") ?? "") \(Fmt.compactJSON(e["data"]))"
                    .localizedCaseInsensitiveContains(logFilter))
        }
    }
}

// MARK: - หน้าต่างหลัก

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if app.backend.phase == .ready { SystemView() } else { BootView() }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(Theme.canvas)
        .onAppear { app.openMain = { openWindow(id: "main") } }
    }
}

struct SystemView: View {
    @Environment(AppState.self) private var app
    private var model: SystemModel { app.system }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("ศูนย์ควบคุม").font(Theme.serif(28)).foregroundStyle(Theme.ink)
                if model.busy { ProgressView().controlSize(.small).padding(.leading, 6) }
                Spacer()
                Button { app.summon() } label: { Label("เรียก April  \(app.hotkey.choice.label)", systemImage: "waveform.circle") }
                    .buttonStyle(AccentButtonStyle())
                Button { Task { await app.backend.restart() } } label: { Label("เริ่ม April ใหม่", systemImage: "arrow.clockwise") }
                    .buttonStyle(QuietButtonStyle())
                Button { app.openLogs() } label: { Label("ไฟล์ log", systemImage: "doc.text") }
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 28).padding(.top, 18)

            HScroll {
                HStack(spacing: 6) {
                    ForEach(SysTab.allCases) { t in
                        Button { model.tab = t } label: {
                            Label(t.rawValue, systemImage: t.icon)
                                .lineLimit(1).fixedSize()
                                .font(.system(size: 12.5, weight: model.tab == t ? .semibold : .regular))
                                .foregroundStyle(model.tab == t ? Theme.accent : Theme.muted)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(model.tab == t ? Theme.accentSoft : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 12)
            }

            if let err = model.error {
                Label(err, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.danger)
                    .padding(.horizontal, 28).padding(.bottom, 8)
            }
            if let s = model.saved {
                HStack {
                    Label(s, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(Theme.accent)
                    Button { model.saved = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 28).padding(.bottom, 8)
            }

            Group {
                switch model.tab {
                case .overview: OverviewTab(model: model)
                case .ram: RAMTab(model: model)
                case .tasks: TasksTab(model: model)
                case .scheduled: ScheduledTab(model: model)
                case .models: ModelsTab(model: model)
                case .logs: LogsTab(model: model)
                case .memory: MemoryTab(model: model)
                case .persona: PersonaTab(model: model)
                case .tools: ToolsTab(model: model)
                case .voice: VoiceTab()
                case .connections: ConnectionsTab(model: model)
                case .update: UpdateTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task(id: model.tab) {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(model.interval))
            }
        }
    }
}

struct TabScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if APRIL_PREVIEW
        inner   // ImageRenderer วาดเนื้อหาใน ScrollView ไม่ได้
        #else
        ScrollView { inner }
        #endif
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(.horizontal, 28).padding(.bottom, 28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

/// แถบแท็บเลื่อนแนวนอน (build พรีวิวไม่ใช้ ScrollView — ImageRenderer วาดไม่ได้)
struct HScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if APRIL_PREVIEW
        content
        #else
        ScrollView(.horizontal, showsIndicators: false) { content }
        #endif
    }
}

struct Stat: View {
    let label: String
    let value: String
    var note: String? = nil
    var tone: Color = Theme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(tone).monospacedDigit()
            // ไม่มีบรรทัดย่อยก็เว้นที่ไว้ — การ์ดในแถวเดียวกันสูงเท่ากัน
            Text(note ?? " ").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
    }
}

struct KV: View {
    let k: String
    let v: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.system(size: 12.5)).foregroundStyle(Theme.muted).frame(width: 130, alignment: .leading)
            Text(v).font(.system(size: 12.5)).foregroundStyle(Theme.ink).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

func statusColor(_ s: String?) -> Color {
    switch s ?? "" {
    case "done", "ok", "loaded", "running", "online": Theme.accent
    case "failed", "error", "cancelled": Theme.danger
    case "queued", "unknown", "starting", "paused": Theme.warn
    default: Theme.muted
    }
}

// MARK: - เปิดระบบ / ติดตั้งครั้งแรก

struct BootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            switch app.backend.phase {
            case .working(let what):
                Text(what).font(Theme.serif(24)).foregroundStyle(Theme.ink)
                if let inst = app.backend.installer { InstallSteps(installer: inst) }
                else {
                    ProgressView().controlSize(.small)
                    Text(app.backend.log).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            case .failed(let why):
                Text("เปิด April ไม่สำเร็จ").font(Theme.serif(24)).foregroundStyle(Theme.ink)
                Text(why).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 460)
                Button("ลองใหม่") { Task { await app.backend.boot() } }.buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            case .ready:
                EmptyView()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InstallSteps: View {
    let installer: Installer

    var body: some View {
        Card {
            ForEach(Installer.Step.allCases) { s in
                HStack(spacing: 10) {
                    Group {
                        if installer.done.contains(s) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                        else if installer.step == s { ProgressView().controlSize(.small) }
                        else { Image(systemName: "circle").foregroundStyle(Theme.line) }
                    }
                    .frame(width: 18)
                    Text(s.title).font(.system(size: 13)).foregroundStyle(installer.step == s ? Theme.ink : Theme.muted)
                }
            }
            if let p = installer.progress { ProgressView(value: p).tint(Theme.accent) }
            Text(installer.detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(2)
            Text("ครั้งแรกต้องต่อเน็ต ใช้เวลา 5–20 นาที (โมเดลในเครื่อง ~3 GB)").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .frame(width: 420)
    }
}
