import SwiftUI
import UIKit

/// Preserve the Figma 210×44 viewport and fixed 84×40 center selection.
/// The edge treatment affects departing labels, never the centered selection.
private enum CameraModeSelectorLayout {
    static let width: CGFloat = 210
    static let height: CGFloat = 44
    static let cellWidth: CGFloat = 84
    static let selectionHeight: CGFloat = 40
    static let spacing: CGFloat = 6
    static let step = cellWidth + spacing
    static let edgeFade: CGFloat = 10
    static let dragThreshold: CGFloat = 8
    static let rowHeight: CGFloat = 52
    static let rowSpacing: CGFloat = 8
    static let rowInset: CGFloat = 10
    static let rowStep = rowHeight + rowSpacing
    static let firstRowCenter = rowInset + rowHeight / 2

    static func edgeBlur(ordinal: Int, position: CGFloat) -> CGFloat {
        let center = width / 2 + (CGFloat(ordinal) - position) * step
        let edgeDistance = min(center, width - center)
        return min(1, max(0, (24 - edgeDistance) / 24)) * 0.45
    }
    static func isHorizontalDrag(_ movement: CGSize) -> Bool {
        abs(movement.width) > dragThreshold && abs(movement.width) > abs(movement.height)
    }
    static func isTap(_ movement: CGSize) -> Bool {
        abs(movement.width) <= dragThreshold && abs(movement.height) <= dragThreshold
    }
}

/// One persistent visual position prevents gesture reset and binding updates from
/// applying two offsets during release. The camera mode commits only on release.
struct AdvancedCameraModeSelector: View {
    @Binding var mode: CaptureMode
    @ViewState private var position: CGFloat
    @ViewState private var dragStart: CGFloat?
    @GestureState private var pressing = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private let layout = CameraModeSelectorLayout.self
    private var index: Int { CaptureMode.allCases.firstIndex(of: mode) ?? 1 }

    init(mode: Binding<CaptureMode>) {
        _mode = mode
        _position = ViewState(initialValue: CGFloat(CaptureMode.allCases.firstIndex(of: mode.wrappedValue) ?? 1))
    }

    var body: some View {
        ZStack {
            CameraModeSelectionPlate(shape: Capsule(), pressing: pressing)
                .frame(width: layout.cellWidth, height: layout.selectionHeight)
            modeTrack.zIndex(1)

        }
        .frame(width: layout.width, height: layout.height)
        .modifier(CameraSelectorSurface())
        .clipShape(Capsule())
        .contentShape(Capsule())
        .highPriorityGesture(dragGesture)
        .onChange(of: pressing) { _, active in handlePressChange(active) }
        .onChange(of: mode) { _, _ in if dragStart == nil { settle(at: index) } }
        .onChange(of: isEnabled) { _, enabled in if !enabled { cancelDrag() } }
        .onDisappear {
            dragStart = nil
            position = CGFloat(index)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("촬영 모드")
        .accessibilityHint("누른 채 좌우로 밀어 원하는 모드를 선택하세요")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: select(CaptureMode.allCases[min(CaptureMode.allCases.count - 1, index + 1)])
            case .decrement: select(CaptureMode.allCases[max(0, index - 1)])
            @unknown default: break
            }
        }
    }

    private var modeTrack: some View {
        // Keep this animation stable across touch-down/up. Finger tracking still
        // disables animation in its transaction, without replacing the spring.
        CameraModeAnimatedTrack(position: position, mode: mode, pressing: pressing, select: select)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.36, dampingFraction: 0.90, blendDuration: 0.12), value: position)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($pressing) { _, state, _ in state = isEnabled }
            .onChanged(handleDragChange)
            .onEnded(handleDragEnd)
    }

    private func handleDragChange(_ value: DragGesture.Value) {
        guard isEnabled else { return }
        if dragStart == nil { dragStart = position }
        let movement = value.translation
        guard layout.isHorizontalDrag(movement) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position = CGFloat(
                CaptureModeDragRules.position(
                    start: Double(dragStart ?? position), translation: Double(movement.width), step: Double(layout.step)
                ))
        }
    }

    private func handleDragEnd(_ value: DragGesture.Value) {
        guard isEnabled else {
            cancelDrag()
            return
        }
        let start = dragStart ?? position
        let movement = value.translation
        let target: Double
        if layout.isHorizontalDrag(movement) {
            target = CaptureModeDragRules.position(
                start: Double(start), translation: Double(movement.width), step: Double(layout.step))
        } else if layout.isTap(movement) {
            target = CaptureModeDragRules.position(
                start: Double(start), translation: Double(layout.width / 2 - value.location.x),
                step: Double(layout.step))
        } else {
            target = Double(index)
        }
        dragStart = nil
        select(CaptureMode.allCases[Int(target.rounded())])
    }

    private func handlePressChange(_ active: Bool) {
        guard !active else { return }
        // Let a release commit first; only cancelled gestures still need cleanup.
        Task { @MainActor in
            await Task.yield()
            if !pressing && dragStart != nil { cancelDrag() }
        }
    }

    private func select(_ value: CaptureMode) {
        guard isEnabled else { return }
        // Update the camera independently of the visual track's short settling animation.
        if mode != value { mode = value }
        settle(at: CaptureMode.allCases.firstIndex(of: value) ?? 1)
    }
    private func settle(at index: Int) {
        guard position != CGFloat(index) else { return }
        position = CGFloat(index)
    }
    private func cancelDrag() {
        dragStart = nil
        settle(at: index)
    }
}

