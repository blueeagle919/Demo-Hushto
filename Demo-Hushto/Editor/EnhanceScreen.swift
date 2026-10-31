import AVKit
import PDFKit
import Photos
import SwiftUI
import UniformTypeIdentifiers

struct EnhanceScreen: View {
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
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    editorPreview
                        .frame(height: previewHeight(in: geo.size))
                        .padding(.horizontal, 24)
                        .padding(.top, tool == .crop ? 28 : 34)
                    Text(guidance)
                        .font(.footnote).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 18)
                        .padding(.horizontal, 24)
                        .padding(.top, tool == .crop ? 20 : (is3D ? 15 : 12))
                    if tool != .crop && !is3D { Spacer(minLength: 0) }
                    if tool != .crop {
                        contextPanel
                            .padding(.horizontal, is3D ? 0 : 4)
                            .padding(.vertical, is3D || tool == .adjust ? 0 : 5)
                            .modifier(EditorContextSurface(glass: tool != .adjust && !is3D))
                            .disabled(store.busy)
                            .frame(minHeight: is3D ? 90 : 54)
                            .padding(.horizontal, 24)
                            .padding(.top, is3D ? 15 : 0)
                    }
                    toolDock
                        .padding(.horizontal, 24)
                        .padding(.top, tool == .crop ? 10 : (is3D ? 13 : (tool == .adjust ? 14 : 12)))
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: tool != .crop && !is3D ? max(0, geo.size.height - (tool == .adjust ? 16 : 20)) : 0, alignment: .top)
                .padding(.bottom, is3D ? 6 : (tool == .adjust ? 16 : 20))
            }
            .scrollIndicators(.hidden)
            .modifier(EditorScrollEdgeStyle())
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
        .alert(item: $store.notice) { n in
            Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("확인")))
        }
    }
    private var is3D: Bool { tool == .rotate && rotation3D }
    private var guidance: String {
        if tool == .crop { return "네 모서리를 문서 끝에 맞추고, 각각 조정하세요." }
        if is3D { return "좌우와 상하 기울기를 따로 조절하세요" }
        if tool == .rotate { return "회전 · \(geometry.quarterTurns * 90)°" }
        return pageLabel
    }
    @ViewBuilder private var editorPreview: some View {
        if tool == .crop {
            CropEditor(image: cropPreview, appleStyle: true, geometry: $draft).disabled(store.busy)
        } else if is3D {
            PerspectiveZoomPreview(image: preview, fillsFrame: false, contentInset: 12)
        } else {
            DocumentPreview(image: preview, fillsFrame: false, contentInset: 12, surface: Theme.background)
        }
    }
    private func previewHeight(in size: CGSize) -> CGFloat {
        if tool == .crop { return max(160, min((size.width - 48) * 557 / 342, size.height - 162)) }
        if is3D { return max(120, min((size.width - 48) * 462 / 342, size.height - 257)) }
        // Figma's brightness/contrast/2D rotation share a 342×490 viewport.
        // Every regular editor tool uses the same bounds; control spacing below
        // absorbs the adjustment labels without moving the preview or tool dock.
        return max(160, min((size.width - 48) * 490 / 342, size.height - 229))
    }

    @ViewBuilder private var contextPanel: some View {
        switch tool {
        case .filters:
            HStack(spacing: 2) {
                ForEach(Enhancement.allCases) { item in
                    Button {
                        filter = item
                        tool = .filters
                    } label: {
                        Text(item.rawValue).font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(filter == item ? Theme.onAccent : Theme.label)
                            .background { if filter == item { Capsule().fill(Theme.label.opacity(0.9)) } }
                    }.buttonStyle(.plain).accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }
        case .rotate:
            if rotation3D {
                VStack(spacing: 2) {
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
                    Button("2D 회전") { rotation3D = false }.frame(maxWidth: .infinity, minHeight: 54)
                    Button("재설정") {
                        geometry.horizontalTilt = nil
                        geometry.verticalTilt = nil
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
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
                    ), crispSelection: false)
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
        HStack(spacing: 12) {
            Text(title).frame(width: 96, alignment: .leading)
            Slider(value: value, in: -20...20, step: 1).tint(Theme.label).accessibilityLabel(title)
            Text(String(format: value.wrappedValue == 0 ? "%.0f°" : "%+.0f°", value.wrappedValue))
                .monospacedDigit().frame(width: 36, alignment: .trailing)
        }.font(.system(size: 13)).frame(minHeight: 44)
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
            }.frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(selected ? Theme.onAccent : Theme.label)
                .background { if selected { Capsule().fill(Theme.label).allowsHitTesting(false) } }
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}
