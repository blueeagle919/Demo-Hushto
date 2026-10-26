import SwiftUI
import PDFKit
import Photos
import AVKit
import UniformTypeIdentifiers

struct CaptureReview: View {
    let pageID: UUID
    var onFinish: (() -> Void)? = nil
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var enhance = false
    @ViewState private var pages = false
    var body: some View {
        GeometryReader { geo in
        ScrollView {
        VStack(spacing: 16) {
            if let page = store.pages.first(where: { $0.id == pageID }) {
                DocumentPreview(image: store.preview(page)).frame(height: min(416, max(180, geo.size.height * 0.55)))
                Text("\(store.pages.count)페이지를 촬영했어요").font(.system(size: 17, weight: .semibold)).padding(.top, 16)
                Text("사진 보정으로 페이지를 다듬거나 다음 촬영을 이어가세요.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                VStack(spacing: 24) {
                    Button { enhance = true } label: {
                        Text("사진 보정")
                            .font(.subheadline)
                            .foregroundStyle(Theme.label)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Theme.surface, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { dismiss() } label: {
                        Text("다음 촬영")
                            .font(.body)
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 13)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Theme.label, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
                Button { savePhoto(page) } label: { Label("사진 앱에 저장", systemImage: "square.and.arrow.down") }.font(.footnote).padding(.bottom, 12)
                .navigationDestination(isPresented: $enhance) { EnhanceScreen(page: page) }
            } else { ContentUnavailableView("페이지가 없어요", systemImage: "doc") }
        }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 20)
        }.scrollIndicators(.hidden)
        }.background(Theme.background)
            .navigationTitle("촬영 확인").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("다음 촬영") }
                ToolbarItem(placement: .topBarTrailing) { Button { pages = true } label: { Image(systemName: "checkmark") }.accessibilityLabel("페이지 관리") }
            }
            .navigationDestination(isPresented: $pages) { PagesScreen(onAdd: { dismiss() }, onFinish: onFinish) }
            .alert(item: $store.notice) { n in Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("확인"))) }
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
struct EnhanceScreen: View {
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
        GeometryReader { geo in
            VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    Group {
                        if tool == .crop {
                            CropEditor(image: cropPreview, appleStyle: true, geometry: $draft).disabled(store.busy)
                        } else {
                            Group {
                                if tool == .rotate && rotation3D { PerspectiveZoomPreview(image: preview, fillsFrame: false, contentInset: 0) }
                                else { DocumentPreview(image: preview, fillsFrame: false, contentInset: 0) }
                            }
                        }
                    }
                    .frame(height: tool == .rotate && rotation3D
                        ? max(60, min((geo.size.width - 48) * 462 / 342, geo.size.height - 266))
                        : max(190, min((geo.size.width - 48) * 490 / 342, geo.size.height - 208)))
                    Text(tool == .crop ? "네 모서리를 문서의 끝에 맞춰주세요" : (tool == .rotate ? (rotation3D ? "좌우와 상하 기울기를 따로 조절하세요" : "회전 · \(geometry.quarterTurns * 90)°") : pageLabel))
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    contextPanel.disabled(store.busy).frame(minHeight: tool == .rotate && rotation3D ? 92 : 66)
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .modifier(EditorScrollEdgeStyle())
            toolDock
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(Theme.background.ignoresSafeArea(edges: .bottom))
            }
        }
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

