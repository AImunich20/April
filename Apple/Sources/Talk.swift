// Talk.swift — สมองของการเรียกใช้แบบ Siri: ฟัง -> คิด -> พูด (พอร์ตจาก Envy Apple/Sources/Talk.swift)
//   ฟัง:  ไมค์ (AVAudioEngine) จับเงียบเองว่าพูดจบ -> ถอดเสียงไทยด้วย Apple Speech (บนเครื่องถ้าเครื่องรองรับ)
//   คิด:  POST /chat (voice=true -> April ตอบสั้นแบบภาษาพูด) บทสนทนา "voice-…" ความจำเดียวกับทุกช่องทาง
//   พูด:  AVSpeechSynthesizer เสียงไทย อ่านทีละท่อนระหว่าง stream
//   แบบ Siri: เรียก (⌥Space / "April") -> ฟังทันที -> ตอบ -> รอฟังคำถามต่อ 5 วิ -> เงียบ = จบ (เกาะหดกลับเข้ารอยบาก)
//   ไม่ได้เรียกเกิน 5 นาที = เริ่มบทสนทนาใหม่ · แตะลูกแก้วระหว่างพูด = พูดแทรก · Esc = หยุด
// หน้าตาอยู่ที่ Island.swift

import AVFoundation
import Speech
import SwiftUI
import Observation

enum TalkState: String {
    case idle, listening, hearing, thinking, speaking, error

    var label: String {
        switch self {
        case .idle: "พร้อมรับใช้ครับ"
        case .listening: "กำลังฟัง…"
        case .hearing: "กำลังแปลงเสียง…"
        case .thinking: "กำลังคิด…"
        case .speaking: "กำลังพูด…"
        case .error: "มีปัญหา"
        }
    }

    var hud: String {
        switch self {
        case .idle: "STANDBY"
        case .listening: "LISTENING"
        case .hearing: "TRANSCRIBING"
        case .thinking: "PROCESSING"
        case .speaking: "SPEAKING"
        case .error: "FAULT"
        }
    }
}

struct TalkTurn: Identifiable {
    let id = UUID()
    let me: Bool
    var text: String
}

// MARK: - สถานะการคุย

