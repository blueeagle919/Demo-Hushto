import SwiftUI
import UIKit

@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var session = ScanSession()
    @Published var busy = false
    @Published var notice: AppNotice?
    @Published var duplicate: ScanPage?
    @Published var lastCapture: UUID?
    @Published var exportedURL: URL?
    @Published private(set) var exportedPageCount = 0
    let root: URL
    private let thumbnailCache = NSCache<NSString, UIImage>()
    private let previewCache = NSCache<NSString, UIImage>()
    private var memoryObserver: NSObjectProtocol?
    private let worker = DispatchQueue(label: "app.hushto.image-worker", qos: .userInitiated, autoreleaseFrequency: .workItem)

    init(root: URL? = nil, restoreInBackground: Bool? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Hushto", isDirectory: true)
        thumbnailCache.totalCostLimit = RuntimeBudget.current.thumbnailCacheBytes
        thumbnailCache.countLimit = 48
        previewCache.totalCostLimit = RuntimeBudget.current.previewCacheBytes
        previewCache.countLimit = 3
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.thumbnailCache.removeAllObjects(); self?.previewCache.removeAllObjects()
                await EnhancementPreviewRenderer.shared.releaseCaches()
            }
        }
        let directory = self.root
        if restoreInBackground ?? (root == nil) {
            // Restore before allowing capture, but leave the main thread free to draw the first frame.
            busy = true
            worker.async {
                let result = Result { try Self.loadSession(at: directory) }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let restored): self.session = restored
                    case .failure(let error): self.report(error, title: "이전 스캔을 불러오지 못했어요")
                    }
                    self.busy = false
                }
            }
        } else {
            // Explicit stores keep synchronous restoration for importers and deterministic tests.
            do { session = try Self.loadSession(at: directory) }
            catch { report(error, title: "이전 스캔을 불러오지 못했어요") }
        }
    }
    deinit { if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) } }
    nonisolated private static func loadSession(at root: URL) throws -> ScanSession {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = root.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return ScanSession() }
        let restored = try JSONDecoder().decode(ScanSession.self, from: Data(contentsOf: manifest))
        guard restored.pages.allSatisfy({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0.original).path) }) else { throw HushtoError.image }
        return restored
    }
    var pages: [ScanPage] { session.pages }
    var title: String { session.title }
    func url(_ file: String) -> URL { root.appendingPathComponent(file) }
    func image(_ page: ScanPage, original: Bool = false) -> UIImage? {
        let current = pages.first(where: { $0.id == page.id }) ?? page
        return UIImage(contentsOfFile: url(original ? current.original : current.rendered).path)
    }
    /// Screen-only decoding is bounded; export and Photos still use the full-resolution original.
    func preview(_ page: ScanPage) -> UIImage? {
        let current = pages.first(where: { $0.id == page.id }) ?? page
        let key = current.rendered as NSString
        if let image = previewCache.object(forKey: key) { return image }
        guard let image = ImageProcessor.previewImage(at: url(current.rendered)) else { return nil }
        previewCache.setObject(image, forKey: key,
            cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
        return image
    }
    func thumbnail(_ page: ScanPage) -> UIImage? {
        let current = pages.first(where: { $0.id == page.id }) ?? page
        let key = current.thumbnail as NSString
        if let image = thumbnailCache.object(forKey: key) { return image }
        guard let image = ImageProcessor.previewImage(at: url(current.thumbnail), maxEdge: 360) else { return nil }
        thumbnailCache.setObject(image, forKey: key, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
        return image
    }
    private func persist(_ candidate: ScanSession) throws {
        try JSONEncoder().encode(candidate).write(to: url("session.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        session = candidate
    }
    func rename(_ title: String) {
        guard !busy else { return }
        var candidate = session; candidate.title = title.isEmpty ? "새 스캔 문서" : title
        do { try persist(candidate) } catch { report(error) }
    }
    func report(_ error: Error, title: String = "작업을 완료하지 못했어요") {
        notice = AppNotice(title: title, message: error.localizedDescription)
    }
    /// Returns camera media for Photos without adding it to the PDF scan session.
    func receiveCapture(_ image: UIImage, mode: CaptureMode, filter: Enhancement) -> GalleryCapture? {
        if mode.savesToPhotoLibrary { return GalleryCapture(image: image) }
        add(image, mode: mode, filter: filter)
        return nil
    }
    func add(_ image: UIImage, mode: CaptureMode, filter: Enhancement) {
        guard !busy else { return }
        busy = true
        let root = self.root
        worker.async {
            var created: [URL] = []
            do {
                let processor = ImageProcessor.shared
                let normalized = processor.normalize(image)
                let corners = mode.needsCorrection ? CIImage(image: normalized).map { processor.documentCorners(in: $0).map(CropPoint.init) } : nil
                let rendered = try processor.render(normalized, filter: filter, correct: mode.needsCorrection, correctionCorners: corners)
                let id = UUID(); let stem = id.uuidString
                let page = ScanPage(id: id, original: stem + "-original.jpg", rendered: stem + ".jpg",
                    thumbnail: stem + "-thumb.jpg", fingerprint: processor.fingerprint(rendered), filter: filter, corrected: mode.needsCorrection, correctionCorners: corners, mode: mode)
                for (name, img, quality) in [(page.original, normalized, 0.98), (page.rendered, rendered, 0.96), (page.thumbnail, processor.normalize(rendered, maxEdge: 360), 0.7)] {
                    guard let data = img.jpegData(compressionQuality: quality) else { throw HushtoError.image }
                    let target = root.appendingPathComponent(name); created.append(target)
                    try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                DispatchQueue.main.async {
                    self.busy = false
                    if self.pages.contains(where: { ScanRules.isDuplicate($0.fingerprint, page.fingerprint) }) {
                        self.duplicate = page
                    } else { self.accept(page) }
                }
            } catch {
                created.forEach { try? FileManager.default.removeItem(at: $0) }
                DispatchQueue.main.async { self.busy = false; self.report(error) }
            }
        }
    }
    func accept(_ page: ScanPage) {
        var candidate = session; candidate.pages.append(page)
        do { try persist(candidate); lastCapture = page.id; duplicate = nil }
        catch { removeFiles(page); duplicate = nil; report(error) }
    }
    func rejectDuplicate() { if let page = duplicate { removeFiles(page) }; duplicate = nil }
    private func removeFiles(_ page: ScanPage) {
        thumbnailCache.removeObject(forKey: page.thumbnail as NSString)
        previewCache.removeObject(forKey: page.rendered as NSString)
        [page.original, page.rendered, page.thumbnail].forEach { try? FileManager.default.removeItem(at: url($0)) }
    }
    func delete(_ ids: Set<UUID>) {
        guard !busy else { return }
        let removed = pages.filter { ids.contains($0.id) }
        var candidate = session; candidate.pages.removeAll { ids.contains($0.id) }
        do { try persist(candidate); removed.forEach(removeFiles) } catch { report(error) }
    }
    func move(from offsets: IndexSet, to destination: Int) {
        guard !busy else { return }
        var candidate = session; candidate.pages.move(fromOffsets: offsets, toOffset: destination)
        do { try persist(candidate) } catch { report(error) }
    }
    func movePage(_ id: UUID, offset: Int) {
        guard !busy, let from = pages.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard pages.indices.contains(to) else { return }
        move(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
    }
    func update(_ page: ScanPage, filter: Enhancement, brightness: Double, contrast: Double, geometry: PageGeometry? = nil, completion: @escaping () -> Void) {
        guard !busy, let page = pages.first(where: { $0.id == page.id }) else { return }
        busy = true
        let root = self.root
        worker.async {
            do {
                guard let original = UIImage(contentsOfFile: root.appendingPathComponent(page.original).path) else { throw HushtoError.image }
                let processor = ImageProcessor.shared
                let corners = page.correctionCorners ?? (page.corrected ? CIImage(image: original).map { processor.documentCorners(in: $0).map(CropPoint.init) } : nil)
                let rendered = try processor.render(original, filter: filter, brightness: brightness, contrast: contrast, correct: page.corrected, correctionCorners: corners, geometry: geometry ?? page.geometry ?? PageGeometry())
                // New files keep the previous page intact if rendering or manifest saving fails.
                let stem = UUID().uuidString
                var changed = page; changed.rendered = stem + ".jpg"; changed.thumbnail = stem + "-thumb.jpg"
                changed.correctionCorners = corners
                changed.geometry = geometry ?? page.geometry; changed.filter = filter; changed.brightness = brightness; changed.contrast = contrast
                changed.fingerprint = processor.fingerprint(rendered)
                guard let data = rendered.jpegData(compressionQuality: 0.96), let thumb = processor.normalize(rendered, maxEdge: 360).jpegData(compressionQuality: 0.7) else { throw HushtoError.image }
                try data.write(to: root.appendingPathComponent(changed.rendered), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                do { try thumb.write(to: root.appendingPathComponent(changed.thumbnail), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                catch { try? FileManager.default.removeItem(at: root.appendingPathComponent(changed.rendered)); throw error }
                let finalPage = changed
                DispatchQueue.main.async {
                    self.busy = false
                    guard let index = self.pages.firstIndex(where: { $0.id == page.id }) else { self.removeEditedFiles(finalPage); return }
                    var candidate = self.session; candidate.pages[index] = finalPage
                    do {
                        try self.persist(candidate)
                        self.thumbnailCache.removeObject(forKey: page.thumbnail as NSString)
                        self.previewCache.removeObject(forKey: page.rendered as NSString)
                        [page.rendered, page.thumbnail].forEach { try? FileManager.default.removeItem(at: self.url($0)) }
                        completion()
                    } catch { self.removeEditedFiles(finalPage); self.report(error) }
                }
            } catch { DispatchQueue.main.async { self.busy = false; self.report(error) } }
        }
    }
    private func removeEditedFiles(_ page: ScanPage) {
        [page.rendered, page.thumbnail].forEach { try? FileManager.default.removeItem(at: url($0)) }
    }
    func export(name: String, paper: PaperSize, quality: ExportQuality) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ScanRules.validFilename(clean) else { report(HushtoError.filename); return }
        guard !pages.isEmpty else { report(HushtoError.noPages); return }
        guard !busy else { return }; busy = true
        let snapshot = pages, root = self.root
        worker.async {
            do {
                let file = root.appendingPathComponent(clean + ".pdf")
                guard !FileManager.default.fileExists(atPath: file.path) else {
                    throw NSError(domain: "Hushto", code: 1, userInfo: [NSLocalizedDescriptionKey: "같은 이름의 PDF가 있어요. 다른 이름으로 저장해주세요."])
                }
                let temporary = root.appendingPathComponent(UUID().uuidString + ".tmp")
                defer { try? FileManager.default.removeItem(at: temporary) }
                let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: paper.size ?? CGSize(width: 595, height: 842)))
                var failedPage = false
                try renderer.writePDF(to: temporary) { context in
                    for page in snapshot {
                        autoreleasepool {
                            guard let decoded = ImageProcessor.previewImage(at: root.appendingPathComponent(page.rendered), maxEdge: Int(quality.edge)),
                                  let jpeg = decoded.jpegData(compressionQuality: quality.compression),
                                  let image = UIImage(data: jpeg) else { failedPage = true; return }
                            let size = paper.size ?? image.size
                            context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                            UIColor.white.setFill(); context.cgContext.fill(CGRect(origin: .zero, size: size))
                            let margin: CGFloat = paper == .original ? 0 : 20
                            let available = CGSize(width: size.width - margin * 2, height: size.height - margin * 2)
                            let ratio = min(available.width / image.size.width, available.height / image.size.height)
                            let scaled = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                            image.draw(in: CGRect(x: (size.width - scaled.width) / 2, y: (size.height - scaled.height) / 2, width: scaled.width, height: scaled.height))
                        }
                    }
                }
                // Validate every page was rendered before publishing the file.
                guard !failedPage, let document = CGPDFDocument(temporary as CFURL), document.numberOfPages == snapshot.count else { throw HushtoError.image }
                try FileManager.default.moveItem(at: temporary, to: file)
                DispatchQueue.main.async {
                    do {
                        // Publish a fresh session only after the PDF and manifest are safely saved.
                        try self.persist(ScanSession())
                        self.exportedPageCount = snapshot.count
                        self.lastCapture = nil
                        self.duplicate = nil
                        snapshot.forEach(self.removeFiles)
                        self.busy = false
                        self.exportedURL = file
                    } catch {
                        self.busy = false
                        self.report(error, title: "PDF는 저장됐지만 촬영 목록을 비우지 못했어요")
                    }
                }
            } catch { DispatchQueue.main.async { self.busy = false; self.report(error) } }
        }
    }
    func deleteSavedFiles(_ files: [URL]) {
        guard !busy else { return }
        for file in files {
            guard file.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
                  ["pdf", "mov"].contains(file.pathExtension.lowercased()) else { continue }
            do { try FileManager.default.removeItem(at: file) } catch { report(error); return }
        }
        objectWillChange.send()
    }
    var savedFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["pdf", "mov"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    var usedBytes: Int64 {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []).reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
