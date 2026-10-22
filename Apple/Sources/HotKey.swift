// HotKey.swift — คีย์ลัดเรียก April จากแอปไหนก็ได้ (เหมือนกดเรียก Siri)
// ใช้ Carbon RegisterEventHotKey: ทำงานทั้งระบบโดยไม่ต้องขอสิทธิ์ Accessibility · เลือกคีย์ได้ในแท็บ "เสียง"

import Carbon
import Observation

enum HotKeyChoice: String, CaseIterable, Identifiable {
    case optionSpace, controlSpace, optionCommandSpace, commandShiftA
    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlSpace: "⌃ Space"
        case .optionCommandSpace: "⌥⌘ Space"
        case .commandShiftA: "⇧⌘ A"
        }
    }

    var keyCode: UInt32 { self == .commandShiftA ? UInt32(kVK_ANSI_A) : UInt32(kVK_Space) }

    var modifiers: UInt32 {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlSpace: UInt32(controlKey)
        case .optionCommandSpace: UInt32(optionKey | cmdKey)
        case .commandShiftA: UInt32(cmdKey | shiftKey)
        }
    }
}

@MainActor @Observable
final class HotKey {
    var choice: HotKeyChoice {
        didSet {
            UserDefaults.standard.set(choice.rawValue, forKey: "AprilHotKey")
            register()
        }
    }
    private(set) var problem: String?

    @ObservationIgnored var onPress: (() -> Void)?
    @ObservationIgnored private var ref: EventHotKeyRef?
    @ObservationIgnored private var installed = false

    /// ตัวรับเหตุการณ์ของ Carbon เป็น C callback — ส่งต่อผ่านตัวแปร static
    nonisolated(unsafe) static var current: HotKey?

    init() {
        choice = HotKeyChoice(rawValue: UserDefaults.standard.string(forKey: "AprilHotKey") ?? "") ?? .optionSpace
    }

    func register() {
        HotKey.current = self
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.current?.onPress?() } }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        let id = EventHotKeyID(signature: OSType(0x4150_524C), id: 1)   // 'APRL'
        let status = RegisterEventHotKey(choice.keyCode, choice.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        problem = status == noErr ? nil : "คีย์ \(choice.label) ถูกแอปอื่นใช้อยู่ — เลือกคีย์อื่น"
    }
}