/// Tablet landscape shares release-to-commit semantics without animating every
/// finger update or recreating the selection plate at each row boundary.
struct AdvancedCameraVerticalModeSelector: View {
    @Binding var mode: CaptureMode
    @ViewState private var position: CGFloat
    @ViewState private var dragging = false
    @GestureState private var pressing = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private let layout = CameraModeSelectorLayout.self
    private var index: Int { CaptureMode.allCases.firstIndex(of: mode) ?? 1 }

    init(mode: Binding<CaptureMode>) {
        _mode = mode
        _position = ViewState(initialValue: CGFloat(CaptureMode.allCases.firstIndex(of: mode.wrappedValue) ?? 1))
    }

    var body: some View {
        CameraModeAnimatedTrack(position: position, mode: mode, pressing: pressing, vertical: true, select: select)
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.36, dampingFraction: 0.90, blendDuration: 0.12), value: position)
        .padding(layout.rowInset)
        .modifier(CameraSelectorSurface(vertical: true))
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .updating($pressing) { _, state, _ in state = isEnabled }
                .onChanged { value in
                    guard isEnabled else { return }
                    dragging = true
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { position = position(at: value.location.y) }
                }
                .onEnded { value in
                    guard isEnabled else {
                        cancelDrag()
                        return
                    }
                    let target = Int(position(at: value.location.y).rounded())
                    dragging = false
                    select(CaptureMode.allCases[target])
                }
        )
        .onChange(of: pressing) { _, active in
            guard !active else { return }
            Task { @MainActor in
                await Task.yield()
                if !pressing && dragging { cancelDrag() }
            }
        }
        .onChange(of: mode) { _, _ in if !dragging { settle(at: index) } }
        .onChange(of: isEnabled) { _, enabled in if !enabled { cancelDrag() } }
        .onDisappear {
            dragging = false
            position = CGFloat(index)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("촬영 모드")
        .accessibilityHint("누른 채 위아래로 움직여 원하는 모드를 선택하세요")
    }
    private func position(at y: CGFloat) -> CGFloat {
        CGFloat(
            CaptureModeDragRules.position(
                start: 0, translation: Double(layout.firstRowCenter - y), step: Double(layout.rowStep)))
    }
    private func select(_ value: CaptureMode) {
        guard isEnabled else { return }
        if mode != value { mode = value }
        settle(at: CaptureMode.allCases.firstIndex(of: value) ?? 1)
    }
    private func settle(at index: Int) {
        guard position != CGFloat(index) else { return }
        position = CGFloat(index)
    }
    private func cancelDrag() {
        dragging = false
        settle(at: index)
    }
}

