// Vision.swift — ตาของ April: กล้องของ Mac + ตรวจจับบนเครื่อง แล้วส่งให้ backend (april/vision.py)
//
//   CameraEngine (คิวของกล้อง — ทุกอย่างบนเครื่อง ไม่มีอะไรออกเน็ต):
//     · การเคลื่อนไหว ~10 ครั้ง/วิ: ย่อภาพเป็นขาวดำ 32×18 เทียบเฟรมก่อน (หักแสงที่เปลี่ยนทั้งภาพออก) = สัดส่วนที่ขยับ
//     · ตรวจจับ ~5 ครั้ง/วิ: Apple Vision — คน (ครึ่งตัวบน), ใบหน้า, แมว/สุนัข
//       + โมเดล Core ML ที่ใส่เอง (เช่น YOLO) ใน <April>/data/vision/ = ตรวจวัตถุได้ทุกชนิดที่โมเดลรู้จัก
//     · จัดฉาก ~ทุก 2 วิ: VNClassifyImageRequest (ป้ายฉาก/สิ่งของ ~1,300 แบบ)
//   VisionModel (main):
//     · โหมด ปิด / เมื่อ April ต้องมอง (เปิดกล้องตอน look หรือมีสิ่งที่เฝ้าดู แล้วปิดเอง) / เปิดตลอด (เรียลไทม์)
//     · ส่งผลตรวจจับ + JPEG ล่าสุดไป /api/vision/frame ทุก 1 วิ
//     · แปลงผลตรวจจับเป็นเหตุการณ์ -> /api/vision/event: คนมา/ไป, ขยับตอนไม่มีคน, สัตว์, วัตถุใหม่
//     · พูดสิ่งที่ backend ส่งกลับ (เจอสิ่งที่เฝ้าดู, แจ้งเหตุการณ์, ทักทายตอนกลับมา) ผ่าน Dynamic Island
//   ภาพไม่ถูกบันทึกลงดิสก์ · ไฟเขียวข้างกล้องติดเสมอเมื่อเปิด (ฮาร์ดแวร์) · ไอคอน menu bar เป็นรูปตาเมื่อกล้องเปิด

import AVFoundation
import AppKit
import CoreImage
import CoreML
import ImageIO
import Observation
import Vision

struct Detection: Identifiable, @unchecked Sendable {
    enum Kind: String { case person, face, animal, object }
    let id = UUID()
    let kind: Kind
    let label: String
    let confidence: Float
    let box: CGRect            // 0–1 พิกัดของ Vision (จุดเริ่มซ้ายล่าง)
}

struct VisionTick: @unchecked Sendable {
    var detections: [Detection]
    var scene: [String]?       // nil = รอบนี้ไม่ได้จัดฉาก
    var motion: Float
    var preview: CGImage?
    var jpeg: Data?
    var size: CGSize
}

// MARK: - กล้อง + ตรวจจับ (คิวของกล้อง)

