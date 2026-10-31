import SwiftUI

/// Device routing never substitutes a tablet layout for an iPhone size class.
struct HushtoRootScreen: View {
    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad { CameraScreen(tablet: true) }
        else { CameraScreen() }
    }
}

enum IPadLayout {
    static func isLandscape(_ size: CGSize) -> Bool { size.width > size.height && size.width >= 900 }
    static func inset(_ size: CGSize) -> CGFloat { size.width < 600 ? 20 : 32 }
    static func cameraPreviewSize(_ size: CGSize, hasPages: Bool) -> CGSize {
        let inset = inset(size)
        if isLandscape(size) {
            return CGSize(width: max(1, size.width - inset * 2 - 278), height: max(140, size.height - 140))
        }
        return CGSize(width: max(1, size.width - inset * 2), height: max(140, size.height - (hasPages ? 368 : 326)))
    }
}

/// Figma 04: preview/inspector columns in landscape, stacked regions in portrait.
struct IPadWorkspace<Preview: View, Inspector: View>: View {
    @ViewBuilder var preview: () -> Preview
    @ViewBuilder var inspector: () -> Inspector
    var portraitInspectorHeight: CGFloat = 240
    var topInset: CGFloat = 24
    var body: some View {
        GeometryReader { geometry in
            let inset = IPadLayout.inset(geometry.size)
            if IPadLayout.isLandscape(geometry.size) {
                HStack(alignment: .top, spacing: 28) {
                    preview().frame(maxWidth: .infinity, maxHeight: .infinity)
                    inspector().frame(width: 342).frame(maxHeight: .infinity)
                }.padding(.horizontal, inset).padding(.top, topInset).padding(.bottom, 24)
            } else {
                VStack(spacing: 20) {
                    preview().frame(maxWidth: .infinity, maxHeight: .infinity)
                    inspector().frame(height: min(portraitInspectorHeight, geometry.size.height * 0.4))
                }.padding(.horizontal, inset).padding(.top, topInset).padding(.bottom, 24)
            }
        }
    }
}

extension View {
    @ViewBuilder func hushtoPadSelectionGlass() -> some View {
        if #available(iOS 26.0, *) { self.glassEffect(.clear.interactive(), in: Capsule()) }
        else { self }
    }
    @ViewBuilder func hushtoPadGlass() -> some View {
        if #available(iOS 26.0, *) { self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24)) }
        else { self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24)) }
    }
}

#if DEBUG
struct HushtoIPadPreviewProvider: PreviewProvider {
    static var previews: some View {
        Group {
            CameraScreen(tablet: true).environmentObject(ScanStore()).tint(Theme.label)
                .previewDevice("iPad Pro 11-inch (M5)")
                .previewInterfaceOrientation(.landscapeLeft)
                .previewLayout(.fixed(width: 1194, height: 834)).previewDisplayName("iPad 가로")
            CameraScreen(tablet: true).environmentObject(ScanStore()).tint(Theme.label)
                .previewDevice("iPad Pro 11-inch (M5)")
                .previewInterfaceOrientation(.portrait)
                .previewLayout(.fixed(width: 834, height: 1194)).previewDisplayName("iPad 세로")
        }
    }
}
#endif

/// iPad bottom actions have explicit label bounds, without native button padding.
struct IPadActionLabel: View {
    let title: String
    var prominent = false
    var height: CGFloat = 64
    var fixedContrast = false
    private var dark: Color { Color(white: 32.0 / 255) }
    private var fill: Color { fixedContrast ? (prominent ? dark : Color.white.opacity(0.8)) : (prominent ? Theme.label : Theme.surface) }
    private var ink: Color { fixedContrast ? (prominent ? .white : dark) : (prominent ? Theme.onAccent : Theme.label) }
    var body: some View {
        Text(title).font(.system(size: 17, weight: prominent ? .semibold : .regular))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity).frame(height: height)
            .background {
                ZStack {
                    Capsule().fill(fill)
                    if #available(iOS 26.0, *) {
                        Capsule().fill(.clear).glassEffect(prominent ? .clear : .regular, in: Capsule())
                    }
                }.allowsHitTesting(false)
            }
            .overlay { if !prominent { Capsule().strokeBorder(Theme.label.opacity(0.08), lineWidth: 0.5).allowsHitTesting(false) } }
            .contentShape(Capsule())
    }
}
struct IPadActionButton: View {
    let title: String
    var prominent = false
    var height: CGFloat = 64
    var fixedContrast = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            IPadActionLabel(title: title, prominent: prominent, height: height, fixedContrast: fixedContrast)
        }.buttonStyle(.plain)
    }
}

