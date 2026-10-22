// Backend.swift — หาโฟลเดอร์ของ April, ติดตั้ง (ครั้งแรก/หลังอัปเดตแอป), เปิด/หยุด Ollama + เซิร์ฟเวอร์ April, ติดตาม /health
//
// โฟลเดอร์ (ที่มี april/__init__.py) หาตามลำดับ:
//   1) AprilRoot ใน Info.plist — เครื่องนักพัฒนาที่ build แอป (ใช้ .venv ของโปรเจกต์)
//   2) ~/Library/Application Support/April — ติดตั้งจากโค้ดที่อยู่ในแอป (Installer.swift) เครื่องใหม่ใช้ทางนี้
// เซิร์ฟเวอร์รันแยกจากแอป (nohup) -> ปิดแอปแล้วตัวเตือน/สรุปประจำวันยังทำงาน · ⌥⌘Q = หยุดแล้วออก

import Foundation
import Observation

enum Phase: Equatable {
    case working(String)
    case ready
    case failed(String)
}

@MainActor @Observable
final class Backend {
    var phase: Phase = .working("กำลังเปิด April…")
    var log = ""
    var online = false
    private(set) var root: URL?
    var installer: Installer?
    let port = 8100

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    /// APRIL_API_TOKEN ใน .env (ตั้งเมื่อเปิดให้เครื่องอื่นเรียก) — ทุกคำขอของแอปแนบให้เอง
    var token: String { envFile.flatMap { EnvFile(url: $0).read()["APRIL_API_TOKEN"] } ?? "" }
    var api: AprilAPI { AprilAPI(base: baseURL, token: token) }

    func authorize(_ req: inout URLRequest) {
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    nonisolated static func isProject(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("april/__init__.py").path)
    }

    nonisolated static var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("April")
    }

    nonisolated static var repoSlug: String {
        let u = (Bundle.main.object(forInfoDictionaryKey: "AprilRepo") as? String ?? "https://github.com/AImunich20/April.git")
            .replacingOccurrences(of: ".git", with: "")
        return u.split(whereSeparator: { $0 == "/" || $0 == ":" }).suffix(2).joined(separator: "/")
    }

    @discardableResult
    func resolveRoot() -> URL? {
        var candidates: [String] = []
        if let s = Bundle.main.object(forInfoDictionaryKey: "AprilRoot") as? String, !s.isEmpty, !s.hasPrefix("__") {
            candidates.append(s)
        }
        candidates.append(Backend.supportRoot.path)
        root = candidates.map { URL(fileURLWithPath: $0) }.first(where: Backend.isProject)
        return root
    }

    var isAppInstall: Bool { root?.standardized.path == Backend.supportRoot.standardized.path }
    var envFile: URL? { root?.appendingPathComponent(".env") }
    private var python: URL? { root?.appendingPathComponent(".venv/bin/python") }

    private var sayLine: @Sendable (String) -> Void {
        { [weak self] line in Task { @MainActor in self?.log = line } }
    }

    // ---- health
    func healthy() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8100/health")!)
        req.timeoutInterval = 2
        authorize(&req)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func serverVersion() async -> String? {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        authorize(&req)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return nil }
        return o.str("version")
    }

    func waitHealthy(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await healthy() { return true }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    func monitor() async {
        while !Task.isCancelled {
            online = await healthy()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    // ---- เปิดระบบ: (ติดตั้ง) -> Ollama -> เซิร์ฟเวอร์ April
    func boot() async {
        phase = .working("กำลังเปิด April…")
        let up = await healthy()
        resolveRoot()
        let target = root ?? (Installer.bundledCode != nil ? Backend.supportRoot : nil)
        guard let target else {
            phase = .failed("ไม่พบโค้ดของ April — ดาวน์โหลดแอปรุ่นเต็มจาก GitHub Releases")
            return
        }
        if target.standardized.path == Backend.supportRoot.standardized.path, Installer.needed(target) {
            let inst = Installer(root: target)
            installer = inst
            phase = .working(Installer.installedVersion(target) == nil ? "ติดตั้ง April ครั้งแรก" : "อัปเดต April เป็น \(Installer.appVersion)")
            do { try await inst.run() } catch { phase = .failed(error.localizedDescription); return }
            installer = nil
            root = target
            if up { await stop() }        // เซิร์ฟเวอร์รุ่นเก่ายังรันอยู่ -> เปิดใหม่ด้วยโค้ดรุ่นนี้
        } else if up {
            // เซิร์ฟเวอร์ที่รันค้างอยู่เป็นโค้ดรุ่นเก่า (เพิ่งอัปเดตแอป) -> เริ่มใหม่ให้ตรงรุ่น ไม่งั้นศูนย์ควบคุมเรียก API ใหม่ไม่ได้
            if let v = await serverVersion(), v != Installer.appVersion {
                log = "เซิร์ฟเวอร์เป็นรุ่น \(v) — เริ่มใหม่เป็นรุ่น \(Installer.appVersion)"
                await stop()
                await start()
                return
            }
            online = true
            phase = .ready
            return
        }
        await start()
    }

    func start() async {
        guard let root, let python, FileManager.default.isExecutableFile(atPath: python.path) else {
            phase = .failed("ไม่พบ Python ของ April (.venv) — ลองติดตั้งใหม่")
            return
        }
        phase = .working("กำลังเปิด Ollama…")
        await Installer.startOllama(logDir: root.appendingPathComponent("data/logs"), runDir: root.appendingPathComponent("data/run"))
        phase = .working("กำลังเปิด April…")
        let logs = root.appendingPathComponent("data/logs"), run = root.appendingPathComponent("data/run")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        await Shell.run("/bin/bash", ["-c", "nohup \"$0\" -m april serve >> \"$1\" 2>&1 & echo $! > \"$2\"",
                                      python.path, logs.appendingPathComponent("server.log").path,
                                      run.appendingPathComponent("april.pid").path],
                        in: root, env: ["APRIL_PORT": String(port)], onLine: sayLine)
        if await waitHealthy(seconds: 40) { online = true; phase = .ready }
        else { phase = .failed("เปิด April ไม่สำเร็จ — ดู data/logs/server.log") }
    }

    func stop() async {
        guard let root = root ?? resolveRoot() else { return }
        let pidFile = root.appendingPathComponent("data/run/april.pid")
        if let pid = (try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pid.isEmpty {
            await Shell.run("/bin/kill", [pid])
            try? FileManager.default.removeItem(at: pidFile)
        } else {
            // เปิดจากที่อื่น (python -m april serve ในเทอร์มินัล) -> หยุดตามพอร์ต
            await Shell.run("/bin/bash", ["-c", "lsof -ti tcp:8100 -sTCP:LISTEN | xargs kill 2>/dev/null; true"])
        }
        for _ in 0..<20 where await healthy() { try? await Task.sleep(for: .milliseconds(250)) }
        online = false
    }

    func restart() async {
        phase = .working("กำลังเริ่ม April ใหม่…")
        await stop()
        await start()
    }
}