/// Keep one native glass layer alive; animate its backing rather than swapping
/// between Glass.identity and Glass.clear during the transition.
struct CameraModeSelectionPlate<Plate: Shape>: View {
    let shape: Plate
    let pressing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    private var selectionColor: Color {
        if reduceTransparency { return colorScheme == .dark ? Color(white: 0.2) : .white }
        return colorScheme == .dark ? .white : Color(white: 0.2)
    }
    // The front lens is more transparent than the outer glass backing.
    private var backingOpacity: Double {
        if reduceTransparency { return 1 }
        return colorScheme == .dark ? (pressing ? 0.16 : 0.12) : (pressing ? 0.09 : 0.06)
    }
    var body: some View {
        Group {
            if colorScheme == .dark { darkPlate }
            else { lightPlate }
        }
            .scaleEffect(pressing && !reduceMotion ? 1.04 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: pressing)
            .allowsHitTesting(false)
    }
    private var lightPlate: some View {
        plate
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [.white.opacity(0.12), .clear, .white.opacity(0.03)]
                            : [.white.opacity(0.40), .clear, .white.opacity(0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .opacity(reduceTransparency ? 0 : (pressing ? 1 : (colorScheme == .dark ? 0.35 : 0.85)))
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [.white.opacity(0.62), .white.opacity(0.10), .white.opacity(0.34)]
                            : [.white.opacity(0.95), .black.opacity(0.18), .white.opacity(0.70)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: colorScheme == .dark ? 0.8 : 1
                )
                .opacity(reduceTransparency ? 0 : (pressing ? 1 : (colorScheme == .dark ? 0.35 : 0.85)))
            }
            .shadow(color: .black.opacity(pressing ? 0.10 : (colorScheme == .dark ? 0 : 0.08)), radius: colorScheme == .dark ? 5 : 2, x: 0, y: colorScheme == .dark ? 2 : 1)
    }
    private var darkPlate: some View {
        darkGlass
            .overlay(shape.stroke(.white.opacity(0.30), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 3)
    }
    @ViewBuilder private var darkGlass: some View {
        let backing = Color(red: 82.0 / 255, green: 84.0 / 255, blue: 92.0 / 255)
            .opacity(reduceTransparency ? 1 : 0.78)
        if reduceTransparency {
            shape.fill(backing)
        } else if #available(iOS 26.0, *) {
            shape.fill(backing)
                .background { shape.fill(.clear).glassEffect(.clear, in: shape) }
        } else {
            shape.fill(backing).background(.regularMaterial, in: shape)
        }
    }
    @ViewBuilder private var plate: some View {
        if #available(iOS 26.0, *) {
            shape.fill(selectionColor.opacity(backingOpacity))
                .background {
                    shape.fill(.clear).glassEffect(.clear, in: shape)
                }
        } else {
            shape.fill(selectionColor.opacity(backingOpacity))
                .background(.regularMaterial, in: shape)
        }
    }
}

