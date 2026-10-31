import SwiftUI
import PDFKit
import Photos
import AVKit
import UniformTypeIdentifiers

struct PagesScreen: View {
    var onAdd: (() -> Void)? = nil
    var onFinish: (() -> Void)? = nil
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selected: Set<UUID> = []
    @ViewState private var selecting = false
    @ViewState private var draggingPage: UUID?
    @ViewState private var deleting = false
    @ViewState private var rename = false
    @ViewState private var draftTitle = ""
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Button { draftTitle = store.title; rename = true } label: { Text(store.title).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.label) }
                    Text("\(store.pages.count)페이지 · 길게 눌러 순서를 바꾸세요").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if !store.pages.isEmpty { Menu {
                    Button(selecting ? "선택 취소" : "페이지 선택", systemImage: "checkmark.circle") { selecting.toggle(); selected.removeAll() }
                    Button("전체 삭제", systemImage: "trash", role: .destructive) { selected = Set(store.pages.map(\.id)); deleting = true }
                } label: { Image(systemName: "ellipsis.circle").font(.title2) }.accessibilityLabel("페이지 작업") }
            }.padding(.horizontal, 24).padding(.top, 20)
            if store.pages.isEmpty {
                ContentUnavailableView { Label("아직 촬영한 페이지가 없어요", systemImage: "doc.viewfinder") } description: { Text("촬영하거나 사진을 가져와 스캔을 시작하세요.") } actions: { Button("촬영하러 가기") { dismiss() } }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 24) {
                        ForEach(Array(store.pages.enumerated()), id: \.element.id) { index, page in
                            if selecting {
                                Button { if selected.contains(page.id) { selected.remove(page.id) } else { selected.insert(page.id) } } label: { card(page, index: index) }.buttonStyle(.plain)
                            } else {
                                NavigationLink { EnhanceScreen(page: page) } label: { card(page, index: index) }
                                    .buttonStyle(.plain)
                                    .onDrag {
                                        draggingPage = page.id
                                        return NSItemProvider(object: page.id.uuidString as NSString)
                                    }
                                    .onDrop(of: [UTType.text], delegate: PageReorderDropDelegate(
                                        targetID: page.id, store: store, dragging: $draggingPage))
                                    .accessibilityAction(named: Text("앞으로 이동")) { store.movePage(page.id, offset: -1) }
                                    .accessibilityAction(named: Text("뒤로 이동")) { store.movePage(page.id, offset: 1) }
                            }
                        }
                    }.padding(.horizontal, 24)
                }
            }
            if selecting {
                HStack {
                    Button(selected.count == store.pages.count ? "선택 해제" : "전체 선택") { selected = selected.count == store.pages.count ? [] : Set(store.pages.map(\.id)) }
                    Spacer()
                    Button("\(selected.count)페이지 삭제", role: .destructive) { deleting = true }.disabled(selected.isEmpty)
                }.padding(.horizontal, 24)
            }
            NavigationLink { ExportScreen(onFinish: onFinish) } label: { Text("PDF 만들기").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 50) }
                .hushtoProminentAction().buttonBorderShape(.capsule).tint(Theme.label).foregroundStyle(Theme.onAccent).disabled(store.pages.isEmpty)
                .padding(.horizontal, 24).padding(.bottom, 20)
        }.background(Theme.background).navigationTitle("스캔 문서").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label("돌아가기", systemImage: "chevron.left") }
                        .accessibilityLabel("돌아가기")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("추가") { if let onAdd { onAdd() } else { dismiss() } }
                }
            }
            .alert("선택한 페이지를 삭제할까요?", isPresented: $deleting) {
                Button("취소", role: .cancel) { selected.removeAll() }
                Button("삭제", role: .destructive) { store.delete(selected); selected.removeAll(); selecting = false }
            } message: { Text("\(selected.count)페이지가 삭제돼요. 저장한 PDF는 유지돼요.") }
            .alert("문서 이름", isPresented: $rename) { TextField("문서 이름", text: $draftTitle); Button("저장") { store.rename(draftTitle) }; Button("취소", role: .cancel) {} }
            .alert(item: $store.notice) { n in Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("확인"))) }
    }
    private func card(_ page: ScanPage, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StoredPageImage(store: store, page: page, thumbnail: true) { image in
                if let image { Image(uiImage: image).resizable().scaledToFit().id(page.thumbnail).frame(maxWidth: .infinity).frame(height: 183).clipShape(RoundedRectangle(cornerRadius: 12)) }
                else { Color.clear.frame(height: 183) }
            }
            HStack { Text(String(format: "페이지 %02d", index + 1)).font(.system(size: 13)).foregroundStyle(Theme.secondary); Spacer(); if selecting { Image(systemName: selected.contains(page.id) ? "checkmark.circle.fill" : "circle") } }
        }.padding(8).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20)).accessibilityLabel("페이지 \(index + 1)")
    }
}
@MainActor
private struct PageReorderDropDelegate: DropDelegate {
    let targetID: UUID
    let store: ScanStore
    @Binding var dragging: UUID?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil && !store.busy }
    func dropEntered(info: DropInfo) {
        guard let id = dragging, id != targetID,
              let from = store.pages.firstIndex(where: { $0.id == id }),
              let to = store.pages.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            store.move(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}
