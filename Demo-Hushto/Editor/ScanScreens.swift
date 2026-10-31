import AVKit
import PDFKit
import Photos
import SwiftUI
import UniformTypeIdentifiers

struct CaptureReview: View {
    let pageID: UUID
    var onFinish: (() -> Void)? = nil
    var onNextCapture: (() -> Void)? = nil
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var enhance = false
    @ViewState private var pages = false
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    if let page = store.pages.first(where: { $0.id == pageID }) {
                        reviewPreview(page, size: geometry.size)
                        VStack(spacing: 8) {
                            Text("\(store.pages.count)페이지를 촬영했어요").font(.headline)
                            Text("다음으로 추가 촬영 · 체크로 페이지 관리")
                                .font(.footnote).foregroundStyle(Theme.secondary)
                        }.padding(.top, 12)
                        VStack(spacing: 12) {
                            CaptureReviewActionButton(title: "사진 보정") { enhance = true }
                            CaptureReviewActionButton(title: "다음", prominent: true, action: nextCapture)
                        }.padding(.horizontal, 24).padding(.top, 16)
                    } else {
                        ContentUnavailableView("페이지가 없어요", systemImage: "doc")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 20)
            }.scrollIndicators(.hidden)
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
        .navigationDestination(isPresented: $enhance) {
            if let page = store.pages.first(where: { $0.id == pageID }) { EnhanceScreen(page: page) }
        }
        .navigationDestination(isPresented: $pages) { PagesScreen(onAdd: nextCapture, onFinish: onFinish) }
        .alert(item: $store.notice) { n in
            Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("확인")))
        }
    }
    private func reviewPreview(_ page: ScanPage, size: CGSize) -> some View {
        let width = max(1, size.width - 32)
        let height = max(180, min(width * 512 / 358, size.height - 208))
        return StoredPageImage(store: store, page: page) { image in
                    DocumentPreview(image: image, fillsFrame: false, contentInset: 12)
                }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 16)
            .contextMenu { Button("사진 앱에 저장", systemImage: "square.and.arrow.down") { savePhoto(page) } }
            .accessibilityAction(named: Text("사진 앱에 저장")) { savePhoto(page) }
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
