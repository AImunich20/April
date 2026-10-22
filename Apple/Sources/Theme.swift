// Theme.swift — สีและองค์ประกอบร่วมของศูนย์ควบคุม: ธีมเหลือง-ดำ (โครงการ์ด/ปุ่ม/Pill ยกมาจาก Envy)
// แอปบังคับโหมดมืดเสมอ (AprilApp.swift) — สีจึงเป็นค่าเดียว ไม่สลับตามโหมดของระบบ

import SwiftUI

extension Color {
    init(hex v: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255,
                  opacity: alpha)
    }
}

enum Theme {
    static let accent = Color(hex: 0xffd60a)            // เหลือง — สีหลัก
    static let accentSoft = Color(hex: 0xffd60a, alpha: 0.14)
    static let onAccent = Color(hex: 0x0a0a0a)           // ตัวหนังสือบนพื้นเหลือง
    static let canvas = Color(hex: 0x0a0a0a)             // พื้นหลังหลัก
    static let sidebar = Color(hex: 0x111111)
    static let surface = Color(hex: 0x161616)            // การ์ด / ช่องพิมพ์
    static let bubble = Color(hex: 0x1f1f1f)
    static let line = Color(hex: 0x2a2a2a)
    static let ink = Color(hex: 0xf4f4ef)
    static let muted = Color(hex: 0x9b9b93)
    static let danger = Color(hex: 0xff5f57)
    static let warn = Color(hex: 0xff9f0a)               // ส้ม (แยกจากเหลืองของสีหลัก)

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink) }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.muted
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct StatusDot: View {
    let ok: Bool?
    var body: some View {
        Circle().fill(ok == nil ? Theme.warn : ok! ? Theme.accent : Theme.danger).frame(width: 8, height: 8)
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.surface.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

func copyToClipboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