final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "april.camera", qos: .userInitiated)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var wantJPEG = false
    private var wantPreview = false
    private var prevGray: [UInt8] = []
    private var motion: Float = 0
    private var lastMotion: CFTimeInterval = 0
    private var lastDetect: CFTimeInterval = 0
    private var lastScene: CFTimeInterval = 0
    private let custom: VNCoreMLModel?
    var onTick: (@Sendable (VisionTick) -> Void)?

    private let humans: VNDetectHumanRectanglesRequest = {
        let r = VNDetectHumanRectanglesRequest()
        r.upperBodyOnly = true                    // กล้องหน้าจอเห็นแค่ครึ่งตัวบนเป็นปกติ
        return r
    }()
    private let faces = VNDetectFaceRectanglesRequest()
    private let animals = VNRecognizeAnimalsRequest()
    private let classify = VNClassifyImageRequest()
    private lazy var customRequest: VNCoreMLRequest? = custom.map {
        let r = VNCoreMLRequest(model: $0)
        r.imageCropAndScaleOption = .scaleFill
        return r
    }

    init(custom: VNCoreMLModel?) {
        self.custom = custom
    }

    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    /// ขอให้รอบตรวจจับถัดไปแนบ JPEG (ส่ง backend) / ภาพย่อ (แสดงในแท็บ)
    func request(jpeg: Bool, preview: Bool) {
        lock.lock()
        if jpeg { wantJPEG = true }
        wantPreview = preview
        lock.unlock()
    }

    /// บล็อกจนกล้องเปิด — เรียกนอก main thread
    func start(deviceID: String) throws {
        let device = CameraEngine.cameras.first { $0.uniqueID == deviceID }
            ?? AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video)
        guard let device else { throw APIError(message: "ไม่พบกล้องในเครื่องนี้") }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw APIError(message: "เปิดกล้อง \(device.localizedName) ไม่ได้ (แอปอื่นใช้อยู่?)") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw APIError(message: "อ่านภาพจากกล้องไม่ได้") }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
        onTick = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
        let now = CACurrentMediaTime()
        let image = CIImage(cvPixelBuffer: pb)
        if now - lastMotion >= 0.1 {
            lastMotion = now
            motion = measureMotion(image)
        }
        guard now - lastDetect >= 0.2 else { return }
        lastDetect = now
        let sceneDue = now - lastScene >= 2
        if sceneDue { lastScene = now }
        let (detections, scene) = detect(pb, scene: sceneDue)

        lock.lock()
        let jpegNow = wantJPEG, previewNow = wantPreview
        wantJPEG = false
        lock.unlock()
        var tick = VisionTick(detections: detections, scene: scene, motion: motion, size: image.extent.size)
        if jpegNow { tick.jpeg = encodeJPEG(image) }
        if previewNow {
            let s = min(1, 640 / image.extent.width)
            tick.preview = ci.createCGImage(image.transformed(by: CGAffineTransform(scaleX: s, y: s)),
                                            from: CGRect(x: 0, y: 0, width: (image.extent.width * s).rounded(.down),
                                                         height: (image.extent.height * s).rounded(.down)))
        }
        onTick?(tick)
    }

    /// สัดส่วนพื้นที่ภาพที่เปลี่ยนจากเฟรมก่อน (0–1) — หักค่าความสว่างเฉลี่ยที่เปลี่ยนทั้งภาพ (กล้องปรับแสงเอง) ออกก่อน
    private func measureMotion(_ image: CIImage) -> Float {
        let w = 32, h = 18
        let sy = CGFloat(h) / image.extent.height, sx = CGFloat(w) / image.extent.width
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": sy, "inputAspectRatio": sx / sy])
        var gray = [UInt8](repeating: 0, count: w * h)
        ci.render(small, toBitmap: &gray, rowBytes: w,
                  bounds: CGRect(x: small.extent.minX.rounded(.down), y: small.extent.minY.rounded(.down), width: CGFloat(w), height: CGFloat(h)),
                  format: .L8, colorSpace: nil)
        defer { prevGray = gray }
        guard prevGray.count == gray.count else { return 0 }
        let shift = (gray.reduce(0) { $0 + Int($1) } - prevGray.reduce(0) { $0 + Int($1) }) / gray.count
        var changed = 0
        for i in 0..<gray.count where abs(Int(gray[i]) - Int(prevGray[i]) - shift) > 22 { changed += 1 }
        return Float(changed) / Float(gray.count)
    }

    private func detect(_ pb: CVPixelBuffer, scene: Bool) -> ([Detection], [String]?) {
        var requests: [VNRequest] = [humans, faces, animals]
        if let c = customRequest { requests.append(c) }
        if scene { requests.append(classify) }
        do { try VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up).perform(requests) } catch { return ([], nil) }

        var out: [Detection] = []
        for o in humans.results ?? [] where o.confidence > 0.5 {
            out.append(Detection(kind: .person, label: "person", confidence: o.confidence, box: o.boundingBox))
        }
        for o in faces.results ?? [] where o.confidence > 0.5 {
            out.append(Detection(kind: .face, label: "face", confidence: o.confidence, box: o.boundingBox))
        }
        for o in animals.results ?? [] {
            guard let l = o.labels.first, l.confidence > 0.5 else { continue }
            out.append(Detection(kind: .animal, label: l.identifier.lowercased(), confidence: l.confidence, box: o.boundingBox))
        }
        var labels: [String]? = nil
        if let c = customRequest {
            for o in c.results ?? [] {
                if let obj = o as? VNRecognizedObjectObservation, let l = obj.labels.first, l.confidence > 0.45 {
                    out.append(Detection(kind: .object, label: l.identifier, confidence: l.confidence, box: obj.boundingBox))
                } else if let cls = o as? VNClassificationObservation, cls.confidence > 0.5 {
                    labels = (labels ?? []) + [cls.identifier]     // โมเดลจัดประเภททั้งภาพ -> นับเป็นป้ายฉาก
                }
            }
        }
        if scene {
            let top = (classify.results ?? []).filter { $0.confidence > 0.3 }.prefix(6).map(\.identifier)
            labels = (labels ?? []) + top
        }
        return (out, labels)
    }

    private func encodeJPEG(_ image: CIImage) -> Data? {
        let s = min(1, 1024 / image.extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ci.jpegRepresentation(of: scaled, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [key: 0.6])
    }

    /// โมเดล Core ML ที่ผู้ใช้ใส่เอง (.mlmodel / .mlpackage / .mlmodelc) — คอมไพล์ครั้งแรกแล้วเก็บ .mlmodelc ไว้ข้างกัน
    static func loadCustomModel(in dir: URL) async -> (VNCoreMLModel, String)? {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["mlmodelc", "mlmodel", "mlpackage"].contains($0.pathExtension) }
            .sorted { ($0.pathExtension == "mlmodelc" ? 0 : 1, $0.lastPathComponent) < ($1.pathExtension == "mlmodelc" ? 0 : 1, $1.lastPathComponent) }
        guard let file = files.first else { return nil }
        do {
            var url = file
            if file.pathExtension != "mlmodelc" {
                let compiled = try await MLModel.compileModel(at: file)
                let keep = dir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".mlmodelc")
                try? fm.removeItem(at: keep)
                url = (try? fm.moveItem(at: compiled, to: keep)).map { keep } ?? compiled
            }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            return (try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config)), file.deletingPathExtension().lastPathComponent)
        } catch {
            return nil
        }
    }
}

