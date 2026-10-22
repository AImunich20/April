// Installer.swift — ติดตั้ง April บน Mac เครื่องใหม่จากโค้ดที่อยู่ในแอป (ไม่ต้อง clone / Homebrew / รหัสผ่านเครื่อง)
// พอร์ตจาก Envy — ที่ติดตั้ง: ~/Library/Application Support/April
//   1) โค้ด     คัดลอกจาก April.app/Contents/Resources/April (ไม่แตะ data/ .venv/ tools/ และ .env ของผู้ใช้)
//   2) uv       ตัวจัดการ Python (มีแล้วใช้เลย ไม่มี = ดาวน์โหลดจาก GitHub ของ astral-sh/uv)
//   3) Python   Python 3.12 + .venv ของ April เอง
//   4) package  uv pip install -r requirements.txt
//   5) Ollama   มีแล้วใช้เลย ไม่มี = ดาวน์โหลด Ollama.app ทางการไปไว้ ~/Applications
//   6) โมเดล    โมเดลในเครื่องตัวเดียวของ April (APRIL_LOCAL_MODEL ใน .env หรือ qwen3.5:4b)
// ทุกขั้นตรวจก่อนว่าทำแล้วหรือยัง -> ล้มกลางทาง (เน็ตหลุด) กดลองใหม่ทำต่อจากที่ค้างได้
// เสร็จแล้วเขียน .april-installed = เวอร์ชันแอป -> แอปรุ่นใหม่เปิดครั้งแรกจะซิงก์โค้ด + package ให้เอง

import Foundation
import Observation

