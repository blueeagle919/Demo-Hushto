import SwiftUI

#if DEBUG
struct HushtoCameraPreviewProvider: PreviewProvider {
    static var previews: some View {
        HushtoCameraPreviewHost()
            .previewDisplayName("Demo-Hushto 카메라")
    }
}

private struct HushtoCameraPreviewHost: View {
    @StateObject private var store = ScanStore()

    var body: some View {
        CameraScreen()
            .environmentObject(store)
            .tint(Theme.label)

    }
}
#endif
