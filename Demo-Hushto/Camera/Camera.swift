import AVFoundation
import SwiftUI
import UIKit
import Photos

/// Only the corner overlay observes these updates; live recognition must not
/// invalidate the mode selector and the rest of the camera screen.
struct CameraDetectionSnapshot: Equatable {
    var points: [CGPoint] = []
    var imageSize: CGSize = .zero
}
final class CameraDetectionFeedback: ObservableObject {
    @Published private(set) var snapshot = CameraDetectionSnapshot()
    @MainActor func update(points: [CGPoint], imageSize: CGSize) {
        let valid = PageGeometry.valid(points) && imageSize.width.isFinite && imageSize.height.isFinite
            && imageSize.width > 0 && imageSize.height > 0
        let next = valid ? CameraDetectionSnapshot(points: points, imageSize: imageSize) : CameraDetectionSnapshot()
        if next != snapshot { snapshot = next }
    }
}

/// Smooth only live feedback. Raw current observations still drive auto capture.
struct LiveDocumentTracking {
    private var points: [CGPoint] = []
    private var size: CGSize = .zero
    private var lastSeen: TimeInterval?
    private var candidate: [CGPoint] = []
    mutating func reset() { self = Self() }
    mutating func observe(_ next: [CGPoint], imageSize: CGSize, now: TimeInterval) -> [CGPoint] {
        if size != imageSize { reset(); size = imageSize }
        guard PageGeometry.valid(next) else {
            if let lastSeen, now - lastSeen <= 0.45 { return points }
            points = []; candidate = []; return []
        }
        lastSeen = now
        guard points.count == 4 else { points = next; return points }
        let displacement = zip(points, next).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 1
        if displacement > 0.12 {
            let confirmed = candidate.count == 4 && zip(candidate, next).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.06 }
            candidate = next
            if confirmed { points = next; candidate = [] }
        } else {
            candidate = []
            if displacement > 0.002 {
                points = zip(points, next).map { CGPoint(x: $0.x * 0.55 + $1.x * 0.45, y: $0.y * 0.55 + $1.y * 0.45) }
            }
        }
        return points
    }
}

/// Serial camera-queue scheduler. Visual mode selection remains immediate;
/// only the latest expensive stream reconfiguration runs after rapid gestures.
final class CameraModeSwitchScheduler: @unchecked Sendable {
    let queue: DispatchQueue
    private var pending: DispatchWorkItem?
    private var action: (() -> Void)?
    init(queue: DispatchQueue) { self.queue = queue }
    func schedule(_ action: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        cancel()
        self.action = action
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    func flush() {
        dispatchPrecondition(condition: .onQueue(queue))
        pending?.cancel(); pending = nil
        let next = action; action = nil
        next?()
    }
    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        pending?.cancel(); pending = nil; action = nil
    }
}

/// Both tracks must span the recording; AAC encoder priming gets a small tolerance.
enum RecordingAudioValidation {
    static func issue(at url: URL) async -> String? {
        do {
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first,
                  let audio = try await asset.loadTracks(withMediaType: .audio).first else {
                return "녹화 파일에 영상 또는 오디오 트랙이 없어요. 촬영본은 보존합니다."
            }
            let videoTime = try await video.load(.timeRange)
            let audioTime = try await audio.load(.timeRange)
            let start = CMTimeGetSeconds(audioTime.start) - CMTimeGetSeconds(videoTime.start)
            let end = CMTimeGetSeconds(videoTime.end) - CMTimeGetSeconds(audioTime.end)
            guard CMTimeGetSeconds(videoTime.duration) > 0, CMTimeGetSeconds(audioTime.duration) > 0, start.isFinite, end.isFinite,
                  start <= 0.2, end <= 0.3 else {
                return "녹화 중 일부 구간에 소리가 기록되지 않았어요. 촬영본은 보존합니다."
            }
            return nil
        } catch { return "녹화 오디오 확인에 실패했어요. 촬영본은 보존합니다. " + error.localizedDescription }
    }
}

