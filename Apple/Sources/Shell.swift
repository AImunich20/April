// Shell.swift — รันคำสั่งแบบ async พร้อมส่ง output ทีละบรรทัด (พอร์ตจาก Envy)

import Foundation

struct ShellResult {
    let code: Int32
    let output: String
    var ok: Bool { code == 0 }
}

enum Shell {
    /// GUI app ได้ PATH สั้นมาก — ใส่ที่ที่ uv / ollama / lsof อยู่ให้หาเจอ
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let tools = Backend.supportRoot.appendingPathComponent("tools/bin").path
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", tools,
                       "\(home)/Applications/Ollama.app/Contents/Resources", "/Applications/Ollama.app/Contents/Resources",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin", env["PATH"] ?? ""].joined(separator: ":")
        return env
    }

    /// สถาปัตยกรรมของเครื่องจริง (Rosetta รายงาน x86_64 ทั้งที่เป็น Apple Silicon)
    static var arch: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        var translated: Int32 = 0, len = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &len, nil, 0) == 0, translated == 1 { return "arm64" }
        return String(cString: buf)
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String], in dir: URL? = nil, env extra: [String: String] = [:],
                    onLine: (@Sendable (String) -> Void)? = nil) async -> ShellResult {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe.hasPrefix("/") ? exe : "/usr/bin/env")
            p.arguments = exe.hasPrefix("/") ? args : [exe] + args
            if let dir { p.currentDirectoryURL = dir }
            p.environment = environment.merging(extra) { $1 }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            let buffer = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                buffer.append(s)
                s.split(whereSeparator: \.isNewline).forEach { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { onLine?(t) }
                }
            }
            // process ลูกที่แยกตัวออกไป (nohup … &) ไม่ต้องรอ — รอแค่คำสั่งนี้จบ
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: ShellResult(code: proc.terminationStatus, output: buffer.text))
            }
            do { try p.run() } catch {
                cont.resume(returning: ShellResult(code: 127, output: error.localizedDescription))
            }
        }
    }
}

final class OutputBuffer: @unchecked Sendable {
    private var s = ""
    private let lock = NSLock()
    func append(_ t: String) { lock.lock(); s += t; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return s }
}