@MainActor @Observable
final class TalkModel: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var state: TalkState = .idle
    private(set) var detail: String?
    private(set) var convo = false
    private(set) var busy = false
    var turns: [TalkTurn] = []
    var input = ""
    private(set) var caption = ""
    var speakTyped: Bool { didSet { UserDefaults.standard.set(speakTyped, forKey: "AprilTalkSpeak") } }
    var voiceID: String { didSet { UserDefaults.standard.set(voiceID, forKey: "AprilTalkVoice"); pickVoice() } }
    var rate: Double { didSet { UserDefaults.standard.set(rate, forKey: "AprilTalkRate") } }
    var bargeIn: Bool { didSet { UserDefaults.standard.set(bargeIn, forKey: "AprilTalkBargeIn") } }
    var liveCaptions: Bool { didSet { UserDefaults.standard.set(liveCaptions, forKey: "AprilTalkCaptions") } }

    @ObservationIgnored private(set) var level: Float = 0
    @ObservationIgnored private(set) var levels = [Float](repeating: 0, count: 48)
    @ObservationIgnored private(set) var pulseAt = 0.0

    #if APRIL_PREVIEW
    /// เฉพาะ build พรีวิว (Apple/tests/render-previews.sh): ตั้งสถานะเพื่อวาดภาพแต่ละแบบ
    func previewSet(_ s: TalkState, level: Float, pulse: Bool) {
        state = s
        self.level = level
        levels = (0..<48).map { i in Float(0.15 + 0.6 * abs(sin(Double(i) * 0.37))) * (s == .listening ? 1 : 0) }
        if pulse { pulseAt = Date.now.timeIntervalSinceReferenceDate }
    }
    #endif

    /// เรียกเมื่อเลิกคุย (ไมค์ว่าง) — WakeWord กลับไปรอฟังคำว่า "April"
    @ObservationIgnored var onIdleMic: (() -> Void)?
    /// เรียกก่อนเปิดไมค์ — WakeWord ต้องปล่อยไมค์ก่อน
    @ObservationIgnored var willUseMic: (() -> Void)?

    private let backend: Backend
    private let synth = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?
    private var spoken = 0
    private var pending = 0
    private var onIdle: (() -> Void)?
    private var mic: MicCapture?
    private var monitor: MicCapture?
    private var monitorStart = Date.now
    private var monitorFloor: Float = 0
    private var loudRun = 0
    private var captionTask: SFSpeechRecognitionTask?
    private static let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "th-TH"))
    private var recording = false
    private var listenStart = Date.now
    private var floor: Float = 0.01
    private var spoke = false
    private var lastVoice = 0.0
    private var answerTask: Task<Void, Never>?
    private var viewers = 0
    private var pendingWake = false
    private var followUp = false             // ตอบไปแล้ว กำลังรอฟังคำถามต่อ (เงียบ 5 วิ = จบ)
    private var lastActivity = Date.distantPast

    init(backend: Backend) {
        self.backend = backend
        let d = UserDefaults.standard
        speakTyped = d.object(forKey: "AprilTalkSpeak") as? Bool ?? true
        voiceID = d.string(forKey: "AprilTalkVoice") ?? ""
        rate = d.object(forKey: "AprilTalkRate") as? Double ?? 1.1
        bargeIn = d.bool(forKey: "AprilTalkBargeIn")
        liveCaptions = d.object(forKey: "AprilTalkCaptions") as? Bool ?? true
        super.init()
        synth.delegate = self
        pickVoice()
    }

    var talkLabel: String {
        convo ? (state == .speaking ? "แตะเพื่อพูดแทรก" : "แตะเพื่อจบการคุย") : "แตะเพื่อเริ่มคุย"
    }

    var micBusy: Bool { recording || monitor != nil || convo }

    private func setState(_ next: TalkState, _ text: String? = nil) {
        state = next
        detail = text
    }

    // ---- เปิด/ปิดหน้า (หน้าในแอป + หน้าต่างแยกนับรวมกัน)
    func appear() {
        viewers += 1
        if pendingWake { pendingWake = false; setConvo(true) }
    }

    func disappear() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { setConvo(false) }
    }

    /// เรียก April (คีย์ลัด / "April") -> เริ่มฟังคำสั่งทันที (ถ้าหน้ายังไม่เปิด เริ่มเมื่อเปิดเสร็จ)
    func wake() {
        NSSound(named: "Tink")?.play()
        if Date.now.timeIntervalSince(lastActivity) > 300 {      // ห่างไปนาน = เรื่องใหม่
            UserDefaults.standard.removeObject(forKey: "AprilTalkSession")
            turns = []
        }
        followUp = false
        if viewers > 0 { if !convo { setConvo(true) } } else { pendingWake = true }
    }

    // ---- บทสนทนาเสียง (ความจำเดียวกับแชท)
    private var session: String {
        if let s = UserDefaults.standard.string(forKey: "AprilTalkSession") { return s }
        let s = "voice-" + UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(s, forKey: "AprilTalkSession")
        return s
    }

    func newConversation() {
        interrupt()
        setConvo(false)
        UserDefaults.standard.removeObject(forKey: "AprilTalkSession")
        turns = []
        setState(.idle, "เริ่มบทสนทนาใหม่แล้ว")
    }

    func tap() {
        if !convo { setConvo(true); return }
        if state == .speaking { stopSpeaking(); Task { await listen() }; return }
        setConvo(false)
    }

    func setConvo(_ on: Bool) {
        convo = on
        if on {
            if !busy { Task { await listen() } }
        } else {
            if recording { endListening(send: false) }
            stopMonitor()
            stopSpeaking()
            if !busy { setState(.idle) }
            followUp = false
            onIdleMic?()
        }
    }

    func interrupt() {
        stopSpeaking()
        answerTask?.cancel()
    }

    func submitTyped() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        if recording { endListening(send: false) }
        input = ""
        send(text)
    }

    // ---- ฟัง: พูดแล้วเงียบ 0.65 วิ = จบประโยค · ไม่พูดเลย 10 วิ = พัก · ยาวสุด 30 วิ
    private func listen() async {
        guard !recording, viewers > 0 else { return }
        recording = true
        stopSpeaking()
        willUseMic?()
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            recording = false
            setState(.error, "ไม่ได้รับสิทธิ์ใช้ไมโครโฟน — เปิดที่ System Settings › Privacy & Security › Microphone")
            convo = false
            return
        }
        stopMonitor()
        let m = MicCapture()
        caption = ""
        if let req = await captionRequest() {
            m.request = req
            captionTask = TalkModel.recognizer?.recognitionTask(with: req) { [weak self] result, _ in
                guard let text = result?.bestTranscription.formattedString else { return }
                Task { @MainActor in if self?.recording == true { self?.caption = text } }
            }
        }
        do {
            try m.start { [weak self] rms in Task { @MainActor in self?.heard(rms) } }
        } catch {
            recording = false
            captionTask?.cancel()
            captionTask = nil
            setState(.error, "เปิดไมค์ไม่ได้: \(error.localizedDescription)")
            convo = false
            return
        }
        mic = m
        listenStart = .now
        floor = 0.01
        spoke = false
        lastVoice = 0
        setState(.listening, "กำลังฟัง… พูดได้เลยครับ")
    }

    private func heard(_ rms: Float) {
        guard recording, mic != nil else { return }
        let now = Date.now.timeIntervalSince(listenStart)
        if now < 0.3 { floor = max(floor, rms) }
        let loud = rms > max(0.015, floor * 2.5)
        level += (min(0.35, rms * 3) - level) * 0.5
        levels.removeFirst()
        levels.append(min(1, rms * 8))
        if loud { spoke = true; lastVoice = now }
        if (spoke && now - lastVoice > 0.65) || now > 30 { endListening(send: true) }
        else if !spoke && now > (followUp ? 5 : 8) {
            endListening(send: false)
            let wasFollowUp = followUp
            setConvo(false)
            setState(.idle, wasFollowUp ? nil : "ไม่ได้ยินเสียง — เรียกใหม่ได้ทุกเมื่อ")
        }
    }

    private func endListening(send: Bool) {
        guard recording, let m = mic else { return }
        recording = false
        mic = nil
        m.stop()
        m.request?.endAudio()
        captionTask?.cancel()
        captionTask = nil
        if !send { caption = "" }
        level = 0
        levels = [Float](repeating: 0, count: levels.count)
        guard send else { return }
        setState(.hearing)
        Task {
            do {
                let text = WakePhrase.strip(try await AppleSTT.transcribe(m.url))   // ตัด "ฮัลโหล April" ที่ขึ้นต้น
                guard !text.isEmpty else {
                    caption = ""
                    setState(.idle, "ไม่ได้ยินเสียงพูด ลองอีกครั้งครับ")
                    if convo { await listen() }
                    return
                }
                self.send(text, voice: true)
            } catch {
                caption = ""
                setState(.error, "แปลงเสียงไม่ได้: \(error.localizedDescription)")
                setConvo(false)
            }
        }
    }

    // ---- คิด: ส่งให้ April แล้ว stream คำตอบ
    private func send(_ text: String, voice: Bool = false) {
        guard !busy else { return }
        caption = ""
        turns.append(TalkTurn(me: true, text: text))
        turns.append(TalkTurn(me: false, text: ""))
        if turns.count > 16 { turns.removeFirst(turns.count - 16) }
        let speak = voice || speakTyped
        busy = true
        setState(.thinking)
        if speak { startSpeaking() }
        let api = backend.api, session = session
        lastActivity = .now
        answerTask = Task {
            var streamed = "", answer = ""
            do {
                for try await ev in api.chat(text, session: session, voice: voice || speakTyped) {
                    switch ev.str("type") {
                    case "token":
                        streamed += ev.str("text") ?? ""
                        setLast(streamed)
                        if state == .thinking { detail = nil }
                        if speak { feed(streamed) }
                    case "tool_call" where streamed.isEmpty:
                        let name = ev.str("name") ?? ""
                        detail = "\(ToolsTab.labels[name] ?? name)…"
                    case "revision":
                        streamed = ""
                        if speak { startSpeaking() }
                    case "error":
                        answer = "ขอโทษครับ มีปัญหา: \(ev.str("message") ?? "")"
                    case "done":
                        if let t = ev.str("text"), !t.isEmpty { answer = t }
                    default: break
                    }
                }
            } catch {
                if !Task.isCancelled { answer = "ส่งไม่สำเร็จ: \(error.localizedDescription)" }
            }
            if answer.isEmpty { answer = streamed.isEmpty ? (Task.isCancelled ? "หยุดแล้ว" : "(ไม่มีคำตอบ)") : streamed }
            setLast(answer)
            if speak && !Task.isCancelled { finishSpeaking(answer, streamed: streamed) }
            busy = false
            if !speakingNow { setState(.idle); afterAnswer() }
        }
    }

    private func setLast(_ text: String) {
        guard let i = turns.indices.last else { return }
        turns[i].text = text
    }

    private func afterAnswer() {
        lastActivity = .now
        followUp = true
        if viewers > 0, convo, !recording, !busy { Task { await listen() } }
        else if !convo { onIdleMic?() }
    }

    // ---- คำบรรยายสด: Apple Speech บนเครื่องเท่านั้น
    private func captionRequest() async -> SFSpeechAudioBufferRecognitionRequest? {
        guard liveCaptions, let r = TalkModel.recognizer, r.supportsOnDeviceRecognition else { return nil }
        guard await AppleSTT.authorize() else { return nil }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        return req
    }

    // ---- พูดแทรกด้วยเสียง: เปิดไมค์แบบตัดเสียงสะท้อน ดังต่อเนื่อง ~0.2 วิ = ผู้ใช้พูดแทรก
    private func startMonitor() {
        guard bargeIn, convo, monitor == nil, viewers > 0 else { return }
        let m = MicCapture(record: false, voiceProcessing: true)
        do { try m.start { [weak self] rms in Task { @MainActor in self?.heardWhileSpeaking(rms) } } } catch { return }
        monitor = m
        monitorStart = .now
        monitorFloor = 0
        loudRun = 0
    }

    private func stopMonitor() {
        monitor?.stop()
        monitor = nil
    }

    private func heardWhileSpeaking(_ rms: Float) {
        guard monitor != nil, state == .speaking else { return }
        let t = Date.now.timeIntervalSince(monitorStart)
        if t < 0.5 { monitorFloor = max(monitorFloor, rms); return }
        loudRun = rms > max(0.03, monitorFloor * 3) ? loudRun + 1 : 0
        if loudRun >= 8 {
            stopMonitor()
            stopSpeaking()
            Task { await listen() }
        }
    }

    // ---- พูด: อ่านท่อนที่ครบระหว่าง stream
    private var speakingNow: Bool { pending > 0 || synth.isSpeaking }

    private func pickVoice() {
        let all = TalkModel.thaiVoices
        voice = all.first { $0.identifier == voiceID } ?? all.first ?? AVSpeechSynthesisVoice(language: "th-TH")
    }

    static var thaiVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("th") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    func preview() { startSpeaking(); say("สวัสดีครับบอส April พร้อมรับใช้ครับ") }

    private func startSpeaking() { stopSpeaking(); spoken = 0 }

    func stopSpeaking() {
        pending = 0
        onIdle = nil
        synth.stopSpeaking(at: .immediate)
    }

    private func say(_ raw: String) {
        let words = TalkModel.clean(raw)
        guard !words.isEmpty else { return }
        let u = AVSpeechUtterance(string: words)
        u.voice = voice
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate))
        u.pitchMultiplier = 1.05
        pending += 1
        synth.speak(u)
    }

    private func feed(_ full: String) {
        let rest = Array(full.dropFirst(spoken))
        let first = spoken == 0, minCut = first ? 10 : 20
        let nl = rest.lastIndex(of: "\n") ?? -1
        let sp = rest.count >= (first ? 16 : 40) ? (rest.lastIndex(of: " ") ?? -1) : -1
        let cut = max(nl, sp)
        if cut < minCut && !(cut >= 0 && rest[cut] == "\n") { return }
        say(String(rest[..<cut]))
        spoken += cut
    }

    /// คำตอบฉบับสุดท้ายอาจต่างจากที่ stream (ตรวจแล้วแก้) — ต่างตั้งแต่ต้นให้พูดใหม่ทั้งหมด
    private func finishSpeaking(_ answer: String, streamed: String) {
        if spoken == 0 || !answer.hasPrefix(String(streamed.prefix(spoken))) {
            if spoken > 0 { stopSpeaking() }
            say(answer)
        } else {
            say(String(answer.dropFirst(spoken)))
        }
        spoken = answer.count
        onIdle = { [weak self] in self?.afterAnswer() }
    }

    private func utteranceEnded() {
        pending = max(0, pending - 1)
        guard pending == 0, !synth.isSpeaking else { return }
        stopMonitor()
        if !busy && !recording { setState(.idle) }
        let cb = onIdle
        onIdle = nil
        cb?()
    }

    static func clean(_ s: String) -> String {
        var t = s
        for (pattern, with) in [("```[\\s\\S]*?```", " (มีโค้ดอยู่บนหน้าจอ) "), ("`([^`]*)`", "$1"),
                                ("\\[([^\\]]+)\\]\\([^)]+\\)", "$1"), ("https?://\\S+", " "),
                                ("(?m)^\\s*\\|?[\\s:|-]+\\|?\\s*$", " "), ("[|*_#>~]", " "), ("(?m)^\\s*[-•]\\s+", ""),
                                ("[\\x{1F300}-\\x{1FAFF}\\x{2600}-\\x{27BF}\\x{FE0F}]", ""), ("\\s+", " ")] {
            t = t.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.recording else { return }
            self.setState(.speaking)
            self.startMonitor()
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) {
        Task { @MainActor in self.pulseAt = Date.now.timeIntervalSinceReferenceDate }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }
}

