// Talk.swift — คุยด้วยเสียงแบบ JARVIS (พอร์ตจาก Envy Apple/Sources/Talk.swift)
//   ฟัง:  ไมค์ (AVAudioEngine) จับเงียบเองว่าพูดจบ -> ถอดเสียงไทยด้วย Apple Speech (บนเครื่องถ้าเครื่องรองรับ)
//   คิด:  POST /chat (voice=true -> April ตอบสั้นแบบภาษาพูด) บทสนทนา "voice-…" แยกจากแชท แต่ความจำเดียวกัน
//   พูด:  AVSpeechSynthesizer เสียงไทย อ่านทีละท่อนระหว่าง stream — แกนอนุภาคพองตามจังหวะคำ
//   คุยต่อเนื่อง: April พูดจบ -> ฟังต่อเอง · แตะระหว่างพูด = พูดแทรก · Esc = หยุด
//   เรียกด้วยเสียง: WakeWord.swift ได้ยิน "April" -> เปิดหน้านี้แล้วเริ่มฟังทันที (wake())
// ต่างจาก Envy: ไม่มี Whisper บนเซิร์ฟเวอร์ (April ไม่มี endpoint เสียง) · มี wake word · HUD เป็น A.P.R.I.L

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

    /// เรียกเมื่อเลิกคุย (ไมค์ว่าง) — WakeWord กลับไปรอฟังคำว่า "April"
    @ObservationIgnored var onIdleMic: (() -> Void)?
    /// เรียกก่อนเปิดไมค์ — WakeWord ต้องปล่อยไมค์ก่อน
    @ObservationIgnored var willUseMic: (() -> Void)?

    private let chat: ChatModel
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

    init(chat: ChatModel) {
        self.chat = chat
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

    /// ได้ยิน "April" (WakeWord) -> เริ่มฟังคำสั่งทันที (ถ้าหน้ายังไม่เปิด เริ่มเมื่อเปิดเสร็จ)
    func wake() {
        NSSound(named: "Tink")?.play()
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
        else if !spoke && now > 10 {
            endListening(send: false)
            setConvo(false)
            setState(.idle, "ไม่ได้ยินเสียง — พักไว้ก่อน เรียก \"April\" หรือแตะเพื่อคุยต่อ")
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
                let text = try await AppleSTT.transcribe(m.url)
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
        let api = chat.api, session = session, model = chat.model
        answerTask = Task {
            var streamed = "", answer = ""
            do {
                for try await ev in api.chat(text, session: session, model: model, voice: voice || speakTyped) {
                    switch ev.str("type") {
                    case "token":
                        streamed += ev.str("text") ?? ""
                        setLast(streamed)
                        if state == .thinking { detail = nil }
                        if speak { feed(streamed) }
                    case "tool_call" where streamed.isEmpty:
                        let name = ev.str("name") ?? ""
                        detail = "\(ChatModel.toolLabels[name] ?? name)…"
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

// MARK: - HUD: วงแหวนแบบ JARVIS + แกนอนุภาค 900 จุดที่เปลี่ยนรูปตามเสียง (จาก Envy)

final class TalkFace {
    static let epoch = Date.now
    var pointer: CGPoint?
    var pointerAt = 0.0
    private var energy = 0.0, spin = 0.0, morph = 0.0, tiltX = 0.0, tiltY = 0.0, pulse = 0.0, seenPulse = 0.0, last = 0.0
    private var main: [Double] = [255, 170, 70], hot: [Double] = [255, 230, 190]

    private static let points: [(x: Double, y: Double, z: Double, s: Double)] = (0..<900).map { i in
        let y = 1 - Double(i) / 899 * 2, r = (1 - y * y).squareRoot(), a = Double(i) * 2.399963
        return (cos(a) * r, y, sin(a) * r, Double.random(in: 0..<1))
    }
    // April = โทนทองอำพันแบบ FRIDAY (Envy เป็นฟ้า)
    private static let palette: [TalkState: ([Double], [Double])] = [
        .idle: ([255, 170, 70], [255, 230, 190]), .speaking: ([255, 190, 90], [255, 245, 220]),
        .listening: ([90, 230, 255], [215, 250, 255]), .thinking: ([200, 140, 255], [235, 215, 255]),
        .hearing: ([200, 140, 255], [235, 215, 255]), .error: ([255, 85, 85], [255, 205, 195]),
    ]

    private func c(_ v: [Double], _ a: Double) -> Color {
        Color(.sRGB, red: v[0] / 255, green: v[1] / 255, blue: v[2] / 255, opacity: max(0, min(1, a)))
    }
    private func mix(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }

    private func field(_ x: Double, _ y: Double, _ z: Double, _ t: Double, _ k: Double) -> Double {
        sin(x * 2.1 + t * 1.3) * sin(y * 2.7 - t * 0.9) * 0.5 + sin(z * 3.3 + t * 1.7 + x * 1.5) * 0.3
            + sin((x + y - z) * k + t * 2.2) * 0.2
    }

    private func arc(_ c: CGPoint, _ r: Double, _ a0: Double, _ a1: Double) -> Path {
        var p = Path()
        let steps = max(6, min(360, Int(abs(a1 - a0) * r / 5)))
        for i in 0...steps {
            let a = a0 + (a1 - a0) * Double(i) / Double(steps)
            let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }

    private func ring(_ g: GraphicsContext, _ ctr: CGPoint, _ r: Double, _ a0: Double, _ a1: Double, _ w: Double,
                      _ color: Color, dash: [CGFloat] = []) {
        g.stroke(arc(ctr, r, a0, a1), with: .color(color), style: StrokeStyle(lineWidth: w, dash: dash))
    }

    func draw(_ g: inout GraphicsContext, size: CGSize, t: Double, state: TalkState, level: Float, levels: [Float],
              pulseAt: Double, link: String) {
        let dt = last == 0 ? 0 : min(0.05, max(0, t - last))
        last = t
        let W = size.width, H = size.height, ctr = CGPoint(x: W / 2, y: H / 2), R = min(W, H) * 0.19
        let speaking = state == .speaking, listening = state == .listening
        let thinking = state == .thinking || state == .hearing

        if pulseAt > seenPulse { seenPulse = pulseAt; pulse = 1 }
        pulse *= pow(0.02, dt)
        let voice = speaking ? 0.3 + 0.45 * abs(sin(t * 12)) * (0.5 + pulse) + 0.35 * pulse : 0
        let target = speaking ? voice : listening ? 0.12 + Double(level) * 2.4 : thinking ? 0.5 : 0.1
        energy = mix(energy, min(1.25, target), 1 - pow(0.0005, dt))
        spin += (thinking ? 2.2 : speaking ? 0.9 : listening ? 0.6 : 0.3) * dt
        morph += (thinking ? 2.8 : 0.7 + energy * 2.2) * dt
        let p = TalkFace.palette[state] ?? TalkFace.palette[.idle]!, k = 1 - pow(0.02, dt)
        main = zip(main, p.0).map { mix($0, $1, k) }
        hot = zip(hot, p.1).map { mix($0, $1, k) }

        if let ptr = pointer, t - pointerAt < 2.5 {
            tiltX = mix(tiltX, (ptr.y - ctr.y) / H * 0.8, 0.05)
            tiltY = mix(tiltY, (ptr.x - ctr.x) / W * 0.8, 0.05)
        } else {
            tiltX = mix(tiltX, 0.35 * sin(t * 0.3), 0.05)
            tiltY = mix(tiltY, 0, 0.05)
        }

        g.blendMode = .normal
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(.sRGB, red: 8 / 255, green: 6 / 255, blue: 4 / 255)))
        var grid = Path()
        var x = ctr.x.truncatingRemainder(dividingBy: 40)
        while x < W { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: H)); x += 40 }
        var y = ctr.y.truncatingRemainder(dividingBy: 40)
        while y < H { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: W, y: y)); y += 40 }
        g.stroke(grid, with: .color(c(main, 0.05)), lineWidth: 1)
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(colors: [c(main, 0.10 + energy * 0.12), .black.opacity(0.6)]),
            center: ctr, startRadius: R * 0.5, endRadius: max(W, H) * 0.7))

        g.blendMode = .plusLighter

        ring(g, ctr, R * 2.15, 0, .pi * 2, 1, c(main, 0.22))
        var long = Path(), short = Path()
        for i in 0..<120 {
            let a = Double(i) / 120 * .pi * 2 - spin * 0.25, isLong = i % 10 == 0
            let r0 = R * 1.95, r1 = r0 + R * (isLong ? 0.12 : 0.05)
            let from = CGPoint(x: ctr.x + cos(a) * r0, y: ctr.y + sin(a) * r0), to = CGPoint(x: ctr.x + cos(a) * r1, y: ctr.y + sin(a) * r1)
            if isLong { long.move(to: from); long.addLine(to: to) } else { short.move(to: from); short.addLine(to: to) }
        }
        g.stroke(long, with: .color(c(main, 0.6)), lineWidth: 1.6)
        g.stroke(short, with: .color(c(main, 0.25)), lineWidth: 1)
        for q in 0..<4 {
            let a = Double(q) * .pi / 2 + .pi / 4
            ring(g, ctr, R * 2.3, a - 0.12, a + 0.12, 2.5, c(hot, 0.55))
        }

        let r1 = spin * 0.9, r2 = r1 - spin * 2.3, r3 = r2 + spin * 3.1
        for s in 0..<3 { ring(g, ctr, R * 1.72, r1 + Double(s) * 2.094, r1 + Double(s) * 2.094 + 1.5, R * 0.035, c(main, 0.5)) }
        ring(g, ctr, R * 1.55, r2, r2 + .pi * 2, R * 0.05, c(main, 0.35), dash: [2, 7])
        ring(g, ctr, R * 1.85, r3, r3 + 0.5 + energy * 1.2, 2, c(hot, 0.7))
        ring(g, ctr, R * 1.85, r3 + .pi, r3 + .pi + 0.3, 2, c(hot, 0.5))

        if thinking {
            let a = spin * 3.5
            for i in 0..<18 {
                ring(g, ctr, R * 1.3, a - Double(i) * 0.04, a - Double(i) * 0.04 + 0.04, R * 0.5, c(hot, 0.35 * (1 - Double(i) / 18)))
            }
            ring(g, ctr, R * 1.42, a * 1.7, a * 1.7 + 1.1, 3, c(hot, 0.8))
        }

        let bars = 96
        for i in 0..<bars {
            let v: Double
            if listening {
                let idx = min(levels.count - 1, i < bars / 2 ? i : bars - i)
                v = Double(levels[levels.count - 1 - idx])
            } else if speaking {
                v = energy * (0.35 + 0.65 * abs(sin(Double(i) * 0.45 + t * 9) * sin(Double(i) * 0.13 - t * 5)))
            } else {
                v = 0.04 + 0.03 * sin(Double(i) * 0.3 + t * 2)
            }
            let a = Double(i) / Double(bars) * .pi * 2 - .pi / 2, b0 = R * 1.22, b1 = b0 + R * (0.03 + v * 0.42)
            var bar = Path()
            bar.move(to: CGPoint(x: ctr.x + cos(a) * b0, y: ctr.y + sin(a) * b0))
            bar.addLine(to: CGPoint(x: ctr.x + cos(a) * b1, y: ctr.y + sin(a) * b1))
            g.stroke(bar, with: .color(c(v > 0.5 ? hot : main, 0.3 + v * 0.7)), lineWidth: max(1.5, R * 0.022))
        }

        let yaw = spin * 0.8 + tiltY, pitch = tiltX
        let cyw = cos(yaw), syw = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        let amp = 0.17 + energy * 0.4, freq = 2.6 + energy * 3
        let scale = R * (0.95 + energy * 0.12 + 0.02 * sin(t * 1.7))
        var dots = [[Path]](repeating: [Path](repeating: Path(), count: 8), count: 2)
        for pt in TalkFace.points {
            let d = 1 + amp * field(pt.x, pt.y, pt.z, morph, freq) + (thinking ? 0.08 * sin(pt.y * 9 + morph * 4) : 0)
            let x = pt.x * d, y = pt.y * d, z = pt.z * d
            let x1 = x * cyw - z * syw, z1 = x * syw + z * cyw
            let y2 = y * cp - z1 * sp, z2 = y * sp + z1 * cp
            let persp = 2.4 / (2.4 - z2)
            let front = max(0, min(0.999, (z2 + 1.4) / 2.8))
            let size = (0.7 + front * 1.6) * (0.7 + pt.s * 0.6) * max(0.8, R / 150)
            let px = ctr.x + x1 * scale * persp, py = ctr.y + y2 * scale * persp
            dots[d > 1 + amp * 0.55 ? 1 : 0][Int(front * 8)].addRect(CGRect(x: px - size / 2, y: py - size / 2, width: size, height: size))
        }
        for h in 0..<2 {
            for b in 0..<8 { g.fill(dots[h][b], with: .color(c(h == 1 ? hot : main, 0.18 + (Double(b) + 0.5) / 8 * 0.62))) }
        }
        let coreR = R * (0.85 + energy * 0.5)
        g.fill(Path(ellipseIn: CGRect(x: ctr.x - coreR, y: ctr.y - coreR, width: coreR * 2, height: coreR * 2)), with: .radialGradient(
            Gradient(stops: [.init(color: c(hot, 0.55 + energy * 0.3), location: 0),
                             .init(color: c(main, 0.22 + energy * 0.2), location: 0.35),
                             .init(color: c(main, 0), location: 1)]),
            center: ctr, startRadius: 0, endRadius: coreR))

        g.blendMode = .normal
        let fs = max(10, min(13, W / 70)), m = 18.0
        func label(_ s: String, _ color: Color, _ at: CGPoint, _ anchor: UnitPoint) {
            g.draw(Text(s).font(.system(size: fs, weight: .semibold, design: .monospaced)).foregroundColor(color), at: at, anchor: anchor)
        }
        let clock = Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        label("A.P.R.I.L  //  \(state.hud)", c(hot, 0.85), CGPoint(x: m, y: m), .topLeading)
        label(String(format: "CORE %03d%%   LINK %@", Int(energy * 100), link), c(main, 0.6), CGPoint(x: m, y: m + 18), .topLeading)
        label(clock, c(hot, 0.85), CGPoint(x: W - m, y: m), .topTrailing)
        label(String(format: "ROT %05.1f°", (spin * 57.3).truncatingRemainder(dividingBy: 360)), c(main, 0.6),
              CGPoint(x: W - m, y: m + 18), .topTrailing)
        var corners = Path()
        let cl = 22.0
        for (px, py, sx, sy) in [(8.0, 8.0, 1.0, 1.0), (W - 8, 8, -1, 1), (8, H - 8, 1, -1), (W - 8, H - 8, -1, -1)] {
            corners.move(to: CGPoint(x: px, y: py + sy * cl))
            corners.addLine(to: CGPoint(x: px, y: py))
            corners.addLine(to: CGPoint(x: px + sx * cl, y: py))
        }
        g.stroke(corners, with: .color(c(main, 0.55)), lineWidth: 2)
    }
}

