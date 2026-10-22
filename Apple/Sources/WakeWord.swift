// WakeWord.swift — เรียก April ด้วยเสียง: ฟังคำว่า "April / เอพริล" ตลอดเวลา (เปิดเองในตั้งค่าเสียง ปิดเป็นค่าเริ่มต้น)
//
// ความเป็นส่วนตัว: ถอดเสียงด้วย Apple Speech แบบ "บนเครื่องเท่านั้น" (requiresOnDeviceRecognition)
//   เครื่องที่ถอดเสียงไทยบนเครื่องไม่ได้ = ไม่เปิดให้ใช้ (ไม่ส่งเสียงในห้องออกไปนอกเครื่องตลอดเวลา)
// ทำงาน: AVAudioEngine -> SFSpeechAudioBufferRecognitionRequest (partial results) -> หาคำปลุกในข้อความช่วงใหม่
//   เริ่มรอบฟังใหม่ทุก 50 วิ (งานถอดเสียงต่อเนื่องมีเพดานเวลา และข้อความสะสมยาวขึ้นเรื่อยๆ)
//   ได้ยินคำปลุก -> ปล่อยไมค์ -> onWake (เปิดหน้าคุยด้วยเสียงแล้วเริ่มฟังคำสั่ง) -> คุยจบแล้วกลับมารอฟังเอง
// ไมค์ใช้ร่วมกับ TalkModel: TalkModel.willUseMic -> pause() · TalkModel.onIdleMic -> resume()

import AVFoundation
import Observation
import Speech

@MainActor @Observable
final class WakeWord {
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "AprilWakeWord")
            if enabled { Task { await start() } } else { stop() }
        }
    }
    private(set) var listening = false
    private(set) var problem: String?

    @ObservationIgnored var onWake: (() -> Void)?

    // เสียง "April" ที่ตัวถอดเสียงไทยมักเขียนออกมา (ตัดช่องว่างแล้ว ตัวพิมพ์เล็ก)
    static let phrases = ["april", "เอพริล", "เอพริว", "เอพิล", "เอพริ้ล", "เอพรีล", "เอพิว", "เอบริล", "เอปริล", "เอเพริล",
                          "เอพริลล์", "เอพิ้ล", "เอพรีว"]

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "th-TH"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var cycle: Task<Void, Never>?
    private var paused = false
    private var generation = 0

    init() {
        enabled = UserDefaults.standard.bool(forKey: "AprilWakeWord")
    }

    static func matches(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        return phrases.contains { t.contains($0) }
    }

    func start() async {
        guard enabled, !paused, engine == nil else { return }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            problem = "เครื่องนี้ยังถอดเสียงไทยบนเครื่องไม่ได้ — เปิด System Settings › Keyboard › Dictation (ภาษาไทย) ให้ดาวน์โหลดก่อน"
            return
        }
        guard await AppleSTT.authorize() else {
            problem = "ไม่ได้รับสิทธิ์รู้จำเสียง — เปิดที่ System Settings › Privacy & Security › Speech Recognition"
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            problem = "ไม่ได้รับสิทธิ์ใช้ไมโครโฟน — เปิดที่ System Settings › Privacy & Security › Microphone"
            return
        }
        guard enabled, !paused, engine == nil else { return }   // สถานะเปลี่ยนระหว่างรอสิทธิ์
        problem = nil
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { problem = "ไม่พบไมโครโฟน"; return }
        let holder = RequestHolder()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buf, _ in holder.request?.append(buf) }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            problem = "เปิดไมค์ไม่ได้: \(error.localizedDescription)"
            return
        }
        self.engine = engine
        self.holder = holder
        listening = true
        beginRound()
        cycle = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(50))
                guard !Task.isCancelled else { return }
                self?.beginRound()
            }
        }
    }

    private var holder: RequestHolder?

    /// รอบฟังใหม่: ปิดงานถอดเสียงเดิม เริ่มงานใหม่บนไมค์เดิม
    private func beginRound() {
        guard let recognizer, let holder else { return }
        task?.cancel()
        request?.endAudio()
        generation += 1
        let gen = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.taskHint = .confirmation
        request = req
        holder.request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let ended = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                guard let self, gen == self.generation, self.listening else { return }
                if let text, WakeWord.matches(text) { self.fire(); return }
                if ended { self.beginRound() }      // งานจบเอง (เงียบนาน/ข้อผิดพลาด) -> ฟังต่อ
            }
        }
    }

    private func fire() {
        stop()
        paused = true          // ให้หน้าคุยด้วยเสียงใช้ไมค์ จนกว่าจะคุยจบ (resume)
        onWake?()
    }

    func stop() {
        cycle?.cancel()
        cycle = nil
        generation += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        holder?.request = nil
        holder = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        listening = false
    }

    func pause() {
        paused = true
        stop()
    }

    func resume() {
        paused = false
        Task { await start() }
    }
}

/// request ปัจจุบันสำหรับ audio thread (เปลี่ยนทุกรอบฟัง)
private final class RequestHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _request }
        set { lock.lock(); _request = newValue; lock.unlock() }
    }
}
