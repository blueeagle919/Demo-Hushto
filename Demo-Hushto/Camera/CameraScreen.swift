import Photos
import PhotosUI
import SwiftUI

struct CameraScreen: View {
    var tablet = false
    @EnvironmentObject private var store: ScanStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraController()
    @AppStorage("silent") private var silent = true
    @AppStorage("feedback") private var feedback = true
    @AppStorage("defaultMode") private var defaultMode = CaptureMode.photo.rawValue
    @AppStorage("enhancement") private var enhancement = Enhancement.auto.rawValue
    @AppStorage("defaultFlash") private var defaultFlash = false
    @ViewState private var mode: CaptureMode = .photo
    @ViewState private var auto = false
    @ViewState private var duplicateAlert = false
    @ViewState private var settings = false
    @ViewState private var pages = false
    @ViewState private var reviewPage: ScanPage?
    @ViewState private var awaitingScanReview = false
    @ViewState private var blink = false
    @ViewState private var requestedPhotoMode: CaptureMode?
    @ViewState private var scanQuarterTurns = 0
    @ViewState private var picker: PhotosPickerItem?
    @ViewState private var galleryCapture: GalleryCapture?
    @ViewState private var savingToGallery = false
    @ViewState private var galleryRecoveryLoaded = false
    @ViewState private var galleryWasBackgrounded = false
    @ViewState private var gallerySaveError: String?
    @ViewState private var capturedMode: CaptureMode = .photo
    @ViewState private var appeared = false
    private var simulatorAutoActive: Bool {
        isSimulator && auto && mode.needsCorrection && scenePhase == .active && !settings && !pages && reviewPage == nil
            && !store.busy && galleryRecoveryLoaded && galleryCapture == nil && store.duplicate == nil
    }
    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }
    var body: some View {
        NavigationStack { lifecycleCamera }
    }

    private var lifecycleCamera: some View {
        observedCamera
            .onChange(of: picker) { _, item in
                guard let item else { return }
                camera.stop()
                capturedMode = .scan
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self),
                            let image = UIImage(data: data)
                        else { throw HushtoError.image }
                        processScan(image)
                    } catch {
                        store.report(error)
                        resume()
                    }
                    picker = nil
                }
            }
            .onChange(of: settings) { _, shown in if shown { camera.stop() } else { resume() } }
            .onChange(of: pages) { _, shown in if shown { camera.stop() } else { resume() } }
            .onChange(of: reviewPage?.id) { _, id in if id == nil { resume() } }
            .onChange(of: store.busy) { _, busy in if !busy { resume() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    let retryAfterSettings = galleryWasBackgrounded
                    galleryWasBackgrounded = false
                    if retryAfterSettings && galleryRecoveryLoaded && galleryCapture != nil && !savingToGallery {
                        saveToGallery()
                    } else {
                        resume()
                    }
                } else {
                    if phase == .background { galleryWasBackgrounded = true }
                    // A microphone permission prompt temporarily makes the scene
                    // inactive; keep this requested recording's preview ready.
                    if phase == .background || !camera.requestingMicrophonePermission { camera.stop() }
                }
            }
            .task { await restoreGalleryCapture() }
            .task(id: simulatorAutoActive) { await runSimulatorAutoCapture() }
            .task(id: isSimulator ? mode : nil) { await updateSimulatorDetection() }
    }

    private var observedCamera: some View {
        alertCamera
            .onAppear {
                if !appeared {
                    mode = CaptureMode.restored(defaultMode)
                    defaultMode = mode.rawValue
                    appeared = true
                }
                camera.onCapture = receive
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                updateScanOrientation()
                resume()
            }
            .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                updateScanOrientation()
            }
            .onChange(of: mode) { _, value in
                blink = false
                requestedPhotoMode = nil
                camera.setVideoMode(value == .video)
            }
            .onChange(of: camera.recording) { _, _ in
                blink = false
                requestedPhotoMode = nil
            }
            .onChange(of: store.duplicate?.id) { _, id in duplicateAlert = id != nil }
            .onChange(of: camera.videoURL) { _, url in
                if let url {
                    galleryCapture = GalleryCapture(videoURL: url)
                    saveToGallery()
                }
            }
            .onChange(of: camera.status) { _, status in
                if status == .ready && defaultFlash && !camera.torch { camera.toggleTorch() }
            }

    }

    private var alertCamera: some View {
        presentedCamera
            .alert(
                "갤러리에 저장하지 못했어요",
                isPresented: Binding(
                    get: { gallerySaveError != nil },
                    set: { if !$0 { gallerySaveError = nil } }
                )
            ) {
                Button("다시 저장") { saveToGallery() }
                Button("설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("촬영본 버리기", role: .destructive) { clearGalleryCapture() }
            } message: {
                Text(gallerySaveError ?? "")
            }
            .overlay {
                if store.busy {
                    ProgressView("처리 중…").padding(24).background(
                        .regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .alert(item: Binding(get: { tablet ? nil : store.notice }, set: { store.notice = $0 })) { notice in
                Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("확인")))
            }
            .overlay { if tablet { IPadNoticeOverlay(notice: $store.notice) } }
            .alert("같은 페이지를 촬영한 것 같아요", isPresented: Binding(
                get: { duplicateAlert && !tablet }, set: { duplicateAlert = $0 }
            )) {
                Button("다시 촬영", role: .cancel) {
                    store.rejectDuplicate()
                    resume()
                }
                Button("그래도 추가") {
                    if let page = store.duplicate {
                        store.accept(page)
                        if store.lastCapture == page.id { reviewPage = page } else { resume() }
                    }
                }
            } message: {
                Text("기존 페이지와 매우 비슷해요. 추가할까요?")
            }
            .overlay {
                if tablet, let page = store.duplicate {
                    IPadDuplicateWarning(page: page, onKeep: {
                        store.accept(page)
                        if store.lastCapture == page.id { reviewPage = page } else { resume() }
                    }, onDiscard: {
                        store.rejectDuplicate()
                        resume()
                    }).environmentObject(store)
                }
            }
            .overlay {
                if tablet, let error = camera.error {
                    IPadDecisionOverlay(title: "카메라 안내", message: error, confirmTitle: "다시 시도") {
                        camera.error = nil; resume()
                    }
                }
            }
            .alert("카메라 안내", isPresented: Binding(get: { camera.error != nil && !tablet }, set: { if !$0 { camera.error = nil } }))
        {
            Button("다시 시도", role: .cancel) { camera.error = nil; resume() }
        } message: {
            Text(camera.error ?? "")
        }

    }

    private var presentedCamera: some View {
        cameraContent
            .background(Theme.cameraBackground).toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $settings, onDismiss: resume) {
                Group {
                    if tablet {
                        IPadSettingsScreen(camera: camera, onFinish: { settings = false })
                    } else {
                        SettingsScreen(camera: camera, onFinish: { settings = false })
                    }
                }.environmentObject(store)
            }
            .fullScreenCover(isPresented: $pages, onDismiss: resume) {
                NavigationStack {
                    Group {
                        if tablet {
                            IPadPagesScreen(onFinish: { pages = false })
                        } else {
                            PagesScreen(onFinish: { pages = false })
                        }
                    }.environmentObject(store)
                }
            }
            .fullScreenCover(item: $reviewPage, onDismiss: resume) { page in
                NavigationStack {
                    Group {
                        if tablet {
                            IPadCaptureReview(pageID: page.id, onFinish: { reviewPage = nil }, onNextCapture: { reviewPage = nil })
                        } else {
                            CaptureReview(pageID: page.id, onFinish: { reviewPage = nil }, onNextCapture: { reviewPage = nil })
                        }
                    }.environmentObject(store)
                }
            }

    }

    @ViewBuilder private var cameraContent: some View {
        Group {
            if tablet {
                IPadCameraScreenContent(
                    camera: camera,
                    store: store,
                    mode: $mode,
                    auto: $auto,
                    picker: $picker,
                    pages: $pages,
                    settings: $settings,
                    blink: blink,
                    isSimulator: isSimulator,
                    configureAuto: configureAuto,
                    shutter: shutter
                )
            } else {
                CameraScreenContent(
                    camera: camera,
                    store: store,
                    mode: $mode,
                    auto: $auto,
                    picker: $picker,
                    pages: $pages,
                    settings: $settings,
                    blink: blink,
                    isSimulator: isSimulator,
                    configureAuto: configureAuto,
                    shutter: shutter
                )
            }
        }
    }

    @MainActor private func updateSimulatorDetection() async {
        guard isSimulator else { return }
        guard mode.needsCorrection, let sample = UIImage(named: "CameraSample") else {
            camera.updateDetectionFeedback(points: [], imageSize: .zero)
            return
        }
        let points = await Task.detached(priority: .userInitiated) {
            guard let image = CIImage(image: sample) else { return [CGPoint]() }
            return ImageProcessor.shared.liveDocumentCorners(in: image)
        }.value
        guard !Task.isCancelled else { return }
        camera.updateDetectionFeedback(points: points, imageSize: sample.size)
    }
    @MainActor private func runSimulatorAutoCapture() async {
        guard simulatorAutoActive, let sample = UIImage(named: "CameraSample") else { return }
        let points = await Task.detached(priority: .userInitiated) {
            guard let image = CIImage(image: sample) else { return [CGPoint]() }
            return ImageProcessor().liveDocumentCorners(in: image)
        }.value
        guard !Task.isCancelled else { return }
        camera.updateDetectionFeedback(points: points, imageSize: sample.size)
        var stability = AutomaticScanStability()
        while !Task.isCancelled && simulatorAutoActive {
            if stability.observe(points, now: ProcessInfo.processInfo.systemUptime, enabled: true) {
                capturedMode = mode
                receive(sample)
                return
            }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }
    private func configureAuto() {
        capturedMode = mode
        let enabled = auto && !store.busy
        camera.configureAuto(enabled, detection: mode.needsCorrection && !store.busy)
    }
    private func resume() {
        guard galleryRecoveryLoaded, scenePhase == .active, !settings, !pages, reviewPage == nil, !awaitingScanReview,
            galleryCapture == nil,
            store.duplicate == nil, (!store.busy || store.isRestoring)
        else { return }
        if !isSimulator {
            camera.setVideoMode(mode == .video)
            camera.start()
            configureAuto()
        }
    }
    private func receive(_ image: UIImage) {
        guard mode != .video, capturedMode != .video, !camera.recording else { return }
        guard requestedPhotoMode == mode || (auto && mode.needsCorrection) else { return }
        guard !store.busy, reviewPage == nil, !settings, !pages, galleryCapture == nil, store.duplicate == nil else {
            return
        }
        let showPhotoBlink = requestedPhotoMode == .photo
        requestedPhotoMode = nil
        if feedback && showPhotoBlink {
            blink = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { blink = false }
        }
        if capturedMode.savesToPhotoLibrary {
            // Photos and videos stay on the camera screen without a result sheet.
            galleryCapture = GalleryCapture(image: image)
            saveToGallery()
        } else {
            // All scan subjects share one correction and review pipeline.
            processScan(image, quarterTurns: scanQuarterTurns)
        }
    }
    private func updateScanOrientation() {
        switch UIDevice.current.orientation {
        case .portrait: scanQuarterTurns = 0
        case .landscapeLeft: scanQuarterTurns = 1
        case .portraitUpsideDown: scanQuarterTurns = 2
        case .landscapeRight: scanQuarterTurns = 3
        default: break // Keep the last upright direction when the phone is flat.
        }
    }
    /// The processing completion carries the accepted page directly into the item
    /// presentation, avoiding a bool/page-ID race and a missed lastCapture observer.
    private func processScan(_ image: UIImage, quarterTurns: Int = 0) {
        camera.stop()
        awaitingScanReview = true
        store.add(image, mode: .scan, filter: Enhancement(rawValue: enhancement) ?? .auto, quarterTurns: quarterTurns) { result in
            awaitingScanReview = false
            switch result {
            case .success(.added(let page)):
                reviewPage = page
            case .success(.duplicate):
                break  // The existing duplicate alert owns the next decision.
            case .failure:
                resume()  // Store reports the processing error; never leave capture blocked.
            }
        }
    }

    private func restoreGalleryCapture() async {
        guard !galleryRecoveryLoaded else { return }
        do {
            galleryCapture = try await PendingGalleryStore.shared.load()
            galleryRecoveryLoaded = true
            if galleryCapture != nil {
                gallerySaveError = "이전에 저장 완료를 확인하지 못한 촬영본이 있어요. 사진 앱에서 저장 여부를 확인한 뒤 다시 저장하거나 버릴 수 있어요."
            } else {
                resume()
            }
        } catch {
            galleryRecoveryLoaded = true
            gallerySaveError = error.localizedDescription
        }
    }
    private func clearGalleryCapture() {
        guard let capture = galleryCapture else { return }
        savingToGallery = true
        Task { @MainActor in
            do {
                try await PendingGalleryStore.shared.remove(capture)
                if let url = camera.videoURL, FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                galleryCapture = nil
                camera.videoURL = nil
                gallerySaveError = nil
                savingToGallery = false
                resume()
            } catch {
                savingToGallery = false
                gallerySaveError = error.localizedDescription
            }
        }
    }
    private func saveToGallery() {
        guard galleryCapture != nil, !savingToGallery else { return }
        savingToGallery = true
        Task { @MainActor in
            let background = GallerySaveBackgroundTask()
            defer { background.finish() }
            do {
                // Persist before requesting Photos permission; then release the full decoded image.
                guard var prepared = galleryCapture else {
                    savingToGallery = false
                    return
                }
                do { prepared = try await PendingGalleryStore.shared.stage(prepared) } catch {
                    if let recovered = try? await PendingGalleryStore.shared.load(), recovered.id == prepared.id {
                        galleryCapture = recovered
                    } else {
                        throw NSError(
                            domain: "Hushto.PendingGallery", code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "촬영본을 임시 보관하지 못했어요. 앱을 종료하지 말고 저장 공간을 확보한 뒤 다시 저장해주세요. "
                                    + error.localizedDescription
                            ])
                    }
                    throw error
                }
                galleryCapture = prepared
                try await PhotoLibraryWriter.save(prepared)
                try await PendingGalleryStore.shared.remove(prepared)
                galleryCapture = nil
                camera.videoURL = nil
                gallerySaveError = nil
                savingToGallery = false
                resume()
            } catch {
                savingToGallery = false
                gallerySaveError = error.localizedDescription
            }
        }
    }
    private func shutter() {
        guard galleryRecoveryLoaded else {
            store.notice = AppNotice(title: "촬영 준비 중", message: "이전 촬영본을 확인하고 있어요. 잠시 후 다시 촬영해주세요.")
            return
        }
        guard galleryCapture == nil, !savingToGallery else {
            if !savingToGallery { gallerySaveError = "아직 저장되지 않은 촬영본이 있어요. 다시 저장하거나 버린 뒤 촬영해주세요." }
            return
        }
        capturedMode = mode
        requestedPhotoMode = mode == .video ? nil : mode
        if mode == .video {
            blink = false
            camera.configureAuto(false, detection: false)
            if isSimulator {
                store.notice = AppNotice(
                    title: "실기기에서 녹화해주세요", message: "시뮬레이터에는 카메라가 없어요. iPhone에서 소리와 함께 동영상을 녹화할 수 있어요.")
            } else {
                camera.toggleRecording()
            }
        } else if isSimulator, let image = UIImage(named: "CameraSample") {
            receive(image)
        } else {
            capturedMode = mode
            camera.capture(silent: silent)
        }
    }
}

