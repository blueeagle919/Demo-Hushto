import SwiftUI
import PDFKit
import Photos
import AVKit
import UniformTypeIdentifiers

struct IPadCaptureReview: View {
    let pageID: UUID
    var onFinish: (() -> Void)? = nil
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var enhance = false
    @ViewState private var pages = false
    var body: some View {
        IPadWorkspace(preview: {
            if let page = store.pages.first(where: { $0.id == pageID }) {
                DocumentPreview(image: store.preview(page), fillsFrame: true)
            } else { ContentUnavailableView("페이지가 없어요", systemImage: "doc") }
        }, inspector: {
            if let page = store.pages.first(where: { $0.id == pageID }) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(store.pages.count)페이지를 촬영했어요").font(.system(size: 17, weight: .semibold))
                    Text("사진 보정으로 페이지를 다듬거나 다음 촬영을 이어가세요.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    Spacer(minLength: 24)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 24) { reviewActions }
                            .frame(minWidth: 500)
                        VStack(spacing: 16) { reviewActions }
                    }
                    Button { savePhoto(page) } label: { Label("사진 앱에 저장", systemImage: "square.and.arrow.down") }
                        .font(.footnote).frame(minHeight: 44)
                }
                .navigationDestination(isPresented: $enhance) { IPadEnhanceScreen(page: page) }
            }
        }, portraitInspectorHeight: 240)
        .background(Theme.background)
            .navigationTitle("촬영 확인").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("다음 촬영") }
                ToolbarItem(placement: .topBarTrailing) { Button { pages = true } label: { Image(systemName: "checkmark") }.accessibilityLabel("페이지 관리") }
            }
            .navigationDestination(isPresented: $pages) { IPadPagesScreen(onAdd: { dismiss() }, onFinish: onFinish) }
            .alert(item: $store.notice) { n in Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("확인"))) }
    }
    @ViewBuilder private var reviewActions: some View {
        Button { enhance = true } label: {
            Text("사진 보정").frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(Theme.label).background(Theme.surface, in: Capsule())
        }.buttonStyle(.plain)
        PrimaryButton(title: "다음 촬영") { dismiss() }
    }
    private func savePhoto(_ page: ScanPage) {
        guard let image = store.image(page) else { store.report(HushtoError.image); return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in store.notice = AppNotice(title: "사진 저장 권한이 필요해요", message: "설정에서 Hushto의 사진 추가 권한을 허용해주세요.") }; return
            }
            PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) } completionHandler: { success, error in
                Task { @MainActor in
                    if let error { store.report(error) }
                    else if success { store.notice = AppNotice(title: "사진 앱에 저장했어요", message: "촬영한 페이지를 사진 앱에서 확인할 수 있어요.") }
                }
            }
        }
    }
}
struct IPadEnhanceScreen: View {
    let page: ScanPage
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var filter: Enhancement = .auto
    @ViewState private var brightness = 0.0
    @ViewState private var contrast = 1.0
    @ViewState private var geometry = PageGeometry()
    @ViewState private var draft = PageGeometry()
    @ViewState private var tool = EditorTool.filters
    @ViewState private var adjustingContrast = false
    @ViewState private var rotation3D = false
    @ViewState private var preview: UIImage?
    @ViewState private var cropPreview: UIImage?
    @ViewState private var ready = false
    private var key: String { "\(ready)-\(filter)-\(brightness)-\(contrast)-\(geometry)" }
    private var pageLabel: String {
        let number = (store.pages.firstIndex(where: { $0.id == page.id }) ?? 0) + 1
        return "\(number)페이지 · \((page.mode ?? .document).rawValue)"
    }
    var body: some View {
        IPadWorkspace(preview: {
            Group {
                if tool == .crop { CropEditor(image: cropPreview, appleStyle: true, geometry: $draft).disabled(store.busy) }
                else if tool == .rotate && rotation3D { PerspectiveZoomPreview(image: preview, fillsFrame: false) }
                else { DocumentPreview(image: preview, fillsFrame: false, contentInset: 0) }
            }
        }, inspector: {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        if proxy.size.width < 500 { toolDock }
                        Text(tool == .crop ? "네 모서리를 문서의 끝에 맞춰주세요" : (tool == .rotate ? (rotation3D ? "좌우와 상하 기울기를 따로 조절하세요" : "회전 · \(geometry.quarterTurns * 90)°") : pageLabel))
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        contextPanel.disabled(store.busy).frame(minHeight: tool == .rotate && rotation3D ? 92 : 66)
                        if proxy.size.width >= 500 { toolDock }
                    }
                }.scrollIndicators(.hidden)
            }
        }, portraitInspectorHeight: tool == .rotate && rotation3D ? 226 : 194)
        .background(Theme.background)
        .navigationTitle(tool == .crop ? "자르기" : (tool == .rotate && rotation3D ? "3D 회전" : "사진 보정"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(tool == .crop)
        .toolbar {
            if tool == .crop {
                ToolbarItem(placement: .topBarLeading) {
                    Button { tool = .filters } label: { Image(systemName: "chevron.left") }.accessibilityLabel("자르기 취소")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    if tool == .crop {
                        var applied = geometry
                        applied.resetCrop()
                        applied.sourceCorners = draft.points.map(CropPoint.init)
                        store.update(page, filter: filter, brightness: brightness, contrast: contrast, geometry: applied) {
                            geometry = applied; tool = .filters
                        }
                    }
                    else { store.update(page, filter: filter, brightness: brightness, contrast: contrast, geometry: geometry) { dismiss() } }
                } label: { Image(systemName: "checkmark") }
                .disabled(store.busy || preview == nil || (tool == .crop && cropPreview == nil))
                .accessibilityLabel(tool == .crop ? "자르기 적용" : "보정 저장")
            }
        }
        .overlay { if store.busy { ProgressView("보정 저장 중…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)) } }
        .onAppear {
            guard !ready else { return }
            let current = store.pages.first(where: { $0.id == page.id }) ?? page
            filter = current.filter; brightness = current.brightness; contrast = current.contrast
            geometry = current.geometry ?? PageGeometry(); preview = ImageProcessor.previewImage(at: store.url(current.rendered)); ready = true
        }
        .task(id: key) {
            guard ready else { return }
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            let current = store.pages.first(where: { $0.id == page.id }) ?? page
            do {
                let result = try await EnhancementPreviewRenderer.shared.render(url: store.url(current.original),
                    filter: filter, brightness: brightness, contrast: contrast, corrected: current.corrected,
                    correctionCorners: current.correctionCorners, geometry: geometry)
                try Task.checkCancellation()
                preview = result.0
            } catch is CancellationError { return }
            catch { store.report(error) }
        }
        .task(id: tool) {
            guard tool == .crop else { cropPreview = nil; return }
            let current = store.pages.first(where: { $0.id == page.id }) ?? page
            let result = await OriginalCropLoader.load(url: store.url(current.original), geometry: geometry,
                correction: current.correctionCorners, corrected: current.corrected)
            guard !Task.isCancelled else { return }
            if let result { cropPreview = result.0; draft = PageGeometry(); draft.corners = result.1.map(CropPoint.init) }
            else { store.report(HushtoError.image); tool = .filters }
        }
        .alert(item: $store.notice) { n in Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("확인"))) }
    }
    @ViewBuilder private var contextPanel: some View {
        switch tool {
        case .filters:
            HStack(spacing: 8) {
                ForEach(Enhancement.allCases) { item in
                    Button { filter = item; tool = .filters } label: {
                        Text(item.rawValue).font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(filter == item ? Theme.onAccent : Theme.label)
                            .background(filter == item ? Theme.label : Theme.surface, in: Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }
        case .rotate:
            if rotation3D {
                VStack(spacing: 4) {
                    tiltSlider("좌우 기울기", value: Binding(get: { geometry.tiltHorizontal }, set: { geometry.horizontalTilt = $0 }))
                    tiltSlider("상하 기울기", value: Binding(get: { geometry.tiltVertical }, set: { geometry.verticalTilt = $0 }))
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
                    Button { if adjustingContrast { adjustingContrast = false } else { brightness = 0 } } label: { Text(adjustingContrast ? "밝기" : "밝기  \(Int((brightness * 100).rounded()))") }.frame(maxWidth: .infinity)
                    Button { if adjustingContrast { contrast = 1 } else { adjustingContrast = true } } label: { Text(adjustingContrast ? "대비  \(Int(((contrast - 1) * 100).rounded()))" : "대비") }.frame(maxWidth: .infinity)
                }.font(.system(size: 13)).frame(minHeight: 24)
                if adjustingContrast { Slider(value: $contrast, in: 0.6...1.6).accessibilityLabel("대비") }
                else { Slider(value: $brightness, in: -0.3...0.3).accessibilityLabel("밝기") }
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
                    Button("재설정") { geometry.horizontalTilt = nil; geometry.verticalTilt = nil }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .disabled(geometry.tiltHorizontal == 0 && geometry.tiltVertical == 0)
                }.font(.system(size: 15)).buttonStyle(.plain)
            } else if tool == .crop {
                HStack(spacing: 8) {
                    dockButton("재설정", symbol: "arrow.counterclockwise", selected: false) { draft.resetCrop() }.disabled(draft == PageGeometry())
                    dockButton("자동 맞춤", symbol: "crop", selected: true) { autoFit() }
                }
            } else {
                EditorToolSelector(selection: Binding(
                    get: { tool },
                    set: { selected in
                        if selected == .crop { cropPreview = nil; tool = .crop }
                        else { tool = selected }
                    }
                ), crispSelection: page.mode == .screen)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .background {
            HushtoSelectorBackplate()
                .overlay {
                    if page.mode == .screen { Capsule().fill(Theme.surface).padding(1) }
                }
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
        Button(action: action) { Text(title).font(.system(size:13))
            .frame(maxWidth:.infinity,minHeight:44).background(Theme.surface,in:Capsule()) }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "−90°" ? "왼쪽 90도 회전" : (title == "+90°" ? "오른쪽 90도 회전" : title))
    }
    private func autoFit() {
        guard let image = cropPreview, let ci = CIImage(image:image) else { return }
        let points = ImageProcessor().documentCorners(in: ci)
        if PageGeometry.valid(points) { draft.corners = points.map(CropPoint.init) }
    }
    private func dockButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
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
// Keep the context controls crisp instead of fading them beneath a floating dock.
private struct EditorScrollEdgeStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .bottom)
        } else { content }
    }
}
private enum EditorTool: String, CaseIterable, Identifiable {
    case filters = "필터", adjust = "조절", crop = "자르기", rotate = "회전"
    var id: Self { self }
    var symbol: String {
        switch self { case .filters: "camera.filters"; case .adjust: "slider.horizontal.3"; case .crop: "crop"; case .rotate: "rotate.left" }
    }
}
// Figma geometry with the same tap-and-slide behavior as the camera modes.
private struct EditorToolSelector: View {
    @Binding var selection: EditorTool
    var crispSelection = false
    var body: some View {
        HushtoSlidingSelector(
            titles: EditorTool.allCases.map(\.rawValue),
            symbols: EditorTool.allCases.map(\.symbol),
            selection: Binding(
                get: { EditorTool.allCases.firstIndex(of: selection) ?? 0 },
                set: { selection = EditorTool.allCases[$0] }
            ),
            cellHeight: 54, spacing: 8, crispSelection: crispSelection
        )
        .accessibilityElement(children: .contain)
    }
}

struct IPadPagesScreen: View {
    var onAdd: (() -> Void)? = nil
    var onFinish: (() -> Void)? = nil
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selected: Set<UUID> = []
    @ViewState private var selecting = false
    @ViewState private var draggingPage: UUID?
    @ViewState private var deleting = false
    @ViewState private var rename = false
    @ViewState private var draftTitle = ""
    private var pageGrid: some View {
        GeometryReader { geometry in
        let thumbnailHeight: CGFloat = geometry.size.height > geometry.size.width
            ? min(318, max(183, (geometry.size.width - 24) / 2 - 16)) : 183
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Button { draftTitle = store.title; rename = true } label: { Text(store.title).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.label) }
                    Text("\(store.pages.count)페이지 · 길게 눌러 순서를 바꾸세요").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if !store.pages.isEmpty { Menu {
                    Button(selecting ? "선택 취소" : "페이지 선택", systemImage: "checkmark.circle") { selecting.toggle(); selected.removeAll() }
                    Button("전체 삭제", systemImage: "trash", role: .destructive) { selected = Set(store.pages.map(\.id)); deleting = true }
                } label: { Image(systemName: "ellipsis.circle").font(.title2) }.accessibilityLabel("페이지 작업") }
            }.padding(.top, 12)
            if store.pages.isEmpty {
                ContentUnavailableView { Label("아직 촬영한 페이지가 없어요", systemImage: "doc.viewfinder") } description: { Text("촬영하거나 사진을 가져와 스캔을 시작하세요.") } actions: { Button("촬영하러 가기") { dismiss() } }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 24, alignment: .leading), GridItem(.flexible(), spacing: 24, alignment: .leading)], spacing: 24) {
                        ForEach(Array(store.pages.enumerated()), id: \.element.id) { index, page in
                            if selecting {
                                Button { if selected.contains(page.id) { selected.remove(page.id) } else { selected.insert(page.id) } } label: { card(page, index: index, height: thumbnailHeight) }.buttonStyle(.plain)
                            } else {
                                NavigationLink { IPadEnhanceScreen(page: page) } label: { card(page, index: index, height: thumbnailHeight) }
                                    .buttonStyle(.plain)
                                    .onDrag {
                                        draggingPage = page.id
                                        return NSItemProvider(object: page.id.uuidString as NSString)
                                    }
                                    .onDrop(of: [UTType.text], delegate: PageReorderDropDelegate(
                                        targetID: page.id, store: store, dragging: $draggingPage))
                                    .accessibilityAction(named: Text("앞으로 이동")) { store.movePage(page.id, offset: -1) }
                                    .accessibilityAction(named: Text("뒤로 이동")) { store.movePage(page.id, offset: 1) }
                            }
                        }
                    }.padding(.horizontal, 0)
                }
            }
        }
        }
    }
    var body: some View {
        IPadWorkspace(preview: { pageGrid }, inspector: {
            VStack {
                Spacer(minLength: 0)
            if selecting {
                HStack {
                    Button(selected.count == store.pages.count ? "선택 해제" : "전체 선택") { selected = selected.count == store.pages.count ? [] : Set(store.pages.map(\.id)) }
                    Spacer()
                    Button("\(selected.count)페이지 삭제", role: .destructive) { deleting = true }.disabled(selected.isEmpty)
                }.padding(.horizontal, 24)
            }
            NavigationLink { IPadExportScreen(onFinish: onFinish) } label: { Text("PDF 만들기").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 50) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Theme.label).foregroundStyle(Theme.onAccent).disabled(store.pages.isEmpty)
                .padding(.bottom, 12)
            }
        }, portraitInspectorHeight: selecting ? 130 : 80)
        .background(Theme.background).navigationTitle("스캔 문서").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label("돌아가기", systemImage: "chevron.left") }
                        .accessibilityLabel("돌아가기")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("추가") { if let onAdd { onAdd() } else { dismiss() } }
                }
            }
            .alert("선택한 페이지를 삭제할까요?", isPresented: $deleting) {
                Button("취소", role: .cancel) { selected.removeAll() }
                Button("삭제", role: .destructive) { store.delete(selected); selected.removeAll(); selecting = false }
            } message: { Text("\(selected.count)페이지가 삭제돼요. 저장한 PDF는 유지돼요.") }
            .alert("문서 이름", isPresented: $rename) { TextField("문서 이름", text: $draftTitle); Button("저장") { store.rename(draftTitle) }; Button("취소", role: .cancel) {} }
            .alert(item: $store.notice) { n in Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("확인"))) }
    }
    private func card(_ page: ScanPage, index: Int, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = store.thumbnail(page) { Image(uiImage: image).resizable().scaledToFit().id(page.thumbnail).frame(maxWidth: .infinity).frame(height: height).clipShape(RoundedRectangle(cornerRadius: 12)) }
            HStack { Text(String(format: "페이지 %02d", index + 1)).font(.system(size: 13)).foregroundStyle(Theme.secondary); Spacer(); if selecting { Image(systemName: selected.contains(page.id) ? "checkmark.circle.fill" : "circle") } }
        }.frame(width: height <= 183 ? 151 : nil)
        .padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20)).accessibilityLabel("페이지 \(index + 1)")
    }
}
struct IPadExportScreen: View {
    var onFinish: (() -> Void)? = nil
    @EnvironmentObject private var store: ScanStore
    @AppStorage("paperSize") private var defaultPaper = PaperSize.original.rawValue
    @AppStorage("quality") private var defaultQuality = ExportQuality.standard.rawValue
    @ViewState private var name = ""
    @ViewState private var paper = PaperSize.original
    @ViewState private var quality = ExportQuality.standard
    @ViewState private var success = false
    var body: some View {
        GeometryReader { proxy in
            let wide = IPadLayout.isLandscape(proxy.size)
            Group {
                if wide {
                    IPadWorkspace(preview: { exportPreview }, inspector: {
                        ScrollView { VStack(alignment: .leading, spacing: 28) {
                            exportOptions
                            Spacer(minLength: 64)
                            exportAction
                        }}.scrollDismissesKeyboard(.interactively)
                    })
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            exportOptions
                            exportPreview.frame(height: max(220, proxy.size.height * 0.4))
                            exportAction
                        }.padding(32)
                    }.scrollDismissesKeyboard(.interactively)
                }
            }
        }.background(Theme.background).navigationTitle("PDF 만들기").navigationBarTitleDisplayMode(.inline)
            .onAppear { name = store.title; paper = PaperSize(rawValue: defaultPaper) ?? .original; quality = ExportQuality(rawValue: defaultQuality) ?? .standard; store.exportedURL = nil }
            .onChange(of: store.exportedURL) { _, url in if url != nil { success = true } }
            .navigationDestination(isPresented: $success) { if let url = store.exportedURL { IPadPDFSuccess(url: url, count: store.exportedPageCount, onFinish: onFinish) } }
            .alert(item: $store.notice) { n in Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("확인"))) }
    }
    private var exportPreview: some View {
        DocumentPreview(image: store.pages.first.flatMap { store.preview($0) })
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
    }
    private var exportOptions: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("파일 이름").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                HStack { TextField("문서 이름", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled(); Text(".pdf").foregroundStyle(Theme.secondary) }.padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
            }
            VStack(alignment: .leading, spacing: 8) { Text("페이지 크기").font(.footnote).foregroundStyle(Theme.secondary); Picker("페이지 크기", selection: $paper) { ForEach(PaperSize.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).controlSize(.large).frame(minHeight: 44).hushtoGlassControl() }
            VStack(alignment: .leading, spacing: 8) { Text("화질").font(.footnote).foregroundStyle(Theme.secondary); Picker("화질", selection: $quality) { ForEach(ExportQuality.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).controlSize(.large).frame(minHeight: 44).hushtoGlassControl() }
            Text("\(store.pages.count)페이지 · 파일 크기는 이미지에 따라 달라져요").font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
    }
    private var exportAction: some View {
        PrimaryButton(title: store.busy ? "PDF 저장 중…" : "PDF 저장") {
            store.export(name: name, paper: paper, quality: quality)
        }.disabled(store.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

}
struct IPadPDFSuccess: View {
    let url: URL
    let count: Int
    var onFinish: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ViewState private var open = false
    @ViewState private var share = false
    var body: some View {
        IPadWorkspace(preview: {
            VStack(spacing: 16) {
            Image(systemName: "checkmark").font(.system(size: 40)).frame(width: 80, height: 80).background(Theme.label.opacity(0.08), in: Circle())
            Text("PDF가 준비됐어요").font(.system(size: 22, weight: .bold))
            Text(url.lastPathComponent).font(.body)
            VStack(spacing: 0) { info("페이지", "\(count)페이지"); info("파일 크기", ByteCountFormatter.string(fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file)); info("저장 위치", "문서 / Hushto") }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                Spacer(minLength: 0)
            }.frame(maxWidth: 342).frame(maxWidth: .infinity).padding(.top, 40)
        }, inspector: {
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                PDFSuccessAction(title: "PDF 열기", prominent: true) { open = true }
                PDFSuccessAction(title: "공유", prominent: false) { share = true }
                Button("완료 · 촬영으로 돌아가기", action: finish).frame(minHeight: 44)
            }
        }, portraitInspectorHeight: 200)
        .background(Theme.background).navigationTitle("저장 완료").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료", action: finish) } }
            .sheet(isPresented: $share) { ShareSheet(items: [url]) }
            .navigationDestination(isPresented: $open) { PDFPreview(url: url).navigationTitle(url.deletingPathExtension().lastPathComponent).navigationBarTitleDisplayMode(.inline) }
    }
    private func finish() { if let onFinish { onFinish() } else { dismiss() } }
    private func info(_ title: String, _ value: String) -> some View { HStack { Text(title); Spacer(); Text(value).font(.footnote).foregroundStyle(Theme.secondary) }.padding(.horizontal, 16).frame(minHeight: 48) }
}
private struct PDFSuccessAction: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    private var button: some View {
        Button(action: action) {
            Text(title).font(.system(size: 17))
                .frame(maxWidth: .infinity)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(Theme.label)
        .foregroundStyle(prominent ? Theme.onAccent : Theme.label)
    }

    var body: some View {
        styled.frame(maxWidth: .infinity).frame(height: 50)
    }

    @ViewBuilder private var styled: some View {
        if #available(iOS 26.0, *) {
            if prominent { button.buttonStyle(.glassProminent) }
            else { button.buttonStyle(.glass) }
        } else {
            if prominent { button.buttonStyle(.borderedProminent) }
            else { button.buttonStyle(.bordered) }
        }
    }
}

struct IPadVideoResult: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @ViewState private var share = false
    @ViewState private var player: AVPlayer?
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let player { VideoPlayer(player: player).frame(maxHeight: .infinity) }
                Text("동영상이 저장됐어요").font(.title3.bold())
                Text("소리 없이 촬영한 영상 · 문서 / Hushto").font(.footnote).foregroundStyle(.secondary)
                PrimaryButton(title: "공유 · 파일에 저장") { share = true }
            }.padding(24).background(Theme.background).navigationTitle("녹화 완료").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
                .onAppear { player = AVPlayer(url: url) }.onDisappear { player?.pause() }
                .sheet(isPresented: $share) { ShareSheet(items: [url]) }
        }
    }
}

@MainActor
private struct PageReorderDropDelegate: DropDelegate {
    let targetID: UUID
    let store: ScanStore
    @Binding var dragging: UUID?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil && !store.busy }
    func dropEntered(info: DropInfo) {
        guard let id = dragging, id != targetID,
              let from = store.pages.firstIndex(where: { $0.id == id }),
              let to = store.pages.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            store.move(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