struct CropEditor: View {
    let image: UIImage?
    var appleStyle = false
    @Binding var geometry: PageGeometry
    @State private var dragStarts: [Int: CGPoint] = [:]
    @GestureState private var activeCorner: Int?
    private let labels = ["왼쪽 위", "오른쪽 위", "오른쪽 아래", "왼쪽 아래"]
    var body: some View {
        GeometryReader { proxy in
            if let image {
                let available = CGSize(width:max(1,proxy.size.width - (appleStyle ? 24 : 44)),height:max(1,proxy.size.height - (appleStyle ? 24 : 44)))
                let scale = min(available.width/image.size.width,available.height/image.size.height)
                let size = CGSize(width:image.size.width*scale,height:image.size.height*scale)
                let origin = CGPoint(x:(proxy.size.width-size.width)/2,y:(proxy.size.height-size.height)/2)
                let points = geometry.points.map { CGPoint(x:origin.x+$0.x*size.width,y:origin.y+$0.y*size.height) }
                ZStack(alignment:.topLeading) {
                    Image(uiImage:image).resizable().frame(width:size.width,height:size.height)
                        .position(x:proxy.size.width/2,y:proxy.size.height/2)
                    if !appleStyle {
                    Path { p in
                        p.addRect(CGRect(origin:.zero,size:proxy.size))
                        p.addLines(points); p.closeSubpath()
                    }.fill(.black.opacity(0.3),style:FillStyle(eoFill:true)).allowsHitTesting(false)
                    }
                    Path { p in p.addLines(points); p.closeSubpath() }
                        .stroke(.white,style:StrokeStyle(lineWidth:appleStyle ? 1 : 2,lineJoin:.round)).allowsHitTesting(false)
                    if !appleStyle {
                    Path { path in
                        func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
                            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                        }
                        for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
                            path.move(to: mix(points[0], points[1], fraction))
                            path.addLine(to: mix(points[3], points[2], fraction))
                            path.move(to: mix(points[0], points[3], fraction))
                            path.addLine(to: mix(points[1], points[2], fraction))
                        }
                    }
                    .stroke(.white.opacity(0.65), lineWidth: 0.75)
                    .allowsHitTesting(false)
                    }
                    ForEach(0..<4,id:\.self) { index in
                        Group {
                            if appleStyle { Circle().strokeBorder(.white, lineWidth: 1).frame(width: 20, height: 20).frame(width: 44, height: 44) }
                            else { Image("CropDragHandle").frame(width:44,height:44) }
                        }.contentShape(Rectangle())
                            .position(points[index])
                            .highPriorityGesture(DragGesture(minimumDistance:0, coordinateSpace: .named("cropCanvas"))
                                .updating($activeCorner) { _, state, _ in state = index }
                                .onChanged { value in
                                if dragStarts[index] == nil { dragStarts[index] = geometry.points[index] }
                                guard let start = dragStarts[index] else { return }
                                geometry.moveCorner(index,to:CGPoint(x:start.x+value.translation.width/size.width,
                                                                    y:start.y+value.translation.height/size.height))
                            }.onEnded { _ in
                                dragStarts[index] = nil
                            })
                            .accessibilityLabel("자르기 모서리 \(labels[index])")
                            .accessibilityValue("가로 \(Int(geometry.points[index].x * 100))퍼센트, 세로 \(Int(geometry.points[index].y * 100))퍼센트")
                            .accessibilityAdjustableAction { direction in
                                let point=geometry.points[index], step:CGFloat=direction == .increment ? 0.02 : -0.02
                                geometry.moveCorner(index,to:CGPoint(x:point.x+step,y:point.y+step))
                            }
                    }
                    if let index = activeCorner {
                        let target = points[index]
                        let margin: CGFloat = appleStyle ? 42 : 64
                        let lensX = min(proxy.size.width - margin, max(margin, appleStyle ? target.x : target.x + (target.x < proxy.size.width / 2 ? 82 : -82)))
                        let lensY = min(proxy.size.height - margin, max(margin, appleStyle ? target.y : (target.y < 140 ? target.y + 92 : target.y - 92)))
                        magnifier(image, size: size, point: geometry.points[index])
                            .position(x: lensX, y: lensY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }.background(Theme.surface).clipShape(RoundedRectangle(cornerRadius:24))
            } else { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity) }
        }
        .coordinateSpace(name: "cropCanvas")
        .onChange(of: activeCorner) { _, corner in
            if corner == nil { dragStarts.removeAll() }
        }
    }
    private func magnifier(_ image: UIImage, size: CGSize, point: CGPoint) -> some View {
        let diameter: CGFloat = appleStyle ? 80 : 112, zoom: CGFloat = 2.8
        return ZStack(alignment: .topLeading) {
            Color.white
            // Anchor the enlarged image in the lens viewport, not in its own oversized layout.
            GeometryReader { _ in
                Image(uiImage: image).resizable().interpolation(.high)
                    .frame(width: size.width * zoom, height: size.height * zoom)
                    .position(x: diameter / 2 + (0.5 - point.x) * size.width * zoom,
                              y: diameter / 2 + (0.5 - point.y) * size.height * zoom)
            }.frame(width: diameter, height: diameter)
            if appleStyle {
                Path { path in
                    let enlarged = geometry.points.map { CGPoint(x: diameter / 2 + ($0.x - point.x) * size.width * zoom,
                        y: diameter / 2 + ($0.y - point.y) * size.height * zoom) }
                    path.addLines(enlarged); path.closeSubpath()
                }.stroke(.white, lineWidth: 1)
            } else {
            Path { path in
                path.move(to: CGPoint(x: diameter / 2 - 12, y: diameter / 2))
                path.addLine(to: CGPoint(x: diameter / 2 + 12, y: diameter / 2))
                path.move(to: CGPoint(x: diameter / 2, y: diameter / 2 - 12))
                path.addLine(to: CGPoint(x: diameter / 2, y: diameter / 2 + 12))
            }.stroke(.white, lineWidth: 1).shadow(color: .black, radius: 1)
            }
        }
        .frame(width: diameter, height: diameter).clipShape(Circle())
        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

}
// The crop sheet alone adopts the supplied Apple document-scanner reference.
enum OriginalCropLoader {
    static func load(url: URL, geometry: PageGeometry, correction: [CropPoint]?, corrected: Bool) async -> (UIImage, [CGPoint])? {
        await Task.detached(priority: .userInitiated) {
            guard let raw = ImageProcessor.previewImage(at: url, maxEdge: RuntimeBudget.current.cropPreviewEdge), let ci = CIImage(image: raw) else { return nil }
            let processor = ImageProcessor()
            let detected = correction ?? (corrected ? processor.documentCorners(in: ci).map(CropPoint.init) : nil)
            let points = geometry.originalCropPoints(correction: detected, corrected: corrected)
            guard let rotated = try? processor.render(raw, filter: .original, correct: false,
                geometry: PageGeometry(quarterTurns: geometry.quarterTurns)) else { return nil }
            return (rotated, points)
        }.value
    }
}

