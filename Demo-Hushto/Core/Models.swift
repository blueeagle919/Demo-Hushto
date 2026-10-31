import Foundation
import SwiftUI

enum Enhancement: String, CaseIterable, Codable, Identifiable {
    case original = "원본", auto = "자동", clear = "선명", monochrome = "흑백"
    var id: String { rawValue }
}
enum PaperSize: String, CaseIterable, Identifiable {
    case a4 = "A4", original = "원본", letter = "레터"
    var id: String { rawValue }
    var size: CGSize? {
        switch self { case .original: nil; case .a4: CGSize(width: 595.28, height: 841.89); case .letter: CGSize(width: 612, height: 792) }
    }
}
enum ExportQuality: String, CaseIterable, Identifiable {
    case small = "작게", standard = "표준", high = "고화질"
    var id: String { rawValue }
    var edge: CGFloat { switch self { case .small: 1000; case .standard: 1600; case .high: 4032 } }
    var compression: CGFloat { switch self { case .small: 0.5; case .standard: 0.75; case .high: 0.92 } }
}
struct ScanPage: Identifiable, Codable, Equatable {
    var id: UUID
    var original: String
    var rendered: String
    var thumbnail: String
    var fingerprint: [Double]
    var filter: Enhancement = .auto
    var brightness: Double = 0
    var contrast: Double = 1
    var corrected: Bool = false
    var correctionCorners: [CropPoint]? = nil
    var geometry: PageGeometry? = nil
    var mode: CaptureMode? = nil
}
struct ScanSession: Codable {
    var title = "새 스캔 문서"
    var pages: [ScanPage] = []
}
struct AppNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
enum HushtoError: LocalizedError {
    case image, noPages, filename, camera, storage
    var errorDescription: String? {
        switch self {
        case .image: "이미지를 처리하지 못했어요. 다른 사진으로 다시 시도해주세요."
        case .noPages: "먼저 페이지를 촬영하거나 가져와주세요."
        case .filename: "파일 이름에 /, :, \\를 사용할 수 없어요. 이름을 확인해주세요."
        case .camera: "카메라를 사용할 수 없어요. 다른 앱에서 카메라를 사용 중인지 확인해주세요."
        case .storage: "저장 공간이 부족해요. 공간을 확보한 뒤 다시 시도해주세요."
        }
    }
}
enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "시스템 설정", light = "라이트 모드", dark = "다크 모드"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}
enum Theme {
    static let background = Color("HushtoBackground")
    static let cameraBackground = Color("CameraBackground")
    static let surface = Color("HushtoSurface")
    static let label = Color("HushtoLabel")
    static let secondary = Color("HushtoSecondary")
    static let onAccent = Color("HushtoOnAccent")
}

struct GalleryCapture: Identifiable {
    let id: UUID
    var image: UIImage?
    var imageURL: URL?
    var videoURL: URL?
    init(id: UUID = UUID(), image: UIImage? = nil, imageURL: URL? = nil, videoURL: URL? = nil) {
        self.id = id; self.image = image; self.imageURL = imageURL; self.videoURL = videoURL
    }
}

/// Crop coordinates are normalized in the rotated, perspective-corrected image.
struct PageGeometry: Codable, Equatable {
    var quarterTurns = 0
    var horizontalTilt: Double? = nil
    var verticalTilt: Double? = nil
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1
    var corners: [CropPoint]? = nil
    var sourceCorners: [CropPoint]? = nil
    var points: [CGPoint] { corners?.map(\.point) ?? [CGPoint(x:x,y:y), CGPoint(x:x+width,y:y), CGPoint(x:x+width,y:y+height), CGPoint(x:x,y:y+height)] }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    mutating func rotateLeft() {
        let rotated = points.map { CGPoint(x:$0.y,y:1-$0.x) }
        if corners != nil { corners = [rotated[1],rotated[2],rotated[3],rotated[0]].map(CropPoint.init) }
        if let sourceCorners {
            let rotated = sourceCorners.map { CGPoint(x: $0.y, y: 1 - $0.x) }
            self.sourceCorners = [rotated[1], rotated[2], rotated[3], rotated[0]].map(CropPoint.init)
        }
        let oldX = x, oldWidth = width
        x = y; y = 1 - oldX - oldWidth
        width = height; height = oldWidth
        quarterTurns = (quarterTurns + 1) % 4
    }
    mutating func resetCrop() { x = 0; y = 0; width = 1; height = 1; corners = nil; sourceCorners = nil }
    mutating func setRect(_ rect: CGRect) {
        x = Double(rect.minX); y = Double(rect.minY)
        width = Double(rect.width); height = Double(rect.height)
    }
}

