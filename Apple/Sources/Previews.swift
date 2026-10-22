// Previews.swift — วาดภาพ UI ออกเป็นไฟล์ PNG เพื่อตรวจหน้าตาโดยไม่ต้องเปิดแอปบนจอ
// คอมไพล์เข้าเฉพาะ build พรีวิว (-D APRIL_PREVIEW): ./Apple/tests/render-previews.sh <โฟลเดอร์ปลายทาง>

#if APRIL_PREVIEW
import AppKit
import SwiftUI

@MainActor
func renderPreviews() {
    guard let dir = ProcessInfo.processInfo.environment["APRIL_PREVIEW_DIR"] else { return }
    let app = AppState.shared
    let island = Island.state
    island.expanded = true
    island.notch = CGSize(width: 200, height: 32)

    func save<V: View>(_ view: V, _ name: String, _ size: CGSize) {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed: \(name)"); return }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        print("saved \(name).png")
    }

    // เกาะทุกสถานะ วางบนพื้นแถบเมนูสีเทาเพื่อเห็นขอบ
    for (s, level, pulse) in [(TalkState.listening, Float(0.18), false), (.thinking, 0, false), (.speaking, 0, true), (.error, 0, false)] {
        app.talk.previewSet(s, level: level, pulse: pulse)
        let w = 200 + Island.ear * 2, h = 32 + Island.strip
        save(ZStack(alignment: .top) {
            Color(white: 0.85)
            IslandView(onClose: {}).frame(width: w, height: h).environment(app.talk).environment(island)
        }, "island-\(s.rawValue)", CGSize(width: w + 80, height: h + 30))
    }

    // ศูนย์ควบคุม (ข้อมูลตัวอย่าง)
    let sys = app.system
    sys.overview = ["active_runs": 1, "llm_calls": 42, "llm_errors": 1, "tool_calls": 17, "notes": 6, "sessions": 9,
                    "reminders_pending": 2, "uptime_seconds": 5400,
                    "tokens": ["input": 48_200, "output": 3_100],
                    "runs_24h": ["done": ["count": 12, "avg_seconds": 8.4], "failed": ["count": 1]],
                    "ollama": ["online": true, "installed": 16, "loaded": ["qwen3.5:4b"]],
                    "cloud": ["default": "auto", "chain": ["claude-opus", "local"], "cooling": []],
                    "announcements": [["kind": "reminder", "title": "เตือนความจำ", "text": "โทรหาแม่", "created": Date().timeIntervalSince1970 - 600]]]
    app.backend.phase = .ready
    save(SystemView().environment(app).environment(app.talk).environment(app.wake).environment(app.hotkey)
            .background(Theme.canvas), "control-center", CGSize(width: 1060, height: 720))
    exit(0)
}
#endif
