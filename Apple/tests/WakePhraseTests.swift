// WakePhraseTests.swift — เทสการจับ/ตัดคำปลุก (รันด้วย Apple/tests/wake-phrase.sh)
import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String, line: Int = #line) {
    if !ok { failures += 1; print("✗ \(name) (บรรทัด \(line))") }
}

@main
struct Tests {
    static func main() {
        let cases: [(String, String)] = [
            ("ฮัลโหลเอพริลช่วยหาข้อมูลเกี่ยวกับ SEO ให้หน่อย", "ช่วยหาข้อมูลเกี่ยวกับ SEO ให้หน่อย"),   // จาก log จริง
            ("เอพริล ครับ เปิดเพลงหน่อย", "เปิดเพลงหน่อย"),
            ("Hey April, what time is it", "what time is it"),
            ("สวัสดี เอพริว", ""),
            ("ช่วยจำว่าเอพริลคือชื่อแมวของผม", "ช่วยจำว่าเอพริลคือชื่อแมวของผม"),       // คำปลุกกลางประโยค ไม่ตัด
            ("ฮัลโหล ช่วยเปิดไฟ", "ฮัลโหล ช่วยเปิดไฟ"),                                   // ไม่มีคำปลุก ไม่ตัดคำทักทาย
            ("เอพริลล์ช่วยเตือนตอนสามโมง", "ช่วยเตือนตอนสามโมง"),
        ]
        for (input, want) in cases {
            let got = WakePhrase.strip(input)
            check(got == want, "strip(\"\(input)\") = \"\(got)\" ควรเป็น \"\(want)\"")
        }
        check(WakePhrase.matches("ฮัลโหล เอ พริล"), "จับคำปลุกที่มีช่องว่างคั่น")
        check(!WakePhrase.matches("วันนี้อากาศดี"), "ไม่จับประโยคทั่วไป")
        print(failures == 0 ? "✔ WakePhrase ผ่านทั้งหมด" : "✗ ไม่ผ่าน \(failures) ข้อ")
        exit(failures == 0 ? 0 : 1)
    }
}
