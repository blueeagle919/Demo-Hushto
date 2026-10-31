import SwiftUI

struct IPadSettingsScreen: View {
    var camera: CameraController? = nil
    var onFinish: (() -> Void)? = nil
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("silent") private var silent = true
    @AppStorage("feedback") private var feedback = true
    @AppStorage("defaultFlash") private var flash = false
    @AppStorage("defaultMode") private var mode = CaptureMode.photo.rawValue
    @AppStorage("enhancement") private var enhancement = Enhancement.auto.rawValue
    @AppStorage("paperSize") private var paper = PaperSize.original.rawValue
    @AppStorage("quality") private var quality = ExportQuality.standard.rawValue
    @ViewState private var deleteAll = false
    @ViewState private var section = "카메라"
    var body: some View {
        ScrollViewReader { scroll in
        NavigationSplitView {
            List(["화면", "카메라", "스캔", "PDF", "저장 공간", "정보"], id: \.self) { item in
                Button {
                    section = item
                    withAnimation { scroll.scrollTo(item, anchor: .top) }
                } label: {
                    Text(item).foregroundStyle(Theme.label).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 48)
                }
                .listRowBackground(section == item ? Theme.label.opacity(0.08) : Color.clear)
            }
            .listStyle(.sidebar)
            .navigationTitle("설정")
            .navigationSplitViewColumnWidth(min: 240, ideal: 310, max: 310)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("카메라로 돌아가기")
                }
            }
        } detail: {
        NavigationStack {
            Form {
                Section("화면") {
                    Picker("화면 모드", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                }.id("화면")
                Section("카메라") {
                    Group {
                        Toggle("무음 촬영", isOn: $silent)
                        Toggle("촬영 피드백", isOn: $feedback)
                        Toggle("기본 플래시", isOn: $flash)
                    }
                    .toggleStyle(IPadSettingsNativeToggleStyle())
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }.id("카메라")
                Section("스캔") {
                    Picker("기본 모드", selection: $mode) { ForEach(CaptureMode.allCases.filter { $0 != .video }) { Text($0.rawValue).tag($0.rawValue) } }
                    Picker("자동 보정", selection: $enhancement) { ForEach(Enhancement.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                }.id("스캔")
                Section("PDF") {
                    Picker("페이지 크기", selection: $paper) { ForEach(PaperSize.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    Picker("화질", selection: $quality) { ForEach(ExportQuality.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                }.id("PDF")
                Section("저장 공간") {
                    LabeledContent("사용 중", value: ByteCountFormatter.string(fromByteCount: store.usedBytes, countStyle: .file))
                    NavigationLink("스캔 관리") { IPadPagesScreen(onFinish: onFinish) }
                    NavigationLink("저장한 PDF·동영상") { IPadSavedFilesScreen() }
                    Button("촬영 페이지 모두 삭제", role: .destructive) { deleteAll = true }
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .disabled(store.pages.isEmpty)
                }.id("저장 공간")
                Section("정보") {
                    LabeledContent("Demo-Hushto", value: "1.0.0")
                    informationLink("개인정보처리방침", url: "https://even-kale-201.notion.site/Hushto-3fa582c1e59681728478c1bc9596cc6d")
                    informationLink("도움말", url: "https://even-kale-201.notion.site/Hushto-3fa582c1e5968103b383f84a100f916d")
                    informationLink("고객지원", url: "https://even-kale-201.notion.site/Hushto-3fb582c1e596815b8cb7d4eb3a3477cc")
                    informationLink("촬영 방식 안내", url: "https://even-kale-201.notion.site/Hushto-3fa582c1e596810eb671fb459dcb86c1")
                    if let camera { NavigationLink("촬영 방식 확인") { CaptureDiagnosticsScreen(camera: camera) } }
                }.id("정보")
            }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("설정").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("카메라로 돌아가기") } }

        }
        }
        .navigationSplitViewStyle(.balanced)
                .overlay {
                    if deleteAll {
                        IPadDecisionOverlay(title: "촬영 페이지를 모두 삭제할까요?",
                                            message: "현재 스캔의 원본과 보정 이미지가 삭제돼요. 저장한 PDF와 동영상은 유지돼요.",
                                            confirmTitle: "삭제", cancelTitle: "취소", confirm: {
                            store.delete(Set(store.pages.map(\.id))); deleteAll = false
                        }, cancel: { deleteAll = false })
                    }
                }
                .overlay { IPadNoticeOverlay(notice: $store.notice) }
        }
    }

    private func informationLink(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Text(title).foregroundStyle(Theme.label)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
    }
}
struct IPadSavedFilesScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: ScanStore
    @ViewState private var files: [URL] = []
    @ViewState private var sharing: SavedFileShare?
    @ViewState private var deletingFiles: [URL] = []
    @ViewState private var confirmDeletion = false
    var body: some View {
        List {
            if files.isEmpty { ContentUnavailableView("저장한 파일이 없어요", systemImage: "doc") }
            ForEach(files, id: \.self) { file in
                HStack {
                    NavigationLink { if file.pathExtension == "pdf" { PDFPreview(url: file).navigationTitle(file.lastPathComponent).navigationBarTitleDisplayMode(.inline) } else { IPadVideoResult(url: file) } } label: { Label(file.lastPathComponent, systemImage: "doc.richtext") }
                    Button { sharing = SavedFileShare(url: file) } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless).accessibilityLabel("\(file.lastPathComponent) 공유")
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deletingFiles = [file]; confirmDeletion = true
                    } label: {
                        Label("삭제", systemImage: "trash").foregroundStyle(colorScheme == .dark ? Color.white : Theme.onAccent)
                    }
                    .tint(colorScheme == .dark ? Color(white: 0.2) : Theme.label)
                }
            }
        }.navigationTitle("저장한 PDF·동영상").navigationBarTitleDisplayMode(.inline).onAppear { files = store.savedFiles }
            .alert("선택한 파일을 삭제할까요?", isPresented: $confirmDeletion) {
                Button("삭제", role: .destructive) { let selected = deletingFiles; store.deleteSavedFiles(selected); deletingFiles = []; files = store.savedFiles }
                Button("취소", role: .cancel) { deletingFiles = [] }
            } message: { Text("앱에 저장한 파일이 삭제돼요. 이미 공유한 사본은 유지돼요.") }
            .sheet(item: $sharing) { selected in ShareSheet(items: [selected.url]) }
    }
}

// Preserve the system switch's glass, touch tracking and accessibility.
// Only the switch rendering is inverted in dark mode; row labels keep their theme.
private struct IPadSettingsNativeToggleStyle: ToggleStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label.font(.system(size: 17))
            Spacer(minLength: 16)
            Group {
                if colorScheme == .dark {
                    nativeSwitch(configuration).colorInvert()
                } else {
                    nativeSwitch(configuration)
                }
            }
        }
        .frame(minHeight: 48)
    }

    private func nativeSwitch(_ configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255))
            .environment(\.colorScheme, .light)
            .fixedSize()
    }
}
