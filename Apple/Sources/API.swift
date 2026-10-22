// API.swift — คุยกับเซิร์ฟเวอร์ April (http://127.0.0.1:8100) · /chat เป็น SSE (event ตาม april/agent/loop.py)

import Foundation

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func num(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func bool(_ k: String) -> Bool? { self[k] as? Bool }
    func arr(_ k: String) -> [JSON] { self[k] as? [JSON] ?? [] }
    func obj(_ k: String) -> JSON { self[k] as? JSON ?? [:] }
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ModelInfo: Identifiable, Hashable {
    let id: String
    let label: String
    let local: Bool
    let ready: Bool
}

struct SessionInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let updated: Date
}

struct AprilAPI: Sendable {
    let base: URL

    private func request(_ path: String, method: String = "GET", body: Any? = nil, timeout: TimeInterval = 30) throws -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func call(_ path: String, method: String = "GET", body: Any? = nil, timeout: TimeInterval = 30) async throws -> Any {
        let (data, resp) = try await URLSession.shared.data(for: try request(path, method: method, body: body, timeout: timeout))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        guard (200..<300).contains(code) else {
            throw APIError(message: ((obj as? JSON)?.str("detail")) ?? "HTTP \(code)")
        }
        return obj
    }

    func models() async throws -> (String, [ModelInfo]) {
        let o = try await call("models") as? JSON ?? [:]
        let list = o.arr("models").map {
            ModelInfo(id: $0.str("id") ?? "", label: $0.str("label") ?? "", local: $0.bool("local") ?? false, ready: $0.bool("ready") ?? false)
        }
        return (o.str("default") ?? "auto", list)
    }

    func sessions() async throws -> [SessionInfo] {
        (try await call("sessions") as? [JSON] ?? []).map {
            SessionInfo(id: $0.str("id") ?? "", title: $0.str("title") ?? "", updated: Date(timeIntervalSince1970: $0.num("updated") ?? 0))
        }
    }

    func messages(_ session: String) async throws -> [JSON] { try await call("sessions/\(session)") as? [JSON] ?? [] }
    func deleteSession(_ session: String) async throws { _ = try await call("sessions/\(session)", method: "DELETE") }
    func announcements(unread: Bool) async throws -> [JSON] {
        try await call("announcements" + (unread ? "?unread=true" : "")) as? [JSON] ?? []
    }
    func markRead() async throws { _ = try await call("announcements/read", method: "POST") }
    func notes() async throws -> [JSON] { try await call("notes") as? [JSON] ?? [] }
    func deleteNote(_ id: Int) async throws { _ = try await call("notes/\(id)", method: "DELETE") }
    func reminders() async throws -> [JSON] { try await call("reminders") as? [JSON] ?? [] }
    func briefing() async throws -> String { (try await call("briefing", method: "POST", timeout: 300) as? JSON)?.str("text") ?? "" }

    /// ส่งข้อความแล้วรับ event ทีละตัวจนถึง done
    func chat(_ message: String, session: String?, model: String?, voice: Bool = false) -> AsyncThrowingStream<JSON, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: JSON = ["message": message, "voice": voice]
                    if let session { body["session_id"] = session }
                    if let model, model != "auto" { body["model"] = model }
                    let req = try request("chat", method: "POST", body: body, timeout: 600)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200 else { throw APIError(message: "ส่งไม่สำเร็จ (HTTP \(code))") }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let ev = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? JSON {
                            continuation.yield(ev)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
