import AVKit
import PDFKit
import Photos
import SwiftUI
import UniformTypeIdentifiers

struct IPadCaptureReview: View {
    let pageID: UUID
    var onFinish: (() -> Void)? = nil
    var onNextCapture: (() -> Void)? = nil
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var enhance = false
    @ViewState private var pages = false
    var body: some View {
        GeometryReader { workspace in
        IPadWorkspace(
            preview: {
                if let page = store.pages.first(where: { $0.id == pageID }) {
                    StoredPageImage(store: store, page: page) { image in
                    DocumentPreview(image: image, fillsFrame: false)
                }
                        .contextMenu { Button("사진 앱에 저장", systemImage: "square.and.arrow.down") { savePhoto(page) } }

                } else {
                    ContentUnavailableView("페이지가 없어요", systemImage: "doc")
                }
            },
            inspector: {
                if let page = store.pages.first(where: { $0.id == pageID }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(store.pages.count)페이지를 촬영했어요").font(.system(size: 17, weight: .semibold))
                        Text("다음으로 추가 촬영 · 체크로 페이지 관리")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        Spacer(minLength: 24)
                        VStack(spacing: 12) { reviewActions(portrait: !IPadLayout.isLandscape(workspace.size)) }

                    }
                    .navigationDestination(isPresented: $enhance) { IPadEnhanceScreen(page: page) }
                }
            }, portraitInspectorHeight: 240, topInset: 62
        )
        }
        .background(Theme.background)
        .navigationTitle("촬영 확인").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    nextCapture()
                } label: {
                    Image(systemName: "chevron.left")
                }.accessibilityLabel("다음 촬영")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    pages = true
                } label: {
                    Image(systemName: "checkmark")
                }.accessibilityLabel("페이지 관리")
            }
        }
        .navigationDestination(isPresented: $pages) { IPadPagesScreen(onAdd: nextCapture, onFinish: onFinish) }
        .overlay { IPadNoticeOverlay(notice: $store.notice) }
    }
    @ViewBuilder private func reviewActions(portrait: Bool) -> some View {
        if portrait {
            IPadActionButton(title: "사진 보정", fixedContrast: true) { enhance = true }
            IPadActionButton(title: "다음", prominent: true, fixedContrast: true, action: nextCapture)
        } else {
            CaptureReviewActionButton(title: "사진 보정") { enhance = true }
            CaptureReviewActionButton(title: "다음", prominent: true, action: nextCapture)
        }
    }
    private func nextCapture() {
        if let onNextCapture { onNextCapture() }
        else { dismiss() }
    }
    private func savePhoto(_ page: ScanPage) {
        guard let image = store.image(page) else {
            store.report(HushtoError.image)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    store.notice = AppNotice(title: "사진 저장 권한이 필요해요", message: "설정에서 Demo-Hushto의 사진 추가 권한을 허용해주세요.")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                Task { @MainActor in
                    if let error {
                        store.report(error)
                    } else if success {
                        store.notice = AppNotice(title: "사진 앱에 저장했어요", message: "촬영한 페이지를 사진 앱에서 확인할 수 있어요.")
                    }
                }
            }
        }
    }
}