/// One presentation value drives movement, emphasis, and edge treatment together.
/// A label is drawn exactly once; no rounded-index swaps or crossfade layers.
private struct CameraModeAnimatedTrack: View, Animatable {
    var position: CGFloat
    let mode: CaptureMode
    let pressing: Bool
    var vertical = false
    let select: (CaptureMode) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var fontSize: CGFloat = 15
    private let layout = CameraModeSelectorLayout.self
    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }
    var body: some View {
        Group {
            if vertical {
                ZStack(alignment: .top) {
                    CameraModeSelectionPlate(shape: RoundedRectangle(cornerRadius: 12), pressing: pressing)
                        .frame(height: layout.rowHeight)
                        .offset(y: position * layout.rowStep)
                    VStack(spacing: layout.rowSpacing) { labels }
                }
            } else {
                HStack(spacing: layout.spacing) { labels }
                    .fixedSize()
                    .offset(x: (1 - position) * layout.step)
                    .frame(width: layout.width, height: layout.height)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: layout.edgeFade / layout.width),
                            .init(color: .white, location: 1 - layout.edgeFade / layout.width),
                            .init(color: .clear, location: 1)
                        ], startPoint: .leading, endPoint: .trailing)
                    }
            }
        }
        // Children use the interpolated presentation value directly, rather than
        // starting separate animations for each font, scale, blur, and offset.
        .transaction { $0.animation = nil }
    }
    private func labelColor(emphasis: CGFloat) -> Color {
        if colorScheme == .dark {
            return Color(red: (209 + 41 * emphasis) / 255,
                         green: (213 + 38 * emphasis) / 255,
                         blue: (222 + 33 * emphasis) / 255)
                .opacity(0.65 + 0.35 * emphasis)
        }
        return Color(white: (64 - 32 * emphasis) / 255)
    }
    private var labels: some View {
        ForEach(Array(CaptureMode.allCases.enumerated()), id: \.element.id) { ordinal, item in
            let distance = min(1, abs(CGFloat(ordinal) - position))
            let progress = 1 - distance
            let emphasis = progress * progress * (3 - 2 * progress)
            Button { select(item) } label: {
                Text(item.rawValue)
                    .font(CameraModeFontCache.font(size: fontSize, emphasis: vertical ? 1 : emphasis))
                    .scaleEffect((vertical ? 1 : 1 + emphasis * (17.0 / 15.0 - 1)) * (1 + (pressing && !reduceMotion ? emphasis * 0.04 : 0)))
                    .foregroundStyle(labelColor(emphasis: emphasis))
                    .modifier(CameraModeLabelShadow())
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .blur(radius: vertical ? 0 : layout.edgeBlur(ordinal: ordinal, position: position))
                    .frame(width: vertical ? nil : layout.cellWidth, height: vertical ? layout.rowHeight : layout.height)
                    .frame(maxWidth: vertical ? .infinity : nil)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(item == mode ? .isSelected : [])
            .accessibilityIdentifier("capture.mode.\(item.id)")
        }
    }
}

private struct CameraSelectorSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    private var surface: Color { colorScheme == .dark ? Color(red: 18.0 / 255, green: 19.0 / 255, blue: 20.0 / 255).opacity(reduceTransparency ? 1 : 0.76) : .white.opacity(reduceTransparency ? 1 : 0.68) }
    private var edge: Color { .white.opacity(colorScheme == .dark ? 0.20 : 0.75) }
    var vertical = false
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: vertical ? 24 : 22) }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if colorScheme == .dark {
            surfaceContent(content).shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 3)
        } else {
            surfaceContent(content)
        }
    }
    private func surfaceContent(_ content: Content) -> some View {
        content
            .background { backdrop }
            .overlay(shape.strokeBorder(edge, lineWidth: 0.5).allowsHitTesting(false))
    }
    @ViewBuilder private var backdrop: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            shape.fill(.clear)
                .glassEffect(.clear, in: shape)
                .overlay { shape.fill(surface) }
        } else {
            shape.fill(surface)
                .background(.ultraThinMaterial, in: shape)
        }
    }
}

/// Keep the light-mode treatment exactly as before; dark labels need no black halo.
private struct CameraModeLabelShadow: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder func body(content: Content) -> some View {
        if colorScheme == .dark { content }
        else { content.shadow(color: .white.opacity(0.8), radius: 1, x: 0, y: 0.5) }
    }
}

/// Geometry/color still interpolate continuously. Cache a fine set of font
/// weights instead of rebuilding UIFont and Font on every animation frame.
private enum CameraModeFontCache {
    private final class Entry: NSObject {
        let value: Font
        init(_ value: Font) { self.value = value }
    }
    private static let entries: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 192
        return cache
    }()
    static func font(size: CGFloat, emphasis: CGFloat) -> Font {
        let step = Int((min(1, max(0, emphasis)) * 32).rounded())
        let key = "\(size)-\(step)" as NSString
        if let cached = entries.object(forKey: key) { return cached.value }
        let weight = UIFont.Weight(rawValue: UIFont.Weight.semibold.rawValue * CGFloat(step) / 32)
        let font = Font(UIFont.systemFont(ofSize: size, weight: weight))
        entries.setObject(Entry(font), forKey: key)
        return font
    }
}
