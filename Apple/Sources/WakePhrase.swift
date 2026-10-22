// WakePhrase.swift — คำปลุก "April" (ไม่พึ่ง UI/เสียง -> ทดสอบได้ด้วย Apple/tests/wake-phrase.sh)
//   matches: ข้อความที่ถอดเสียงได้มีคำปลุกไหม (WakeWord.swift)
//   strip:   ตัดคำทักทาย + คำปลุกที่ขึ้นต้นคำสั่งออกก่อนส่งให้ April
//            (วัดจริง: ส่งไปทั้งประโยค "ฮัลโหลเอพริลช่วยหาข้อมูล…")

import Foundation

enum WakePhrase {
    // เสียง "April" ที่ตัวถอดเสียงไทยมักเขียนออกมา (ตัวพิมพ์เล็ก ไม่มีช่องว่าง)
    static let phrases = ["april", "เอพริลล์", "เอพริล", "เอพริว", "เอพริ้ล", "เอพรีล", "เอพรีว", "เอพิ้ล", "เอพิล", "เอพิว",
                          "เอบริล", "เอปริล", "เอเพริล"]
    static let greetings = ["ฮัลโหล", "ฮาโหล", "สวัสดี", "หวัดดี", "เฮ้", "เฮ", "hey", "hello", "hi", "โอเค", "ok"]
    static let particles = ["ครับ", "คับ", "ค่ะ", "คะ", "จ๊ะ", "จ้ะ", "จ้า", "นะ"]

    static func matches(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        return phrases.contains { t.contains($0) }
    }

    /// "ฮัลโหล เอพริล ช่วยหาข้อมูล" -> "ช่วยหาข้อมูล" · คำปลุกกลางประโยคไม่แตะ · เหลือว่าง = ""
    static func strip(_ text: String) -> String {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        func dropPrefix(_ words: [String]) -> Bool {
            let low = rest.lowercased()
            for w in words.sorted(by: { $0.count > $1.count }) where low.hasPrefix(w) {
                rest = rest.dropFirst(w.count)
                rest = rest.drop { $0.isWhitespace || ",.!?".contains($0) }
                return true
            }
            return false
        }
        let original = rest
        _ = dropPrefix(greetings)
        guard dropPrefix(phrases) else { return String(original) }
        _ = dropPrefix(particles)
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
