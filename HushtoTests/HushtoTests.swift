import XCTest
import UIKit
import CoreMedia
import AVFoundation
import CoreImage
import Photos
@testable import Hushto

final class HushtoTests: XCTestCase {
    func testStagedPhotoCanSaveDirectlyToPhotosAndClearOutbox() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 160)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 160))
        }
        let box = PendingGalleryStore(root: root)
        let staged = try await box.stage(GalleryCapture(image: image))
        XCTAssertNil(staged.image)
        try await PhotoLibraryWriter.save(staged)
        try await box.remove(staged)
        let empty = try await box.load()
        XCTAssertNil(empty)
    }

    func testPendingPhotoSurvivesStoreRecreationWithoutFullImageDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4032, height: 32), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4032, height: 32))
        }
        let capture = GalleryCapture(image: image)
        let box = PendingGalleryStore(root: root)
        let staged = try await box.stage(capture)
        XCTAssertNil(staged.image)
        XCTAssertEqual(staged.id, capture.id)
        let url = try XCTUnwrap(staged.imageURL)
        XCTAssertEqual(UIImage(contentsOfFile: url.path)?.cgImage?.width, 4032)
        let reloaded = try await PendingGalleryStore(root: root).load()
        XCTAssertEqual(reloaded?.id, capture.id)
        XCTAssertEqual(reloaded?.imageURL, url)
        let bytes = try Data(contentsOf: url)
        _ = try await box.stage(staged)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        try await box.remove(staged)
        let empty = try await box.load()
        XCTAssertNil(empty)
    }

    func testPendingMovieRecoversBetweenMediaAndManifestWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let bytes = Data(repeating: 29, count: 1024)
        try bytes.write(to: source)
        let capture = GalleryCapture(videoURL: source)
        let box = PendingGalleryStore(root: root)
        let staged = try await box.stage(capture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let url = try XCTUnwrap(staged.videoURL)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        try FileManager.default.removeItem(at: root.appendingPathComponent("capture.json"))
        let restored = try await PendingGalleryStore(root: root).load()
        XCTAssertEqual(restored?.id, capture.id)
        XCTAssertEqual(restored?.videoURL, url)
        try await box.remove(capture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPendingCaptureCannotBeOverwrittenByAnotherCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = UIImage(systemName: "doc")!
        let first = GalleryCapture(image: image)
        let box = PendingGalleryStore(root: root)
        let staged = try await box.stage(first)
        let data = try Data(contentsOf: XCTUnwrap(staged.imageURL))
        do { _ = try await box.stage(GalleryCapture(image: image)); XCTFail("Must retain pending capture") } catch {}
        let restored = try await box.load()
        XCTAssertEqual(restored?.id, first.id)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored?.imageURL)), data)
    }

    func testPendingStageFailureLeavesMovieSourceIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        try Data([0]).write(to: root)
        let bytes = Data([1, 2, 3]); try bytes.write(to: source)
        do { _ = try await PendingGalleryStore(root: root).stage(GalleryCapture(videoURL: source)); XCTFail("Expected write failure") } catch {}
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testRuntimeBudgetBoundsLowMemoryWorkWithoutChangingExportQuality() {
        let low = RuntimeBudget(physicalMemory: 3 * 1024 * 1024 * 1024)
        let normal = RuntimeBudget(physicalMemory: 4 * 1024 * 1024 * 1024)
        XCTAssertLessThan(low.previewEdge, normal.previewEdge)
        XCTAssertLessThan(low.cropPreviewEdge, normal.cropPreviewEdge)
        XCTAssertLessThan(low.previewCacheBytes, normal.previewCacheBytes)
        XCTAssertGreaterThan(low.detectionInterval, normal.detectionInterval)
        XCTAssertEqual(ExportQuality.high.edge, 4032)
    }

    @MainActor func testMemoryWarningDropsPreviewCachesWithoutDroppingPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanStore(root: root)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 96)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        }
        store.add(image, mode: .photo, filter: .original)
        try await settled(store)
        let page = try XCTUnwrap(store.pages.first)
        let before = try XCTUnwrap(store.preview(page))
        XCTAssertTrue(before === store.preview(page))
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(before === store.preview(page))
        XCTAssertEqual(store.pages, [page])
        XCTAssertNotNil(store.image(page))
    }

    func testDeniedPhotosPermissionPreservesPendingMedia() async throws {
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .denied else {
            throw XCTSkip("Run with simulator photos-add permission denied")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await PhotoLibraryWriter.save(GalleryCapture(videoURL: url))
            XCTFail("Denied permission must fail")
        } catch {
            XCTAssertEqual((error as NSError).domain, "Hushto.Photos")
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        let image = UIImage(systemName: "doc")!
        let capture = GalleryCapture(image: image)
        do { try await PhotoLibraryWriter.save(capture); XCTFail("Denied permission must fail") }
        catch { XCTAssertTrue(capture.image === image) }
    }

    @MainActor func testThirtyPageEditingRestoreAndPDFRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanStore(root: root)
        let started = ProcessInfo.processInfo.systemUptime
        for index in 0..<30 {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 480), format: format).image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 480))
                UIColor.black.setFill()
                for row in 0..<8 { ctx.fill(CGRect(x: 20 + index * 2, y: 30 + row * 45, width: 150 + index, height: 5)) }
            }
            store.add(image, mode: [.document, .board, .screen][index % 3], filter: .auto)
            try await settled(store)
            if let duplicate = store.duplicate { store.accept(duplicate) }
            let page = try XCTUnwrap(store.pages.last)
            let geometry = PageGeometry(quarterTurns: index % 4, horizontalTilt: 3, verticalTilt: -2, width: 0.8, height: 0.9)
            store.update(page, filter: .auto, brightness: 0.03, contrast: 1.05, geometry: geometry) {}
            try await settled(store)
            let saved = try XCTUnwrap(store.pages.last)
            XCTAssertEqual(saved.geometry, geometry)
            XCTAssertNotNil(store.preview(saved))
            XCTAssertNotNil(store.thumbnail(saved))
            XCTAssertEqual(ScanStore(root: root).pages, store.pages)
        }
        XCTAssertEqual(store.pages.count, 30)
        let renderedSizes = store.pages.map { store.image($0)!.size }
        store.export(name: "30-page-validation", paper: .original, quality: .high)
        try await settled(store)
        let pdf = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(store.exportedURL) as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 30)
        for index in 0..<30 {
            let size = try XCTUnwrap(pdf.page(at: index + 1)).getBoxRect(.mediaBox).size
            XCTAssertEqual(size.width, renderedSizes[index].width, accuracy: 1)
            XCTAssertEqual(size.height, renderedSizes[index].height, accuracy: 1)
        }
        XCTAssertTrue(store.pages.isEmpty)
        XCTAssertTrue(ScanStore(root: root).pages.isEmpty)
        print("VALIDATION: 30 pages capture/edit/restore/PDF seconds=", ProcessInfo.processInfo.systemUptime - started)
    }

    @MainActor func testWriteFailurePreservesExistingSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backup = root.appendingPathExtension("backup")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: backup) }
        let store = ScanStore(root: root)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 96)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        }
        store.add(image, mode: .photo, filter: .original)
        try await settled(store)
        let before = store.pages
        let manifest = try Data(contentsOf: root.appendingPathComponent("session.json"))
        try FileManager.default.moveItem(at: root, to: backup)
        try Data([0]).write(to: root)
        store.add(image, mode: .photo, filter: .original)
        try await settled(store)
        XCTAssertNotNil(store.notice)
        XCTAssertEqual(store.pages, before)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: backup, to: root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("session.json")), manifest)
        XCTAssertEqual(ScanStore(root: root).pages, before)
    }

    @MainActor func testBackgroundRestoreKeepsSessionAndBlocksEarlyCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ScanStore(root: root)
        original.rename("복원 테스트")
        let restored = ScanStore(root: root, restoreInBackground: true)
        XCTAssertTrue(restored.busy)
        restored.rename("복원 중 덮어쓰기 금지")
        try await settled(restored)
        XCTAssertEqual(restored.title, original.title)
        XCTAssertEqual(restored.pages, original.pages)
        XCTAssertNil(restored.notice)
    }

    func testLaptopScreenWinsOverLargerKeyboardWithoutRejectingWideScreen() {
        func quad(_ rect: CGRect) -> [CGPoint] {
            [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        }
        let screen = quad(CGRect(x: 0.25, y: 0.06, width: 0.5, height: 0.4))
        let keyboard = quad(CGRect(x: 0.125, y: 0.53, width: 0.75, height: 0.32))
        XCTAssertEqual(ImageProcessor.preferredRectangle([(keyboard, 0.95), (screen, 0.85)]), screen)
        XCTAssertEqual(ImageProcessor.preferredRectangle([(screen, 0.85), (keyboard, 0.95)]), screen)
        XCTAssertEqual(ImageProcessor.preferredRectangle([(keyboard, 0.95)]), keyboard)
    }

    func testMultipleSmallDocumentsAndScreensRemainDetectable() {
        let processor = ImageProcessor()
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        for rectangles in [
            [CGRect(x: 50, y: 80, width: 120, height: 180), CGRect(x: 300, y: 100, width: 130, height: 190), CGRect(x: 600, y: 240, width: 120, height: 170)],
            [CGRect(x: 35, y: 200, width: 200, height: 115), CGRect(x: 295, y: 220, width: 210, height: 120), CGRect(x: 560, y: 180, width: 190, height: 110)]
        ] {
            var scene = CIImage(color: .gray).cropped(to: bounds)
            for rect in rectangles { scene = CIImage(color: .white).cropped(to: rect).composited(over: scene) }
            XCTAssertTrue(PageGeometry.valid(processor.documentCorners(in: scene)))
        }
        XCTAssertTrue(processor.documentCorners(in: CIImage(color: .gray).cropped(to: bounds)).isEmpty)
    }

    func testQuietRequestNeverAcceptsSystemPhotoOrSecondRequest() {
        var gate = CaptureRequestGate()
        XCTAssertEqual(gate.begin(silent: true, now: 10), .videoFrame)
        XCTAssertNil(gate.begin(silent: false, now: 10.1))
        gate.completePhoto()
        XCTAssertEqual(gate.route, .videoFrame)
        XCTAssertTrue(gate.consumeVideoFrame(now: 10.2))
        XCTAssertFalse(gate.consumeVideoFrame(now: 10.3))
    }
    func testTimeoutDoesNotFallBackToPhoto() throws {
        var gate = CaptureRequestGate()
        _ = gate.begin(silent: true, now: 10)
        let token = try XCTUnwrap(gate.token)
        XCTAssertFalse(gate.expire(token: token, now: 12))
        XCTAssertTrue(gate.expire(token: token, now: 14))
        XCTAssertNil(gate.route)
        XCTAssertFalse(gate.consumeVideoFrame(now: 14))
    }
    func testOldTimeoutCannotCancelNewCapture() throws {
        var gate = CaptureRequestGate()
        _ = gate.begin(silent: true, now: 0)
        let oldToken = try XCTUnwrap(gate.token)
        gate.cancel()
        _ = gate.begin(silent: true, now: 1)
        XCTAssertFalse(gate.expire(token: oldToken, now: 9))
        XCTAssertEqual(gate.route, .videoFrame)
    }
    @MainActor func testSyntheticSilentBufferProducesImageWithoutPhotoRequest() throws {
        let camera = CameraController()
        let finished = expectation(description: "Video frame callback")
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 3024, 4032, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, 180, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        camera.onCapture = { image in
            XCTAssertEqual(image.cgImage?.width, 3024)
            XCTAssertEqual(image.cgImage?.height, 4032)
            XCTAssertEqual(camera.systemPhotoCount, 0)
            XCTAssertEqual(camera.silentFrameCount, 1)
            finished.fulfill()
        }
        camera.testSilentFrame(try XCTUnwrap(sample))
        wait(for: [finished], timeout: 10)
    }
    @MainActor func testSessionPersistenceDuplicateReorderAndPDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanStore(root: root)
        func note(_ offset: CGFloat) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
                UIColor.black.setFill()
                for row in 0..<10 { context.fill(CGRect(x: 20 + offset, y: CGFloat(row * 30) + 30, width: 180 - offset, height: 8)) }
            }
        }
        store.add(note(0), mode: .photo, filter: .original)
        try await settled(store)
        XCTAssertEqual(store.pages.count, 1)
        let first = try XCTUnwrap(store.pages.first)
        store.add(note(0), mode: .photo, filter: .original)
        try await settled(store)
        XCTAssertNotNil(store.duplicate)
        store.rejectDuplicate()
        XCTAssertEqual(store.pages.count, 1)
        store.add(note(100), mode: .photo, filter: .original)
        try await settled(store)
        XCTAssertEqual(store.pages.count, 2)
        store.move(from: IndexSet(integer: 1), to: 0)
        store.rename("테스트 노트")
        let restored = ScanStore(root: root)
        XCTAssertEqual(restored.pages, store.pages)
        XCTAssertEqual(restored.title, "테스트 노트")
        XCTAssertEqual(restored.pages.last?.id, first.id)
        store.export(name: "검증", paper: .a4, quality: .standard)
        try await settled(store)
        let url = try XCTUnwrap(store.exportedURL)
        let pdf = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 2)
        XCTAssertEqual(try XCTUnwrap(pdf.page(at: 1)).getBoxRect(.mediaBox).width, 595.28, accuracy: 1)
        XCTAssertTrue(store.pages.isEmpty)
        XCTAssertNil(store.lastCapture)
        XCTAssertEqual(store.exportedPageCount, 2)
        XCTAssertTrue(ScanStore(root: root).pages.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(first.original).path))
        store.add(note(60), mode: .document, filter: .original)
        try await settled(store)
        XCTAssertEqual(store.pages.count, 1, "New scans must start a fresh session")
        let bytes = try Data(contentsOf: url)
        store.export(name: "검증", paper: .a4, quality: .small)
        try await settled(store)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "Existing PDF must not be overwritten")
        store.notice = nil
        store.export(name: "../outside", paper: .a4, quality: .standard)
        XCTAssertNotNil(store.notice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("outside.pdf").path))
        store.delete(Set(store.pages.map(\.id)))
        XCTAssertTrue(ScanStore(root: root).pages.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    @MainActor func testAllFiltersRenderAndCorruptPageCannotExportPartialPDF() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 160)).image { context in
            UIColor.lightGray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 160))
        }
        for filter in Enhancement.allCases {
            let rendered = try ImageProcessor().render(image, filter: filter, brightness: 0.1, contrast: 1.1, correct: false)
            XCTAssertEqual(rendered.cgImage?.width, image.cgImage?.width)
            XCTAssertEqual(rendered.cgImage?.height, image.cgImage?.height)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanStore(root: root)
        store.add(image, mode: .photo, filter: .original)
        try await settled(store)
        let page = try XCTUnwrap(store.pages.first)
        try FileManager.default.removeItem(at: store.url(page.rendered))
        store.export(name: "incomplete", paper: .a4, quality: .standard)
        try await settled(store)
        XCTAssertNil(store.exportedURL)
        XCTAssertNotNil(store.notice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url("incomplete.pdf").path))
    }
    @MainActor func testPhotoBypassesScanSessionAndScanModesEnterSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanStore(root: root)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            UIColor.black.setFill(); context.fill(CGRect(x: 40, y: 40, width: 100, height: 120))
        }
        XCTAssertNotNil(store.receiveCapture(image, mode: .photo, filter: .original))
        XCTAssertTrue(store.pages.isEmpty)
        XCTAssertFalse(store.busy)
        XCTAssertTrue(CaptureMode.video.savesToPhotoLibrary)
        for mode in [CaptureMode.document, .board, .screen] {
            XCTAssertFalse(mode.savesToPhotoLibrary)
            XCTAssertNil(store.receiveCapture(image, mode: mode, filter: .original))
            try await settled(store)
            if let duplicate = store.duplicate { store.accept(duplicate) }
        }
        XCTAssertEqual(store.pages.count, 3)
        let ids = store.pages.map(\.id)
        store.movePage(ids[0], offset: 1)
        XCTAssertEqual(store.pages.map(\.id), [ids[1], ids[0], ids[2]])
        store.movePage(ids[0], offset: -1)
        XCTAssertEqual(store.pages.map(\.id), ids)
        store.movePage(ids[0], offset: -1)
        XCTAssertEqual(store.pages.map(\.id), ids, "Cannot move before first page")
        XCTAssertEqual(ScanStore(root: root).pages.map(\.id), ids)
    }
    @MainActor func testPhotoLibrarySavesImageAndVideo() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        try await PhotoLibraryWriter.save(GalleryCapture(image: image))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, 200, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for second in 0...1 {
            let timeout = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData && Date() < timeout { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(seconds: Double(second), preferredTimescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        try await PhotoLibraryWriter.save(GalleryCapture(videoURL: url))
    }
    func testRotationCropCoordinatesAndLegacyPageDecoding() throws {
        var geometry = PageGeometry(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let initial = geometry
        geometry.rotateLeft()
        XCTAssertEqual(geometry.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(geometry.y, 0.6, accuracy: 0.0001)
        XCTAssertEqual(geometry.width, 0.4, accuracy: 0.0001)
        for _ in 0..<3 { geometry.rotateLeft() }
        XCTAssertEqual(geometry.quarterTurns, 0)
        XCTAssertEqual(geometry.x, initial.x, accuracy: 0.0001)
        XCTAssertEqual(geometry.y, initial.y, accuracy: 0.0001)
        let page = ScanPage(id: UUID(), original: "original.jpg", rendered: "page.jpg", thumbnail: "thumb.jpg", fingerprint: [])
        let data = try JSONEncoder().encode(page)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "geometry"); json.removeValue(forKey: "mode")
        let legacy = try JSONDecoder().decode(ScanPage.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.geometry)
    }
    func testDocumentDetectionIncludesSmallPagesAndWideBoardsWithoutInventingBlankPage() throws {
        let processor = ImageProcessor()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for rect in [CGRect(x: 100, y: 80, width: 360, height: 440),
                     CGRect(x: 300, y: 100, width: 160, height: 400),
                     CGRect(x: 70, y: 180, width: 660, height: 220)] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: format).image { ctx in
                UIColor.darkGray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
                UIColor.white.setFill(); ctx.fill(rect)
            }
            let corners = processor.documentCorners(in: try XCTUnwrap(CIImage(image: image)))
            XCTAssertEqual(corners.count, 4)
            if corners.count == 4 {
                XCTAssertEqual(corners[0].x, rect.minX / 800, accuracy: 0.04)
                XCTAssertEqual(corners[0].y, rect.minY / 600, accuracy: 0.04)
                XCTAssertEqual(corners[2].x, rect.maxX / 800, accuracy: 0.04)
                XCTAssertEqual(corners[2].y, rect.maxY / 600, accuracy: 0.04)
            }
        }
        let blank = CIImage(color: CIColor.gray).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(processor.documentCorners(in: blank).isEmpty)
    }
    func testAutoEnhancementRetainsResolutionAndImprovesFaintTextContrast() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1000), format: format).image { ctx in
            UIColor(white: 0.78, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
            UIColor(white: 0.48, alpha: 1).setFill()
            for row in 0..<20 { ctx.fill(CGRect(x: 60, y: 60 + row * 40, width: 580, height: 5)) }
        }
        let processor = ImageProcessor()
        let result = try processor.render(image, filter: .auto, correct: false)
        XCTAssertEqual(result.cgImage?.width, 800); XCTAssertEqual(result.cgImage?.height, 1000)
        func contrast(_ image: UIImage) throws -> Int {
            var pixels = [UInt8](repeating: 0, count: 800 * 1000)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 800, height: 1000,
                    bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
                context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: 800, height: 1000))
            }
            return Int(pixels.max()!) - Int(pixels.min()!)
        }
        XCTAssertGreaterThan(try contrast(result), try contrast(image))
    }
    @MainActor func testRepeatedEditsWithOldSnapshotRefreshThumbnailAndPersistLatestCrop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanStore(root: root)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
            UIColor.black.setFill(); ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 500))
        }
        store.add(image, mode: .document, filter: .original)
        try await settled(store)
        let snapshot = try XCTUnwrap(store.pages.first)
        _ = store.thumbnail(snapshot)
        let cachedPreview = try XCTUnwrap(store.preview(snapshot))
        XCTAssertTrue(cachedPreview === store.preview(snapshot))
        var crop = PageGeometry(height: 0.5)
        store.update(snapshot, filter: .auto, brightness: 0, contrast: 1, geometry: crop) {}
        try await settled(store)
        let first = try XCTUnwrap(store.pages.first)
        XCTAssertNotEqual(snapshot.thumbnail, first.thumbnail)
        XCTAssertFalse(cachedPreview === store.preview(snapshot))
        XCTAssertTrue(store.preview(snapshot) === store.preview(first))
        XCTAssertEqual(store.image(snapshot)?.size, store.image(first)?.size)
        XCTAssertEqual(store.thumbnail(snapshot)?.size, store.thumbnail(first)?.size)
        crop = PageGeometry(width: 0.5)
        store.update(snapshot, filter: .original, brightness: 0, contrast: 1, geometry: crop) {}
        try await settled(store)
        let latest = try XCTUnwrap(store.pages.first)
        XCTAssertEqual(latest.geometry, crop)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(first.rendered).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(first.thumbnail).path))
        XCTAssertNotNil(store.thumbnail(snapshot))
        XCTAssertEqual(ScanStore(root: root).pages.first, latest)
        let decoded = try XCTUnwrap(ImageProcessor.previewImage(at: store.url(latest.original), maxEdge: 128))
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 128)
    }
    func testOriginalCropMappingPreservesSavedSelectionAndRotation() throws {
        let quad = [CGPoint(x: 0.15, y: 0.2), CGPoint(x: 0.8, y: 0.15), CGPoint(x: 0.85, y: 0.9), CGPoint(x: 0.1, y: 0.85)]
        let correction = quad.map(CropPoint.init)
        let geometry = PageGeometry()
        let mapped = geometry.originalCropPoints(correction: correction, corrected: true)
        for index in 0..<4 {
            XCTAssertEqual(mapped[index].x, quad[index].x, accuracy: 0.00001)
            XCTAssertEqual(mapped[index].y, quad[index].y, accuracy: 0.00001)
        }
        var manual = PageGeometry(); manual.sourceCorners = correction
        XCTAssertEqual(manual.originalCropPoints(correction: nil, corrected: true), quad)
        let decoded = try JSONDecoder().decode(PageGeometry.self, from: JSONEncoder().encode(manual))
        XCTAssertEqual(decoded, manual)
        for _ in 0..<4 { manual.rotateLeft() }
        for index in 0..<4 {
            XCTAssertEqual(manual.sourceCorners![index].x, quad[index].x, accuracy: 0.00001)
            XCTAssertEqual(manual.sourceCorners![index].y, quad[index].y, accuracy: 0.00001)
        }
    }
    func testOriginalPhotoCropDoesNotApplyAutomaticPerspectiveTwice() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 100, y: 150, width: 200, height: 300))
        }
        var crop = PageGeometry()
        crop.sourceCorners = [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.25), CGPoint(x: 0.75, y: 0.75), CGPoint(x: 0.25, y: 0.75)].map(CropPoint.init)
        let correction = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.9)].map(CropPoint.init)
        let processor = ImageProcessor()
        let automatic = try processor.render(image, filter: .original, correct: true, correctionCorners: correction, geometry: crop)
        let manual = try processor.render(image, filter: .original, correct: false, geometry: crop)
        XCTAssertEqual(automatic.size, manual.size)
        XCTAssertEqual(automatic.size.width, 200, accuracy: 2)
        XCTAssertEqual(automatic.size.height, 300, accuracy: 2)
        XCTAssertEqual(automatic.pngData(), manual.pngData())
    }
    func testPerspectiveAxesAreIndependentBoundedAndLegacyCompatible() throws {
        var horizontal = PageGeometry(); horizontal.horizontalTilt = 12
        var vertical = PageGeometry(); vertical.verticalTilt = 12
        XCTAssertEqual(horizontal.tiltVertical, 0)
        XCTAssertEqual(vertical.tiltHorizontal, 0)
        XCTAssertNotEqual(horizontal.projectedCorners, vertical.projectedCorners)
        var both = horizontal; both.verticalTilt = -12
        XCTAssertEqual(both.tiltHorizontal, 12); XCTAssertEqual(both.tiltVertical, -12)
        XCTAssertTrue(both.projectedCorners.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        both.horizontalTilt = .infinity; both.verticalTilt = 400
        XCTAssertEqual(both.tiltHorizontal, 0); XCTAssertEqual(both.tiltVertical, 20)
        let legacy = try JSONDecoder().decode(PageGeometry.self, from: Data("{\"quarterTurns\":0,\"x\":0,\"y\":0,\"width\":1,\"height\":1}".utf8))
        XCTAssertEqual(legacy.tiltHorizontal, 0); XCTAssertEqual(legacy.tiltVertical, 0)
        let restored = try JSONDecoder().decode(PageGeometry.self, from: JSONEncoder().encode(horizontal))
        XCTAssertEqual(restored.horizontalTilt, 12)
    }
    func testColorScanPreservesColorAndPerspectiveOutputDimensions() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600), format: format).image { ctx in
            UIColor(red: 0.7, green: 0.2, blue: 0.15, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        }
        let processor = ImageProcessor()
        var geometry = PageGeometry(); geometry.horizontalTilt = 12; geometry.verticalTilt = -12
        let result = try processor.render(image, filter: .auto, correct: false, geometry: geometry)
        XCTAssertEqual(result.size.width, 400); XCTAssertEqual(result.size.height, 600)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(try XCTUnwrap(result.cgImage), in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(pixel[0], pixel[1]); XCTAssertGreaterThan(pixel[0], pixel[2])
    }
    @MainActor func testEditedGeometryPersistsAndOriginalRemainsIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanStore(root: root)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 200), format: format).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 100))
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 100, width: 120, height: 100))
        }
        let processor = ImageProcessor()
        let upper = try processor.render(image, filter: .original, correct: false, geometry: PageGeometry(height: 0.5))
        XCTAssertEqual(upper.size.width, 120); XCTAssertEqual(upper.size.height, 100)
        var bytes = [UInt8](repeating:0,count:4)
        let context = try XCTUnwrap(CGContext(data:&bytes,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try XCTUnwrap(upper.cgImage),in:CGRect(x:0,y:0,width:1,height:1))
        XCTAssertGreaterThan(bytes[0],bytes[2],"Top-left crop should retain the red upper half")
        store.add(image, mode: .photo, filter: .original)
        try await settled(store)
        let page = try XCTUnwrap(store.pages.first)
        let originalData = try Data(contentsOf: store.url(page.original))
        var edit = PageGeometry(); edit.rotateLeft(); edit.width = 0.5; edit.horizontalTilt = 12; edit.verticalTilt = -8
        var completed = false
        store.update(page, filter: .original, brightness: 0, contrast: 1, geometry: edit) { completed = true }
        try await settled(store)
        XCTAssertTrue(completed)
        XCTAssertEqual(try Data(contentsOf: store.url(page.original)), originalData)
        let restored = ScanStore(root: root)
        let changed = try XCTUnwrap(restored.pages.first)
        XCTAssertEqual(changed.geometry, edit)
        let rendered = try XCTUnwrap(restored.image(changed))
        XCTAssertEqual(rendered.size.width, 100); XCTAssertEqual(rendered.size.height, 120)
        store.export(name: "Edited", paper: .original, quality: .high)
        try await settled(store)
        XCTAssertNotNil(store.exportedURL)
    }
    func testIndependentCornersAndRotationPreserveQuadrilateral() throws {
        var edit = PageGeometry()
        edit.moveCorner(0,to:CGPoint(x:0.15,y:0.1))
        XCTAssertEqual(edit.points[1],CGPoint(x:1,y:0))
        XCTAssertEqual(edit.points[2],CGPoint(x:1,y:1))
        let before = edit.points
        edit.moveCorner(0,to:CGPoint(x:1,y:1))
        XCTAssertEqual(edit.points,before,"Crossed/degenerate corners must be rejected")
        for _ in 0..<4 { edit.rotateLeft() }
        for i in 0..<4 {
            XCTAssertEqual(edit.points[i].x,before[i].x,accuracy:0.00001)
            XCTAssertEqual(edit.points[i].y,before[i].y,accuracy:0.00001)
        }
        let decoded = try JSONDecoder().decode(PageGeometry.self,from:JSONEncoder().encode(edit))
        XCTAssertEqual(decoded,edit)
        let format=UIGraphicsImageRendererFormat(); format.scale=1
        let image=UIGraphicsImageRenderer(size:CGSize(width:300,height:400),format:format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x:0,y:0,width:300,height:400))
        }
        let output = try ImageProcessor().render(image,filter:.original,correct:false,geometry:edit)
        XCTAssertGreaterThan(output.size.width,200)
        XCTAssertGreaterThan(output.size.height,300)
    }
    func testOfficialSilentPhotoRequiresCapabilityAndNeverConsumesVideo() {
        var gate = CaptureRequestGate()
        XCTAssertEqual(gate.begin(silent:true,canSuppressShutter:true,now:0),.silentPhoto)
        XCTAssertFalse(gate.consumeVideoFrame(now:1))
        gate.completePhoto()
        XCTAssertNil(gate.route)
        XCTAssertEqual(gate.begin(silent:true,canSuppressShutter:false,now:2),.videoFrame)
        gate.completePhoto()
        XCTAssertEqual(gate.route,.videoFrame)
    }
    func testNormalizationPreservesNative4032PixelsIncludingImageScale() {
        let format=UIGraphicsImageRendererFormat(); format.scale=2
        let image=UIGraphicsImageRenderer(size:CGSize(width:2016,height:20),format:format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x:0,y:0,width:2016,height:20))
        }
        let original=ImageProcessor().normalize(image)
        XCTAssertEqual(original.cgImage?.width,4032)
        let preview=ImageProcessor().normalize(image,maxEdge:900)
        XCTAssertEqual(preview.cgImage?.width,900)
    }
    @MainActor private func settled(_ store: ScanStore) async throws {
        let end = Date().addingTimeInterval(15)
        while store.busy && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(store.busy, "Worker timed out")
    }
}
