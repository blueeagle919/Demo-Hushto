import SwiftUI
import PDFKit
import Photos
import AVKit
import UniformTypeIdentifiers

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
            VStack(alignment: .leading, spacing: 8) { Text("페이지 크기").font(.footnote).foregroundStyle(Theme.secondary); Picker("페이지 크기", selection: $paper) { ForEach(PaperSize.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).controlSize(.large).frame(minHeight: 44) }
            VStack(alignment: .leading, spacing: 8) { Text("화질").font(.footnote).foregroundStyle(Theme.secondary); Picker("화질", selection: $quality) { ForEach(ExportQuality.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).controlSize(.large).frame(minHeight: 44) }
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
                Text("촬영한 영상 · 문서 / Hushto").font(.footnote).foregroundStyle(.secondary)
                PrimaryButton(title: "공유 · 파일에 저장") { share = true }
            }.padding(24).background(Theme.background).navigationTitle("녹화 완료").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
                .onAppear { player = AVPlayer(url: url) }.onDisappear { player?.pause() }
                .sheet(isPresented: $share) { ShareSheet(items: [url]) }
        }
    }
}
