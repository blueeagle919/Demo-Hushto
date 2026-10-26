import SwiftUI
import PhotosUI
import Photos

struct IPadCameraScreen: View {
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
    @ViewState private var review = false
    @ViewState private var reviewPageID: UUID?
    @ViewState private var awaitingScanReview = false
    @ViewState private var blink = false
    @ViewState private var picker: PhotosPickerItem?
    @ViewState private var galleryCapture: GalleryCapture?
    @ViewState private var savingToGallery = false
    @ViewState private var galleryRecoveryLoaded = false
    @ViewState private var galleryWasBackgrounded = false
    @ViewState private var savedMode: CaptureMode?
    @ViewState private var gallerySaveError: String?
    @ViewState private var capturedMode: CaptureMode = .photo
    @ViewState private var appeared = false
    private var simulatorAutoActive: Bool {
        isSimulator && auto && mode.needsCorrection && scenePhase == .active &&
        !settings && !pages && !review && !store.busy && galleryRecoveryLoaded && galleryCapture == nil && store.duplicate == nil
    }
    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
    var body: some View {
        NavigationStack {
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
                saving: savingToGallery,
                savedMode: savedMode,
                configureAuto: configureAuto,
                shutter: shutter
            ).background(Theme.background).toolbar(.hidden, for: .navigationBar)
                .fullScreenCover(isPresented: $settings, onDismiss: resume) { IPadSettingsScreen(camera: camera, onFinish: { settings = false }).environmentObject(store) }
                .fullScreenCover(isPresented: $pages, onDismiss: resume) { NavigationStack { IPadPagesScreen(onFinish: { pages = false }).environmentObject(store) } }
                .fullScreenCover(isPresented: $review, onDismiss: resume) {
                    if let id = reviewPageID { NavigationStack { IPadCaptureReview(pageID: id, onFinish: { review = false }).environmentObject(store) } }
                }
                .alert("갤러리에 저장하지 못했어요", isPresented: Binding(
                    get: { gallerySaveError != nil },
                    set: { if !$0 { gallerySaveError = nil } }
                )) {
                    Button("다시 저장") { saveToGallery() }
                    Button("설정 열기") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Button("촬영본 버리기", role: .destructive) { clearGalleryCapture() }
                } message: { Text(gallerySaveError ?? "") }
                .overlay { if store.busy { ProgressView("처리 중…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
                .alert(item: $store.notice) { notice in Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("확인"))) }
                .alert("같은 페이지를 촬영한 것 같아요", isPresented: $duplicateAlert) {
                    Button("다시 촬영", role: .cancel) { store.rejectDuplicate(); resume() }
                    Button("그래도 추가") { if let page = store.duplicate { store.accept(page) } }
                } message: { Text("기존 페이지와 매우 비슷해요. 추가할까요?") }
                .alert("카메라 안내", isPresented: Binding(get: { camera.error != nil }, set: { if !$0 { camera.error = nil } })) {
                    Button("확인", role: .cancel) { camera.error = nil }
                } message: { Text(camera.error ?? "") }
                .onAppear {
                    if !appeared { mode = CaptureMode(rawValue: defaultMode) ?? .photo; appeared = true }
                    camera.onCapture = receive; resume()
                }
                .onChange(of: store.duplicate?.id) { _, id in duplicateAlert = id != nil }
                .onChange(of: store.lastCapture) { _, id in if let id, awaitingScanReview { awaitingScanReview = false; reviewPageID = id; camera.stop(); review = true } }
                .onChange(of: camera.videoURL) { _, url in if let url { galleryCapture = GalleryCapture(videoURL: url); saveToGallery() } }
                .onChange(of: camera.status) { _, status in if status == .ready && defaultFlash && !camera.torch { camera.toggleTorch() } }
                .onChange(of: picker) { _, item in
                    guard let item else { return }
                    camera.stop(); capturedMode = mode
                    Task {
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw HushtoError.image }
                            awaitingScanReview = true
                            store.add(image, mode: capturedMode, filter: Enhancement(rawValue: enhancement) ?? .auto)
                        } catch { store.report(error); resume() }
                        picker = nil
                    }
                }
                .onChange(of: settings) { _, shown in if shown { camera.stop() } }
                .onChange(of: pages) { _, shown in if shown { camera.stop() } }
                .onChange(of: store.busy) { _, busy in if !busy { resume() } }
                .onChange(of: scenePhase) { _, phase in if phase == .active {
                    let retryAfterSettings = galleryWasBackgrounded
                    galleryWasBackgrounded = false
                    if retryAfterSettings && galleryRecoveryLoaded && galleryCapture != nil && !savingToGallery { saveToGallery() }
                    else { resume() }
                } else {
                    if phase == .background { galleryWasBackgrounded = true }
                    camera.stop()
                } }
                .task { await restoreGalleryCapture() }
                .task(id: simulatorAutoActive) { await runSimulatorAutoCapture() }
        }
    }
    @MainActor private func runSimulatorAutoCapture() async {
        guard simulatorAutoActive, let sample = UIImage(named: "CameraSample") else { return }
        let points = await Task.detached(priority: .userInitiated) {
            guard let image = CIImage(image: sample) else { return [CGPoint]() }
            return ImageProcessor().documentCorners(in: image)
        }.value
        guard !Task.isCancelled else { return }
        camera.detected = points.count == 4
        var stability = AutomaticScanStability()
        while !Task.isCancelled && simulatorAutoActive {
            if stability.observe(points, now: ProcessInfo.processInfo.systemUptime, enabled: true) {
                capturedMode = mode; receive(sample); return
            }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }
    private func horizontalInset(_ geo: GeometryProxy) -> CGFloat { geo.size.width < 350 ? 16 : 24 }
    private func contentWidth(_ geo: GeometryProxy) -> CGFloat { max(0, geo.size.width - horizontalInset(geo) * 2) }
    private func previewHeight(_ geo: GeometryProxy) -> CGFloat {
        min(contentWidth(geo) * 416 / 342, max(140, geo.size.height - 320))
    }
    private func configureAuto() { capturedMode = mode; camera.configureAuto(auto, detection: mode.needsCorrection) }
    private func resume() {
        guard galleryRecoveryLoaded, scenePhase == .active, !settings, !pages, !review, galleryCapture == nil, store.duplicate == nil, !store.busy else { return }
        if !isSimulator { camera.start(); configureAuto() }
    }
    private func receive(_ image: UIImage) {
        guard mode != .video, capturedMode != .video, !camera.recording else { return }
        guard !store.busy, !review, !settings, !pages, galleryCapture == nil, store.duplicate == nil else { return }
        if feedback && capturedMode != .video { blink = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { blink = false } }
        if capturedMode.savesToPhotoLibrary {
            // Photos and videos stay on the camera screen without a result sheet.
            galleryCapture = GalleryCapture(image: image)
            saveToGallery()
        } else {
            // Document, board and screen captures open Capture Review after processing.
            camera.stop()
            awaitingScanReview = true
            store.add(image, mode: capturedMode, filter: Enhancement(rawValue: enhancement) ?? .auto)
        }
    }
    private func restoreGalleryCapture() async {
        guard !galleryRecoveryLoaded else { return }
        do {
            galleryCapture = try await PendingGalleryStore.shared.load()
            galleryRecoveryLoaded = true
            if galleryCapture != nil {
                gallerySaveError = "이전에 저장 완료를 확인하지 못한 촬영본이 있어요. 사진 앱에서 저장 여부를 확인한 뒤 다시 저장하거나 버릴 수 있어요."
            } else { resume() }
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
                if let url = camera.videoURL, FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
                galleryCapture = nil; camera.videoURL = nil; gallerySaveError = nil
                savingToGallery = false; resume()
            } catch { savingToGallery = false; gallerySaveError = error.localizedDescription }
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
                guard var prepared = galleryCapture else { savingToGallery = false; return }
                do { prepared = try await PendingGalleryStore.shared.stage(prepared) }
                catch {
                    if let recovered = try? await PendingGalleryStore.shared.load(), recovered.id == prepared.id {
                        galleryCapture = recovered
                    } else {
                        throw NSError(domain: "Hushto.PendingGallery", code: 1, userInfo: [NSLocalizedDescriptionKey:
                            "촬영본을 임시 보관하지 못했어요. 앱을 종료하지 말고 저장 공간을 확보한 뒤 다시 저장해주세요. " + error.localizedDescription])
                    }
                    throw error
                }
                galleryCapture = prepared
                try await PhotoLibraryWriter.save(prepared)
                try await PendingGalleryStore.shared.remove(prepared)
                galleryCapture = nil; camera.videoURL = nil; gallerySaveError = nil
                savingToGallery = false
                savedMode = prepared.videoURL == nil ? .photo : .video
                let saved = savedMode
                Task { try? await Task.sleep(for:.seconds(2)); if savedMode == saved { savedMode = nil } }
                resume()
            } catch {
                savingToGallery = false
                gallerySaveError = error.localizedDescription
            }
        }
    }
    private func shutter() {
        guard galleryRecoveryLoaded else { return }
        guard galleryCapture == nil, !savingToGallery else {
            if !savingToGallery { gallerySaveError = "아직 저장되지 않은 촬영본이 있어요. 다시 저장하거나 버린 뒤 촬영해주세요." }
            return
        }
        savedMode = nil
        capturedMode = mode
        if mode == .video {
            if isSimulator { store.notice = AppNotice(title: "실기기에서 녹화해주세요", message: "시뮬레이터에는 카메라가 없어요. iPhone에서 무음 동영상을 녹화할 수 있어요.") }
            else { camera.toggleRecording() }
        } else if isSimulator, let image = UIImage(named: "CameraSample") { receive(image) }
        else { capturedMode = mode; camera.capture(silent: silent) }
    }
}

