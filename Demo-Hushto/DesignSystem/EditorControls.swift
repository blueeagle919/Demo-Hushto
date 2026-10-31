import SwiftUI
import UIKit
import PDFKit
import Photos
import AVKit
import UniformTypeIdentifiers

// Keep the context controls crisp instead of fading them beneath a floating dock.
struct EditorScrollEdgeStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .bottom)
        } else { content }
    }
}
enum EditorTool: String, CaseIterable, Identifiable {
    case filters = "필터", adjust = "조절", crop = "자르기", rotate = "회전"
    var id: Self { self }
    var symbol: String {
        switch self { case .filters: "camera.filters"; case .adjust: "slider.horizontal.3"; case .crop: "crop"; case .rotate: "rotate.left" }
    }
}
// Figma geometry with the same tap-and-slide behavior as the camera modes.
struct EditorToolSelector: View {
    @Binding var selection: EditorTool
    var crispSelection = false
    var cellHeight: CGFloat = 54
    var body: some View {
        HushtoSlidingSelector(
            titles: EditorTool.allCases.map(\.rawValue),
            symbols: EditorTool.allCases.map(\.symbol),
            selection: Binding(
                get: { EditorTool.allCases.firstIndex(of: selection) ?? 0 },
                set: { selection = EditorTool.allCases[$0] }
            ),
            cellHeight: cellHeight, spacing: 8, crispSelection: crispSelection
        )
        .accessibilityElement(children: .contain)
    }
}


/// Glass remains on filter/rotation controls; adjustment sliders use the plain Figma surface.
struct EditorContextSurface: ViewModifier {
    let glass: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if glass { content.hushtoGlassControl() }
        else { content }
    }
}

/// Preserve native slider interaction and accessibility while matching Figma's
/// 3pt gray track and solid 22pt thumb, without the system glass thumb.
struct EditorAdjustmentSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    final class Coordinator: NSObject {
        var parent: EditorAdjustmentSlider
        var renderedScheme: ColorScheme?
        init(_ parent: EditorAdjustmentSlider) { self.parent = parent }
        @objc func changed(_ slider: UISlider) { parent.value = Double(slider.value) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return slider
    }
    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        slider.isEnabled = isEnabled
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.setValue(Float(value), animated: false)
        guard context.coordinator.renderedScheme != colorScheme else { return }
        context.coordinator.renderedScheme = colorScheme
        let thumbColor = UIColor(white: colorScheme == .dark ? 0.96 : 0.125, alpha: 1)
        let trackColor = UIColor(white: colorScheme == .dark ? 0.36 : 0.80, alpha: 1)
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { context in
            thumbColor.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 22, height: 22))
        }
        let track = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 3)).image { context in
            trackColor.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        }.resizableImage(withCapInsets: .zero)
        slider.setThumbImage(thumb, for: .normal)
        slider.setThumbImage(thumb, for: .highlighted)
        slider.setMinimumTrackImage(track, for: .normal)
        slider.setMaximumTrackImage(track, for: .normal)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 342, height: 44)
    }
}