struct TalkHUD: View {
    @Environment(TalkModel.self) private var talk
    @Environment(ChatModel.self) private var chat
    @ViewState private var face = TalkFace()

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { g, size in
                face.draw(&g, size: size, t: tl.date.timeIntervalSince(TalkFace.epoch), state: talk.state, level: talk.level,
                          levels: talk.levels, pulseAt: talk.pulseAt - TalkFace.epoch.timeIntervalSinceReferenceDate,
                          link: chat.model.uppercased())
            }
        }
        .onContinuousHover { phase in
            if case .active(let p) = phase { face.pointer = p; face.pointerAt = Date.now.timeIntervalSince(TalkFace.epoch) }
        }
    }
}

// MARK: - หน้าคุยด้วยเสียง

struct TalkPage: View {
    @Environment(TalkModel.self) private var talk
    @Environment(WakeWord.self) private var wake
    @ViewState private var settings = false

    static let glow = Color(.sRGB, red: 1, green: 0.72, blue: 0.32)

    var body: some View {
        @Bindable var talk = talk
        ZStack {
            TalkHUD()
                .contentShape(Rectangle())
                .onTapGesture { talk.tap() }
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    if wake.enabled {
                        Label(wake.listening ? "รอฟัง \"April\"" : "wake word พัก", systemImage: "ear")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    hudButton("plus.bubble", "บทสนทนาใหม่") { talk.newConversation() }
                    hudButton("slider.horizontal.3", "ตั้งค่าเสียง") { settings.toggle() }
                        .popover(isPresented: $settings, arrowEdge: .bottom) { TalkSettings().environment(talk).environment(wake) }
                }
                .padding(.top, 14).padding(.horizontal, 18)
                Spacer()
                TalkTranscript(turns: talk.turns)
                if !talk.caption.isEmpty {
                    Text("“\(talk.caption)”").font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).lineLimit(3).frame(maxWidth: 560)
                }
                Text(talk.detail ?? talk.state.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(talk.state == .error ? Color(.sRGB, red: 1, green: 0.5, blue: 0.45) : .white.opacity(0.8))
                    .lineLimit(2).multilineTextAlignment(.center)
                Button { talk.tap() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: talk.convo ? "waveform" : "mic.fill")
                            .symbolEffect(.variableColor, isActive: talk.state == .listening)
                        Text(talk.talkLabel)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(talk.convo ? .black : TalkPage.glow)
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(talk.convo ? TalkPage.glow : TalkPage.glow.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(TalkPage.glow.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("⌘↩")
                HStack(spacing: 8) {
                    TextField("หรือพิมพ์คุยกับ April…", text: $talk.input)
                        .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(.white)
                        .onSubmit { talk.submitTyped() }
                    if talk.busy || talk.state == .speaking {
                        Button { talk.interrupt(); talk.setConvo(false) } label: {
                            Image(systemName: "stop.fill").font(.system(size: 10)).foregroundStyle(.black)
                                .frame(width: 24, height: 24).background(.white.opacity(0.85), in: Circle())
                        }
                        .buttonStyle(.plain).help("หยุด (Esc)")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.white.opacity(0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                .frame(maxWidth: 520)
                Text("ถอดเสียงด้วย Apple Speech บนเครื่องนี้ · แตะวงแหวนเพื่อคุย · Esc หยุด")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 24).padding(.bottom, 22)
        }
        .background(Color(.sRGB, red: 8 / 255, green: 6 / 255, blue: 4 / 255))
        .environment(\.colorScheme, .dark)
        .background {
            Button("") { talk.interrupt(); talk.setConvo(false) }
                .keyboardShortcut(.escape, modifiers: []).opacity(0).frame(width: 0, height: 0)
        }
        // appear()/disappear() เรียกจาก TalkWindow (หน้าต่างแยก) ตอนเปิด/ปิดหน้าต่าง
    }

    private func hudButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                .frame(width: 30, height: 30).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
        }
        .buttonStyle(.plain).help(help)
    }
}

struct TalkTranscript: View {
    let turns: [TalkTurn]

    var body: some View {
        if !turns.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(turns) { t in
                            if t.me {
                                HStack {
                                    Spacer(minLength: 60)
                                    Text(t.text).font(.system(size: 13.5)).foregroundStyle(.white)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                }
                            } else {
                                Text(markdown(t.text.isEmpty ? "…" : t.text))
                                    .font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.92)).textSelection(.enabled)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(14)
                }
                .onChange(of: turns.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(maxWidth: 640, maxHeight: 230)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
        }
    }
}

struct TalkSettings: View {
    @Environment(TalkModel.self) private var talk
    @Environment(WakeWord.self) private var wake

