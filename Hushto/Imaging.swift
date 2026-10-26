import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import ImageIO

/// Core Image rectangle detection and filters run entirely on the device. No ML model or server.
final class ImageProcessor {
    static let shared = ImageProcessor()
    let context = CIContext(options: [.cacheIntermediates: false])
    private let detector: CIDetector? = CIDetector(ofType: CIDetectorTypeRectangle,
        context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh, CIDetectorMaxFeatureCount: 24])

    func normalize(_ image: UIImage, maxEdge: CGFloat = .greatestFiniteMagnitude) -> UIImage {
        if image.imageOrientation == .up, image.scale == 1,
           max(image.size.width, image.size.height) <= maxEdge { return image }
        let scale = min(1, maxEdge / max(image.size.width * image.scale, image.size.height * image.scale))
        let size = CGSize(width: max(1, image.size.width * image.scale * scale), height: max(1, image.size.height * image.scale * scale))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
    /// Decode only the pixels needed by previews instead of expanding a full 12MP JPEG.
    static func previewImage(at url: URL, maxEdge: Int = RuntimeBudget.current.previewEdge) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxEdge,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    /// Analyze a bounded image; Vision handles perspective and wider board/screen ratios.
    func documentCorners(in image: CIImage) -> [CGPoint] {
        let zero = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        let factor = min(1, 768 / max(zero.extent.width, zero.extent.height))
        let small = zero.transformed(by: .init(scaleX: factor, y: factor))
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 24
        request.minimumConfidence = 0.45
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1
        request.minimumSize = 0.06
        request.quadratureTolerance = 35
        if (try? VNImageRequestHandler(ciImage: small, options: [:]).perform([request])) != nil {
            let candidates = (request.results ?? []).map { observation in
                ([observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
                    .map { CGPoint(x: $0.x, y: 1 - $0.y) }, CGFloat(observation.confidence))
            }
            let points = Self.preferredRectangle(candidates)
            if !points.isEmpty { return points }
        }
        // Contrast-normalized fallback uses the same screen/keyboard selection rule.
        let boosted = small.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.4])
        let candidates = (detector?.features(in: boosted) ?? []).compactMap { feature -> ([CGPoint], CGFloat)? in
            guard let rectangle = feature as? CIRectangleFeature else { return nil }
            return ([rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
                .map { CGPoint(x: $0.x / small.extent.width, y: 1 - $0.y / small.extent.height) }, 1)
        }
        return Self.preferredRectangle(candidates)
    }

    /// A flat lower rectangle aligned with a taller upper rectangle is usually a laptop base.
    /// Apply this only when both candidates exist, retaining standalone wide boards/screens.
    static func preferredRectangle(_ candidates: [([CGPoint], CGFloat)]) -> [CGPoint] {
        func bounds(_ p: [CGPoint]) -> CGRect {
            CGRect(x: p.map(\.x).min()!, y: p.map(\.y).min()!,
                   width: p.map(\.x).max()! - p.map(\.x).min()!,
                   height: p.map(\.y).max()! - p.map(\.y).min()!)
        }
        let valid = candidates.filter { PageGeometry.valid($0.0) && bounds($0.0).width * bounds($0.0).height >= 0.02 }
        func score(_ candidate: ([CGPoint], CGFloat)) -> CGFloat {
            let b = bounds(candidate.0)
            var score = b.width * b.height * candidate.1
            if b.width / b.height > 1.6 {
                let hasScreenAbove = valid.contains { other in
                    let upper = bounds(other.0)
                    return upper.midY < b.midY - b.height * 0.6
                        && upper.maxY <= b.minY + b.height * 0.35
                        && abs(upper.midX - b.midX) < b.width * 0.3
                        && (0.55...1.5).contains(upper.width / b.width)
                        && upper.height > b.height * 1.15
                }
                if hasScreenAbove { score *= 0.15 }
            }
            return score
        }
        return valid.max { score($0) < score($1) }?.0 ?? []
    }
    func render(_ image: UIImage, filter: Enhancement, brightness: Double = 0,
                contrast: Double = 1, correct: Bool, correctionCorners: [CropPoint]? = nil, geometry: PageGeometry = PageGeometry()) throws -> UIImage {
        guard var input = CIImage(image: image) else { throw HushtoError.image }
        input = input.transformed(by: .init(translationX: -input.extent.minX, y: -input.extent.minY))
        if correct && geometry.sourceCorners == nil {
            let points = correctionCorners?.map(\.point) ?? documentCorners(in: input)
            if PageGeometry.valid(points) {
                let size = input.extent.size
                func vector(_ index: Int) -> CIVector { CIVector(x: points[index].x * size.width, y: (1 - points[index].y) * size.height) }
                input = input.applyingFilter("CIPerspectiveCorrection", parameters: [
                    "inputTopLeft": vector(0), "inputTopRight": vector(1),
                    "inputBottomRight": vector(2), "inputBottomLeft": vector(3)])
            }
        }
        // Work in a zero-origin extent before rotating and cropping.
        input = input.transformed(by: .init(translationX: -input.extent.minX, y: -input.extent.minY))
        for _ in 0..<((geometry.quarterTurns % 4 + 4) % 4) {
            input = input.oriented(.left)
            input = input.transformed(by: .init(translationX: -input.extent.minX, y: -input.extent.minY))
        }
        let extent = input.extent
        if geometry.corners != nil || geometry.sourceCorners != nil {
            let points = geometry.sourceCorners?.map(\.point) ?? geometry.points
            guard PageGeometry.valid(points) else { throw HushtoError.image }
            func vector(_ index: Int) -> CIVector {
                CIVector(x:points[index].x * extent.width,y:(1-points[index].y) * extent.height)
            }
            input = input.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft":vector(0),"inputTopRight":vector(1),
                "inputBottomRight":vector(2),"inputBottomLeft":vector(3)])
        } else {
            let crop = geometry.rect.intersection(CGRect(x:0,y:0,width:1,height:1))
            guard !crop.isNull, crop.width >= 0.02, crop.height >= 0.02 else { throw HushtoError.image }
            input = input.cropped(to:CGRect(x:crop.minX * extent.width,y:(1-crop.maxY) * extent.height,
                                           width:crop.width * extent.width,height:crop.height * extent.height))
        }
        if geometry.tiltHorizontal != 0 || geometry.tiltVertical != 0 {
            let bounds = input.extent
            let points = geometry.projectedCorners
            func vector(_ index: Int) -> CIVector {
                CIVector(x: bounds.minX + points[index].x * bounds.width,
                         y: bounds.minY + (1 - points[index].y) * bounds.height)
            }
            let warped = input.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": vector(0), "inputTopRight": vector(1),
                "inputBottomRight": vector(2), "inputBottomLeft": vector(3)])
            input = warped.composited(over: CIImage(color: .white).cropped(to: bounds)).cropped(to: bounds)
        }
        if filter == .auto {
            // Gentle color scan: preserve ink/color, avoid the previous double sharpening.
            for adjustment in input.autoAdjustmentFilters(options: [.enhance: true, .redEye: false]) {
                adjustment.setValue(input, forKey: kCIInputImageKey)
                if let output = adjustment.outputImage {
                    input = output.cropped(to: input.extent).applyingFilter("CIDissolveTransition", parameters: [
                        kCIInputTargetImageKey: input, kCIInputTimeKey: 0.55]).cropped(to: input.extent)
                }
            }
            input = input.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.008, "inputSharpness": 0.2])
        } else if filter != .original {
            input = input.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02, "inputSharpness": 0.4])
        }
        let saturation = filter == .monochrome ? 0.0 : 1.0
        let baseContrast = filter == .clear ? 1.3 : (filter == .monochrome ? 1.12 : (filter == .auto ? 1.025 : 1))
        input = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation,
            kCIInputBrightnessKey: brightness, kCIInputContrastKey: baseContrast * contrast])
        guard !input.extent.isEmpty, let cg = context.createCGImage(input, from: input.extent) else { throw HushtoError.image }
        return UIImage(cgImage: cg)
    }
    /// Spatial grayscale fingerprint. Comparing pixel layout avoids histogram false positives on white pages.
    func fingerprint(_ image: UIImage) -> [Double] {
        guard let cg = normalize(image, maxEdge: 64).cgImage else { return [] }
        var pixels = [UInt8](repeating: 0, count: 32 * 32)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                                      bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        return rendered ? pixels.map { Double($0) / 255 } : []
    }
}