@MainActor @Observable
final class Installer {
    enum Step: Int, CaseIterable, Identifiable {
        case code, uv, python, packages, ollama, model
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .code: "คัดลอกโค้ด April"
            case .uv: "ตัวจัดการ Python (uv)"
            case .python: "Python 3.12"
            case .packages: "package ของ April"
            case .ollama: "Ollama (ตัวรันโมเดลในเครื่อง)"
            case .model: "โมเดล AI ในเครื่อง"
            }
        }
    }

    var step: Step?
    var done: Set<Step> = []
    var progress: Double?
    var detail = ""

    let root: URL
    private var tools: URL { root.appendingPathComponent("tools") }
    private var python: URL { root.appendingPathComponent(".venv/bin/python") }
    nonisolated static let ollamaURL = URL(string: "http://127.0.0.1:11434")!

    init(root: URL) { self.root = root }

    nonisolated static var bundledCode: URL? {
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("April"),
              FileManager.default.fileExists(atPath: u.appendingPathComponent("april/__init__.py").path) else { return nil }
        return u
    }

    nonisolated static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    nonisolated static func installedVersion(_ root: URL) -> String? {
        (try? String(contentsOf: root.appendingPathComponent(".april-installed"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func needed(_ root: URL) -> Bool {
        bundledCode != nil && installedVersion(root) != appVersion
    }

    private var onLine: @Sendable (String) -> Void { { [weak self] s in Task { @MainActor in self?.detail = s } } }
    private func begin(_ s: Step) { step = s; progress = nil; detail = "" }
    private func finish(_ s: Step) { done.insert(s); progress = nil }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func run() async throws {
        try await syncCode()
        try await ensureUV()
        try await ensurePython()
        try await installPackages()
        try await ensureOllama()
        try await ensureModel()
        try Installer.appVersion.write(to: root.appendingPathComponent(".april-installed"), atomically: true, encoding: .utf8)
        step = nil
    }

    // 1) โค้ด — rsync ทับของเดิม ลบไฟล์ที่รุ่นใหม่ไม่มีแล้ว แต่ไม่แตะข้อมูลของผู้ใช้
    func syncCode() async throws {
        begin(.code)
        guard let src = Installer.bundledCode else { throw Failure(message: "ไม่พบโค้ด April ในแอป") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keep = ["/.venv/", "/tools/", "/data/", "/.env", "/.april-installed", "__pycache__/", ".DS_Store"]
        let r = await Shell.run("/usr/bin/rsync", ["-a", "--delete"] + keep.flatMap { ["--exclude", $0] }
                                + [src.path + "/", root.path + "/"], onLine: onLine)
        guard r.ok else { throw Failure(message: "คัดลอกโค้ดไม่สำเร็จ: \(r.output.suffix(300))") }
        let env = root.appendingPathComponent(".env"), example = root.appendingPathComponent(".env.example")
        if !FileManager.default.fileExists(atPath: env.path), FileManager.default.fileExists(atPath: example.path) {
            try? FileManager.default.copyItem(at: example, to: env)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.path)   // มี API key
        finish(.code)
    }

    // 2) uv
    private var uvPath: String? {
        let home = NSHomeDirectory()
        return [tools.appendingPathComponent("bin/uv").path, "\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func ensureUV() async throws {
        begin(.uv)
        if uvPath == nil {
            let name = "uv-\(Shell.arch == "arm64" ? "aarch64" : "x86_64")-apple-darwin"
            let tgz = try await download(URL(string: "https://github.com/astral-sh/uv/releases/latest/download/\(name).tar.gz")!,
                                         label: "ดาวน์โหลด uv")
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("april-uv")
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            guard await Shell.run("/usr/bin/tar", ["-xzf", tgz.path, "-C", tmp.path]).ok else {
                throw Failure(message: "แตกไฟล์ uv ไม่ได้")
            }
            let bin = tools.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for exe in ["uv", "uvx"] {
                let dst = bin.appendingPathComponent(exe)
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.moveItem(at: tmp.appendingPathComponent("\(name)/\(exe)"), to: dst)
            }
            guard uvPath != nil else { throw Failure(message: "ติดตั้ง uv ไม่สำเร็จ") }
        }
        finish(.uv)
    }

    // 3) Python + .venv
    private var uvEnv: [String: String] {
        ["UV_PYTHON_INSTALL_DIR": tools.appendingPathComponent("python").path,
         "UV_CACHE_DIR": tools.appendingPathComponent("cache").path, "UV_NO_PROGRESS": "1"]
    }

    private func pythonOK() async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        return await Shell.run(python.path, ["-c", "import sys; sys.exit(0 if sys.version_info[:2] >= (3, 11) else 1)"]).ok
    }

    func ensurePython() async throws {
        begin(.python)
        if await !pythonOK() {
            guard let uv = uvPath else { throw Failure(message: "ไม่มี uv") }
            detail = "กำลังติดตั้ง Python 3.12 (ครั้งแรก ~30 MB)…"
            let r = await Shell.run(uv, ["venv", "--clear", "--python", "3.12", root.appendingPathComponent(".venv").path],
                                    in: root, env: uvEnv, onLine: onLine)
            guard r.ok, await pythonOK() else { throw Failure(message: "ติดตั้ง Python ไม่สำเร็จ: \(r.output.suffix(300))") }
        }
        finish(.python)
    }

    // 4) package
    func installPackages() async throws {
        begin(.packages)
        guard let uv = uvPath else { throw Failure(message: "ไม่มี uv") }
        detail = "กำลังติดตั้ง package (ครั้งแรก 1–3 นาที)…"
        let r = await Shell.run(uv, ["pip", "install", "--python", python.path, "-r", "requirements.txt"],
                                in: root, env: uvEnv, onLine: onLine)
        guard r.ok else { throw Failure(message: "ติดตั้ง package ไม่สำเร็จ: \(r.output.suffix(400))") }
        let check = await Shell.run(python.path, ["-c", "import april.server"], in: root)
        guard check.ok else { throw Failure(message: "เปิดโค้ด April ไม่ผ่าน: \(check.output.suffix(300))") }
        finish(.packages)
    }

    // 5) Ollama
    nonisolated static var ollamaBinary: String? {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "\(home)/.local/bin/ollama",
                "\(home)/Applications/Ollama.app/Contents/Resources/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func ollamaUp() async -> Bool {
        var req = URLRequest(url: ollamaURL.appendingPathComponent("api/version"))
        req.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: req)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    /// เปิด ollama serve แยกจากแอป (ปิดแอปแล้วยังรัน) — มีอยู่แล้ว/ไม่มี Ollama = ไม่ทำอะไร
    @discardableResult
    nonisolated static func startOllama(logDir: URL, runDir: URL) async -> Bool {
        if await ollamaUp() { return true }
        guard let bin = ollamaBinary else { return false }
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        await Shell.run("/bin/bash", ["-c", "nohup \"$0\" serve >> \"$1\" 2>&1 & echo $! > \"$2\"", bin,
                                      logDir.appendingPathComponent("ollama.log").path, runDir.appendingPathComponent("ollama.pid").path])
        for _ in 0..<40 {
            if await ollamaUp() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    func ensureOllama() async throws {
        begin(.ollama)
        if Installer.ollamaBinary == nil {
            let zip = try await download(URL(string: "https://ollama.com/download/Ollama-darwin.zip")!, label: "ดาวน์โหลด Ollama")
            let apps = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
            try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
            detail = "กำลังแตกไฟล์ Ollama…"
            guard await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, apps.path]).ok, Installer.ollamaBinary != nil else {
                throw Failure(message: "ติดตั้ง Ollama ไม่สำเร็จ")
            }
        }
        detail = "กำลังเปิด Ollama…"
        guard await Installer.startOllama(logDir: root.appendingPathComponent("data/logs"),
                                          runDir: root.appendingPathComponent("data/run")) else {
            throw Failure(message: "เปิด Ollama ไม่สำเร็จ — ดู data/logs/ollama.log")
        }
        finish(.ollama)
    }

    // 6) โมเดลในเครื่อง
    var localModel: String {
        let env = (try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)) ?? ""
        for line in env.split(separator: "\n") where line.hasPrefix("APRIL_LOCAL_MODEL=") {
            let v = line.dropFirst("APRIL_LOCAL_MODEL=".count).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        return "qwen3.5:4b"
    }

    func ensureModel() async throws {
        begin(.model)
        let model = localModel
        var have: Set<String> = []
        if let (data, _) = try? await URLSession.shared.data(from: Installer.ollamaURL.appendingPathComponent("api/tags")),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for m in obj["models"] as? [[String: Any]] ?? [] {
                if let n = m["name"] as? String { have.insert(n); have.insert(n.replacingOccurrences(of: ":latest", with: "")) }
            }
        }
        if !have.contains(model) { try await pull(model) }
        finish(.model)
    }

    private func pull(_ model: String) async throws {
        var req = URLRequest(url: Installer.ollamaURL.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        var lastError: String?
        for try await raw in bytes.lines {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { continue }
            if let e = o["error"] as? String { lastError = e; break }
            let total = (o["total"] as? NSNumber)?.doubleValue ?? 0, got = (o["completed"] as? NSNumber)?.doubleValue ?? 0
            if total > 0 {
                progress = got / total
                detail = "ดาวน์โหลด \(model) · \(Installer.size(got)) / \(Installer.size(total))"
            } else {
                detail = "ดาวน์โหลด \(model) · \(o["status"] as? String ?? "")"
            }
            if o["status"] as? String == "success" { return }
        }
        throw Failure(message: "ดาวน์โหลด \(model) ไม่สำเร็จ: \(lastError ?? "การเชื่อมต่อหลุด")")
    }

    private func download(_ url: URL, label: String) async throws -> URL {
        detail = label
        return try await Downloader.fetch(URLRequest(url: url)) { [weak self] got, total in
            Task { @MainActor in
                guard let self, total > 0 else { return }
                self.progress = got / total
                self.detail = "\(label) · \(Installer.size(got)) / \(Installer.size(total))"
            }
        }
    }

    nonisolated static func size(_ b: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }
}

/// ดาวน์โหลดไฟล์ใหญ่ลงดิสก์ พร้อมรายงานความคืบหน้า (Installer: uv/Ollama · Updater: แอปรุ่นใหม่)
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double, Double) -> Void
    private var cont: CheckedContinuation<URL, Error>?
    private var name = "download"

    private init(onProgress: @escaping @Sendable (Double, Double) -> Void) { self.onProgress = onProgress }

    static func fetch(_ request: URLRequest, onProgress: @escaping @Sendable (Double, Double) -> Void) async throws -> URL {
        let d = Downloader(onProgress: onProgress)
        d.name = request.url?.lastPathComponent ?? "download"
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            d.cont = c
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(Double(totalBytesWritten), Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            cont?.resume(throwing: Installer.Failure(message: "ดาวน์โหลด \(name) ไม่สำเร็จ (HTTP \(code))")); cont = nil; return
        }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        do { try FileManager.default.moveItem(at: location, to: dst); cont?.resume(returning: dst) }
        catch { cont?.resume(throwing: error) }
        cont = nil
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { cont?.resume(throwing: error); cont = nil }
    }
}
