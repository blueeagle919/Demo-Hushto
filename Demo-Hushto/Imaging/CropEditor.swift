import SwiftUI
import PDFKit
import Photos
import AVKit
import UniformTypeIdentifiers

struct CropEditor: View {
    let image: UIImage?
    var appleStyle = false
    @Binding var geometry: PageGeometry
    @ViewState private var dragStarts: [Int: CGPoint] = [:]
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
                    Path { p in
                        p.addRect(CGRect(origin:.zero,size:proxy.size))
                        p.addLines(points); p.closeSubpath()
                    }.fill(.black.opacity(appleStyle ? 0.28 : 0.3),style:FillStyle(eoFill:true)).allowsHitTesting(false)
                    Path { p in p.addLines(points); p.closeSubpath() }
                        .stroke(.white,style:StrokeStyle(lineWidth: 2,lineJoin:.round)).allowsHitTesting(false)
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
                            if appleStyle {
                                Circle().fill(.white)
                                    .overlay(Circle().stroke(.black, lineWidth: 1.5))
                                    .frame(width: 14, height: 14).frame(width: 44, height: 44)
                            }
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
                            .accessibilityIdentifier("crop.corner.\(index)")
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
    @ViewState private var scale: CGFloat = 1
    @ViewState private var offset: CGSize = .zero
    @ViewState private var pinching = false
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
