// UpdateSettings.swift — แท็บ "อัปเดต" ในตั้งค่า: เลือกโหมดอัปเดตอัตโนมัติ + รายการทุกรุ่น (ติดตั้ง/ย้อนรุ่น/ข้าม)

import SwiftUI

struct UpdateSettings: View {
    @Environment(AppState.self) private var app
    @ViewState private var confirm: Release?

    var body: some View {
        @Bindable var updater = app.updater
        Form {
            Section {
                LabeledContent("รุ่นที่ใช้อยู่", value: updater.version)
                Picker("อัปเดตอัตโนมัติ", selection: $updater.mode) {
                    ForEach(AutoUpdateMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("รับรุ่นทดสอบ (beta)", isOn: $updater.beta)
                if updater.pinned {
                    HStack {
                        Label("ตรึงไว้ที่รุ่นนี้ — ไม่อัปเดตเอง", systemImage: "pin.fill").foregroundStyle(.orange)
                        Spacer()
                        Button("เลิกตรึง") { updater.pinned = false; Task { await updater.autoApply() } }
                    }
                }
                HStack {
                    if updater.working {
                        ProgressView(value: updater.progress ?? 0).frame(width: 140)
                    }
                    Text(updater.message ?? (updater.lastCheck.map { "ตรวจล่าสุด \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("ตรวจตอนนี้") { Task { await updater.check(verbose: true) } }.disabled(updater.working)
                }
            }

            Section("ทุกรุ่น") {
                if updater.visible.isEmpty { Text("ยังไม่มีข้อมูลรุ่น — กด \"ตรวจตอนนี้\"").foregroundStyle(.secondary) }
                ForEach(updater.visible) { r in ReleaseRow(release: r, confirm: $confirm) }
            }
        }
        .formStyle(.grouped)
        .task { if updater.releases.isEmpty { await updater.check() } }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { r in
            Button(UpdatePolicy.newer(r.version, than: updater.version) ? "อัปเดตเลย" : "ย้อนกลับ") {
                Task { await updater.install(r) }
            }
        } message: { r in
            Text(UpdatePolicy.newer(r.version, than: updater.version)
                 ? "April จะปิดแล้วเปิดใหม่เป็นรุ่น \(r.version) — ข้อมูลและความจำอยู่ครบ"
                 : "ย้อนกลับเป็นรุ่น \(r.version) แล้วตรึงไว้ไม่ให้อัปเดตเองทับ (เลิกตรึงได้ทีหลัง) — ข้อมูลและความจำอยู่ครบ")
        }
    }

    private var confirmTitle: String { confirm.map { "ติดตั้ง April \($0.version)?" } ?? "" }
}

struct ReleaseRow: View {
    @Environment(AppState.self) private var app
    let release: Release
    @Binding var confirm: Release?

    var body: some View {
        let updater = app.updater
        let current = release.version == updater.version
        let newer = UpdatePolicy.newer(release.version, than: updater.version)
        DisclosureGroup {
            Text(markdown(release.notes.isEmpty ? "(ไม่มีรายละเอียด)" : release.notes))
                .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                Text(release.version).font(.body.monospacedDigit().weight(current ? .semibold : .regular))
                if current { badge("ใช้อยู่", .green) }
                if release.prerelease { badge("beta", .purple) }
                if updater.skipped.contains(release.version) { badge("ข้ามแล้ว", .gray) }
                if newer, !updater.skipped.contains(release.version),
                   UpdatePolicy.isPatch(release.version, of: updater.version) { badge("แพตช์", .blue) }
                if let d = release.date { Text(d.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !current {
                    if newer && !updater.skipped.contains(release.version) {
                        Button("ข้าม") { updater.skip(release) }.buttonStyle(.borderless).font(.caption)
                    }
                    Button(newer ? "อัปเดต" : "ย้อนกลับ") { confirm = release }
                        .disabled(updater.working || release.zip == nil)
                }
            }
        }
    }

    private func badge(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2.weight(.semibold)).foregroundStyle(c)
            .padding(.horizontal, 6).padding(.vertical, 1).background(c.opacity(0.15), in: Capsule())
    }
}
