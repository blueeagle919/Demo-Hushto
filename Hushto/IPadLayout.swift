import SwiftUI

/// Device routing never substitutes a tablet layout for an iPhone size class.
struct HushtoRootScreen: View {
    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad { IPadCameraScreen() }
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
    var body: some View {
        GeometryReader { geometry in
            let inset = IPadLayout.inset(geometry.size)
            if IPadLayout.isLandscape(geometry.size) {
                HStack(alignment: .top, spacing: 28) {
                    preview().frame(maxWidth: .infinity, maxHeight: .infinity)
                    inspector().frame(width: 342).frame(maxHeight: .infinity)
                }.padding(.horizontal, inset).padding(.vertical, 24)
            } else {
                VStack(spacing: 20) {
                    preview().frame(maxWidth: .infinity, maxHeight: .infinity)
                    inspector().frame(height: min(portraitInspectorHeight, geometry.size.height * 0.4))
                }.padding(.horizontal, inset).padding(.vertical, 24)
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
        if #available(iOS 26.0, *) { self.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 28)) }
        else { self.overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Theme.surface.opacity(0.85))) }
    }
}

#if DEBUG
struct HushtoIPadPreviewProvider: PreviewProvider {
    static var previews: some View {
        Group {
            IPadCameraScreen().environmentObject(ScanStore()).tint(Theme.label)
                .previewDevice("iPad Pro 11-inch (M5)")
                .previewInterfaceOrientation(.landscapeLeft)
                .previewLayout(.fixed(width: 1194, height: 834)).previewDisplayName("iPad 가로")
            IPadCameraScreen().environmentObject(ScanStore()).tint(Theme.label)
                .previewDevice("iPad Pro 11-inch (M5)")
                .previewInterfaceOrientation(.portrait)
                .previewLayout(.fixed(width: 834, height: 1194)).previewDisplayName("iPad 세로")
        }
    }
}
#endif
