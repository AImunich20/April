// Updater.swift — อัปเดตแอปจาก GitHub Releases ของ AImunich20/April (repo public ไม่ต้องมี token)
//
// ตรวจตอนเปิดแอป + ทุกชั่วโมง -> ติดตั้งเองตามโหมดที่ผู้ใช้เลือก (UpdatePolicy.swift) ตอนที่ April ไม่ได้กำลังตอบอยู่
// ผู้ใช้เลือกติดตั้ง/ย้อนรุ่นใดก็ได้ในหน้า ตั้งค่า › อัปเดต
// ติดตั้ง: ดาวน์โหลด April-<รุ่น>.zip -> ตรวจเลขรุ่นใน Info.plist -> แทนที่แอป -> เปิดใหม่
//   -> Installer เห็นเลขรุ่นไม่ตรงกับที่ติดตั้งไว้ -> ซิงก์โค้ด/package (ทั้งขึ้นและย้อนรุ่น) แล้วเปิดเซิร์ฟเวอร์ใหม่
// ข้อมูลผู้ใช้ (data/, .env) ไม่ถูกแตะทั้งตอนอัปเดตและย้อนรุ่น

import AppKit
import Observation

@MainActor @Observable
final class Updater {
    private(set) var releases: [Release] = []
    private(set) var working = false
    private(set) var progress: Double?
    private(set) var lastCheck: Date?
    var message: String?

    var mode: AutoUpdateMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "AprilUpdateMode") } }
    var beta: Bool { didSet { UserDefaults.standard.set(beta, forKey: "AprilUpdateBeta") } }
    var skipped: Set<String> { didSet { UserDefaults.standard.set(Array(skipped), forKey: "AprilUpdateSkipped") } }
    /// ตรึงรุ่น (ย้อนรุ่นเองหรือกด "อยู่รุ่นนี้") — อัปเดตอัตโนมัติหยุดจนกว่าจะเลิกตรึง
    var pinned: Bool { didSet { UserDefaults.standard.set(pinned, forKey: "AprilUpdatePinned") } }

    @ObservationIgnored var canApply: () -> Bool = { true }

    var version: String { Installer.appVersion }
    var visible: [Release] { UpdatePolicy.visible(releases, current: version, beta: beta) }
    var newest: Release? { UpdatePolicy.newest(releases, current: version, beta: beta, skipped: skipped) }
    var available: Bool { newest != nil }

    init() {
        let d = UserDefaults.standard
        mode = AutoUpdateMode(rawValue: d.string(forKey: "AprilUpdateMode") ?? "") ?? .patch
        beta = d.bool(forKey: "AprilUpdateBeta")
        skipped = Set(d.stringArray(forKey: "AprilUpdateSkipped") ?? [])
        pinned = d.bool(forKey: "AprilUpdatePinned")
    }

    func loop() async {
        announceInstalled()
        try? await Task.sleep(for: .seconds(15))      // ให้ระบบเปิดเสร็จก่อน
        while !Task.isCancelled {
            await check()
            await autoApply()
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// เพิ่งเปลี่ยนรุ่น -> แจ้งครั้งเดียว
    private func announceInstalled() {
        let key = "AprilLastSeenVersion"
        if let seen = UserDefaults.standard.string(forKey: key), seen != version {
            message = UpdatePolicy.newer(version, than: seen) ? "อัปเดตเป็น April \(version) แล้ว" : "ย้อนกลับเป็น April \(version) แล้ว"
        }
        UserDefaults.standard.set(version, forKey: key)
    }

    func check(verbose: Bool = false) async {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Backend.repoSlug)/releases?per_page=30")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("April/\(version)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [JSON] else {
            if verbose { message = "ตรวจอัปเดตไม่ได้ตอนนี้ (เน็ตหลุด?)" }
            return
        }
        let iso = ISO8601DateFormatter()
        releases = list.filter { $0.bool("draft") != true }.map { r in
            Release(version: (r.str("tag_name") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                    notes: r.str("body") ?? "",
                    date: r.str("published_at").flatMap { iso.date(from: $0) },
                    zip: r.arr("assets").first { ($0.str("name") ?? "").hasSuffix(".zip") }
                        .flatMap { $0.str("browser_download_url") }.flatMap(URL.init(string:)),
                    prerelease: r.bool("prerelease") ?? false)
        }
        lastCheck = Date()
        if let n = newest { message = "มี April \(n.version) ใหม่ (ตอนนี้ \(version))" }
        else if verbose { message = "เป็นรุ่นล่าสุดแล้ว (\(version))" }
    }

    func autoApply() async {
        guard let target = UpdatePolicy.autoTarget(releases, current: version, mode: mode, beta: beta,
                                                   skipped: skipped, pinned: pinned) else { return }
        // กำลังตอบแชท/คุยด้วยเสียงอยู่ -> รอรอบถัดไป (แอปต้องปิดเปิดใหม่)
        guard canApply() else { return }
        await install(target)
    }

    func skip(_ r: Release) {
        skipped.insert(r.version)
        if newest == nil { message = nil }
    }

    /// ติดตั้งรุ่นที่เลือก — ย้อนรุ่น = ตรึงรุ่นไว้ · ขึ้นรุ่นเอง = เลิกตรึง
    func install(_ r: Release) async {
        guard let url = r.zip, !working, r.version != version else { return }
        working = true
        progress = 0
        defer { working = false; progress = nil }
        let older = UpdatePolicy.newer(version, than: r.version)
        message = "กำลังดาวน์โหลด April \(r.version)…"
        do {
            let zip = try await Downloader.fetch(URLRequest(url: url)) { [weak self] got, total in
                Task { @MainActor in if total > 0 { self?.progress = got / total } }
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("april-update-\(r.version)")
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            guard await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, tmp.path]).ok else {
                throw Installer.Failure(message: "แตกไฟล์อัปเดตไม่ได้")
            }
            let newApp = tmp.appendingPathComponent("April.app")
            let got = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
            guard got == r.version else { throw Installer.Failure(message: "ไฟล์อัปเดตไม่ตรงรุ่น (\(got ?? "?"))") }
            await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            message = "กำลังติดตั้ง April \(r.version)…"
            let app = Bundle.main.bundlePath
            let res = await Shell.run("/bin/bash", ["-c", "rm -rf \"$1.new\" && ditto \"$0\" \"$1.new\" && rm -rf \"$1\" && mv \"$1.new\" \"$1\"",
                                                    newApp.path, app])
            guard res.ok else { throw Installer.Failure(message: "แทนที่แอปไม่ได้ — ลากแอปจาก dmg ไปทับเองได้") }
            pinned = older
            skipped.remove(r.version)
            relaunch(app)
        } catch {
            message = "ติดตั้งไม่สำเร็จ: \(error.localizedDescription)"
        }
    }

    private func relaunch(_ app: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app]
        try? p.run()
        NSApp.terminate(nil)
    }
}