struct CropPoint: Codable, Equatable {
    var x: Double
    var y: Double
    init(_ point: CGPoint) { x = point.x; y = point.y }
    var point: CGPoint { CGPoint(x:x,y:y) }
}
extension PageGeometry {
    mutating func moveCorner(_ index: Int, to point: CGPoint) {
        var candidate = points
        candidate[index] = CGPoint(x:min(1,max(0,point.x)),y:min(1,max(0,point.y)))
        guard Self.valid(candidate) else { return }
        corners = candidate.map(CropPoint.init)
    }
    static func valid(_ p: [CGPoint]) -> Bool {
        guard p.count == 4, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        for i in 0..<4 {
            let a=p[i], b=p[(i+1)%4], c=p[(i+2)%4]
            guard hypot(b.x-a.x,b.y-a.y) >= 0.05,
                  (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x) > 0.002 else { return false }
        }
        return true
    }
}

// Normalized projected corners for the two independent Figma perspective axes.
extension PageGeometry {
    var tiltHorizontal: Double { Self.safeTilt(horizontalTilt) }
    var tiltVertical: Double { Self.safeTilt(verticalTilt) }
    private static func safeTilt(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(20, max(-20, value))
    }
    var projectedCorners: [CGPoint] {
        let h = tiltHorizontal * .pi / 180, v = tiltVertical * .pi / 180
        return [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map { point in
            let x = Double(point.x) - 0.5, y = 0.5 - Double(point.y)
            let rx = x * cos(h), rz = -x * sin(h)
            let ry = y * cos(v) - rz * sin(v), z = y * sin(v) + rz * cos(v)
            let perspective = 1 - z / 1.7
            return CGPoint(x: 0.5 + rx / perspective, y: 0.5 - ry / perspective)
        }
    }
}

extension PageGeometry {
    /// Map the saved crop back to the original photo, so crop editing retains its surroundings.
    func originalCropPoints(correction: [CropPoint]?, corrected: Bool) -> [CGPoint] {
        if let sourceCorners { return sourceCorners.map(\.point) }
        var quad = corrected ? (correction?.map(\.point) ?? []) : []
        if !Self.valid(quad) { quad = PageGeometry().points }
        for _ in 0..<((quarterTurns % 4 + 4) % 4) {
            let rotated = quad.map { CGPoint(x: $0.y, y: 1 - $0.x) }
            quad = [rotated[1], rotated[2], rotated[3], rotated[0]]
        }
        let p0 = quad[0], p1 = quad[1], p2 = quad[2], p3 = quad[3]
        let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x
        let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y
        let sx = p0.x - p1.x + p2.x - p3.x, sy = p0.y - p1.y + p2.y - p3.y
        let determinant = dx1 * dy2 - dx2 * dy1
        let g = abs(determinant) > 0.000001 ? (sx * dy2 - dx2 * sy) / determinant : 0
        let h = abs(determinant) > 0.000001 ? (dx1 * sy - sx * dy1) / determinant : 0
        let mapped = points.map { point -> CGPoint in
            let denominator = g * point.x + h * point.y + 1
            let x = ((p1.x - p0.x + g * p1.x) * point.x + (p3.x - p0.x + h * p3.x) * point.y + p0.x) / denominator
            let y = ((p1.y - p0.y + g * p1.y) * point.x + (p3.y - p0.y + h * p3.y) * point.y + p0.y) / denominator
            return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
        }
        return Self.valid(mapped) ? mapped : quad
    }
}
