import AVFoundation
import Vision
import SwiftUI

typealias JN = VNHumanBodyPoseObservation.JointName

/// 動作判定(規格書 22.8):可信度 ≥0.5、4 幀平滑、連續 3 幀防抖、走完整圈才計次
final class ExerciseCounter {
    enum Phase { case unknown, start, target }
    let type: Exercise
    private(set) var count = 0
    private var hist: [[JN: CGPoint]] = []
    private var confirmed = Phase.unknown, cand = Phase.unknown
    private var candFrames = 0, sawTarget = false
    static let smooth = 4, debounce = 3
    static let minConf: Float = 0.5

    init(_ t: Exercise) { type = t }

    /// 回傳這一幀是否可信(人有入鏡、關節點夠清楚)
    func update(_ obs: VNHumanBodyPoseObservation) -> Bool {
        guard let all = try? obs.recognizedPoints(.all) else { return false }
        var pts: [JN: CGPoint] = [:]
        for (k, v) in all where v.confidence >= Self.minConf {
            pts[k] = CGPoint(x: v.location.x, y: 1 - v.location.y)   // Vision y 向上 → 轉成向下
        }
        guard reliable(pts) else { return false }
        hist.append(pts)
        if hist.count > Self.smooth { hist.removeFirst() }
        let seen = classify(averaged())
        if seen == cand { candFrames += 1 } else { cand = seen; candFrames = 1 }
        if candFrames >= Self.debounce, seen != .unknown, seen != confirmed {
            confirmed = seen
            if seen == .target { sawTarget = true }
            else if seen == .start, sawTarget { count += 1; sawTarget = false }
        }
        return true
    }

    private func reliable(_ p: [JN: CGPoint]) -> Bool {
        switch type {
        case .squat:
            let l = p[.leftHip] != nil && p[.leftKnee] != nil && p[.leftAnkle] != nil
            let r = p[.rightHip] != nil && p[.rightKnee] != nil && p[.rightAnkle] != nil
            return l || r
        case .raiseHands:
            return [JN.leftShoulder, .rightShoulder, .nose, .leftWrist, .rightWrist].allSatisfy { p[$0] != nil }
        case .jumpingJack:
            return [JN.leftShoulder, .rightShoulder, .nose, .leftWrist, .rightWrist, .leftAnkle, .rightAnkle]
                .allSatisfy { p[$0] != nil }
        }
    }

    private func averaged() -> [JN: CGPoint] {
        var sum: [JN: (x: CGFloat, y: CGFloat, n: CGFloat)] = [:]
        for f in hist {
            for (k, v) in f {
                var e = sum[k] ?? (0, 0, 0)
                e.x += v.x; e.y += v.y; e.n += 1
                sum[k] = e
            }
        }
        return sum.mapValues { CGPoint(x: $0.x / $0.n, y: $0.y / $0.n) }
    }

    private func classify(_ p: [JN: CGPoint]) -> Phase {
        switch type {
        case .jumpingJack, .raiseHands:
            guard let ls = p[.leftShoulder], let rs = p[.rightShoulder], let nose = p[.nose],
                  let lw = p[.leftWrist], let rw = p[.rightWrist] else { return .unknown }
            let down = lw.y > ls.y && rw.y > rs.y          // 雙腕低於肩
            let up = lw.y < nose.y && rw.y < nose.y        // 雙腕高於鼻
            if type == .raiseHands { return down ? .start : (up ? .target : .unknown) }
            guard let la = p[.leftAnkle], let ra = p[.rightAnkle] else { return .unknown }
            let sw = abs(ls.x - rs.x), gap = abs(la.x - ra.x)
            if down && gap < 1.1 * sw { return .start }    // 合
            if up && gap > 1.5 * sw { return .target }     // 開
            return .unknown
        case .squat:
            guard let a = kneeAngle(p) else { return .unknown }
            return a > 160 ? .start : (a < 100 ? .target : .unknown)
        }
    }

    private func kneeAngle(_ p: [JN: CGPoint]) -> Double? {
        func ang(_ j1: JN, _ j2: JN, _ j3: JN) -> Double? {
            guard let hip = p[j1], let knee = p[j2], let ankle = p[j3] else { return nil }
            let k: CGFloat = 0.5625   // 直式 9:16,x 方向校正
            let v1 = CGVector(dx: (hip.x - knee.x) * k, dy: hip.y - knee.y)
            let v2 = CGVector(dx: (ankle.x - knee.x) * k, dy: ankle.y - knee.y)
            let m = hypot(v1.dx, v1.dy) * hypot(v2.dx, v2.dy)
            guard m > 0 else { return nil }
            let cosv = max(-1, min(1, (v1.dx * v2.dx + v1.dy * v2.dy) / m))
            return Double(acos(cosv)) * 180 / .pi
        }
        let vals = [ang(.leftHip, .leftKnee, .leftAnkle), ang(.rightHip, .rightKnee, .rightAnkle)].compactMap { $0 }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }
}

final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published var count = 0
    @Published var hint = ""
    @Published var done = false
    private let queue = DispatchQueue(label: "wakemove.pose")
    private let request = VNDetectHumanBodyPoseRequest()
    private var counter: ExerciseCounter?
    private var target = 20
    private var lastSeen = Date()
    private var configured = false

    func start(_ type: Exercise, target: Int) {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else {
                DispatchQueue.main.async { self.hint = "請到「設定」開啟相機權限(或改用貪睡/一般關閉)" }
                return
            }
            self.queue.async {
                self.counter = ExerciseCounter(type)
                self.target = target
                self.lastSeen = Date()
                if !self.configured { self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.counter = nil
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            session.commitConfiguration(); return
        }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let counter else { return }
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .leftMirrored, options: [:])
        try? handler.perform([request])
        if let obs = request.results?.first, counter.update(obs) { lastSeen = Date() }
        let n = counter.count
        let lost = Date().timeIntervalSince(lastSeen) > 2
        DispatchQueue.main.async {
            self.count = n
            self.hint = lost ? "請讓全身入鏡" : ""
            if n >= self.target { self.done = true }
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
