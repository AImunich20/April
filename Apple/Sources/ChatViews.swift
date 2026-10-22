// ChatViews.swift — หน้าหลัก: เปิดระบบ/ติดตั้ง -> แชท (รายการบทสนทนา + ข้อความ + ช่องพิมพ์)

import SwiftUI

func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if app.backend.phase == .ready { ChatScreen() } else { BootView() }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: - เปิดระบบ / ติดตั้งครั้งแรก

struct BootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 18) {
            AprilMark().frame(width: 72, height: 72)
            switch app.backend.phase {
            case .working(let what):
                Text(what).font(.title3.weight(.semibold))
                if let inst = app.backend.installer { InstallSteps(installer: inst) }
                else { ProgressView().controlSize(.small); Text(app.backend.log).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            case .failed(let why):
                Text("เปิด April ไม่สำเร็จ").font(.title3.weight(.semibold))
                Text(why).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                Button("ลองใหม่") { Task { await app.backend.boot() } }.keyboardShortcut(.defaultAction)
            case .ready:
                EmptyView()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InstallSteps: View {
    let installer: Installer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Installer.Step.allCases) { s in
                HStack(spacing: 10) {
                    Group {
                        if installer.done.contains(s) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        else if installer.step == s { ProgressView().controlSize(.small) }
                        else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                    }
                    .frame(width: 18)
                    Text(s.title).foregroundStyle(installer.step == s ? .primary : .secondary)
                }
            }
            if let p = installer.progress { ProgressView(value: p).frame(width: 320) }
            Text(installer.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(width: 340, alignment: .leading)
            Text("ครั้งแรกต้องต่อเน็ต ใช้เวลา 5–20 นาที (โมเดลในเครื่อง ~3 GB)").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// โลโก้ April: วงแหวน HUD สีอำพัน (ตรงกับ make-icon.swift)
struct AprilMark: View {
    var body: some View {
        Canvas { g, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) / 2
            let amber = Color(.sRGB, red: 1, green: 0.72, blue: 0.32)
            for (k, w, a0, a1) in [(0.92, 0.06, -0.3, 4.2), (0.72, 0.05, 1.2, 5.6), (0.52, 0.04, 3.4, 8.0)] {
                var p = Path()
                p.addArc(center: c, radius: r * k, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
                g.stroke(p, with: .color(amber.opacity(0.9)), style: StrokeStyle(lineWidth: r * w, lineCap: .round))
            }
            g.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.22, y: c.y - r * 0.22, width: r * 0.44, height: r * 0.44)),
                   with: .radialGradient(Gradient(colors: [.white, amber, amber.opacity(0)]), center: c, startRadius: 0, endRadius: r * 0.3))
        }
    }
}

// MARK: - แชท

struct ChatScreen: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var chat = app.chat
        NavigationSplitView {
            List(selection: Binding(get: { chat.current }, set: { id in
                if let s = chat.sessions.first(where: { $0.id == id }) { Task { await chat.open(s) } }
            })) {
                ForEach(chat.sessions) { s in
                    Text(s.title.isEmpty ? "บทสนทนา" : s.title).lineLimit(1).tag(s.id)
                        .contextMenu { Button("ลบ", role: .destructive) { Task { await chat.delete(s) } } }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                ToolbarItem { Button { chat.newChat() } label: { Image(systemName: "square.and.pencil") }.help("แชทใหม่ ⌘N") }
            }
        } detail: {
            VStack(spacing: 0) {
                if let banner = chat.banner {
                    HStack {
                        Text(markdown(banner)).font(.callout).lineLimit(3)
                        Spacer()
                        Button { chat.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                    .padding(10).background(.orange.opacity(0.15))
                }
                Messages()
                if let notice = chat.notice {
                    Text(notice).font(.caption).foregroundStyle(.orange).padding(.top, 4)
                }
                InputBar()
            }
            .toolbar {
                ToolbarItemGroup {
                    Picker("โมเดล", selection: $chat.model) {
                        Text("อัตโนมัติ").tag("auto")
                        ForEach(chat.models) { m in
                            Text(m.label + (m.ready ? "" : " (ยังไม่ได้ตั้งค่า)")).tag(m.id)
                        }
                    }
                    .frame(width: 220)
                    Button { app.openTalk() } label: { Label("คุยด้วยเสียง", systemImage: "waveform.circle") }
                        .help("คุยด้วยเสียง ⇧⌘A")
                    Circle().fill(app.backend.online ? .green : .red).frame(width: 8, height: 8)
                        .help(app.backend.online ? "April ออนไลน์" : "April ออฟไลน์")
                }
            }
        }
        .task { await chat.refresh() }
    }
}

struct Messages: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let chat = app.chat
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.messages.isEmpty { Welcome() }
                    ForEach(chat.messages) { m in MessageRow(message: m) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(20)
            }
            .onChange(of: chat.messages.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: chat.messages.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct Welcome: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AprilMark().frame(width: 44, height: 44)
            Text("April พร้อมรับใช้ครับ").font(.title2.weight(.semibold))
            Text("ลองสั่ง: \"อีก 30 นาทีเตือนให้ดื่มน้ำ\" · \"เช็กแบตเครื่องหน่อย\" · \"ข่าวเทคโนโลยีวันนี้มีอะไรบ้าง\" · "
                 + "\"จำไว้ว่าผมแพ้กุ้ง\"").foregroundStyle(.secondary)
            if app.wake.enabled { Label("เรียก \"April\" เพื่อสั่งด้วยเสียงได้เลย", systemImage: "ear").foregroundStyle(.secondary) }
        }
        .padding(.top, 40)
    }
}

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        if message.me {
            HStack {
                Spacer(minLength: 80)
                Text(message.text).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !message.tools.isEmpty {
                    FlowChips(tools: message.tools)
                }
                if message.text.isEmpty && message.error == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(message.thinking ? "กำลังคิด…" : "…").foregroundStyle(.secondary)
                    }
                } else {
                    Text(markdown(message.text)).textSelection(.enabled)
                }
                if let e = message.error { Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red) }
                if let model = message.model { Text(model).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }
}

struct FlowChips: View {
    let tools: [ToolChip]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tools) { t in
                HStack(spacing: 4) {
                    if t.ok == nil { ProgressView().controlSize(.mini) }
                    else { Image(systemName: t.ok == true ? "checkmark" : "xmark").foregroundStyle(t.ok == true ? .green : .red) }
                    Text(ChatModel.toolLabels[t.name] ?? t.name)
                }
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .help(t.preview)
            }
        }
    }
}

struct InputBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var chat = app.chat
        HStack(alignment: .bottom, spacing: 8) {
            TextField("สั่ง April…", text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...6)
                .onSubmit { chat.send() }
            if chat.busy {
                Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }.buttonStyle(.plain)
            } else {
                Button { chat.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).disabled(chat.input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .padding(12)
    }
}
