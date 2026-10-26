import AVFoundation
import SwiftUI
import UIKit
import Photos

final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    enum Status { case loading, ready, denied, unavailable }
    let session = AVCaptureSession()
    @Published var status: Status = .loading
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published var recording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published var torch = false
    @Published var detected = false
    @Published var corners: [CGPoint] = []
    @Published var frameSize = CGSize(width: 720, height: 1280)
    @Published var error: String?
    @Published var videoURL: URL?
    var onCapture: ((UIImage) -> Void)?
    private let queue = DispatchQueue(label: "app.hushto.camera", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let video = AVCaptureVideoDataOutput()
    private let photo = AVCapturePhotoOutput()
    private let movie = AVCaptureMovieFileOutput()
    private lazy var processor = ImageProcessor()
    private var nativeQuality: NativeCaptureQuality?
    private var configured = false
    private var input: AVCaptureDeviceInput?
    private var pinchStartZoom: CGFloat?
    private var pinchDeviceID: String?
    private var captureGate = CaptureRequestGate()
    private var pendingPhotoID: Int64?
    private var requestedFrameAt: TimeInterval = 0
    @Published private(set) var capturing = false
    @Published private(set) var lastCaptureMethod = "아직 촬영하지 않았어요"
    @Published private(set) var lastCapturePixels = "—"
    @Published private(set) var silentFrameCount = 0
    @Published private(set) var systemPhotoCount = 0
    @Published private(set) var silentPhotoCount = 0
    private var autoCapture = false
    private var needsDetection = false
    private var lastDetection: Double = 0
    private var automaticScan = AutomaticScanStability()
    @Published private(set) var automaticProgress = 0.0
    private var wantsRunning = false
    private var observations: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observations.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            self?.status = .unavailable
            self?.stop()
            self?.error = "카메라 사용이 중단됐어요. 다시 시도를 눌러주세요."
        })
        observations.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] notification in
            self?.status = .unavailable
            self?.stop()
            self?.error = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "카메라를 다시 시작해주세요."
        })
    }
    deinit { observations.forEach { NotificationCenter.default.removeObserver($0) } }
    func start() {
        queue.async { self.wantsRunning = true }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.configureAndStart() } else { DispatchQueue.main.async { self?.status = .denied } }
            }
        default: DispatchQueue.main.async { self.status = .denied }
        }
    }
    private func configureAndStart() {
        queue.async {
            do {
                if !self.configured {
                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }
                    self.session.sessionPreset = .inputPriority
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw HushtoError.camera }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input), self.session.canAddOutput(self.video),
                          self.session.canAddOutput(self.photo) else { throw HushtoError.camera }
                    self.session.addInput(input); self.input = input
                    self.video.alwaysDiscardsLateVideoFrames = true
                    self.video.automaticallyConfiguresOutputBufferDimensions = false
                    self.video.deliversPreviewSizedOutputBuffers = false
                    self.video.videoSettings = [:]
                    self.video.setSampleBufferDelegate(self, queue: self.queue)
                    self.session.addOutput(self.video); self.session.addOutput(self.photo)
                    try self.configureResolution()
                    self.orientConnections()
                    self.configured = true
                }
                if self.wantsRunning && !self.session.isRunning { self.session.startRunning() }
                let running = self.session.isRunning
                DispatchQueue.main.async { self.status = running ? .ready : .unavailable }
            } catch { DispatchQueue.main.async { self.status = .unavailable; self.error = error.localizedDescription } }
        }
    }
    /// Use the largest native frame format; never upscale a 720p buffer.
    private func configureResolution() throws {
        guard let device = input?.device else { return }
        let formats = device.formats.filter {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return d.width <= 4096 && d.height <= 4096 &&
                $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 15 }
        }
        func quality(_ format: AVCaptureDevice.Format) -> NativeCaptureQuality {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let photoPixels = format.supportedMaxPhotoDimensions.map { Int64($0.width) * Int64($0.height) }.max() ?? 0
            return NativeCaptureQuality(width:d.width,height:d.height,binned:format.isVideoBinned,photoPixels:photoPixels)
        }
        guard let best = formats.max(by: { quality($0) < quality($1) }) else { throw HushtoError.camera }
        try device.lockForConfiguration()
        device.activeFormat = best
        let range = best.videoSupportedFrameRateRanges.first { $0.minFrameRate <= 30 && $0.maxFrameRate >= 15 }!
        let duration = CaptureFrameTiming.duration(minimum: range.minFrameDuration, maximum: range.maxFrameDuration)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .none }
        device.isSubjectAreaChangeMonitoringEnabled = true
        device.unlockForConfiguration()
        let currentZoom = device.videoZoomFactor
        DispatchQueue.main.async { self.zoomFactor = currentZoom }
        nativeQuality = quality(best)
        // Native YUV avoids a full-frame BGRA conversion on every 4K/12MP preview frame.
        // Do not specify width/height: the connection rotates native buffers to portrait.
        let pixelType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        video.videoSettings = video.availableVideoPixelFormatTypes.contains(pixelType)
            ? [kCVPixelBufferPixelFormatTypeKey as String: pixelType] : [:]
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width)*Int64($0.height) < Int64($1.width)*Int64($1.height)
        }) { photo.maxPhotoDimensions = largest }
        photo.maxPhotoQualityPrioritization = .quality
    }
    private var supportsSilentPhoto: Bool {
        if #available(iOS 18.0, *) { return photo.isShutterSoundSuppressionSupported }
        return false
    }
    private func orientConnections() {
        for output in [video as AVCaptureOutput, photo, movie] {
            if let connection = output.connection(with: .video) {
                if output === video, connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                if connection.isVideoMirroringSupported { connection.isVideoMirrored = input?.device.position == .front }
            }
        }
    }
    func stop() {
        queue.async {
            self.pinchStartZoom = nil; self.pinchDeviceID = nil
            self.wantsRunning = false; self.captureGate.cancel(); self.pendingPhotoID = nil; self.automaticScan.reset(); self.autoCapture = false
            DispatchQueue.main.async { self.capturing = false }
            if self.movie.isRecording { self.movie.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
    func configureAuto(_ enabled: Bool, detection: Bool) {
        queue.async { self.autoCapture = enabled; self.needsDetection = detection; self.automaticScan.reset() }
        DispatchQueue.main.async {
            self.automaticProgress = 0
            if !detection { self.corners = []; self.detected = false }
        }
    }
    func capture(silent: Bool) {
        queue.async {
            guard self.session.isRunning, !self.movie.isRecording else {
                DispatchQueue.main.async { self.error = "카메라가 준비되지 않았어요. 다시 시도해주세요." }; return
            }
            self.beginCapture(silent: silent)
        }
    }
    private func beginCapture(silent: Bool) {
        let timeout: TimeInterval = silent && !supportsSilentPhoto ? 3 : 10
        guard let route = captureGate.begin(silent: silent, canSuppressShutter: supportsSilentPhoto, now: ProcessInfo.processInfo.systemUptime, timeout: timeout),
              let token = captureGate.token else { return }
        DispatchQueue.main.async { self.capturing = true }
        switch route {
        case .videoFrame:
            requestedFrameAt = ProcessInfo.processInfo.systemUptime
            // Wait for the next frame. Never fall back to capturePhoto in quiet mode.
            break
        case .systemPhoto, .silentPhoto:
            let settings = AVCapturePhotoSettings()
            settings.maxPhotoDimensions = photo.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            if #available(iOS 18.0, *), route == .silentPhoto {
                settings.isShutterSoundSuppressionEnabled = true
            }
            if route == .systemPhoto { DispatchQueue.main.async { self.systemPhotoCount += 1 } }
            pendingPhotoID = settings.uniqueID
            photo.capturePhoto(with: settings, delegate: self)
        }
        queue.asyncAfter(deadline: .now() + timeout + 0.1) { [weak self] in
            guard let self, self.captureGate.expire(token: token, now: ProcessInfo.processInfo.systemUptime) else { return }
            self.pendingPhotoID = nil
            DispatchQueue.main.async {
                self.capturing = false
                self.error = "촬영 프레임을 받지 못했어요. 다시 촬영해주세요. 무음 모드에서는 일반 사진 촬영으로 전환하지 않아요."
            }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processVideoFrame(sampleBuffer)
    }
    private func processVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        let now = ProcessInfo.processInfo.systemUptime
        if needsDetection && now - lastDetection >= (ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical ? 0.75 : RuntimeBudget.current.detectionInterval) {
            lastDetection = now
            let points = processor.documentCorners(in: ci)
            let canCapture = autoCapture && captureGate.route == nil && !movie.isRecording
            let trigger = automaticScan.observe(points, now: now, enabled: canCapture)
            let progress = automaticScan.progress
            let dimensions = ci.extent.size
            DispatchQueue.main.async {
                if self.detected != (points.count == 4) { self.detected = points.count == 4 }
                if self.corners != points { self.corners = points }
                if self.frameSize != dimensions { self.frameSize = dimensions }
                if self.automaticProgress != progress { self.automaticProgress = progress }
            }
            if trigger { beginCapture(silent: true) }
        }
        // A format switch may leave old preview buffers in flight. Never save one as a 4K original.
        let nativeFrame = nativeQuality?.accepts(width:CVPixelBufferGetWidth(buffer),height:CVPixelBufferGetHeight(buffer)) ?? true
        // Give continuous AF/AE up to 0.8 s to settle instead of saving the first blurry frame.
        let adjusting = input.map { $0.device.isAdjustingFocus || $0.device.isAdjustingExposure } ?? false
        let focusReady = !adjusting || now - requestedFrameAt >= 0.8
        if nativeFrame && focusReady && captureGate.consumeVideoFrame(now: now) {
            guard let cg = processor.context.createCGImage(ci, from: ci.extent) else {
                DispatchQueue.main.async { self.capturing = false; self.error = HushtoError.image.localizedDescription }; return
            }
            let image = UIImage(cgImage: cg)
            DispatchQueue.main.async {
                self.capturing = false
                self.silentFrameCount += 1
                self.lastCaptureMethod = "영상 프레임 저장 (무음 경로)"
                self.lastCapturePixels = "\(cg.width) × \(cg.height)"
                self.onCapture?(image)
            }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        queue.async {
            // Ignore a late callback after cancellation or timeout.
            guard self.pendingPhotoID == photo.resolvedSettings.uniqueID else { return }
            self.pendingPhotoID = nil
            let silentPhoto = self.captureGate.route == .silentPhoto
            guard self.captureGate.route == .systemPhoto || silentPhoto else { return }
            self.captureGate.completePhoto()
            DispatchQueue.main.async {
                self.capturing = false
                if let error { self.error = error.localizedDescription; return }
                guard let data, let image = UIImage(data: data) else { self.error = HushtoError.image.localizedDescription; return }
                if silentPhoto { self.silentPhotoCount += 1 }
                self.lastCaptureMethod = silentPhoto ? "고해상도 사진 (공식 무음 경로)" : "시스템 사진 촬영 (촬영음 가능)"
                self.lastCapturePixels = "\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale))"
                self.onCapture?(image)
            }
        }
    }
    func flip() {
        queue.async {
            guard self.configured, self.captureGate.route == nil, !self.movie.isRecording, let old = self.input,
                  let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: old.device.position == .back ? .front : .back) else { return }
            do {
                self.pinchStartZoom = nil; self.pinchDeviceID = nil
                let replacement = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration(); defer { self.session.commitConfiguration() }
                self.session.removeInput(old)
                if self.session.canAddInput(replacement) { self.session.addInput(replacement); self.input = replacement }
                else { self.session.addInput(old) }
                try self.configureResolution()
                self.orientConnections()
                DispatchQueue.main.async { self.torch = false }
            } catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
        }
    }
    func handlePinchZoom(scale: CGFloat, state: UIGestureRecognizer.State) {
        queue.async {
            guard let device = self.input?.device, self.session.isRunning else {
                self.pinchStartZoom = nil; self.pinchDeviceID = nil
                return
            }
            if state == .began {
                self.pinchStartZoom = device.videoZoomFactor
                self.pinchDeviceID = device.uniqueID
            }
            if state == .began || state == .changed || state == .ended {
                if let base = self.pinchStartZoom, self.pinchDeviceID == device.uniqueID,
                   self.captureGate.route == nil,
                   let zoom = CameraZoomRules.factor(start: base, scale: scale,
                       minimum: device.minAvailableVideoZoomFactor,
                       maximum: min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor)) {
                    do {
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }
                        device.cancelVideoZoomRamp()
                        device.videoZoomFactor = zoom
                        let currentZoom = device.videoZoomFactor
                        DispatchQueue.main.async { self.zoomFactor = currentZoom }
                        self.automaticScan.reset()
                    } catch {
                        // A session interruption can make the device temporarily unavailable.
                    }
                }
            }
            if state == .ended || state == .cancelled || state == .failed {
                self.pinchStartZoom = nil; self.pinchDeviceID = nil
            }
        }
    }
    func toggleTorch() {
        queue.async {
            guard let device = self.input?.device, device.hasTorch, device.isTorchAvailable else {
                DispatchQueue.main.async { self.error = "이 카메라에서는 플래시를 사용할 수 없어요." }; return
            }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                let enabled = device.torchMode != .on
                device.torchMode = enabled ? .on : .off
                DispatchQueue.main.async { self.torch = enabled }
            } catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
        }
    }
    func toggleRecording() {
        queue.async {
            if self.movie.isRecording { self.movie.stopRecording(); return }
            guard self.session.isRunning, self.captureGate.route == nil else { return }
            self.session.beginConfiguration()
            self.session.removeOutput(self.video)
            guard self.session.canAddOutput(self.movie) else {
                self.session.addOutput(self.video); self.session.commitConfiguration()
                DispatchQueue.main.async { self.error = "이 기기에서는 동영상을 녹화할 수 없어요." }; return
            }
            if self.session.canSetSessionPreset(.hd4K3840x2160) { self.session.sessionPreset = .hd4K3840x2160 }
            else if self.session.canSetSessionPreset(.hd1920x1080) { self.session.sessionPreset = .hd1920x1080 }
            self.session.addOutput(self.movie); self.orientConnections(); self.session.commitConfiguration()
            let folder = FileManager.default.temporaryDirectory
            let url = folder.appendingPathComponent("영상-\(UUID().uuidString.prefix(8)).mov")
            // No audio input is attached: quiet recording requires no microphone permission.
            self.movie.startRecording(to: url, recordingDelegate: self)
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.recordingStartedAt = Date(); self.recording = true }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            self.session.beginConfiguration()
            self.session.removeOutput(self.movie)
            self.session.sessionPreset = .inputPriority
            if self.session.canAddOutput(self.video) { self.session.addOutput(self.video) }
            do { try self.configureResolution() } catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
            self.orientConnections(); self.session.commitConfiguration()
        }
        DispatchQueue.main.async {
            self.recording = false
            self.recordingStartedAt = nil
            if let error, (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true { self.error = error.localizedDescription }
            else { self.videoURL = outputFileURL }
        }
    }
}
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onPinch: (CGFloat, UIGestureRecognizer.State) -> Void
    final class Coordinator: NSObject {
        var onPinch: (CGFloat, UIGestureRecognizer.State) -> Void
        init(_ onPinch: @escaping (CGFloat, UIGestureRecognizer.State) -> Void) { self.onPinch = onPinch }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) { onPinch(gesture.scale, gesture.state) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onPinch) }
    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> Preview {
        let view = Preview(); view.preview.session = session; view.preview.videoGravity = .resizeAspectFill
        view.isMultipleTouchEnabled = true
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        if let connection = view.preview.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        return view
    }
    func updateUIView(_ uiView: Preview, context: Context) { context.coordinator.onPinch = onPinch }
}
struct DetectionOutline: View {
    let points: [CGPoint]
    let imageSize: CGSize
    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard points.count == 4 else { return }
                let factor = max(geo.size.width / imageSize.width, geo.size.height / imageSize.height)
                let width = imageSize.width * factor, height = imageSize.height * factor
                let mapped = points.map { CGPoint(x: $0.x * width - (width - geo.size.width) / 2, y: $0.y * height - (height - geo.size.height) / 2) }
                path.addLines(mapped); path.closeSubpath()
            }.stroke(.white, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }.allowsHitTesting(false)
    }
}