/// Full-row geometry: 64pt label + 12pt gap + track + 12pt gap + 36pt value.
/// The track therefore starts at x=76 and ends 48pt before the row edge.
struct IPadTiltSlider: View {
    let title: String
    @Binding var value: Double
    @Environment(\.isEnabled) private var isEnabled
    static func trackWidth(for width: CGFloat) -> CGFloat { max(1, width - 124) }
    static func fraction(for value: Double) -> CGFloat { CGFloat(min(1, max(0, (value + 20) / 40))) }
    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 64, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.8)).frame(height: 3)
                    Circle().fill(Theme.label).frame(width: 20, height: 20)
                        .offset(x: geo.size.width * Self.fraction(for: value) - 10)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    guard isEnabled, geo.size.width > 0 else { return }
                    value = min(20, max(-20, (Double(gesture.location.x / geo.size.width) * 40 - 20).rounded()))
                })
            }.frame(height: 44)
            Text(String(format: value == 0 ? "%.0f°" : "%+.0f°", value))
                .monospacedDigit().frame(width: 36, alignment: .leading)
        }
        .font(.system(size: 13)).frame(height: 44).frame(height: 52, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title).accessibilityValue("\(Int(value))도")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: value = min(20, value + 1)
            case .decrement: value = max(-20, value - 1)
            @unknown default: break
            }
        }
    }
}

/// Keeps the existing duplicate decision callbacks; only iPad presentation differs.
struct IPadDuplicateWarning: View {
    let page: ScanPage
    var onKeep: () -> Void
    var onDiscard: () -> Void
    @EnvironmentObject private var store: ScanStore
    private var previous: ScanPage? {
        store.pages.first { ScanRules.isDuplicate($0.fingerprint, page.fingerprint) }
    }
    var body: some View {
        GeometryReader { geo in
            let landscape = IPadLayout.isLandscape(geo.size)
            let width = min(landscape ? 640.0 : 786.0, max(1, geo.size.width - 48))
            let height = min(landscape ? 660.0 : 1030.0, max(1, geo.size.height - 48))
            ZStack {
                Color.black.opacity(0.22).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    Text("중복된 페이지일 수 있어요").font(.system(size: 24, weight: .bold))
                    Text("저장된 페이지와 비슷한 사진을 발견했어요.\n두 페이지를 확인한 뒤 선택해 주세요.")
                        .font(.system(size: 15)).foregroundStyle(Theme.secondary)
                    Text("자동 감지").font(.system(size: 12)).padding(.horizontal, 12).frame(height: 30)
                        .background(Theme.label.opacity(0.08), in: Capsule())
                    ScrollView {
                        if landscape {
                            HStack(spacing: 12) {
                                comparisonCard(previous, title: "저장된 페이지", imageHeight: 240)
                                comparisonCard(page, title: "방금 촬영한 페이지", imageHeight: 240)
                            }
                        } else {
                            VStack(spacing: 12) {
                                comparisonCard(previous, title: "저장된 페이지", imageHeight: 261)
                                comparisonCard(page, title: "방금 촬영한 페이지", imageHeight: 261)
                            }
                        }
                    }.scrollIndicators(.hidden)
                    Text("기존에 저장된 페이지는 삭제되지 않아요.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity)
                    VStack(spacing: 12) {
                        IPadActionButton(title: "새 페이지 유지", prominent: true, height: landscape ? 50 : 64, action: onKeep)
                        IPadActionButton(title: "새 페이지 삭제", height: landscape ? 50 : 64, action: onDiscard)
                    }
                }
                .padding(.horizontal, landscape ? 24 : 32)
                .padding(.top, landscape ? 24 : 32).padding(.bottom, 24)
                .frame(width: width, height: height)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
                .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityAddTraits(.isModal)
            }
        }.ignoresSafeArea()
    }
    private func comparisonCard(_ candidate: ScanPage?, title: String, imageHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold)).frame(height: 18)
            Group {
                if let candidate {
                    StoredPageImage(store: store, page: candidate) { image in
                        if let image { Image(uiImage: image).resizable().scaledToFit() }
                        else { ProgressView() }
                    }
                } else { Color.clear }
            }
            .frame(maxWidth: .infinity).frame(height: imageHeight)
            .clipped()
        }
        .padding(12).frame(maxWidth: .infinity)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// System alerts own their button geometry; iPad uses this local presentation
/// where the requested 64pt bottom actions must be retained.
struct IPadDecisionOverlay: View {
    let title: String
    let message: String
    let confirmTitle: String
    var cancelTitle: String? = nil
    var confirm: () -> Void
    var cancel: () -> Void = {}
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.22).ignoresSafeArea()
                VStack(spacing: 12) {
                    Text(title).font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center)
                    Text(message).font(.system(size: 13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                    VStack(spacing: 12) {
                        IPadActionButton(title: confirmTitle, prominent: true, action: confirm)
                        if let cancelTitle { IPadActionButton(title: cancelTitle, action: cancel) }
                    }.padding(.top, 12)
                }
                .padding(24).frame(width: min(400, max(1, geo.size.width - 48)))
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityAddTraits(.isModal)
            }
        }.ignoresSafeArea()
    }
}
struct IPadNoticeOverlay: View {
    @Binding var notice: AppNotice?
    var body: some View {
        if let notice {
            IPadDecisionOverlay(title: notice.title, message: notice.message, confirmTitle: "확인") { self.notice = nil }
        }
    }
}
