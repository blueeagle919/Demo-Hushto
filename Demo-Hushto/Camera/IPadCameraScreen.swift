import SwiftUI
import PhotosUI

struct IPadCameraScreenContent: View {
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
            let wide = IPadLayout.isLandscape(geometry.size)
            ScrollView {
            VStack(spacing: 16) {
                IPadCameraTopBar(camera: camera, mode: mode, auto: $auto, settings: $settings, configureAuto: configureAuto)
                if wide {
                    HStack(spacing: 16) {
                        cameraPreview(in: geometry)
                        VStack(spacing: 16) {
                            Spacer(minLength: 70)
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
                        .overlay(alignment: .bottom) { captureModePicker.padding(.bottom, 16) }
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
        AdvancedCameraVerticalModeSelector(mode: $mode)
            .disabled(camera.recording || camera.capturing || store.busy)
            .onChange(of: mode) { _, _ in
                if !mode.needsCorrection { auto = false }
                configureAuto()
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
                IPadCameraUnavailableView(camera: camera, portrait: !IPadLayout.isLandscape(geometry.size))
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
                zoomBadge(zoom).padding(.horizontal, 12).padding(.bottom, 12)
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
        if IPadLayout.isLandscape(geometry.size) {
            return max(1, geometry.size.width - IPadLayout.inset(geometry.size) * 2 - 230 - 16)
        }
        return IPadLayout.cameraPreviewSize(geometry.size, hasPages: !store.pages.isEmpty).width
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
        .frame(height: 50)
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

private struct IPadCameraUnavailableView: View {
    @ObservedObject var camera: CameraController
    var portrait: Bool

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
                if portrait {
                    IPadActionButton(title: "설정 열기", prominent: true, action: openSettings)
                } else { Button("설정 열기", action: openSettings).buttonStyle(.bordered) }

            } else if camera.status == .unavailable {
                Text("카메라를 사용할 수 없어요")
                    .font(.footnote)
                if portrait {
                    IPadActionButton(title: "다시 시도", prominent: true) { camera.start() }
                } else { Button("다시 시도") { camera.start() }.buttonStyle(.bordered) }

            } else {
                ProgressView()
            }
        }
        .padding()
    }
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