// MARK: - สถานะการมองเห็น (main)

enum VisionMode: String, CaseIterable, Identifiable {
    case off, demand, always
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "ปิด"
        case .demand: "เมื่อต้องมอง"
        case .always: "เปิดตลอด"
        }
    }
    var detail: String {
        switch self {
        case .off: "April มองไม่เห็นอะไรเลย กล้องไม่เปิด"
        case .demand: "กล้องเปิดเองเฉพาะตอนที่ April ต้องมอง (ถาม \"เห็นอะไร\") หรือกำลังเฝ้าดูสิ่งที่สั่งไว้ แล้วปิดเอง"
        case .always: "เฝ้าดูแบบเรียลไทม์: รู้ว่าคนมา/ไป มีอะไรขยับตอนไม่อยู่ เห็นสัตว์ ทักทายเมื่อกลับมา"
        }
    }
}

@MainActor @Observable
final class VisionModel {
    var mode: VisionMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "AprilVisionMode"); failedAt = nil; reconcile() } }
    var cameraID: String { didSet { UserDefaults.standard.set(cameraID, forKey: "AprilVisionCamera"); if running { stopCamera() }; reconcile() } }
    /// แท็บการมองเห็นเปิดอยู่ (ทำภาพย่อสำหรับแสดงสด)
    var viewers = 0 { didSet { engine?.request(jpeg: false, preview: viewers > 0); reconcile() } }
    /// ปุ่ม "เปิดดูภาพสด" ในแท็บ (โหมดเมื่อต้องมอง)
    var hold = false { didSet { reconcile() } }

    private(set) var running = false
    private(set) var starting = false
    private(set) var problem: String?
    private(set) var detections: [Detection] = []
    private(set) var scene: [String] = []
    private(set) var motion: Float = 0
    private(set) var preview: CGImage?
    private(set) var present = false
    private(set) var keepOn = false             // backend: มีสิ่งที่เฝ้าดูอยู่
    private(set) var customModel: String?
    private(set) var cameras: [(id: String, name: String)] = []

    /// พูดแทน April (AppState.announce) — false = ตอนนี้พูดไม่ได้ (กำลังคุยอยู่) ไว้ลองใหม่
    @ObservationIgnored var onSay: ((String) -> Bool)?

    private let backend: Backend
    private var engine: CameraEngine?
    private var custom: VNCoreMLModel?
    private var customTried = false
    private var demandUntil = Date.distantPast
    private var failedAt: Date?
    private var startedAt = Date.distantPast
    private var lastJPEG: (data: Data, size: CGSize)?
    private var jpegSent = true
    private var pendingEvents: [JSON] = []
    private var pendingSay: [(text: String, at: Date)] = []
    private var seenRun = 0
    private var lastSeen = Date.distantPast
    private var leftAt: Date?
    private var motionRun = 0
    private var lastMotionEvent = Date.distantPast
    private var lastLabel: [String: Date] = [:]
    private var loops = false

    init(backend: Backend) {
        self.backend = backend
        let d = UserDefaults.standard
        mode = VisionMode(rawValue: d.string(forKey: "AprilVisionMode") ?? "") ?? .demand
        cameraID = d.string(forKey: "AprilVisionCamera") ?? ""
    }

    var customDir: URL? { backend.root?.appendingPathComponent("data/vision") }
    private var eventsOn: Bool { mode == .always || keepOn }

    private var shouldRun: Bool {
        if let f = failedAt, Date.now.timeIntervalSince(f) < 15 { return false }    // เพิ่งเปิดไม่สำเร็จ — ไม่ลองถี่
        switch mode {
        case .off: return false
        case .always: return true
        case .demand: return Date.now < demandUntil || keepOn || (hold && viewers > 0)
        }
    }

    func start() {
        guard !loops else { return }
        loops = true
        refreshCameras()
        Task { await pushLoop() }
        Task { await demandLoop() }
    }

    func refreshCameras() {
        cameras = CameraEngine.cameras.map { ($0.uniqueID, $0.localizedName) }
    }

    func reloadCustomModel() {
        custom = nil
        customModel = nil
        customTried = false
        if running { stopCamera() }
        reconcile()
    }

    private func reconcile() {
        if shouldRun, !running, !starting { Task { await startCamera() } }
        else if !shouldRun, running { stopCamera() }
    }

    // ---- เปิด/ปิดกล้อง
    private func startCamera() async {
        starting = true
        defer { starting = false }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return fail("ไม่ได้รับสิทธิ์ใช้กล้อง") }
        default:
            return fail("ไม่ได้รับสิทธิ์ใช้กล้อง — เปิดที่ System Settings › Privacy & Security › Camera แล้วติ๊ก April")
        }
        if !customTried, let dir = customDir {
            customTried = true
            if let (m, name) = await CameraEngine.loadCustomModel(in: dir) { custom = m; customModel = name }
        }
        let engine = CameraEngine(custom: custom)
        engine.onTick = { [weak self] t in Task { @MainActor in self?.ingest(t) } }
        let id = cameraID
        do {
            try await Task.detached { try engine.start(deviceID: id) }.value
        } catch {
            return fail("เปิดกล้องไม่ได้: \(error.localizedDescription)")
        }
        guard shouldRun else { Task.detached { engine.stop() }; return }
        self.engine = engine
        running = true
        problem = nil
        startedAt = .now
        seenRun = 0
        leftAt = nil
        present = false
        lastLabel = [:]
        engine.request(jpeg: true, preview: viewers > 0)
    }

    private func fail(_ why: String) {
        problem = why
        failedAt = .now
    }

    private func stopCamera() {
        guard let e = engine else { return }
        engine = nil
        running = false
        preview = nil
        detections = []
        motion = 0
        lastJPEG = nil
        pendingEvents = []
        Task.detached { e.stop() }
        let api = backend.api
        Task { try? await api.call("POST", "api/vision/stopped", timeout: 3) }
    }

    // ---- ส่งผลให้ backend ทุก 1 วิ
    private func pushLoop() async {
        while !Task.isCancelled {
            reconcile()
            if running, backend.phase == .ready { await push() }
            deliverSay()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func push() async {
        engine?.request(jpeg: true, preview: viewers > 0)       // JPEG ใหม่สำหรับรอบหน้า
        var body: JSON = ["people": count(.person), "faces": count(.face),
                          "animals": detections.filter { $0.kind == .animal }.map(\.label),
                          "objects": detections.filter { $0.kind == .object }.map {
                              ["label": $0.label, "confidence": Double($0.confidence),
                               "box": [$0.box.minX, $0.box.minY, $0.box.width, $0.box.height].map { Double($0) }] as JSON
                          },
                          "scene": scene, "motion": Double(motion), "mode": mode.rawValue]
        if !jpegSent, let j = lastJPEG {
            body["jpeg"] = j.data.base64EncodedString()
            body["width"] = Int(j.size.width)
            body["height"] = Int(j.size.height)
            jpegSent = true
        }
        if let r = try? await backend.api.call("POST", "api/vision/frame", json: body, timeout: 5) { handle(r) }
    }

    private func handle(_ r: JSON) {
        keepOn = r.bool("keep_on") ?? false
        for s in r.strs("say") where !s.isEmpty { pendingSay.append((s, .now)) }
        deliverSay()
    }

    private func deliverSay() {
        pendingSay.removeAll { Date.now.timeIntervalSince($0.at) > 90 }   // ค้างนานเกิน = ไม่ทันเหตุการณ์แล้ว (ยังอยู่ในประกาศ)
        while let first = pendingSay.first, onSay?(first.text) == true { pendingSay.removeFirst() }
    }

    // ---- โหมดเมื่อต้องมอง: รอ backend บอกว่าต้องการภาพ (long-poll)
    private func demandLoop() async {
        while !Task.isCancelled {
            guard mode == .demand, backend.phase == .ready else { try? await Task.sleep(for: .seconds(2)); continue }
            do {
                let r = try await backend.api.call("GET", "api/vision/demand", query: ["wait": "25"], timeout: 35)
                if r.bool("want") == true {
                    demandUntil = max(demandUntil, Date.now.addingTimeInterval(max(5, r.num("seconds") ?? 15)))
                    if r.str("reason") == "watch" { keepOn = true }
                    reconcile()
                    try? await Task.sleep(for: .seconds(1))
                }
            } catch {
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // ---- ผลจากกล้อง -> สถานะ + เหตุการณ์
    private func count(_ k: Detection.Kind) -> Int { detections.filter { $0.kind == k }.count }

    private func ingest(_ t: VisionTick) {
        guard running else { return }
        detections = t.detections
        motion = t.motion
        if let s = t.scene { scene = s }
        if let p = t.preview { preview = p }
        if let j = t.jpeg {
            lastJPEG = (j, t.size)
            jpegSent = false
            flushEvents()
        }
        track()
    }

    private func track() {
        let now = Date.now
        let warm = now.timeIntervalSince(startedAt) > 2.5         // ช่วงแรกหลังเปิดกล้อง = ตั้งต้นสถานะ ไม่แจ้งเหตุการณ์
        let seen = detections.contains { $0.kind == .person || $0.kind == .face || ($0.kind == .object && $0.label == "person") }
        if seen { seenRun += 1; lastSeen = now } else { seenRun = 0 }
        if !present, seenRun >= 3 {
            present = true
            if warm { event("person_arrived", away: leftAt.map { now.timeIntervalSince($0) }) }
        } else if present, now.timeIntervalSince(lastSeen) > 5 {
            present = false
            leftAt = lastSeen
            if warm { event("person_left") }
        }

        motionRun = !present && !seen && motion > 0.04 ? motionRun + 1 : 0
        if warm, motionRun >= 3, now.timeIntervalSince(lastMotionEvent) > 20 {
            lastMotionEvent = now
            motionRun = 0
            event("motion")
        }

        for d in detections where d.kind == .animal || (d.kind == .object && d.label != "person" && d.confidence > 0.6) {
            let key = "\(d.kind.rawValue):\(d.label)"
            let quiet: TimeInterval = d.kind == .animal ? 15 : 60
            if warm, lastLabel[key].map({ now.timeIntervalSince($0) > quiet }) ?? true {
                event(d.kind == .animal ? "animal_appeared" : "object_appeared", label: d.label)
            }
            lastLabel[key] = now
        }
    }

    /// เหตุการณ์รอ JPEG ของรอบตรวจจับถัดไป (ภาพตรงกับตอนที่เกิด ไม่ใช่ภาพเก่า 1 วิ)
    private func event(_ kind: String, label: String = "", away: TimeInterval? = nil) {
        guard eventsOn else { return }
        var body: JSON = ["kind": kind, "label": label]
        if let away { body["away_seconds"] = away }
        pendingEvents.append(body)
        engine?.request(jpeg: true, preview: viewers > 0)
    }

    private func flushEvents() {
        guard !pendingEvents.isEmpty, let j = lastJPEG else { return }
        let api = backend.api, b64 = j.data.base64EncodedString()
        for var body in pendingEvents {
            body["jpeg"] = b64
            body["width"] = Int(j.size.width)
            body["height"] = Int(j.size.height)
            let payload = body
            Task { if let r = try? await api.call("POST", "api/vision/event", json: payload, timeout: 10) { self.handle(r) } }
        }
        pendingEvents = []
    }

    #if APRIL_PREVIEW
    /// เฉพาะ build พรีวิว: ใส่ภาพ/ผลตรวจจับตัวอย่าง
    func previewSet(_ image: CGImage, _ dets: [Detection], scene: [String], motion: Float) {
        preview = image
        detections = dets
        self.scene = scene
        self.motion = motion
        running = true
        present = true
        customModel = "yolov8n"
    }
    #endif
}
