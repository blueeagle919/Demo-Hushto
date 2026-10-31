import AVKit
import PDFKit
import Photos
import SwiftUI
import UniformTypeIdentifiers

struct IPadEnhanceScreen: View {
    let page: ScanPage
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var filter: Enhancement = .auto
    @ViewState private var brightness = 0.0
    @ViewState private var contrast = 1.0
    @ViewState private var geometry = PageGeometry()
    @ViewState private var draft = PageGeometry()
    @ViewState private var initialCrop = PageGeometry()
    @ViewState private var tool = EditorTool.filters
    @ViewState private var adjustingContrast = false
    @ViewState private var rotation3D = false
    @ViewState private var preview: UIImage?
    @ViewState private var cropPreview: UIImage?
    @ViewState private var ready = false
    private var key: String { "\(ready)-\(filter)-\(brightness)-\(contrast)-\(geometry)" }
    private var pageLabel: String {
        let number = (store.pages.firstIndex(where: { $0.id == page.id }) ?? 0) + 1
        return "\(number)페이지 · \((page.mode ?? .scan).rawValue)"
    }
    var body: some View {
        GeometryReader { workspace in
        IPadWorkspace(
            preview: {
                Group {
                    if tool == .crop {
                        CropEditor(image: cropPreview, appleStyle: true, geometry: $draft).disabled(store.busy)
                    } else if tool == .rotate && rotation3D {
                        PerspectiveZoomPreview(image: preview, fillsFrame: false)
                    } else {
                        DocumentPreview(image: preview, fillsFrame: false, contentInset: 20, surface: Theme.background)
                    }
                }
            },
            inspector: {
                GeometryReader { proxy in
                    ScrollView {
                        let landscape = IPadLayout.isLandscape(workspace.size)
                        VStack(spacing: 0) {
                            if landscape {
                                toolDock.padding(.top, 12)
                                if tool != .crop { inspectorContext.padding(.top, 12) }
                                inspectorGuidance.padding(.top, 24)
                            } else {
                                Spacer(minLength: 0)
                                inspectorGuidance
                                if tool != .crop { inspectorContext.padding(.top, 10) }
                                toolDock.padding(.top, 12)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: landscape ? 0 : max(0, proxy.size.height - 4), alignment: .top)
                        .padding(.bottom, landscape ? 0 : 4)
                    }.scrollIndicators(.hidden)
                }
            }, portraitInspectorHeight: tool == .rotate && rotation3D ? 246 : 214, topInset: 62
        )
        }
        .background(Theme.background)
        .navigationTitle(tool == .crop ? "자르기" : (tool == .rotate && rotation3D ? "3D 회전" : "사진 보정"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // Keep one leading item throughout tool changes so the native
            // back button cannot overlap a newly inserted crop cancel button.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if tool == .crop { tool = .filters }
                    else { dismiss() }
                } label: {
                    Image(systemName: "chevron.left")
                }.accessibilityLabel(tool == .crop ? "자르기 취소" : "뒤로")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    if tool == .crop {
                        var applied = geometry
                        applied.resetCrop()
                        applied.sourceCorners = draft.points.map(CropPoint.init)
                        store.update(
                            page, filter: filter, brightness: brightness, contrast: contrast, geometry: applied
                        ) {
                            geometry = applied
                            tool = .filters
                        }
                    } else {
                        store.update(
                            page, filter: filter, brightness: brightness, contrast: contrast, geometry: geometry
                        ) { dismiss() }
                    }
                } label: {
                    Image(systemName: "checkmark")
                }
                .disabled(store.busy || preview == nil || (tool == .crop && cropPreview == nil))
                .accessibilityLabel(tool == .crop ? "자르기 적용" : "보정 저장")
            }
        }
        .overlay {
            if store.busy {
                ProgressView("보정 저장 중…").padding(24).background(
                    .regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .onAppear {
            guard !ready else { return }
            let current = store.pages.first(where: { $0.id == page.id }) ?? page
            filter = current.filter
            brightness = current.brightness
            contrast = current.contrast
            geometry = current.geometry ?? PageGeometry()
            preview = store.cachedDisplayImage(current)
            ready = true
        }
        .task(id: key) {
            guard ready else { return }
            let current = store.pages.first(where: { $0.id == page.id }) ?? page
            if filter == current.filter && brightness == current.brightness && contrast == current.contrast
                && geometry == (current.geometry ?? PageGeometry()) {
                let saved = await store.loadDisplayImage(current)
                guard !Task.isCancelled else { return }
                preview = saved
                return
            }
            // Coalesce rapid slider ticks without imposing the previous 160ms
            // minimum delay on every button press.
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            do {
                let result = try await EnhancementPreviewRenderer.shared.render(
                    url: store.url(current.original),
                    filter: filter, brightness: brightness, contrast: contrast, corrected: current.corrected,
                    correctionCorners: current.correctionCorners, geometry: geometry)
                try Task.checkCancellation()
                preview = result.0
            } catch is CancellationError { return } catch { store.report(error) }
        }
        .task(id: tool) {
            guard tool == .crop else {
                cropPreview = nil
                return
            }
            let current = store.pages.first(where: { $0.id == page.id }) ?? page
            let result = await OriginalCropLoader.load(
                url: store.url(current.original), geometry: geometry,
                correction: current.correctionCorners, corrected: current.corrected)
            guard !Task.isCancelled else { return }
            if let result {
                cropPreview = result.0
                draft = PageGeometry()
                draft.corners = result.1.map(CropPoint.init)
                initialCrop = draft
            } else {
                store.report(HushtoError.image)
                tool = .filters
            }
        }
        .overlay { IPadNoticeOverlay(notice: $store.notice) }
    }
    private var inspectorContext: some View {
        contextPanel.padding(.horizontal, tool == .rotate && rotation3D ? 0 : 8).padding(.vertical, 6)
            .frame(minHeight: tool == .rotate && rotation3D ? 0 : 64)
            .modifier(EditorContextSurface(glass: tool != .adjust && !(tool == .rotate && rotation3D)))
            .disabled(store.busy)
    }
    private var inspectorGuidance: some View {
        Text(tool == .crop
             ? "네 모서리를 문서 끝에 맞추고, 각각 조정하세요."
             : (tool == .rotate
                ? (rotation3D ? "좌우와 상하 기울기를 따로 조절하세요" : "회전 · \(geometry.quarterTurns * 90)°")
                : pageLabel))
            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, minHeight: 24)
    }
    @ViewBuilder private var contextPanel: some View {
        switch tool {
        case .filters:
            HStack(spacing: 8) {
                ForEach(Enhancement.allCases) { item in
                    Button {
                        filter = item
                        tool = .filters
                    } label: {
                        Text(item.rawValue).font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 52)
                            .foregroundStyle(filter == item ? Theme.onAccent : Theme.label)
                            .background { if filter == item { Capsule().fill(Theme.label.opacity(0.9)) } }
                    }.buttonStyle(.plain).accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }
        case .rotate:
            if rotation3D {
                VStack(spacing: 4) {
                    tiltSlider(
                        "좌우 기울기",
                        value: Binding(get: { geometry.tiltHorizontal }, set: { geometry.horizontalTilt = $0 }))
                    tiltSlider(
                        "상하 기울기", value: Binding(get: { geometry.tiltVertical }, set: { geometry.verticalTilt = $0 }))
                }
            } else {
                HStack(spacing: 8) {
                    rotationButton("−90°") { geometry.rotateLeft() }
                    rotationButton("+90°") { for _ in 0..<3 { geometry.rotateLeft() } }
                    rotationButton("재설정") {
                        while geometry.quarterTurns != 0 { geometry.rotateLeft() }
                    }.disabled(geometry.quarterTurns == 0)
                    Button("3D 회전") { rotation3D = true }
                        .font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.surface, in: Capsule()).buttonStyle(.plain)
                }
            }
        case .adjust:
            VStack(spacing: 0) {
                HStack {
                    Button {
                        if adjustingContrast { adjustingContrast = false } else { brightness = 0 }
                    } label: {
                        Text(adjustingContrast ? "밝기" : "밝기  \(Int((brightness * 100).rounded()))")
                    }.frame(maxWidth: .infinity)
                    Button {
                        if adjustingContrast { contrast = 1 } else { adjustingContrast = true }
                    } label: {
                        Text(adjustingContrast ? "대비  \(Int(((contrast - 1) * 100).rounded()))" : "대비")
                    }.frame(maxWidth: .infinity)
                }.font(.system(size: 13)).frame(minHeight: 24)
                if adjustingContrast {
                    EditorAdjustmentSlider(value: $contrast, range: 0.6...1.6).accessibilityLabel("대비")
                } else {
                    EditorAdjustmentSlider(value: $brightness, range: -0.3...0.3).accessibilityLabel("밝기")
                }
            }.tint(Theme.label)
        case .crop:
            Text("모서리를 하나씩 끌어 조정할 수 있어요").font(.system(size: 15)).frame(maxWidth: .infinity)
        }
    }
    private var toolDock: some View {
        Group {
            if tool == .rotate && rotation3D {
                HStack(spacing: 8) {
                    Button("2D 회전") { rotation3D = false }.frame(maxWidth: .infinity, minHeight: 64)
                    Button("재설정") {
                        geometry.horizontalTilt = nil
                        geometry.verticalTilt = nil
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .disabled(geometry.tiltHorizontal == 0 && geometry.tiltVertical == 0)
                }.font(.system(size: 15)).buttonStyle(.plain)
            } else if tool == .crop {
                HStack(spacing: 8) {
                    dockButton("재설정", symbol: "arrow.counterclockwise", selected: false) { draft = initialCrop }
                        .disabled(draft == initialCrop)
                    dockButton("자동 맞춤", symbol: "crop", selected: true) { autoFit() }
                }
            } else {
                EditorToolSelector(
                    selection: Binding(
                        get: { tool },
                        set: { selected in
                            if selected == .crop {
                                cropPreview = nil
                                tool = .crop
                            } else {
                                tool = selected
                            }
                        }
                    ), crispSelection: false, cellHeight: 64)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .background {
            HushtoSelectorBackplate()

                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 3)
        .disabled(store.busy)
    }
    private func tiltSlider(_ title: String, value: Binding<Double>) -> some View {
        IPadTiltSlider(title: title, value: value)
    }

    private func rotationButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if title == "−90°" || title == "+90°" {
                    Image(systemName: title == "−90°" ? "arrow.counterclockwise" : "arrow.clockwise")
                        .font(.system(size: 24, weight: .regular))
                } else {
                    Text(title).font(.system(size: 13))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44).background(Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "−90°" ? "왼쪽 90도 회전" : (title == "+90°" ? "오른쪽 90도 회전" : title))
    }
    private func autoFit() {
        guard let image = cropPreview, let ci = CIImage(image: image) else { return }
        Task { @MainActor in
            let points = await Task.detached(priority: .userInitiated) {
                ImageProcessor().documentCorners(in: ci)
            }.value
            guard tool == .crop, PageGeometry.valid(points) else { return }
            draft.corners = points.map(CropPoint.init)
        }
    }
    private func dockButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 21))
                Text(title).font(.system(size: 11))
            }.frame(maxWidth: .infinity, minHeight: 64)
                .foregroundStyle(selected ? Theme.onAccent : Theme.label)
                .background { if selected { Capsule().fill(Theme.label).allowsHitTesting(false) } }
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}
