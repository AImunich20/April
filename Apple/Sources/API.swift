// API.swift — คุยกับเซิร์ฟเวอร์ April (http://127.0.0.1:8100)
//   call()  = เรียก /api/* ของ Control Center (แบบเดียวกับ EnvyAPI.call)
//   chat()  = POST /chat แบบ SSE (event ตาม april/agent/loop.py) — ใช้กับหน้าต่างเรียกแบบ Siri

import Foundation

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        switch self[k] {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
    func num(_ k: String) -> Double? {
        switch self[k] {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
    func bool(_ k: String) -> Bool? { self[k] as? Bool }
    func obj(_ k: String) -> JSON { self[k] as? JSON ?? [:] }
    func arr(_ k: String) -> [JSON] { self[k] as? [JSON] ?? [] }
    func strs(_ k: String) -> [String] { (self[k] as? [Any] ?? []).map { "\($0)" } }
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AprilAPI: Sendable {
    let base: URL
    var token = ""

    @discardableResult
    func call(_ method: String, _ path: String, query: [String: String] = [:], json: Any? = nil,
              timeout: TimeInterval = 30) async throws -> JSON {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        guard (200..<300).contains(code) else {
            throw APIError(message: ((obj as? JSON)?.str("detail")) ?? "HTTP \(code)")
        }
        if let o = obj as? JSON { return o }
        return ["items": obj]
    }

    /// ส่งข้อความแล้วรับ event ทีละตัวจนถึง done
    func chat(_ message: String, session: String?, model: String? = nil, voice: Bool = false) -> AsyncThrowingStream<JSON, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: JSON = ["message": message, "voice": voice]
                    if let session { body["session_id"] = session }
                    if let model, model != "auto" { body["model"] = model }
                    var req = URLRequest(url: base.appendingPathComponent("chat"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 600
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
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
