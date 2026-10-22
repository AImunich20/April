// AprilApp.swift — แอป macOS ของ April
//
// หน้าต่างของแอปมีหน้าเดียว = ศูนย์ควบคุม (ControlCenter.swift — แบบเดียวกับหน้า "ระบบ" ของ Envy) ไม่มีหน้าเว็บ
// การใช้งาน April = เรียกแบบ Siri: คีย์ลัด (ค่าเริ่มต้น ⌥Space) หรือพูดว่า "April" -> Dynamic Island ที่รอยบากจอ (Island.swift)
// ธีมเหลือง-ดำ บังคับโหมดมืดเสมอ
// เปิดแอป -> ติดตั้ง (ครั้งแรก) -> เปิด Ollama + เซิร์ฟเวอร์ April เบื้องหลัง · ไอคอนบน menu bar อยู่ตลอด
// ⌘Q = ปิดแอป (April ยังรันเบื้องหลัง: ตัวเตือน/สรุปประจำวันยังทำงาน) · ⌥⌘Q = หยุด April แล้วออก
// build: Apple/build.sh · ออกรุ่น: Apple/release.sh

import SwiftUI

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    let backend = Backend()
    let system: SystemModel
    let talk: TalkModel
    let wake = WakeWord()
    let hotkey = HotKey()
    let updater = Updater()
    /// openWindow ของ SwiftUI (เก็บไว้จาก RootView ตอนเปิดแอป — เปิดศูนย์ควบคุมได้แม้ปิดหน้าต่างไปแล้ว)
    @ObservationIgnored var openMain: (() -> Void)?
    private var started = false

    private init() {
        system = SystemModel(backend: backend)
        talk = TalkModel(backend: backend)
        let wake = self.wake, talk = self.talk
        talk.willUseMic = { wake.pause() }
        talk.onIdleMic = { wake.resume() }
        wake.onWake = { [weak self] in self?.summon() }
        hotkey.onPress = { [weak self] in self?.summon() }
        // อัปเดตอัตโนมัติเฉพาะตอนที่ไม่ได้กำลังคุยกับ April (แอปต้องปิดเปิดใหม่)
        updater.canApply = { !talk.busy && !talk.convo }
    }

    func launch() {
        guard !started else { return }
        started = true
        NSApp.appearance = NSAppearance(named: .darkAqua)
        hotkey.register()
        Task { await backend.monitor() }
        Task { await backend.boot() }
        Task { await updater.loop() }
        Task { await wake.start() }
    }

    /// เรียก April แบบ Siri
    func summon() {
        guard backend.phase == .ready else {
            NSSound(named: "Funk")?.play()
            openControlCenter()
            return
        }
        Island.summon(self)
        // โหลดโมเดลในเครื่องขึ้น RAM ระหว่างที่ผู้ใช้พูด — คำตอบแรกไม่ต้องรอโหลด (~20 วิ)
        let api = backend.api
        Task { try? await api.call("POST", "api/models/warm", timeout: 5) }
    }

    func openControlCenter() {
        openMain?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func openLogs() {
        guard let root = backend.root else { return }
        NSWorkspace.shared.open(root.appendingPathComponent("data/logs"))
    }

    func stopAndQuit() {
        Task {
            await backend.stop()
            NSApp.terminate(nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if APRIL_PREVIEW
        MainActor.assumeIsolated { renderPreviews() }
        #endif
        MainActor.assumeIsolated { AppState.shared.launch() }
    }

    // ปิดหน้าต่างแล้วยังอยู่บน menu bar (เรียกด้วยคีย์ลัด/เสียงได้)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct AprilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var app = AppState.shared

    var body: some Scene {
        Window("April", id: "main") {
            RootView()
                .preferredColorScheme(.dark)
                .environment(app)
                .environment(app.talk)
                .environment(app.wake)
                .environment(app.hotkey)
        }
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("April") {
                Button("เรียก April (\(app.hotkey.choice.label))") { app.summon() }
                Divider()
                Button("เริ่ม April ใหม่") { Task { await app.backend.restart() } }
                if let n = app.updater.newest {
                    Button("อัปเดตเป็น \(n.version)") { Task { await app.updater.install(n) } }
                }
                Button("ตรวจหาอัปเดต") { app.system.tab = .update; Task { await app.updater.check(verbose: true) } }
                Divider()
                Button("หยุด April แล้วออก") { app.stopAndQuit() }.keyboardShortcut("q", modifiers: [.command, .option])
            }
        }

        MenuBarExtra {
            MenuBarContent().environment(app)
        } label: {
            Image(systemName: app.wake.listening ? "waveform.circle.fill" : "circle.hexagongrid.circle")
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Text(app.backend.online ? "April ออนไลน์" : "April ออฟไลน์")
        Button("เรียก April  \(app.hotkey.choice.label)") { app.summon() }
        Button("ศูนย์ควบคุม") { app.openControlCenter() }
        Toggle("เรียกด้วยเสียง \"April\"", isOn: Binding(get: { app.wake.enabled }, set: { app.wake.enabled = $0 }))
        if let n = app.updater.newest {
            Button("อัปเดตเป็น April \(n.version)") { Task { await app.updater.install(n) } }
        }
        Divider()
        Button("หยุด April แล้วออก") { app.stopAndQuit() }
        Button("ออก (April ทำงานต่อเบื้องหลัง)") { NSApp.terminate(nil) }
    }
}
