// AprilApp.swift — แอป macOS ของ April (SwiftUI native)
//
// เปิดแอป -> ติดตั้ง (ครั้งแรก) -> เปิด Ollama + เซิร์ฟเวอร์ April เบื้องหลัง -> หน้าแชท
// ไอคอนบน menu bar: เรียก April ได้ตลอด · ⇧⌘A = คุยด้วยเสียง (หน้าต่าง HUD แบบ JARVIS) · เรียก "April" ด้วยเสียงได้ถ้าเปิดไว้
// ⌘Q = ปิดแอป (April ยังรันเบื้องหลัง: ตัวเตือน/สรุปประจำวันยังทำงาน) · ⌥⌘Q = หยุด April แล้วออก
// build: Apple/build.sh · ออกรุ่น: Apple/release.sh

import SwiftUI

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    let backend = Backend()
    let chat: ChatModel
    let talk: TalkModel
    let wake = WakeWord()
    let updater = Updater()
    private var started = false

    private init() {
        chat = ChatModel(backend: backend)
        talk = TalkModel(chat: chat)
        let wake = self.wake
        talk.willUseMic = { wake.pause() }
        talk.onIdleMic = { wake.resume() }
        wake.onWake = { [weak self] in self?.openTalk(fromWake: true) }
    }

    func launch() {
        guard !started else { return }
        started = true
        Task { await backend.monitor() }
        Task {
            await backend.boot()
            await chat.refresh()
        }
        Task { await chat.watchAnnouncements() }
        Task { await updater.loop() }
        Task { await wake.start() }
    }

    func openTalk(fromWake: Bool = false) {
        TalkWindow.show(self)
        if fromWake { talk.wake() }
    }

    func stopAndQuit() {
        Task {
            await backend.stop()
            NSApp.terminate(nil)
        }
    }
}

/// หน้าต่างคุยด้วยเสียง (สร้างเองด้วย AppKit — wake word เปิดได้แม้ไม่มีหน้าต่างอื่นเปิดอยู่)
@MainActor
enum TalkWindow {
    private static var window: NSWindow?
    private static var delegate: Delegate?

    final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { AppState.shared.talk.disappear() }
        }
    }

    static func show(_ app: AppState) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "April"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 520, height: 480)
            w.contentView = NSHostingView(rootView: TalkPage().environment(app.talk).environment(app.chat).environment(app.wake))
            w.center()
            w.setFrameAutosaveName("AprilTalk")
            let d = Delegate()
            w.delegate = d
            delegate = d
            window = w
            return w
        }()
        app.talk.appear()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.launch() }
    }

    // ปิดหน้าต่างสุดท้ายแล้วยังอยู่บน menu bar (เรียกด้วยเสียงได้)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct AprilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var app = AppState.shared

    var body: some Scene {
        Window("April", id: "main") {
            RootView()
                .environment(app)
                .environment(app.chat)
                .environment(app.talk)
                .environment(app.wake)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("แชทใหม่") { app.chat.newChat() }.keyboardShortcut("n")
            }
            CommandMenu("April") {
                Button("คุยด้วยเสียง") { app.openTalk() }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("สรุปประจำวันตอนนี้") {
                    Task { if let t = try? await app.chat.api.briefing(), !t.isEmpty { app.chat.banner = "☀️ \(t)" } }
                }
                Divider()
                Button("เริ่ม April ใหม่") { Task { await app.backend.restart() } }
                Button(app.updater.available ? "อัปเดตเป็น \(app.updater.latest ?? "")" : "ตรวจหาอัปเดต") {
                    Task { if app.updater.available { await app.updater.apply() } else { await app.updater.check(verbose: true); app.chat.banner = app.updater.message } }
                }
                Divider()
                Button("หยุด April แล้วออก") { app.stopAndQuit() }.keyboardShortcut("q", modifiers: [.command, .option])
            }
        }

        MenuBarExtra {
            MenuBarContent().environment(app)
        } label: {
            Image(systemName: app.wake.listening ? "waveform.circle.fill" : "circle.hexagongrid.circle")
        }

        Settings {
            SettingsView().environment(app)
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(app.backend.online ? "April ออนไลน์" : "April ออฟไลน์")
        Button("คุยด้วยเสียง") { app.openTalk() }
        Button("เปิดหน้าแชท") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Toggle("เรียกด้วยเสียง \"April\"", isOn: Binding(get: { app.wake.enabled }, set: { app.wake.enabled = $0 }))
        if let m = app.updater.message, app.updater.available { Button(m) { Task { await app.updater.apply() } } }
        Divider()
        Button("หยุด April แล้วออก") { app.stopAndQuit() }
        Button("ออก (April ทำงานต่อเบื้องหลัง)") { NSApp.terminate(nil) }
    }
}
