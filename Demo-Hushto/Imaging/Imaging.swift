import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import ImageIO

/// Vision document recognition and Core Image processing run entirely on the device.
final class ImageProcessor {
    static let shared = ImageProcessor()
    private static let renderContext = CIContext(options: [.cacheIntermediates: false])
    let context = ImageProcessor.renderContext
    private let detectorLock = NSLock()
    private lazy var detector: CIDetector? = CIDetector(ofType: CIDetectorTypeRectangle,
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
        Self.preferredRectangle(documentCandidates(in: image))
    }
    private func documentCandidates(in image: CIImage) -> [([CGPoint], CGFloat)] {
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
            if !points.isEmpty { return candidates }
        }
        // A shared processor can be reached by independent storage queues.
        detectorLock.lock()
        defer { detectorLock.unlock() }
        // Contrast-normalized fallback uses the same screen/keyboard selection rule.
        let boosted = small.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.4])
        let candidates = (detector?.features(in: boosted) ?? []).compactMap { feature -> ([CGPoint], CGFloat)? in
            guard let rectangle = feature as? CIRectangleFeature else { return nil }
            return ([rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
                .map { CGPoint(x: $0.x / small.extent.width, y: 1 - $0.y / small.extent.height) }, 1)
        }
        return candidates
    }

    func liveDocumentCorners(in image: CIImage, allowRecovery: Bool = true) -> [CGPoint] {
        scanDocumentCorners(in: image, allowRecovery: allowRecovery)
    }
    /// Shared by the live scan finder and initial scan ingestion, so recovered
    /// document boundaries are also used by the saved scan's perspective correction.
    func scanDocumentCorners(in image: CIImage, allowRecovery: Bool = true) -> [CGPoint] {
        let primaryCandidates = documentCandidates(in: image)
        let rectangles = Self.preferredScanContainer(primaryCandidates, imageAspect: image.extent.width / max(1, image.extent.height))
        if !rectangles.isEmpty {
            return pageInsideScreen(in: image, candidates: primaryCandidates, outer: rectangles)
        }
        guard allowRecovery else { return [] }
        let zero = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        guard zero.extent.width > 0, zero.extent.height > 0 else { return [] }
        let scale = min(1, 1024 / max(zero.extent.width, zero.extent.height))
        let normalized = zero.transformed(by: .init(scaleX: scale, y: scale))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.25])
        let rectanglesRequest = VNDetectRectanglesRequest()
        rectanglesRequest.maximumObservations = 16
        rectanglesRequest.minimumConfidence = 0.55
        rectanglesRequest.minimumAspectRatio = 0.15
        rectanglesRequest.maximumAspectRatio = 1
        rectanglesRequest.minimumSize = 0.035
        rectanglesRequest.quadratureTolerance = 45
        let documentRequest = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: normalized, options: [:])
        // Independent requests: one unsupported/failed detector must not discard
        // useful results from the other. Both operate on a bounded recovery frame.
        try? handler.perform([rectanglesRequest])
        try? handler.perform([documentRequest])
        let rectangleResults: [VNRectangleObservation] = rectanglesRequest.results ?? []
        let documentResults: [VNRectangleObservation] = (documentRequest.results ?? []).filter { $0.confidence >= 0.6 }
        var candidates: [([CGPoint], CGFloat)] = []
        for observation in rectangleResults + documentResults {
            let corners: [CGPoint] = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
            let points = corners.map { CGPoint(x: $0.x, y: 1 - $0.y) }
            let canvas = points.allSatisfy { point in
                (point.x < 0.01 || point.x > 0.99) && (point.y < 0.01 || point.y > 0.99)
            }
            if !canvas { candidates.append((points, CGFloat(observation.confidence))) }
        }
        let recovered = Self.preferredScanContainer(candidates, imageAspect: image.extent.width / max(1, image.extent.height))
        return recovered.isEmpty ? [] : pageInsideScreen(in: image, candidates: candidates, outer: recovered)
    }

    private func pageInsideScreen(in image: CIImage, candidates: [([CGPoint], CGFloat)], outer: [CGPoint]) -> [CGPoint] {
        let outerBounds = Self.rectangleBounds(outer)
        // Restrict this preference to wide containing screens/spreads. Ordinary
        // portrait paper keeps the existing detector and correction behavior.
        let imageAspect = image.extent.width / max(1, image.extent.height)
        guard outerBounds.width * imageAspect > outerBounds.height * 1.05 else { return outer }
        var inner = candidates.map(\.0).filter { Self.isInnerPage($0, outer: outer) }
        let zero = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        if !inner.contains(where: { Self.rectangleBounds($0).width * imageAspect < Self.rectangleBounds($0).height }) {
            // A large viewer rectangle can suppress the page observation. Search
            // inside its bezel once, rather than accept the containing window.
            let request = VNDetectRectanglesRequest()
            request.maximumObservations = 12
            request.minimumConfidence = 0.35
            request.minimumAspectRatio = 0.2
            request.maximumAspectRatio = 1
            request.minimumSize = 0.06
            request.quadratureTolerance = 35
            let roi = outerBounds.insetBy(dx: outerBounds.width*0.06, dy: outerBounds.height*0.06)
            request.regionOfInterest = CGRect(x: roi.minX, y: 1-roi.maxY, width: roi.width, height: roi.height)
            let factor = min(1, 1024 / max(zero.extent.width, zero.extent.height))
            let small = zero.transformed(by: .init(scaleX: factor, y: factor))
            try? VNImageRequestHandler(ciImage: small, options: [:]).perform([request])
            let nested = (request.results ?? []).map { observation in
                [observation.topLeft,observation.topRight,observation.bottomRight,observation.bottomLeft]
                    .map { CGPoint(x:$0.x,y:1-$0.y) }
            }
            inner += nested.filter { Self.isInnerPage($0,outer:outer) }
        }
        let scale = min(1, 256 / max(zero.extent.width, zero.extent.height))
        let sample = zero.transformed(by: .init(scaleX: scale, y: scale))
        let width = max(1, Int(sample.extent.width)), height = max(1, Int(sample.extent.height))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(sample, toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        func luma(_ point: CGPoint) -> CGFloat {
            let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
            let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))
            let i = (y * width + x) * 4
            return (CGFloat(pixels[i]) * 0.2126 + CGFloat(pixels[i+1]) * 0.7152 + CGFloat(pixels[i+2]) * 0.0722) / 255
        }
        // A low-contrast page on a white viewer may have no rectangle observation.
        // Generate light-paper regions, then apply the same boundary/text checks.
        let center = CGPoint(x: outer.map(\.x).reduce(0,+)/4, y: outer.map(\.y).reduce(0,+)/4)
        var backgroundSamples: [CGFloat] = []
        for index in 0..<4 {
            let a=outer[index], b=outer[(index+1)%4]
            for t: CGFloat in [0.2,0.5,0.8] {
                let edge=CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)
                backgroundSamples.append(luma(CGPoint(x:edge.x*0.9+center.x*0.1,y:edge.y*0.9+center.y*0.1)))
            }
        }
        let background = backgroundSamples.sorted()[backgroundSamples.count/2]
        let outerPath=CGMutablePath();outerPath.addLines(between:outer);outerPath.closeSubpath()
        var mask=[Bool](repeating:false,count:width*height)
        for y in 0..<height {
            for x in 0..<width {
                let point=CGPoint(x:(CGFloat(x)+0.5)/CGFloat(width),y:(CGFloat(y)+0.5)/CGFloat(height))
                let value=luma(point)
                mask[y*width+x] = value>=0.45 && abs(value-background)>=0.045 && outerPath.contains(point)
            }
        }
        var seen=[Bool](repeating:false,count:mask.count)
        for seed in mask.indices where mask[seed] && !seen[seed] {
            var component=[seed], head=0
            seen[seed]=true
            while head<component.count {
                let index=component[head];head += 1
                let x=index%width,y=index/width
                for next in [x>0 ? index-1:-1,x+1<width ? index+1:-1,y>0 ? index-width:-1,y+1<height ? index+width:-1] {
                    if next>=0 && mask[next] && !seen[next] {seen[next]=true;component.append(next)}
                }
            }
            guard component.count>=width*height/65 else {continue}
            let points=component.map { index in
                CGPoint(x:(CGFloat(index%width)+0.5)/CGFloat(width),y:(CGFloat(index/width)+0.5)/CGFloat(height))
            }
            let topLeft=points.min { $0.x+$0.y < $1.x+$1.y }!
            let topRight=points.max { $0.x-$0.y < $1.x-$1.y }!
            let bottomRight=points.max { $0.x+$0.y < $1.x+$1.y }!
            let bottomLeft=points.min { $0.x-$0.y < $1.x-$1.y }!
            let page=[topLeft,topRight,bottomRight,bottomLeft]
            if Self.isInnerPage(page,outer:outer) {inner.append(page)}
        }
        guard !inner.isEmpty else {return outer}
        let paper = inner.filter { quad in
            let center = CGPoint(x: quad.map(\.x).reduce(0,+)/4, y: quad.map(\.y).reduce(0,+)/4)
            var inside: [CGFloat] = [], outside: [CGFloat] = []
            for index in 0..<4 {
                let a = quad[index], b = quad[(index+1)%4]
                for t: CGFloat in [0.2,0.5,0.8] {
                    let edge = CGPoint(x: a.x+(b.x-a.x)*t, y: a.y+(b.y-a.y)*t)
                    inside.append(luma(CGPoint(x: edge.x*0.94+center.x*0.06, y: edge.y*0.94+center.y*0.06)))
                    outside.append(luma(CGPoint(x: edge.x*1.04-center.x*0.04, y: edge.y*1.04-center.y*0.04)))
                }
            }
            let innerMedian = inside.sorted()[inside.count/2]
            let outerMedian = outside.sorted()[outside.count/2]
            return innerMedian >= 0.45 && abs(innerMedian-outerMedian) >= 0.045
        }
        guard !paper.isEmpty else { return outer }
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        text.automaticallyDetectsLanguage = true
        text.minimumTextHeight = 0.004
        // Only line geometry is used; no recognized text is stored or exported.
        let textEdge: CGFloat = RuntimeBudget.current.constrained ? 768 : 1024
        let factor = min(1, textEdge / max(zero.extent.width, zero.extent.height))
        let small = zero.transformed(by: .init(scaleX: factor, y: factor))
        guard (try? VNImageRequestHandler(ciImage: small, options: [:]).perform([text])) != nil else { return outer }
        let lines = (text.results ?? []).map { observation -> CGRect in
            let b = observation.boundingBox
            return CGRect(x: b.minX, y: 1-b.maxY, width: b.width, height: b.height)
        }.filter { $0.width >= 0.025 && $0.height >= 0.004 && $0.height <= 0.12 && $0.width / $0.height > 1.6 }
        return Self.preferredBookPage(paper, textLines: lines, outer: outer, imageAspect: imageAspect)
    }
    private static func rectangleBounds(_ points: [CGPoint]) -> CGRect {
        CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
               width: points.map(\.x).max()! - points.map(\.x).min()!,
               height: points.map(\.y).max()! - points.map(\.y).min()!)
    }
    private static func contains(_ point: CGPoint, in quad: [CGPoint]) -> Bool {
        let path = CGMutablePath(); path.addLines(between: quad); path.closeSubpath()
        return path.contains(point)
    }
    private static func isInnerPage(_ page: [CGPoint], outer: [CGPoint]) -> Bool {
        guard PageGeometry.valid(page), PageGeometry.valid(outer) else { return false }
        let b = rectangleBounds(page), parent = rectangleBounds(outer)
        let fraction = b.width*b.height / (parent.width*parent.height)
        return fraction >= 0.08 && fraction <= 0.88 && b.width*b.height >= 0.035
            && b.width/b.height >= 0.3 && b.width/b.height <= 2.5
            && page.allSatisfy { contains($0, in: outer) }
    }
    /// Candidates here already have a visible paper/background boundary. Require
    /// most body lines to stay inside, so a diagram/table cannot replace a page.
    static func preferredBookPage(_ candidates: [[CGPoint]], textLines: [CGRect], outer: [CGPoint], imageAspect: CGFloat = 1) -> [CGPoint] {
        guard PageGeometry.valid(outer) else { return outer }
        let bounds = rectangleBounds(outer)
        let content = textLines.filter { line in
            let center = CGPoint(x: line.midX,y: line.midY)
            return contains(center,in: outer) && center.y >= bounds.minY+bounds.height*0.05
                && center.y <= bounds.maxY-bounds.height*0.05
        }
        guard content.count >= 4 else { return outer }
        func coverage(_ quad: [CGPoint]) -> CGFloat {
            CGFloat(content.filter { contains(CGPoint(x:$0.midX,y:$0.midY),in:quad) }.count) / CGFloat(content.count)
        }
        let pages = candidates.filter { isInnerPage($0,outer:outer) }
        func pageShaped(_ page: [CGPoint]) -> Bool {
            let b = rectangleBounds(page)
            if b.width*imageAspect / b.height <= 1.1 { return true }
            // A wide paper candidate must contain two text columns, rather than
            // a single portrait page floating inside a wide white viewer.
            let centers = content.filter { contains(CGPoint(x:$0.midX,y:$0.midY),in:page) }.map(\.midX).sorted()
            guard centers.count >= 6 else { return false }
            for split in 3...(centers.count-3) {
                if centers[split]-centers[split-1] >= b.width*0.15 { return true }
            }
            return false
        }
        var choices = pages.filter { coverage($0) >= 0.85 && pageShaped($0) }
        for left in pages {
            for right in pages {
                let a = rectangleBounds(left), b = rectangleBounds(right)
                guard a.maxX <= b.minX+0.005, b.minX-a.maxX <= bounds.width*0.12,
                      a.intersection(CGRect(x:a.minX,y:b.minY,width:a.width,height:b.height)).height >= min(a.height,b.height)*0.7,
                      (0.5...2).contains(a.height/b.height) else { continue }
                let spread = [left[0],right[1],right[2],left[3]]
                if PageGeometry.valid(spread), coverage(spread) >= 0.85 { choices.append(spread) }
            }
        }
        return choices.min { a,b in
            let capturedA = coverage(a), capturedB = coverage(b)
            if capturedA != capturedB { return capturedA > capturedB }
            let x=rectangleBounds(a),y=rectangleBounds(b)
            return x.width*x.height < y.width*y.height
        } ?? outer
    }

    /// A keyboard below a portrait page should not win merely because the
    /// monitor bezel was not detected. Standalone wide documents remain valid.
    private static func preferredScanContainer(_ candidates: [([CGPoint], CGFloat)], imageAspect: CGFloat) -> [CGPoint] {
        let valid = candidates.filter { PageGeometry.valid($0.0) }
        let ranked = valid.map { candidate -> ([CGPoint], CGFloat) in
            let b = rectangleBounds(candidate.0)
            guard b.width*imageAspect/b.height >= 2.2 else { return candidate }
            let pageAbove = valid.contains { other in
                let page = rectangleBounds(other.0)
                let aspect = page.width*imageAspect/page.height
                return page.maxY <= b.minY+b.height*0.35 && page.height > b.height*1.15
                    && (0.2...1.5).contains(page.width/b.width)
                    && abs(page.midX-b.midX) < b.width*0.5 && (0.35...2).contains(aspect)
            }
            return (candidate.0, candidate.1*(pageAbove ? 0.08:1))
        }
        return preferredRectangle(ranked)
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
        let prepared = try prepare(image, filter: filter, correct: correct, correctionCorners: correctionCorners, geometry: geometry)
        return try finish(prepared, filter: filter, brightness: brightness, contrast: contrast)
    }
    /// Geometry and automatic enhancement are independent of brightness/contrast.
    func prepare(_ image: UIImage, filter: Enhancement, correct: Bool,
                 correctionCorners: [CropPoint]? = nil, geometry: PageGeometry = PageGeometry()) throws -> CIImage {
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
        return input
    }
    func finish(_ prepared: CIImage, filter: Enhancement, brightness: Double, contrast: Double) throws -> UIImage {
        var input = prepared
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
    private struct PreparedKey: Equatable {
        let filter: Enhancement
        let corrected: Bool
        let corners: [CropPoint]?
        let geometry: PageGeometry
    }
    private var preparedKey: PreparedKey?
    private var preparedImage: CIImage?
    func releaseCaches() {
        cachedURL = nil; cachedImage = nil; cachedCorrection = nil; cachedCorrectionReady = false
        preparedKey = nil; preparedImage = nil
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
                preparedKey = nil; preparedImage = nil
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
            let key = PreparedKey(filter: filter, corrected: corrected, corners: fixedCorners, geometry: geometry)
            if preparedKey != key || preparedImage == nil {
                let prepared = try processor.prepare(image, filter: filter, correct: corrected,
                    correctionCorners: fixedCorners, geometry: geometry)
                try Task.checkCancellation()
                // Cache bounded preview pixels, not a lazy graph that reruns Vision,
                // perspective correction and noise reduction on every slider tick.
                // Keep extended-range precision until the final adjustment, so
                // lowering brightness does not turn previously clipped whites gray.
                guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                      let cg = processor.context.createCGImage(prepared, from: prepared.extent, format: .RGBAh, colorSpace: space)
                else { throw HushtoError.image }
                preparedImage = CIImage(cgImage: cg)
                preparedKey = key
            }
            try Task.checkCancellation()
            guard let preparedImage else { throw HushtoError.image }
            let rendered = try processor.finish(preparedImage, filter: filter, brightness: brightness, contrast: contrast)
            try Task.checkCancellation()
            return (rendered, rendered)
        }
    }
}
