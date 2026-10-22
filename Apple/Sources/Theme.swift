// Theme.swift — สีและองค์ประกอบร่วมของ Control Center (ยกมาจาก Envy ทั้งชุด: พื้นงาช้าง/เทาอุ่น สีหลักมิ้นต์)

import SwiftUI

extension Color {
    /// สีเดียวที่เปลี่ยนตามโหมดสว่าง/มืดของระบบ
    init(light: UInt32, dark: UInt32) {
        func c(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255,
                    blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark) : c(light) })
    }
}

enum Theme {
    static let mint = Color(light: 0x1fa982, dark: 0x3ddca6)
    static let mintSoft = Color(light: 0xdff5ec, dark: 0x1d3a31)
    static let canvas = Color(light: 0xfaf9f5, dark: 0x262624)
    static let sidebar = Color(light: 0xf3f2ec, dark: 0x1f1e1d)
    static let surface = Color(light: 0xffffff, dark: 0x30302e)
    static let bubble = Color(light: 0xefede4, dark: 0x3a3936)
    static let line = Color(light: 0xe5e3d8, dark: 0x3d3d38)
    static let ink = Color(light: 0x1f1e1d, dark: 0xf2f1ec)
    static let muted = Color(light: 0x73726c, dark: 0xa3a29b)
    static let danger = Color(light: 0xc2412d, dark: 0xf07a63)
    static let warn = Color(light: 0xb7791f, dark: 0xe8b04f)

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
        Circle().fill(ok == nil ? Theme.warn : ok! ? Theme.mint : Theme.danger).frame(width: 8, height: 8)
    }
}

struct MintButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.mint.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8))
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
