// UpdatePolicy.swift — กติกาการอัปเดต (ไม่มี UI/เครือข่าย -> ทดสอบได้ด้วย Apple/tests/update-policy.sh)
//
// ผู้ใช้เลือกโหมดอัปเดตอัตโนมัติ:
//   off    ไม่อัปเดตเอง (แจ้งว่ามีรุ่นใหม่เท่านั้น)
//   patch  ติดตั้งเองเฉพาะรุ่นแก้บั๊ก x.y.Z ของรุ่นที่ใช้อยู่ (ค่าเริ่มต้น) — รุ่นที่เพิ่มฟีเจอร์ (x.Y.0) ให้ผู้ใช้กดเอง
//   all    ติดตั้งรุ่นล่าสุดเองทุกครั้ง
// และเลือกติดตั้งรุ่นใดก็ได้ในรายการ รวมถึงย้อนกลับไปรุ่นเก่า (ย้อนแล้ว = ตรึงรุ่นไว้ ไม่ให้อัปเดตเองทับ จนกว่าจะเลิกตรึง)
// รุ่นที่กด "ข้าม" จะไม่ถูกติดตั้งอัตโนมัติ · รุ่นทดสอบ (prerelease) แสดงเฉพาะเมื่อเปิด "รับรุ่นทดสอบ"

import Foundation

enum AutoUpdateMode: String, CaseIterable, Identifiable {
    case off, patch, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "ไม่อัปเดตเอง (แจ้งเตือนอย่างเดียว)"
        case .patch: "อัปเดตแพตช์แก้บั๊กให้เอง (แนะนำ)"
        case .all: "อัปเดตทุกรุ่นให้เอง"
        }
    }
}

struct Release: Identifiable, Equatable {
    let version: String
    let notes: String
    let date: Date?
    let zip: URL?
    let prerelease: Bool
    var id: String { version }
}

enum UpdatePolicy {
    static func parts(_ v: String) -> [Int] {
        let core = v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: "-").first ?? ""
        let p = core.split(separator: ".").map { Int($0) ?? 0 }
        return p + Array(repeating: 0, count: max(0, 3 - p.count))
    }

    static func compare(_ a: String, _ b: String) -> Int {
        for (x, y) in zip(parts(a), parts(b)) where x != y { return x < y ? -1 : 1 }
        return 0
    }

    static func newer(_ a: String, than b: String) -> Bool { compare(a, b) > 0 }

    /// a เป็นแพตช์ของ b: major.minor เดียวกันและใหม่กว่า
    static func isPatch(_ a: String, of b: String) -> Bool {
        parts(a).prefix(2) == parts(b).prefix(2) && newer(a, than: b)
    }

    /// รุ่นที่แสดงในรายการ: มีไฟล์อัปเดต + (รุ่นทดสอบเฉพาะเมื่อเปิด หรือเป็นรุ่นที่ใช้อยู่) เรียงใหม่ -> เก่า
    static func visible(_ releases: [Release], current: String, beta: Bool) -> [Release] {
        releases.filter { $0.zip != nil && (beta || !$0.prerelease || compare($0.version, current) == 0) }
            .sorted { newer($0.version, than: $1.version) }
    }

    /// รุ่นใหม่ล่าสุดที่ควรแจ้งผู้ใช้ (ไม่สนโหมดอัตโนมัติ)
    static func newest(_ releases: [Release], current: String, beta: Bool, skipped: Set<String>) -> Release? {
        visible(releases, current: current, beta: beta).first { newer($0.version, than: current) && !skipped.contains($0.version) }
    }

    /// รุ่นที่จะติดตั้งให้เองตอนนี้ (nil = ไม่ต้องทำอะไร)
    static func autoTarget(_ releases: [Release], current: String, mode: AutoUpdateMode, beta: Bool,
                           skipped: Set<String>, pinned: Bool) -> Release? {
        guard mode != .off, !pinned else { return nil }
        let candidates = visible(releases, current: current, beta: beta)
            .filter { newer($0.version, than: current) && !skipped.contains($0.version) }
        return mode == .all ? candidates.first : candidates.first { isPatch($0.version, of: current) }
    }
}
