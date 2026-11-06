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

    // แท็บการมองเห็น: ภาพสังเคราะห์ + ผลตรวจจับตัวอย่าง (ตรวจหน้าตา HUD)
    let scene = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { r in
        NSGradient(colors: [NSColor(white: 0.32, alpha: 1), NSColor(white: 0.12, alpha: 1)])?.draw(in: r, angle: -90)
        NSColor(white: 0.55, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 255, y: 170, width: 110, height: 130)).fill()          // หัว
        NSBezierPath(roundedRect: NSRect(x: 190, y: -40, width: 240, height: 210), xRadius: 60, yRadius: 60).fill()
        NSColor(white: 0.75, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 470, y: 40, width: 60, height: 80), xRadius: 8, yRadius: 8).fill()   // แก้ว
        return true
    }
    let cg = scene.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    app.vision.previewSet(cg, [
        Detection(kind: .person, label: "person", confidence: 0.94, box: CGRect(x: 0.28, y: 0, width: 0.4, height: 0.86)),
        Detection(kind: .face, label: "face", confidence: 0.98, box: CGRect(x: 0.4, y: 0.46, width: 0.17, height: 0.37)),
        Detection(kind: .object, label: "cup", confidence: 0.87, box: CGRect(x: 0.73, y: 0.1, width: 0.1, height: 0.24)),
        Detection(kind: .animal, label: "cat", confidence: 0.81, box: CGRect(x: 0.02, y: 0.02, width: 0.2, height: 0.25)),
    ], scene: ["indoor", "office", "desk", "computer"], motion: 0.07)
    sys.tab = .vision
    sys.visionInfo = ["watching": 1, "settings": ["alerts": true, "cloud": true, "model": "local"],
                      "models": [["id": "local", "label": "Qwen 3.5 4B (ในเครื่อง)", "local": true]],
                      "watches": [["id": 1, "target": "แมวขึ้นโต๊ะ", "minutes_left": 52, "repeat": false, "hits": 0]],
                      "events": [["kind": "animal_appeared", "text": "เห็นสัตว์: แมว", "note": "มีแมวสีส้มเดินผ่านหลังเก้าอี้ครับ", "at": Date().timeIntervalSince1970 - 90],
                                 ["kind": "person_arrived", "text": "มีคนมาอยู่หน้ากล้อง", "note": "ยินดีต้อนรับกลับครับบอส", "at": Date().timeIntervalSince1970 - 600]]]
    save(SystemView().environment(app).environment(app.talk).environment(app.wake).environment(app.hotkey)
            .background(Theme.canvas), "control-center-vision", CGSize(width: 1060, height: 1180))
    exit(0)
}
#endif