    var body: some View {
        @Bindable var talk = talk
        @Bindable var wake = wake
        let voices = TalkModel.thaiVoices
        Form {
            Toggle("เรียกด้วยเสียง \"April\" (ฟังบนเครื่องนี้เท่านั้น)", isOn: $wake.enabled)
            if let problem = wake.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            Picker("เสียง", selection: $talk.voiceID) {
                if voices.isEmpty { Text("ไม่มีเสียงภาษาไทยในเครื่องนี้").tag("") }
                if !voices.contains(where: { $0.identifier == talk.voiceID }) && !voices.isEmpty {
                    Text("อัตโนมัติ").tag(talk.voiceID)
                }
                ForEach(voices, id: \.identifier) { v in
                    Text(v.name + (v.quality == .premium ? " (พรีเมียม)" : v.quality == .enhanced ? " (คุณภาพสูง)" : ""))
                        .tag(v.identifier)
                }
            }
            HStack {
                Text("ความเร็ว")
                Slider(value: $talk.rate, in: 0.8...1.6, step: 0.05)
                Text(String(format: "%.2f×", talk.rate)).monospacedDigit().frame(width: 44)
            }
            Toggle("อ่านออกเสียงเมื่อพิมพ์ถาม", isOn: $talk.speakTyped)
            Toggle("คำบรรยายสดระหว่างพูด (ถอดบนเครื่อง)", isOn: $talk.liveCaptions)
            Toggle("พูดแทรกด้วยเสียงได้ (ใส่หูฟังจะแม่นที่สุด)", isOn: $talk.bargeIn)
            HStack {
                Button("ลองฟังเสียง") { talk.preview() }
                Spacer()
                Button("เพิ่มเสียงไทย…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                }
                .help("System Settings › Accessibility › Spoken Content › System Voice › Manage Voices")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
    }
}