private struct IPadCameraScreenContent: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var store: ScanStore
    @Binding var mode: CaptureMode
    @Binding var auto: Bool
    @Binding var picker: PhotosPickerItem?
    @Binding var pages: Bool
    @Binding var settings: Bool
    let blink: Bool
    let isSimulator: Bool
    let saving: Bool
    let savedMode: CaptureMode?
    let configureAuto: () -> Void
    let shutter: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let wide = IPadLayout.isLandscape(geometry.size)
            ScrollView {
            VStack(spacing: 18) {
                IPadCameraTopBar(camera: camera, mode: mode, auto: $auto, settings: $settings, configureAuto: configureAuto)
                if wide {
                    HStack(spacing: 48) {
                        cameraPreview(in: geometry)
                        VStack(spacing: 16) {
                            Text("촬영 모드").font(.system(size: 17))
                            verticalModePicker
                            Spacer(minLength: 20)
                            captureControls
                            if !store.pages.isEmpty { pageStatus }
                        }
                        .frame(width: 230)
                        .padding(.vertical, 20)
                    }
                } else {
                    cameraPreview(in: geometry)
                    captureModePicker
                    captureControls.padding(.horizontal, min(72, geometry.size.width * 0.08))
                    if !store.pages.isEmpty { pageStatus }
                }
            }
            .padding(.horizontal, IPadLayout.inset(geometry.size))
            .padding(.top, 30).padding(.bottom, 24)
            }.scrollIndicators(.hidden)
        }
    }

    private var verticalModePicker: some View {
        VStack(spacing: 8) {
            ForEach(CaptureMode.allCases) { item in
                Button {
                    mode = item
                    if !mode.needsCorrection { auto = false }
                    configureAuto()
                } label: {
                    Text(item.rawValue).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(mode == item ? Theme.onAccent : Theme.label)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background {
                            if mode == item { Capsule().fill(Theme.label).hushtoPadSelectionGlass() }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == item ? .isSelected : [])
            }
        }
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28))
        .hushtoPadGlass()
        .disabled(camera.recording || camera.capturing || store.busy)
    }

    private func cameraPreview(in geometry: GeometryProxy) -> some View {
        ZStack {
            if isSimulator {
                Image("CameraSample")
                    .resizable()
                    .scaledToFill()
                    .frame(width: viewfinderWidth(geometry), height: previewHeight(geometry))
                    .clipped()
                if mode != .video {
                AssetIcon(
                    name: "Corners",
                    size: CGSize(
                        width: viewfinderWidth(geometry) * 292.69 / 350,
                        height: previewHeight(geometry) * 429.087 / 510
                    )
                )
                }
            } else if camera.status == .ready {
                CameraPreview(session: camera.session, onPinch: camera.handlePinchZoom)
                if mode != .video { DetectionOutline(points: camera.corners, imageSize: camera.frameSize) }
            } else {
                IPadCameraUnavailableView(camera: camera)
            }

            if blink && mode != .video && !camera.recording {
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
            if !statusMessage.isEmpty {
                statusText.padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    private var statusText: some View {
        Text(statusMessage)
        .font(.system(size: 13))
        .foregroundStyle(Theme.label)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .hushtoGlassControl()
        .allowsHitTesting(false)
    }

    private var statusMessage: String {
        if !isSimulator {
            switch camera.status {
            case .denied: return "카메라 접근을 허용해주세요"
            case .unavailable: return "카메라를 사용할 수 없어요"
            case .loading: return "카메라를 준비하고 있어요"
            case .ready: break
            }
        }
        if let zoom = CameraZoomRules.badgeText(factor: camera.zoomFactor) { return zoom }
        if camera.recording { return "" }
        if saving { return mode == .video ? "동영상을 Apple 사진에 저장 중이에요" : "사진을 Apple 사진에 저장 중이에요" }
        if savedMode == mode { return mode == .video ? "동영상을 Apple 사진에 저장했어요" : "사진을 Apple 사진에 저장했어요" }
        if camera.capturing || store.busy { return mode.needsCorrection ? "촬영본을 확인할 준비를 하고 있어요" : "사진을 촬영하고 있어요" }
        if auto && mode.needsCorrection {
            return camera.detected ? "문서 인식됨 · 잠시 멈추면 자동 촬영해요" : "자동 촬영 켜짐 · 문서의 네 모서리를 맞춰주세요"
        }
        switch mode {
        case .photo: return ""
        case .document: return "문서를 프레임 안에 맞춰주세요"
        case .board: return "칠판의 네 모서리가 보이게 맞춰주세요"
        case .screen: return "화면의 반사광을 피해서 촬영하세요"
        case .video: return "동영상을 촬영할 준비가 됐어요"
        }
    }

    private var captureModePicker: some View {
        HushtoSlidingSelector(
            titles: CaptureMode.allCases.map(\.rawValue),
            selection: Binding(
                get: { CaptureMode.allCases.firstIndex(of: mode) ?? 0 },
                set: { mode = CaptureMode.allCases[$0] }
            ),
            cellHeight: 48, spacing: 2
        )
        .padding(8)
        .frame(height: 64)
        .background { HushtoSelectorBackplate().allowsHitTesting(false) }
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
                AssetIcon(name: camera.recording ? "VideoRecordingShutter" : "Shutter",
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
        .frame(height: 96)
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

    private func horizontalInset(_ geometry: GeometryProxy) -> CGFloat { 0 }
    private func viewfinderInset(_ geometry: GeometryProxy) -> CGFloat { 0 }
    private func viewfinderWidth(_ geometry: GeometryProxy) -> CGFloat {
        IPadLayout.cameraPreviewSize(geometry.size, hasPages: !store.pages.isEmpty).width
    }
    private func previewHeight(_ geometry: GeometryProxy) -> CGFloat {
        IPadLayout.cameraPreviewSize(geometry.size, hasPages: !store.pages.isEmpty).height
    }

}

private struct IPadCameraTopBar: View {
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
                if camera.torch {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 24, height: 24)
                } else {
                    AssetIcon(name: "FlashIcon")
                }
            }
            .hushtoCameraButton(active: camera.torch)
            .accessibilityLabel("플래시")
            .accessibilityValue(camera.torch ? "켜짐" : "꺼짐")

            Spacer()

            Button {
                settings = true
            } label: {
                VStack(spacing: 4) {
                    Text("Hushto")
                        .font(.system(size: 17, weight: .semibold))
                    AssetIcon(name: "Chevron", size: CGSize(width: 12, height: 7))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hushto 설정")

            Spacer()

            autoCaptureControl
                .hushtoCameraButton(active: auto)
                .accessibilityLabel("자동 촬영")
                .accessibilityValue(auto ? "켜짐" : "꺼짐")
                .accessibilityHint(mode.needsCorrection ? "문서 영역이 안정되면 자동으로 촬영합니다" : "문서, 칠판, 스크린 모드에서 사용할 수 있습니다")
                .disabled(!mode.needsCorrection)

        }
        .frame(height: 50)
    }

    private var autoCaptureControl: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { auto.toggle() }
            configureAuto()
        } label: {
            // Exact 04 Prototype artwork: 24pt centered in a 50pt system glass button.
            Image("AutoCaptureIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(auto ? Theme.onAccent : Theme.label)
                .accessibilityHidden(true)
        }
    }


}

private struct IPadCameraUnavailableView: View {
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