#if DEBUG
extension CameraController {
    /// Synthetic-buffer integration test; this does not validate microphone-measured sound.
    func testSilentFrame(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            // This seam tests only synthetic video frames, independent of simulated photo capability.
            _ = self.captureGate.begin(silent: true, canSuppressShutter: false,
                                       now: ProcessInfo.processInfo.systemUptime)
            self.requestedFrameAt = ProcessInfo.processInfo.systemUptime - 1
            self.processVideoFrame(sampleBuffer)
        }
    }
}
#endif

/// Give atomic staging/Photos completion time to finish when the app backgrounds.
@MainActor final class GallerySaveBackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Hushto media save") { [weak self] in
            Task { @MainActor in self?.finish() }
        }
    }
    func finish() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Durable outbox outside the scan/PDF session. Original pixels are never downsampled here.
actor PendingGalleryStore {
    static let shared = PendingGalleryStore()
    let root: URL
    private struct Record: Codable { let id: UUID; let filename: String; let video: Bool }
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hushto/PendingGallery", isDirectory: true)
    }
    func load() throws -> GalleryCapture? {
        let manifest = root.appendingPathComponent("capture.json")
        if let data = try? Data(contentsOf: manifest), let record = try? JSONDecoder().decode(Record.self, from: data),
           record.filename == record.id.uuidString + (record.video ? ".mov" : ".jpg") {
            let url = root.appendingPathComponent(record.filename)
            if FileManager.default.fileExists(atPath: url.path) {
                return GalleryCapture(id: record.id, imageURL: record.video ? nil : url, videoURL: record.video ? url : nil)
            }
        }
        // Recover a completed atomic media write if termination preceded the manifest write.
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard ["jpg", "mov"].contains(url.pathExtension), let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            return GalleryCapture(id: id, imageURL: url.pathExtension == "jpg" ? url : nil,
                                  videoURL: url.pathExtension == "mov" ? url : nil)
        }
        return nil
    }
    func stage(_ capture: GalleryCapture) throws -> GalleryCapture {
        if let existing = try load() {
            guard existing.id == capture.id else { throw HushtoError.storage }
            return existing
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = capture.videoURL != nil
        let filename = capture.id.uuidString + (video ? ".mov" : ".jpg")
        let target = root.appendingPathComponent(filename)
        if let source = capture.videoURL ?? capture.imageURL {
            // Same-volume rename avoids copying a potentially large movie into memory.
            if source.standardizedFileURL != target.standardizedFileURL {
                try FileManager.default.moveItem(at: source, to: target)
            }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        } else if let image = capture.image {
            try autoreleasepool {
                guard let data = image.jpegData(compressionQuality: 0.98) else { throw HushtoError.image }
                try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        } else { throw HushtoError.image }
        let record = Record(id: capture.id, filename: filename, video: video)
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent("capture.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return GalleryCapture(id: capture.id, imageURL: video ? nil : target, videoURL: video ? target : nil)
    }
    func remove(_ capture: GalleryCapture) throws {
        if let existing = try load(), existing.id != capture.id { throw HushtoError.storage }
        // Include staged files even when a previous manifest write failed after moving a movie.
        for suffix in [".jpg", ".mov"] {
            let url = root.appendingPathComponent(capture.id.uuidString + suffix)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        let manifest = root.appendingPathComponent("capture.json")
        if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }
    }

}

/// Only adds user-requested media; never requests read access to the photo library.
enum PhotoLibraryWriter {
    static func save(_ capture: GalleryCapture) async throws {
        guard capture.image != nil || capture.imageURL != nil || capture.videoURL != nil else { throw HushtoError.image }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "Hushto.Photos", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "사진 앱에 저장하려면 iOS 설정에서 Hushto의 사진 추가 권한을 허용해주세요. 아직 저장되지 않았으며 이 화면에서 다시 시도할 수 있어요."])
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                if let image = capture.image {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                } else if let url = capture.imageURL {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                } else if let url = capture.videoURL {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .video, fileURL: url, options: nil)
                }
            } completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? HushtoError.image) }
            }
        }
    }
}
