// Updater.swift — อัปเดตแอปจาก GitHub Releases ของ AImunich20/April (repo public ไม่ต้องมี token)
// ตรวจตอนเปิดแอป + ทุก 6 ชั่วโมง -> มีรุ่นใหม่ = แจ้งบนแถบ + เมนู "อัปเดตเป็น …" -> ดาวน์โหลด April-<รุ่น>.zip
// -> แทนที่แอป -> เปิดใหม่ -> Installer ซิงก์โค้ด/package แล้วเปิดเซิร์ฟเวอร์ด้วยโค้ดรุ่นใหม่ (ย่อจาก Envy)

import AppKit
import Observation

@MainActor @Observable
final class Updater {
    var latest: String?
    var notes = ""
    var working = false
    var message: String?
    private var asset: URL?

    var version: String { Installer.appVersion }
    var available: Bool { latest.map { Updater.newer($0, than: version) } ?? false && asset != nil }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func loop() async {
        try? await Task.sleep(for: .seconds(15))
        while !Task.isCancelled {
            await check()
            try? await Task.sleep(for: .seconds(6 * 3600))
        }
    }

    func check(verbose: Bool = false) async {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Backend.repoSlug)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("April/\(version)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
            if verbose { message = "ตรวจอัปเดตไม่ได้ตอนนี้" }
            return
        }
        latest = (r.str("tag_name") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        notes = r.str("body") ?? ""
        asset = r.arr("assets").first { ($0.str("name") ?? "").hasSuffix(".zip") }
            .flatMap { $0.str("browser_download_url") }.flatMap(URL.init(string:))
        if available { message = "มี April \(latest ?? "") ใหม่ (ตอนนี้ \(version))" }
        else if verbose { message = "เป็นรุ่นล่าสุดแล้ว (\(version))" }
    }

    func apply() async {
        guard let asset, let latest, !working else { return }
        working = true
        defer { working = false }
        message = "กำลังดาวน์โหลด April \(latest)…"
        do {
            let zip = try await Downloader.fetch(URLRequest(url: asset)) { _, _ in }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("april-update-\(latest)")
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            guard await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, tmp.path]).ok else {
                throw Installer.Failure(message: "แตกไฟล์อัปเดตไม่ได้")
            }
            let newApp = tmp.appendingPathComponent("April.app")
            let got = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
            guard got == latest else { throw Installer.Failure(message: "ไฟล์อัปเดตไม่ตรงรุ่น (\(got ?? "?"))") }
            await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            let app = Bundle.main.bundlePath
            let r = await Shell.run("/bin/bash", ["-c", "rm -rf \"$1.new\" && ditto \"$0\" \"$1.new\" && rm -rf \"$1\" && mv \"$1.new\" \"$1\"",
                                                  newApp.path, app])
            guard r.ok else { throw Installer.Failure(message: "แทนที่แอปไม่ได้ — ลากแอปจาก dmg รุ่นใหม่ไปทับเองได้") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app]
            try? p.run()
            NSApp.terminate(nil)
        } catch {
            message = "อัปเดตไม่สำเร็จ: \(error.localizedDescription)"
        }
    }
}