/// Inspection zoom changes the viewport only. The image exported/saved is unchanged.
struct PerspectiveZoomPreview: View {
    let image: UIImage?
    var fillsFrame = true
    var contentInset: CGFloat = 16
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var pinching = false
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: fillsFrame ? .fill : .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(scale)
                        .offset(clampedOffset(offset, in: proxy.size, scale: scale))
                }
                if pinching {
                    Path { path in
                        for step in 1..<3 {
                            let x = proxy.size.width * CGFloat(step) / 3
                            let y = proxy.size.height * CGFloat(step) / 3
                            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                        }
                    }.stroke(.white.opacity(0.9), lineWidth: 0.75).shadow(color: .black.opacity(0.6), radius: 1)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
            .contentShape(Rectangle())
            .overlay {
                PerspectiveTouchSurface(onPinch: { factor, active in
                    pinching = active
                    guard factor.isFinite else { return }
                    let next = min(5, max(1, scale * factor))
                    let ratio = next / scale
                    offset = clampedOffset(CGSize(width: offset.width * ratio, height: offset.height * ratio),
                                           in: proxy.size, scale: next)
                    scale = next
                }, onPan: { translation in
                    guard scale > 1 else { offset = .zero; return }
                    offset = clampedOffset(CGSize(width: offset.width + translation.width,
                                                  height: offset.height + translation.height),
                                           in: proxy.size, scale: scale)
                })
            }
            .onChange(of: proxy.size) { _, size in offset = clampedOffset(offset, in: size, scale: scale) }
        }
        .padding(fillsFrame ? 0 : contentInset)
        .background(fillsFrame ? Color.clear : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: fillsFrame ? 24 : 20))
    }
    private func clampedOffset(_ proposed: CGSize, in viewport: CGSize, scale: CGFloat) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let fit = fillsFrame ? max(viewport.width / image.size.width, viewport.height / image.size.height)
                             : min(viewport.width / image.size.width, viewport.height / image.size.height)
        let limitX = max(0, (image.size.width * fit * scale - viewport.width) / 2)
        let limitY = max(0, (image.size.height * fit * scale - viewport.height) / 2)
        return CGSize(width: min(limitX, max(-limitX, proposed.width)),
                      height: min(limitY, max(-limitY, proposed.height)))
    }

}