private struct CameraScreenContent: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var store: ScanStore
    @Binding var mode: CaptureMode
    @Binding var auto: Bool
    @Binding var picker: PhotosPickerItem?
    @Binding var pages: Bool
    @Binding var settings: Bool
    let blink: Bool
    let isSimulator: Bool
    let configureAuto: () -> Void
    let shutter: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    CameraTopBar(
                        camera: camera,
                        mode: mode,
                        auto: $auto,
                        settings: $settings,
                        configureAuto: configureAuto
                    )
                    .padding(.horizontal, horizontalInset(geometry))
                    .padding(.bottom, 16)
                    cameraPreview(in: geometry)
                        .overlay(alignment: .bottom) {
                            captureModePicker.padding(.bottom, 18)
                        }
                        .padding(.horizontal, viewfinderInset(geometry))
                    captureControls
                        .padding(.horizontal, horizontalInset(geometry))
                        .padding(.top, 16)
                    if !store.pages.isEmpty {
                        pageStatus.padding(.horizontal, horizontalInset(geometry))
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: geometry.size.width)
                .frame(minHeight: max(0, geometry.size.height - 5), alignment: .top)
                .padding(.top, 0)
                .padding(.bottom, 5)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func cameraPreview(in geometry: GeometryProxy) -> some View {
        ZStack {
            if isSimulator {
                Image("CameraSample")
                    .resizable()
                    .scaledToFill()
                    .frame(width: viewfinderWidth(geometry), height: previewHeight(geometry))
                    .clipped()

            } else if camera.status == .ready {
                CameraPreview(session: camera.session, onPinch: camera.handlePinchZoom)
            } else {
                CameraUnavailableView(camera: camera)
            }

            if let frame = camera.transitionFrame {
                Image(uiImage: frame).resizable().scaledToFill()
                    .frame(width: viewfinderWidth(geometry), height: previewHeight(geometry))
                    .clipped().allowsHitTesting(false).accessibilityHidden(true)
            }

            if mode.needsCorrection && (isSimulator || camera.status == .ready) {
                CameraDetectionOverlay(feedback: camera.detectionFeedback)
            }

            if blink && mode == .photo && !camera.recording {
                Color.white.opacity(0.8)
            }

            if camera.recording {
                VStack {
                    CameraRecordingBadge(startedAt: camera.recordingStartedAt)
                    Spacer()
                }
                .padding()
            }
        }
        .frame(width: viewfinderWidth(geometry), height: previewHeight(geometry))
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            if let zoom = zoomBadgeText {
                zoomBadge(zoom).padding(.horizontal, 12).padding(.bottom, 76)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    private func zoomBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.label)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .hushtoGlassControl()
            .allowsHitTesting(false)
    }

    private var zoomBadgeText: String? {
        guard isSimulator || camera.status == .ready else { return nil }
        return CameraZoomRules.badgeText(factor: camera.zoomFactor)
    }

    private var captureModePicker: some View {
        AdvancedCameraModeSelector(mode: $mode)
            .accessibilityElement(children: .contain)
            .disabled(camera.recording || camera.capturing || store.busy)
            .onChange(of: mode) { _, _ in
                if !mode.needsCorrection { auto = false }
                configureAuto()
            }
    }

    private var captureControls: some View {
        HStack {
            PhotosPicker(selection: $picker, matching: .images) {
                AssetIcon(name: "GalleryIcon")
            }
            .hushtoCameraButton()
            .accessibilityLabel("사진 가져오기")
            .disabled(camera.recording || store.busy)

            Spacer()

            Button(action: shutter) {
                AssetIcon(
                    name: camera.recording ? "VideoRecordingShutter" : "Shutter",
                    size: CGSize(width: 72, height: 72))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(mode == .video ? "동영상 녹화 또는 중지" : "무음 촬영")
            .disabled(store.busy || camera.capturing || (!isSimulator && camera.status != .ready))

            Spacer()

            Button {
                camera.flip()
            } label: {
                AssetIcon(name: "FlipIcon")
            }
            .hushtoCameraButton()
            .accessibilityLabel("카메라 전환")
            .disabled(camera.recording)
        }
        .frame(height: 72)
    }

    private var pageStatus: some View {
        HStack {
            if !store.pages.isEmpty {
                Button("\(store.pages.count)페이지 · 페이지 관리") {
                    pages = true
                }
                .font(.footnote)
            }
            Spacer()
            if auto {
                Text("자동 촬영 켜짐")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(height: 24)
    }

    private func horizontalInset(_ geometry: GeometryProxy) -> CGFloat {
        geometry.size.width < 350 ? 16 : 24
    }

    private func viewfinderInset(_ geometry: GeometryProxy) -> CGFloat {
        16
    }

    private func viewfinderWidth(_ geometry: GeometryProxy) -> CGFloat {
        max(1, geometry.size.width - viewfinderInset(geometry) * 2)
    }

    private func previewHeight(_ geometry: GeometryProxy) -> CGFloat {
        let pageStatusHeight: CGFloat = store.pages.isEmpty ? 0 : 24
        // Figma: 44pt Navigation + 16pt gap + 16pt gap + 72pt Actions.
        // Keep the 358×614 viewfinder ratio when the safe area permits it.
        let available = geometry.size.height - 153 - pageStatusHeight
        return max(140, min(viewfinderWidth(geometry) * 614 / 358, available))

    }

}

private struct CameraTopBar: View {
    @ObservedObject var camera: CameraController
    let mode: CaptureMode
    @Binding var auto: Bool
    @Binding var settings: Bool
    let configureAuto: () -> Void

    var body: some View {
        HStack {
            Button {
                camera.toggleTorch()
            } label: {
                CameraNavigationButtonLabel {
                    if camera.torch {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(Theme.label)
                            .frame(width: 24, height: 24)
                    } else {
                        Image("FlashIcon")
                            .renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("플래시")
            .accessibilityValue(camera.torch ? "켜짐" : "꺼짐")

            Spacer()

            Button {
                settings = true
            } label: {
                VStack(spacing: 4) {
                    Text("Demo-Hushto")
                        .font(.system(size: 17, weight: .semibold))
                    AssetIcon(name: "Chevron", size: CGSize(width: 12, height: 7))
                }
                .frame(width: 90, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Demo-Hushto 설정")

            Spacer()

            autoCaptureControl
                .buttonStyle(.plain)
                .accessibilityLabel("자동 촬영")
                .accessibilityValue(auto ? "켜짐" : "꺼짐")
                .accessibilityHint(mode.needsCorrection ? "문서 영역이 안정되면 자동으로 촬영합니다" : "스캔 모드에서 사용할 수 있습니다")
                .disabled(!mode.needsCorrection)

        }
        .frame(height: 44)
    }

    private var autoCaptureControl: some View {
        Button {
            auto.toggle()
            configureAuto()
        } label: {
            CameraNavigationButtonLabel {
                AutoCaptureStatusIcon(isOn: auto)
            }
        }
    }

}

private struct CameraUnavailableView: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
            Text(camera.status == .denied ? "카메라 접근을 허용해주세요" : "카메라를 준비하고 있어요")
                .font(.headline)
            if camera.status == .denied {
                Text("문서를 촬영하려면 설정에서 카메라 권한을 켜주세요.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            } else if camera.status == .unavailable {
                Text("카메라를 사용할 수 없어요")
                    .font(.footnote)
                Button("다시 시도") {
                    camera.start()
                }
                .buttonStyle(.bordered)
            } else {
                ProgressView()
            }
        }
        .padding()
    }
}