/// Serial preview work bounds peak memory when sliders are moved rapidly.
actor EnhancementPreviewRenderer {
    static let shared = EnhancementPreviewRenderer()
    private let processor = ImageProcessor()
    private var cachedURL: URL?
    private var cachedImage: UIImage?
    private var cachedCorrection: [CropPoint]?
    private var cachedCorrectionReady = false
    func releaseCaches() {
        cachedURL = nil; cachedImage = nil; cachedCorrection = nil; cachedCorrectionReady = false
        processor.context.clearCaches()
    }
    func render(url: URL, filter: Enhancement, brightness: Double, contrast: Double,
                corrected: Bool, correctionCorners: [CropPoint]?, geometry: PageGeometry) throws -> (UIImage, UIImage) {
        try Task.checkCancellation()
        return try autoreleasepool {
            if cachedURL != url || cachedImage == nil {
                guard let image = ImageProcessor.previewImage(at: url) else { throw HushtoError.image }
                cachedImage = image; cachedURL = url
                cachedCorrection = nil; cachedCorrectionReady = false
            }
            guard let image = cachedImage else { throw HushtoError.image }
            var fixedCorners = correctionCorners
            if corrected && fixedCorners == nil {
                if !cachedCorrectionReady {
                    cachedCorrection = CIImage(image: image).map { processor.documentCorners(in: $0).map(CropPoint.init) }
                    cachedCorrectionReady = true
                }
                fixedCorners = cachedCorrection
            }
            try Task.checkCancellation()
            // Crop now has its own original-photo loader; sliders need only the displayed render.
            let rendered = try processor.render(image, filter: filter, brightness: brightness, contrast: contrast,
                correct: corrected, correctionCorners: fixedCorners, geometry: geometry)
            return (rendered, rendered)
        }
    }
}