/// Two-finger panning shares the same surface as pinch; one-finger scrolling stays with the editor.
private struct PerspectiveTouchSurface: UIViewRepresentable {
    let onPinch: (CGFloat, Bool) -> Void
    let onPan: (CGSize) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pinch.delegate = context.coordinator
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(pan)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PerspectiveTouchSurface
        init(parent: PerspectiveTouchSurface) { self.parent = parent }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            let active = gesture.state == .began || gesture.state == .changed
            parent.onPinch(active ? gesture.scale : 1, active)
            gesture.scale = 1
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .began || gesture.state == .changed else { return }
            let delta = gesture.translation(in: gesture.view)
            parent.onPan(CGSize(width: delta.x, height: delta.y))
            gesture.setTranslation(.zero, in: gesture.view)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer.view === otherGestureRecognizer.view
        }
    }
}

struct PagesScreen: View {
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
    var body: some View {
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
            }.padding(.horizontal, 24).padding(.top, 20)
            if store.pages.isEmpty {
                ContentUnavailableView { Label("아직 촬영한 페이지가 없어요", systemImage: "doc.viewfinder") } description: { Text("촬영하거나 사진을 가져와 스캔을 시작하세요.") } actions: { Button("촬영하러 가기") { dismiss() } }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 24) {
                        ForEach(Array(store.pages.enumerated()), id: \.element.id) { index, page in
                            if selecting {
                                Button { if selected.contains(page.id) { selected.remove(page.id) } else { selected.insert(page.id) } } label: { card(page, index: index) }.buttonStyle(.plain)
                            } else {
                                NavigationLink { EnhanceScreen(page: page) } label: { card(page, index: index) }
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
                    }.padding(.horizontal, 24)
                }
            }
            if selecting {
                HStack {
                    Button(selected.count == store.pages.count ? "선택 해제" : "전체 선택") { selected = selected.count == store.pages.count ? [] : Set(store.pages.map(\.id)) }
                    Spacer()
                    Button("\(selected.count)페이지 삭제", role: .destructive) { deleting = true }.disabled(selected.isEmpty)
                }.padding(.horizontal, 24)
            }
            NavigationLink { ExportScreen(onFinish: onFinish) } label: { Text("PDF 만들기").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 50) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Theme.label).foregroundStyle(Theme.onAccent).disabled(store.pages.isEmpty)
                .padding(.horizontal, 24).padding(.bottom, 20)
        }.background(Theme.background).navigationTitle("스캔 문서").navigationBarTitleDisplayMode(.inline)
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
    private func card(_ page: ScanPage, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image = store.thumbnail(page) { Image(uiImage: image).resizable().scaledToFit().id(page.thumbnail).frame(maxWidth: .infinity).frame(height: 183).clipShape(RoundedRectangle(cornerRadius: 12)) }
            HStack { Text(String(format: "페이지 %02d", index + 1)).font(.system(size: 13)).foregroundStyle(Theme.secondary); Spacer(); if selecting { Image(systemName: selected.contains(page.id) ? "checkmark.circle.fill" : "circle") } }
        }.padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20)).accessibilityLabel("페이지 \(index + 1)")
    }
}
struct ExportScreen: View {
    var onFinish: (() -> Void)? = nil
    @EnvironmentObject private var store: ScanStore
    @AppStorage("paperSize") private var defaultPaper = PaperSize.original.rawValue
    @AppStorage("quality") private var defaultQuality = ExportQuality.standard.rawValue
    @ViewState private var name = ""
    @ViewState private var paper = PaperSize.original
    @ViewState private var quality = ExportQuality.standard
    @ViewState private var success = false
    var body: some View {
        GeometryReader { geo in
        ScrollView {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("파일 이름").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                HStack { TextField("문서 이름", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled(); Text(".pdf").foregroundStyle(Theme.secondary) }.padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
            }
            VStack(alignment: .leading, spacing: 8) { Text("페이지 크기").font(.footnote).foregroundStyle(Theme.secondary); Picker("페이지 크기", selection: $paper) { ForEach(PaperSize.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).controlSize(.large).frame(minHeight: 44).hushtoGlassControl() }
            VStack(alignment: .leading, spacing: 8) { Text("화질").font(.footnote).foregroundStyle(Theme.secondary); Picker("화질", selection: $quality) { ForEach(ExportQuality.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).controlSize(.large).frame(minHeight: 44).hushtoGlassControl() }
            Text("\(store.pages.count)페이지 · 파일 크기는 이미지에 따라 달라져요").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            Spacer()
            PrimaryButton(title: store.busy ? "PDF 저장 중…" : "PDF 저장") { store.export(name: name, paper: paper, quality: quality) }.disabled(store.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.frame(minHeight: max(0, geo.size.height - 48)).padding(24)
        }.scrollDismissesKeyboard(.interactively)
        }.background(Theme.background).navigationTitle("PDF 만들기").navigationBarTitleDisplayMode(.inline)
            .onAppear { name = store.title; paper = PaperSize(rawValue: defaultPaper) ?? .original; quality = ExportQuality(rawValue: defaultQuality) ?? .standard; store.exportedURL = nil }
            .onChange(of: store.exportedURL) { _, url in if url != nil { success = true } }
            .navigationDestination(isPresented: $success) { if let url = store.exportedURL { PDFSuccess(url: url, count: store.exportedPageCount, onFinish: onFinish) } }
            .alert(item: $store.notice) { n in Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("확인"))) }
    }
}
struct PDFSuccess: View {
    let url: URL
    let count: Int
    var onFinish: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ViewState private var open = false
    @ViewState private var share = false
    var body: some View {
        GeometryReader { geo in
        ScrollView {
        VStack(spacing: 16) {
            Spacer().frame(height: min(40, geo.size.height * 0.05))
            Image(systemName: "checkmark").font(.system(size: 40)).frame(width: 80, height: 80).background(Theme.label.opacity(0.08), in: Circle())
            Text("PDF가 준비됐어요").font(.system(size: 22, weight: .bold))
            Text(url.lastPathComponent).font(.body)
            VStack(spacing: 0) { info("페이지", "\(count)페이지"); info("파일 크기", ByteCountFormatter.string(fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file)); info("저장 위치", "문서 / Hushto") }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
            Spacer()
            VStack(spacing: 12) {
                PDFSuccessAction(title: "PDF 열기", prominent: true) { open = true }
                PDFSuccessAction(title: "공유", prominent: false) { share = true }
            }
            Button("완료 · 촬영으로 돌아가기", action: finish).frame(minHeight: 44)
        }.frame(minHeight: max(0, geo.size.height - 48)).padding(24)
        }
        }.background(Theme.background).navigationTitle("저장 완료").navigationBarTitleDisplayMode(.inline)
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

struct PDFPreview: View {
    let url: URL
    @ViewState private var share = false

    var body: some View {
        PDFDocumentView(url: url)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { share = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("PDF 공유")
                }
            }
            .sheet(isPresented: $share) { ShareSheet(items: [url]) }
    }
}

private struct PDFDocumentView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = PDFDocument(url: url); return view }
    func updateUIView(_ view: PDFView, context: Context) {}
}
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
struct VideoResult: View {
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
