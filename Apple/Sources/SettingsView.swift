// SettingsView.swift — ตั้งค่า April (⌘,): ชื่อเจ้านาย, คีย์ cloud, โมเดลในเครื่อง, สรุปประจำวัน, ความจำ
// ค่าเก็บในไฟล์ .env ของ April (chmod 600) — บันทึกแล้วเริ่มเซิร์ฟเวอร์ใหม่ให้ค่ามีผล

import SwiftUI

/// อ่าน/เขียน .env แบบคงบรรทัดอื่นและคอมเมนต์ไว้
struct EnvFile {
    let url: URL

    func read() -> [String: String] {
        var out: [String: String] = [:]
        for line in ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
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

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @ViewState private var values: [String: String] = [:]
    @ViewState private var saved = false
    @ViewState private var error: String?
    @ViewState private var notes: [JSON] = []

    private static let fields: [(String, String, Bool)] = [
        ("APRIL_OWNER_NAME", "ชื่อที่ให้ April เรียก (ว่าง = บอส)", false),
        ("APRIL_LOCAL_MODEL", "โมเดลในเครื่อง (Ollama)", false),
        ("ANTHROPIC_API_KEY", "Claude API key", true),
        ("OLLAMA_API_KEY", "Ollama Cloud API key", true),
        ("OPENAI_API_KEY", "OpenAI API key", true),
        ("APRIL_OPENAI_MODEL", "ชื่อโมเดล OpenAI", false),
        ("GEMINI_API_KEY", "Gemini API key", true),
        ("APRIL_GEMINI_MODEL", "ชื่อโมเดล Gemini", false),
        ("APRIL_BRIEFING_TIME", "สรุปประจำวันเวลา (เช่น 07:30 · ว่าง = ปิด)", false),
    ]

    var body: some View {
        TabView {
            Form {
                Section("April") {
                    ForEach(Self.fields.prefix(2), id: \.0) { field($0) }
                    Toggle("ให้ April สั่งงานเครื่องได้ (เปิดแอป/เว็บ/แจ้งเตือน)", isOn: Binding(
                        get: { values["APRIL_ALLOW_ACTIONS"] != "false" },
                        set: { values["APRIL_ALLOW_ACTIONS"] = $0 ? "true" : "false" }))
                    field(Self.fields[8])
                }
                Section("โมเดล cloud (ไม่ใส่ = ใช้โมเดลในเครื่องอย่างเดียว)") {
                    ForEach(Self.fields[2..<8], id: \.0) { field($0) }
                }
                HStack {
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                    else if saved { Text("บันทึกแล้ว — เริ่ม April ใหม่ให้แล้ว").foregroundStyle(.green).font(.caption) }
                    Spacer()
                    Button("บันทึก") { save() }.keyboardShortcut(.defaultAction)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("ทั่วไป", systemImage: "gearshape") }

            List {
                if notes.isEmpty { Text("ยังไม่มีความจำ — บอก April เรื่องของคุณได้เลย เช่น \"จำไว้ว่าผมแพ้กุ้ง\"").foregroundStyle(.secondary) }
                ForEach(notes.indices, id: \.self) { i in
                    HStack {
                        Text(notes[i].str("text") ?? "")
                        Spacer()
                        Button(role: .destructive) {
                            let id = Int(notes[i].num("id") ?? 0)
                            Task { try? await app.chat.api.deleteNote(id); notes = (try? await app.chat.api.notes()) ?? [] }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            .tabItem { Label("ความจำ", systemImage: "brain") }
            .task { notes = (try? await app.chat.api.notes()) ?? [] }
        }
        .frame(width: 560, height: 560)
        .onAppear { if let url = app.backend.envFile { values = EnvFile(url: url).read() } }
    }

    @ViewBuilder
    private func field(_ f: (String, String, Bool)) -> some View {
        let binding = Binding(get: { values[f.0] ?? "" }, set: { values[f.0] = $0; saved = false })
        if f.2 { SecureField(f.1, text: binding) } else { TextField(f.1, text: binding) }
    }

    private func save() {
        guard let url = app.backend.envFile else { error = "ไม่พบโฟลเดอร์ของ April"; return }
        if let t = values["APRIL_BRIEFING_TIME"], !t.isEmpty, t.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) == nil {
            error = "เวลาสรุปประจำวันต้องเป็นแบบ 07:30"
            return
        }
        do {
            try EnvFile(url: url).write(values)
            error = nil
            saved = true
            Task {
                await app.backend.restart()
                await app.chat.refresh()
            }
        } catch {
            self.error = "บันทึกไม่ได้: \(error.localizedDescription)"
        }
    }
}
