// ChatModel.swift — สถานะของหน้าแชท: รายการบทสนทนา, ข้อความ, การ stream คำตอบ, ประกาศจาก April (ตัวเตือน/สรุปประจำวัน)

import Foundation
import Observation

struct ToolChip: Identifiable, Hashable {
    let id: String
    let name: String
    var ok: Bool?           // nil = กำลังทำ
    var preview = ""
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let me: Bool
    var text: String
    var tools: [ToolChip] = []
    var thinking = false
    var model: String?
    var error: String?
}

@MainActor @Observable
final class ChatModel {
    var sessions: [SessionInfo] = []
    var current: String?
    var messages: [ChatMessage] = []
    var input = ""
    var busy = false
    var models: [ModelInfo] = []
    var model: String { didSet { UserDefaults.standard.set(model, forKey: "AprilModel") } }
    var banner: String?            // ประกาศล่าสุดจาก April / ข้อผิดพลาด
    var notice: String?            // สลับโมเดลสำรอง ฯลฯ

    let backend: Backend
    var api: AprilAPI { AprilAPI(base: backend.baseURL) }
    private var streamTask: Task<Void, Never>?

    init(backend: Backend) {
        self.backend = backend
        model = UserDefaults.standard.string(forKey: "AprilModel") ?? "auto"
    }

    static let toolLabels = [
        "current_datetime": "ดูเวลา", "calculate": "คำนวณ", "web_search": "ค้นเว็บ", "read_webpage": "อ่านหน้าเว็บ",
        "remember": "จดความจำ", "recall": "ค้นความจำ", "forget": "ลบความจำ", "set_reminder": "ตั้งเตือน",
        "list_reminders": "ดูตัวเตือน", "cancel_reminder": "ยกเลิกเตือน", "system_status": "เช็กเครื่อง",
        "open_app": "เปิดแอป", "open_url": "เปิดเว็บ", "notify": "แจ้งเตือน",
    ]

    func refresh() async {
        if let (def, list) = try? await api.models() {
            models = list
            if model != "auto", !list.contains(where: { $0.id == model }) { model = def }
        }
        sessions = (try? await api.sessions()) ?? sessions
    }

    func newChat() {
        stop()
        current = nil
        messages = []
    }

    func open(_ session: SessionInfo) async {
        stop()
        current = session.id
        guard let raw = try? await api.messages(session.id) else { messages = []; return }
        var out: [ChatMessage] = []
        for m in raw {
            switch m.str("role") {
            case "user":
                // ข้อความระบบ (สรุปเมื่อใช้เครื่องมือครบรอบ) ไม่มี text -> ไม่แสดง
                if let t = m.str("text") { out.append(ChatMessage(me: true, text: t)) }
            case "assistant":
                let calls = m.arr("tool_calls").map {
                    ToolChip(id: $0.str("id") ?? UUID().uuidString, name: $0.str("name") ?? "", ok: true)
                }
                let text = m.str("content") ?? ""
                if let last = out.last, !last.me { out[out.count - 1].tools += calls; if !text.isEmpty { out[out.count - 1].text = text } }
                else { out.append(ChatMessage(me: false, text: text, tools: calls)) }
            case "tool":
                if !out.isEmpty, let i = out[out.count - 1].tools.firstIndex(where: { $0.id == m.str("tool_call_id") }) {
                    out[out.count - 1].tools[i].ok = !(m.bool("is_error") ?? false)
                    out[out.count - 1].tools[i].preview = String((m.str("content") ?? "").prefix(200))
                }
            default: break
            }
        }
        messages = out
    }

    func delete(_ session: SessionInfo) async {
        try? await api.deleteSession(session.id)
        if current == session.id { newChat() }
        await refresh()
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        input = ""
        ask(text)
    }

    func ask(_ text: String) {
        messages.append(ChatMessage(me: true, text: text))
        messages.append(ChatMessage(me: false, text: ""))
        busy = true
        notice = nil
        let api = api, session = current, model = model
        streamTask = Task {
            do {
                for try await ev in api.chat(text, session: session, model: model) {
                    apply(ev)
                }
            } catch {
                if !Task.isCancelled { updateLast { $0.error = error.localizedDescription } }
            }
            busy = false
            sessions = (try? await api.sessions()) ?? sessions
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        busy = false
    }

    private func updateLast(_ change: (inout ChatMessage) -> Void) {
        guard let i = messages.indices.last, !messages[i].me else { return }
        change(&messages[i])
    }

    private func apply(_ ev: JSON) {
        switch ev.str("type") {
        case "session": current = ev.str("session_id")
        case "thinking": updateLast { $0.thinking = true }
        case "token": updateLast { $0.text += ev.str("text") ?? ""; $0.thinking = false }
        case "model": updateLast { $0.model = ev.str("model") }
        case "tool_call":
            updateLast { $0.tools.append(ToolChip(id: ev.str("id") ?? UUID().uuidString, name: ev.str("name") ?? "")) }
        case "tool_result":
            updateLast { m in
                if let i = m.tools.firstIndex(where: { $0.id == ev.str("id") }) {
                    m.tools[i].ok = ev.bool("ok")
                    m.tools[i].preview = ev.str("preview") ?? ""
                }
            }
        case "fallback": notice = "\(ev.str("from") ?? "") ใช้ไม่ได้ — สลับไป \(ev.str("to") ?? "")"
        case "revision": updateLast { $0.text = "" }
        case "error": updateLast { $0.error = ev.str("message") }
        case "done":
            updateLast { m in
                if let t = ev.str("text"), !t.isEmpty { m.text = t }
                m.thinking = false
            }
        default: break
        }
    }

    /// ประกาศที่ April แจ้งเอง (เตือนความจำ / สรุปประจำวัน) — ตรวจทุก 20 วิ
    func watchAnnouncements() async {
        while !Task.isCancelled {
            if backend.online, let items = try? await api.announcements(unread: true), let first = items.first {
                banner = "🔔 \(first.str("title") ?? ""): \(first.str("text") ?? "")"
                try? await api.markRead()
            }
            try? await Task.sleep(for: .seconds(20))
        }
    }
}