// MARK: - ไมค์ (audio thread) — อัดเป็น wav + ส่งความดังกลับทุก buffer

final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private let record: Bool
    private let voiceProcessing: Bool
    var request: SFSpeechAudioBufferRecognitionRequest?
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("april-talk.wav")

    init(record: Bool = true, voiceProcessing: Bool = false) {
        self.record = record
        self.voiceProcessing = voiceProcessing
    }

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw APIError(message: "ไม่พบไมโครโฟน") }
        guard record else {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in onLevel(MicCapture.rms(buf)) }
            engine.prepare()
            try engine.start()
            return
        }
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            try? self?.file?.write(from: buf)
            self?.request?.append(buf)
            onLevel(MicCapture.rms(buf))
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); file = nil; throw error }
    }

    static func rms(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return 0 }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return (sum / Float(n)).squareRoot()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }
}

// MARK: - ถอดเสียงไทยด้วย Apple Speech

enum AppleSTT {
    private final class Once: @unchecked Sendable { var done = false }

    static func authorize() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func transcribe(_ url: URL) async throws -> String {
        guard await authorize() else {
            throw APIError(message: "ไม่ได้รับสิทธิ์รู้จำเสียง — เปิดที่ System Settings › Privacy & Security › Speech Recognition")
        }
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: "th-TH")), r.isAvailable else {
            throw APIError(message: "เครื่องนี้ถอดเสียงภาษาไทยไม่ได้ตอนนี้ (ต้องต่อเน็ต หรือเปิด Siri/Dictation ภาษาไทย)")
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        req.requiresOnDeviceRecognition = r.supportsOnDeviceRecognition
        let once = Once()
        return try await withCheckedThrowingContinuation { c in
            r.recognitionTask(with: req) { result, error in
                guard !once.done else { return }
                if let result, result.isFinal {
                    once.done = true
                    c.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    once.done = true
                    if (error as NSError).code == 1110 { c.resume(returning: "") } else { c.resume(throwing: error) }
                }
            }
        }
    }
}

