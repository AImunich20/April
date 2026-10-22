// UpdatePolicyTests.swift — เทสกติกาการอัปเดต (รันด้วย Apple/tests/update-policy.sh)
import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String, line: Int = #line) {
    if !ok { failures += 1; print("✗ \(name) (บรรทัด \(line))") }
}

func rel(_ v: String, beta: Bool = false, zip: Bool = true) -> Release {
    Release(version: v, notes: "", date: nil, zip: zip ? URL(string: "https://x/\(v).zip") : nil, prerelease: beta)
}

@main
struct Tests {
    static func main() {
        let all = [rel("0.2.0"), rel("0.2.1"), rel("0.2.2"), rel("0.3.0"), rel("0.3.1-beta", beta: true), rel("0.1.0", zip: false)]

        // เทียบเลขรุ่น
        check(UpdatePolicy.newer("0.10.0", than: "0.9.9"), "0.10.0 ใหม่กว่า 0.9.9 (เทียบเป็นตัวเลข ไม่ใช่ตัวอักษร)")
        check(!UpdatePolicy.newer("0.2.0", than: "0.2"), "0.2 = 0.2.0")
        check(UpdatePolicy.newer("v1.0.0", than: "0.9.0"), "ตัด v นำหน้า")
        check(UpdatePolicy.isPatch("0.2.2", of: "0.2.0"), "0.2.2 เป็นแพตช์ของ 0.2.0")
        check(!UpdatePolicy.isPatch("0.3.0", of: "0.2.0"), "0.3.0 ไม่ใช่แพตช์")
        check(!UpdatePolicy.isPatch("0.2.0", of: "0.2.0"), "รุ่นเดียวกันไม่ใช่แพตช์")

        // โหมดอัตโนมัติ
        func auto(_ mode: AutoUpdateMode, current: String = "0.2.0", beta: Bool = false, skipped: Set<String> = [],
                  pinned: Bool = false) -> String? {
            UpdatePolicy.autoTarget(all, current: current, mode: mode, beta: beta, skipped: skipped, pinned: pinned)?.version
        }
        check(auto(.off) == nil, "off: ไม่ติดตั้งเอง")
        check(auto(.patch) == "0.2.2", "patch: ไปแพตช์ล่าสุดของ 0.2")
        check(auto(.patch, current: "0.2.2") == nil, "patch: ไม่ข้ามไป 0.3.0 เอง")
        check(auto(.all) == "0.3.0", "all: ไปรุ่นล่าสุดที่ไม่ใช่ beta")
        check(auto(.all, beta: true) == "0.3.1-beta", "all + beta: ได้รุ่นทดสอบ")
        check(auto(.patch, skipped: ["0.2.2"]) == "0.2.1", "ข้าม 0.2.2 -> ได้ 0.2.1")
        check(auto(.all, pinned: true) == nil, "ตรึงรุ่นแล้วไม่อัปเดตเอง")

        // แจ้งเตือน + รายการ
        check(UpdatePolicy.newest(all, current: "0.2.0", beta: false, skipped: [])?.version == "0.3.0", "แจ้งรุ่นใหม่สุด")
        check(UpdatePolicy.newest(all, current: "0.3.0", beta: false, skipped: []) == nil, "ใช้รุ่นล่าสุดอยู่แล้ว")
        let shown = UpdatePolicy.visible(all, current: "0.2.0", beta: false).map(\.version)
        check(shown == ["0.3.0", "0.2.2", "0.2.1", "0.2.0"], "รายการเรียงใหม่->เก่า ไม่มี beta และรุ่นที่ไม่มีไฟล์: \(shown)")
        check(UpdatePolicy.visible(all, current: "0.3.1-beta", beta: false).first?.version == "0.3.1-beta",
              "รุ่น beta ที่ใช้อยู่ยังแสดงแม้ปิด beta")

        print(failures == 0 ? "✔ UpdatePolicy ผ่านทั้งหมด" : "✗ ไม่ผ่าน \(failures) ข้อ")
        exit(failures == 0 ? 0 : 1)
    }
}