final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    enum Status { case loading, ready, denied, unavailable }
    let session = AVCaptureSession()
    let detectionFeedback = CameraDetectionFeedback()
    @Published var status: Status = .loading
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var transitionFrame: UIImage?
    @Published private(set) var requestingMicrophonePermission = false
    @Published var recording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published var torch = false
    // Feedback publishes through its own observable object, keeping recognition
    // updates isolated from the camera controls and mode animation.
    var detected = false
    var corners: [CGPoint] = []
    var frameSize = CGSize(width: 720, height: 1280)
    @Published var error: String?
    @Published var videoURL: URL?
    var onCapture: ((UIImage) -> Void)?
    private let queue = DispatchQueue(label: "app.hushto.camera", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private lazy var modeSwitch = CameraModeSwitchScheduler(queue: queue)
    private var nativeFormats: [String: (AVCaptureDevice.Format, NativeCaptureQuality)] = [:]
    private var microphoneInput: AVCaptureDeviceInput?
    private var recordingAudioActive = false
    private var previousAudioSession: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private let video = AVCaptureVideoDataOutput()
    private let photo = AVCapturePhotoOutput()
    private let movie = AVCaptureMovieFileOutput()
    private lazy var processor = ImageProcessor()
    private let detectionQueue = DispatchQueue(label: "app.hushto.camera-detection", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var detectionInFlight = false
    private var liveDocumentTracking = LiveDocumentTracking()
    private var lastRecoveryAttempt: TimeInterval = -.infinity
    private var lastPreviewBuffer: CVPixelBuffer?
    private var lastPreviewTime: TimeInterval = -.infinity
    private var transitionID: UInt64 = 0
    private var transitionStarted: TimeInterval?
    private var transitionFrames = 0
    private var detectionGeneration: UInt64 = 0
    #if DEBUG
    private var testDocumentDetector: ((CIImage) -> [CGPoint])?
    #endif
    private var nativeQuality: NativeCaptureQuality?
    private var wantsVideoMode = false
    private var recordingTransition = false
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
    private(set) var automaticProgress = 0.0
    private var wantsRunning = false
    private var observations: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observations.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                // An interruption suspends capture, but must not erase the screen's running intent.
                self.detectionGeneration &+= 1
                self.liveDocumentTracking.reset()
                self.captureGate.cancel()
                self.pendingPhotoID = nil
                self.automaticScan.reset()
                DispatchQueue.main.async {
                    self.capturing = false; self.status = .unavailable
                    self.updateDetectionFeedback(points: [], imageSize: .zero)
                }
            }
        })
        observations.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.configureAndStart()
        })
        observations.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            guard let self else { return }
            let failure = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self.queue.async {
                self.detectionGeneration &+= 1
                self.liveDocumentTracking.reset()
                self.captureGate.cancel()
                self.pendingPhotoID = nil
                DispatchQueue.main.async {
                    self.capturing = false; self.status = .unavailable
                    self.updateDetectionFeedback(points: [], imageSize: .zero)
                }
                guard self.wantsRunning else { return }
                if failure?.code == .mediaServicesWereReset {
                    self.nativeFormats.removeAll()
                    self.configureAndStart()
                } else {
                    DispatchQueue.main.async { self.error = failure?.localizedDescription ?? "카메라를 다시 시작해주세요." }
                }
            }
        })
    }
    deinit { observations.forEach { NotificationCenter.default.removeObserver($0) } }
    func start() {
        queue.async {
            if !self.wantsRunning {
                self.detectionGeneration &+= 1
                self.liveDocumentTracking.reset()
                self.automaticScan.reset()
            }
            self.wantsRunning = true
        }
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
            guard self.wantsRunning, !self.session.isInterrupted else { return }
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
                    if self.wantsVideoMode { try self.configureVideoOutputs() }
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
        detectionGeneration &+= 1
        liveDocumentTracking.reset()
        guard let device = input?.device else { return }
        let best: AVCaptureDevice.Format
        let bestQuality: NativeCaptureQuality
        if let cached = nativeFormats[device.uniqueID] {
            (best, bestQuality) = cached
        } else {
            let ranked = device.formats.compactMap { format -> (AVCaptureDevice.Format, NativeCaptureQuality)? in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard d.width <= 4096, d.height <= 4096,
                      format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 15 }) else { return nil }
                let pixels = format.supportedMaxPhotoDimensions.map { Int64($0.width) * Int64($0.height) }.max() ?? 0
                return (format, NativeCaptureQuality(width: d.width, height: d.height, binned: format.isVideoBinned, photoPixels: pixels))
            }
            guard let selected = ranked.max(by: { $0.1 < $1.1 }) else { throw HushtoError.camera }
            (best, bestQuality) = selected
            nativeFormats[device.uniqueID] = selected
        }
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
        nativeQuality = bestQuality
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
            self.modeSwitch.cancel()
            self.pinchStartZoom = nil; self.pinchDeviceID = nil
            self.lastPreviewBuffer = nil
            self.transitionID &+= 1
            self.clearTransitionFrame(id: self.transitionID)
            self.detectionGeneration &+= 1
            self.liveDocumentTracking.reset()
            self.wantsRunning = false; self.captureGate.cancel(); self.pendingPhotoID = nil; self.automaticScan.reset(); self.autoCapture = false
            DispatchQueue.main.async {
                self.capturing = false; self.status = .loading
                self.updateDetectionFeedback(points: [], imageSize: .zero)
            }
            if self.movie.isRecording { self.movie.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
    func configureAuto(_ enabled: Bool, detection: Bool) {
        queue.async {
            let automatic = enabled && detection
            guard self.autoCapture != automatic || self.needsDetection != detection else { return }
            self.detectionGeneration &+= 1
            self.liveDocumentTracking.reset()
            self.autoCapture = automatic
            self.needsDetection = detection
            self.automaticScan.reset()
            DispatchQueue.main.async {
                self.automaticProgress = 0
                if !detection { self.updateDetectionFeedback(points: [], imageSize: .zero) }
            }
        }
    }
    @MainActor func updateDetectionFeedback(points: [CGPoint], imageSize: CGSize) {
        detected = PageGeometry.valid(points)
        corners = detected ? points : []
        frameSize = imageSize
        detectionFeedback.update(points: points, imageSize: imageSize)
    }
    func capture(silent: Bool) {
        queue.async {
            self.modeSwitch.flush()
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
        detectionGeneration &+= 1
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
        // The native preview does not need a CIImage for every delivered buffer.
        let now = ProcessInfo.processInfo.systemUptime
        if wantsRunning, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            lastPreviewBuffer = buffer
            lastPreviewTime = now
            if let started = transitionStarted {
                let dimensions = input.map { CMVideoFormatDescriptionGetDimensions($0.device.activeFormat.formatDescription) }
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                let matchesFormat = dimensions.map {
                    (width == Int($0.width) && height == Int($0.height)) ||
                    (width == Int($0.height) && height == Int($0.width))
                } ?? true
                if matchesFormat { transitionFrames += 1 }
                if transitionFrames >= 2 && now - started >= 0.1 {
                    transitionStarted = nil
                    let id = transitionID
                    queue.asyncAfter(deadline: .now() + 0.08) { self.clearTransitionFrame(id: id) }
                }
            }
        }
        let detectionDue = needsDetection && !detectionInFlight && now - lastDetection >=
            (ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical ? 0.75 : RuntimeBudget.current.detectionInterval)
        guard captureGate.route == .videoFrame || (captureGate.route == nil && detectionDue) else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
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
            return
        }
        // Let capture delivery and AF/AE settle before scheduling more Vision work.
        if captureGate.route != nil { return }
        if detectionDue {
            lastDetection = now
            detectionInFlight = true
            let generation = detectionGeneration
            let dimensions = ci.extent.size
            let recovery = now - lastRecoveryAttempt >= (RuntimeBudget.current.constrained ? 0.75 : 0.5)
            if recovery { lastRecoveryAttempt = now }
            #if DEBUG
            let testDetector = testDocumentDetector
            #endif
            // At most one buffer is retained for analysis. Shutter, torch, zoom,
            // start and stop remain available on the camera's control queue.
            detectionQueue.async {
                let points: [CGPoint]
                #if DEBUG
                if let detector = testDetector { points = detector(ci) }
                else { points = ImageProcessor.shared.liveDocumentCorners(in: ci, allowRecovery: recovery) }
                #else
                points = ImageProcessor.shared.liveDocumentCorners(in: ci, allowRecovery: recovery)
                #endif
                self.queue.async {
                    self.detectionInFlight = false
                    guard generation == self.detectionGeneration, self.needsDetection,
                          self.wantsRunning, self.session.isRunning,
                          self.captureGate.route == nil, !self.movie.isRecording else { return }
                    let displayed = self.liveDocumentTracking.observe(points, imageSize: dimensions, now: ProcessInfo.processInfo.systemUptime)
                    let trigger = self.automaticScan.observe(points, now: ProcessInfo.processInfo.systemUptime, enabled: self.autoCapture)
                    let progress = self.automaticScan.progress
                    DispatchQueue.main.async {
                        self.updateDetectionFeedback(points: displayed, imageSize: dimensions)
                        if self.automaticProgress != progress { self.automaticProgress = progress }
                    }
                    if trigger { self.beginCapture(silent: true) }
                }
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
                if self.wantsVideoMode { try self.configureVideoOutputs() }
                else { try self.configureResolution() }
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
    /// Prepare the recording graph when entering video mode, never on a
    /// record/stop tap: output and preset changes briefly interrupt the preview.
    func setVideoMode(_ enabled: Bool) {
        queue.async {
            guard !self.movie.isRecording, !self.recordingTransition else { return }
            self.wantsVideoMode = enabled
            self.modeSwitch.cancel()
            guard self.configured,
                  self.session.outputs.contains(where: { $0 === self.movie }) != enabled else { return }
            self.modeSwitch.schedule { [weak controller = self] in controller?.applyVideoMode() }
        }
    }
    private func applyVideoMode() {
        guard configured, !movie.isRecording, !recordingTransition,
              session.outputs.contains(where: { $0 === movie }) != wantsVideoMode else { return }
        holdTransitionFrame()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        do {
            if wantsVideoMode { try configureVideoOutputs() }
            else {
                session.removeOutput(movie)
                session.sessionPreset = .inputPriority
                if session.canAddOutput(video) { session.addOutput(video) }
                try configureResolution()
            }
            orientConnections()
        } catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
    }
    /// Hold one bounded frame over the stream reconfiguration, rather than expose
    /// an empty preview. The live preview and capture resolutions remain unchanged.
    private func holdTransitionFrame() {
        transitionID &+= 1
        let id = transitionID
        transitionFrames = 0
        transitionStarted = ProcessInfo.processInfo.systemUptime
        if let buffer = lastPreviewBuffer, ProcessInfo.processInfo.systemUptime - lastPreviewTime < 0.5 {
            let source = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, 1280 / max(source.extent.width, source.extent.height))
            let small = source.transformed(by: .init(scaleX: scale, y: scale))
            if let cg = processor.context.createCGImage(small, from: small.extent) {
                let image = UIImage(cgImage: cg)
                DispatchQueue.main.async { self.transitionFrame = image }
            }
        }
        // A device that cannot deliver data buffers alongside movies still must
        // release the cover; it must never become a frozen viewfinder.
        queue.asyncAfter(deadline: .now() + 0.6) { self.clearTransitionFrame(id: id) }
    }
    private func clearTransitionFrame(id: UInt64) {
        guard id == transitionID else { return }
        transitionStarted = nil
        if ProcessInfo.processInfo.systemUptime - lastPreviewTime > 0.5 { lastPreviewBuffer = nil }
        DispatchQueue.main.async { self.transitionFrame = nil }
    }
    /// Called only inside a session configuration transaction.
    private func configureVideoOutputs() throws {
        if !session.outputs.contains(where: { $0 === movie }) {
            if !session.canAddOutput(movie) { session.removeOutput(video) }
            guard session.canAddOutput(movie) else {
                if session.canAddOutput(video) { session.addOutput(video) }
                throw HushtoError.camera
            }
            session.addOutput(movie)
        }
        if session.canSetSessionPreset(.hd4K3840x2160) { session.sessionPreset = .hd4K3840x2160 }
        else if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
    }
    func toggleRecording() {
        queue.async {
            guard !self.recordingTransition else { return }
            if self.movie.isRecording {
                self.recordingTransition = true
                self.movie.stopRecording()
                return
            }
            self.modeSwitch.flush()
            guard self.wantsVideoMode, self.session.isRunning, self.captureGate.route == nil,
                  self.session.outputs.contains(where: { $0 === self.movie }) else { return }
            self.recordingTransition = true
            DispatchQueue.main.async { self.capturing = true }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: self.startRecordingWithAudio()
            case .notDetermined:
                DispatchQueue.main.async {
                    self.requestingMicrophonePermission = true
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async { self.requestingMicrophonePermission = false }
                        self.queue.async {
                            if granted { self.startRecordingWithAudio() }
                            else { self.failRecordingAudio("동영상 소리를 녹음하려면 설정에서 Demo-Hushto의 마이크 권한을 허용해주세요.") }
                        }
                    }
                }
            default: self.failRecordingAudio("동영상 소리를 녹음하려면 설정에서 Demo-Hushto의 마이크 권한을 허용해주세요.")
            }
        }
    }
    private func startRecordingWithAudio() {
        guard wantsRunning, wantsVideoMode, session.isRunning else {
            recordingTransition = false
            DispatchQueue.main.async { self.capturing = false }
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            previousAudioSession = (audio.category, audio.mode, audio.categoryOptions)
            try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true)
            recordingAudioActive = true
            guard let device = AVCaptureDevice.default(for: .audio) else {
                throw NSError(domain: "Hushto.RecordingAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "마이크를 사용할 수 없어요."])
            }
            let input = try AVCaptureDeviceInput(device: device)
            holdTransitionFrame()
            session.automaticallyConfiguresApplicationAudioSession = false
            session.beginConfiguration()
            if session.canAddInput(input) {
                session.addInput(input)
                microphoneInput = input
            }
            session.commitConfiguration()
            guard microphoneInput != nil, let connection = movie.connection(with: .audio) else {
                throw NSError(domain: "Hushto.RecordingAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "녹화에 마이크를 연결하지 못했어요. 다시 시도해주세요."])
            }
            connection.isEnabled = true
            autoCapture = false
            automaticScan.reset()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("영상-\(UUID().uuidString.prefix(8)).mov")
            movie.startRecording(to: url, recordingDelegate: self)
        } catch { failRecordingAudio(error.localizedDescription) }
    }
    private func releaseRecordingAudio() {
        if let microphoneInput {
            if session.inputs.contains(where: { $0 === microphoneInput }) {
                session.beginConfiguration()
                session.removeInput(microphoneInput)
                session.commitConfiguration()
            }
            self.microphoneInput = nil
        }
        if recordingAudioActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            recordingAudioActive = false
        }
        if let previousAudioSession {
            try? AVAudioSession.sharedInstance().setCategory(previousAudioSession.0, mode: previousAudioSession.1, options: previousAudioSession.2)
            self.previousAudioSession = nil
        }
    }
    private func failRecordingAudio(_ message: String) {
        releaseRecordingAudio()
        recordingTransition = false
        DispatchQueue.main.async { self.capturing = false; self.error = message }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        queue.async { self.recordingTransition = false }
        DispatchQueue.main.async { self.capturing = false; self.recordingStartedAt = Date(); self.recording = true }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            if self.wantsRunning && self.session.isRunning {
                self.holdTransitionFrame()
                // Publish the cover before audio-input teardown can blank the
                // live layer. No photo blink or white animation is scheduled.
                self.queue.asyncAfter(deadline: .now() + 0.05) {
                    self.finishRecordedFile(outputFileURL, error: error)
                }
            } else { self.finishRecordedFile(outputFileURL, error: error) }
        }
    }
    private func finishRecordedFile(_ url: URL, error: Error?) {
        releaseRecordingAudio()
        let failure = error.flatMap { ($0 as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true ? nil : $0 }
        Task {
            let issue = failure == nil ? await RecordingAudioValidation.issue(at: url) : nil
            self.completeRecording(url, failure: failure, audioIssue: issue)
        }
    }
    private func completeRecording(_ url: URL, failure: Error?, audioIssue: String?) {
        queue.async { self.recordingTransition = false }
        DispatchQueue.main.async {
            self.capturing = false
            self.recording = false
            self.recordingStartedAt = nil
            if let failure { self.error = failure.localizedDescription }
            else {
                if let audioIssue { self.error = audioIssue }
                self.videoURL = url
            }
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
struct CameraDetectionOverlay: View {
    @ObservedObject var feedback: CameraDetectionFeedback
    var body: some View {
        if feedback.snapshot.points.count == 4 {
            DetectionOutline(points: feedback.snapshot.points, imageSize: feedback.snapshot.imageSize)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
struct DetectionOutline: View {
    let points: [CGPoint]
    let imageSize: CGSize
    static func mappedPoints(_ points: [CGPoint], imageSize: CGSize, viewSize: CGSize) -> [CGPoint] {
        guard points.count == 4, imageSize.width > 0, imageSize.height > 0 else { return [] }
        let factor = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let width = imageSize.width * factor, height = imageSize.height * factor
        return points.map { CGPoint(x: $0.x * width - (width - viewSize.width) / 2,
                                    y: $0.y * height - (height - viewSize.height) / 2) }
    }
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let mapped = Self.mappedPoints(points, imageSize: imageSize, viewSize: geo.size)
                guard mapped.count == 4 else { return }
                path.addLines(mapped)
                path.closeSubpath()
            }.stroke(.white, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }.allowsHitTesting(false)
    }
}

#if DEBUG
extension CameraController {
    /// Exercise the real bounded analysis path without camera hardware.
    func testDetectionFrame(_ sampleBuffer: CMSampleBuffer, detector: @escaping (CIImage) -> [CGPoint]) {
        queue.async {
            self.needsDetection = true
            self.lastDetection = -.infinity
            self.testDocumentDetector = detector
            self.processVideoFrame(sampleBuffer)
        }
    }
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
                "사진 앱에 저장하려면 iOS 설정에서 Demo-Hushto의 사진 추가 권한을 허용해주세요. 아직 저장되지 않았으며 이 화면에서 다시 시도할 수 있어요."])
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
