import Foundation
import CoreMedia

enum ScanRules {
    static func validFilename(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value != "." && value != ".." && value.count <= 100 &&
            value.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)) == nil
    }
    static func isDuplicate(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(lhs.count) < 0.035
    }
}

/// Quiet requests use an explicitly supported silent photo or a video frame, never an audible fallback.
struct CaptureRequestGate {
    enum Route: String { case videoFrame, systemPhoto, silentPhoto }
    private(set) var route: Route?
    private(set) var token: UUID?
    private var deadline: TimeInterval = 0
    mutating func begin(silent: Bool, canSuppressShutter: Bool = false, now: TimeInterval, timeout: TimeInterval = 3) -> Route? {
        guard route == nil else { return nil }
        route = silent ? (canSuppressShutter ? .silentPhoto : .videoFrame) : .systemPhoto
        token = UUID(); deadline = now + timeout
        return route
    }
    mutating func consumeVideoFrame(now: TimeInterval) -> Bool {
        guard route == .videoFrame, now < deadline else { return false }
        cancel(); return true
    }
    mutating func completePhoto() { if route == .systemPhoto || route == .silentPhoto { cancel() } }
    mutating func expire(token: UUID, now: TimeInterval) -> Bool {
        guard self.token == token, route != nil, now >= deadline else { return false }
        cancel(); return true
    }
    mutating func cancel() { route = nil; token = nil }
}

/// Rank native capture formats by actual delivered pixels, then sensor detail and still quality.
/// A 4:3 4032×3024 frame beats a cropped 3840×2160 frame; no upscaling is involved.
struct NativeCaptureQuality: Comparable {
    let width: Int32
    let height: Int32
    let binned: Bool
    let photoPixels: Int64
    var pixels: Int64 { Int64(width) * Int64(height) }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.pixels != rhs.pixels { return lhs.pixels < rhs.pixels }
        if lhs.binned != rhs.binned { return lhs.binned }
        return lhs.photoPixels < rhs.photoPixels
    }
    /// Rotation swaps dimensions, so compare the long and short edges independently.
    func accepts(width: Int, height: Int) -> Bool {
        max(width, height) >= Int(max(self.width, self.height)) &&
        min(width, height) >= Int(min(self.width, self.height))
    }
}

/// Preserve rational CMTime bounds: rounded nanoseconds can exceed a 30fps limit.
enum CaptureFrameTiming {
    static func duration(minimum: CMTime, maximum: CMTime) -> CMTime {
        let desired = CMTime(value: 1, timescale: 30)
        if CMTimeCompare(desired, minimum) < 0 { return minimum }
        if CMTimeCompare(desired, maximum) > 0 { return maximum }
        return desired
    }
}

/// Track all four normalized corners, allowing normal hand jitter and brief missed detections.
struct AutomaticScanStability {
    private var anchor: [CGPoint] = []
    private var stableSince: TimeInterval?
    private var lastSeen: TimeInterval?
    private var lastCapture: TimeInterval?
    private(set) var progress = 0.0
    mutating func reset() { self = Self() }
    mutating func observe(_ points: [CGPoint], now: TimeInterval, enabled: Bool) -> Bool {
        guard enabled else { reset(); return false }
        guard points.count == 4 else {
            if let lastSeen, now - lastSeen > 0.5 { anchor = []; stableSince = nil; progress = 0 }
            return false
        }
        if let lastSeen, now - lastSeen > 0.5 { anchor = []; stableSince = nil; progress = 0 }
        lastSeen = now
        let steady = anchor.count == 4 && zip(anchor,points).allSatisfy {
            hypot($0.x - $1.x, $0.y - $1.y) <= 0.04
        }
        if !steady { anchor = points; stableSince = now; progress = 0; return false }
        progress = min(1, max(0,now - (stableSince ?? now)))
        guard progress >= 1, lastCapture.map({ now - $0 >= 4 }) ?? true else { return false }
        lastCapture = now; stableSince = nil; anchor = []; progress = 0
        return true
    }
}

// Capture devices reject out-of-range and non-finite zoom factors.
enum CameraZoomRules {
    static func badgeText(factor: CGFloat) -> String? {
        guard factor.isFinite, factor > 1 else { return nil }
        // Keep a decimal point in every locale; show small zoom changes accurately.
        return String(format: factor < 1.05 ? "%.2fx" : "%.1fx", locale: Locale(identifier: "en_US_POSIX"), Double(factor))
    }

    static func factor(start: CGFloat, scale: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat? {
        guard start.isFinite, scale.isFinite, minimum.isFinite, maximum.isFinite,
              start > 0, scale > 0, minimum > 0, maximum >= minimum else { return nil }
        let target = start * scale
        guard target.isFinite else { return nil }
        return min(maximum, max(minimum, target))
    }
}


/// Bound screen-only work on older supported iPhones without lowering saved capture/PDF quality.
struct RuntimeBudget {
    static let current = RuntimeBudget(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    let constrained: Bool
    init(physicalMemory: UInt64) { constrained = physicalMemory <= 3 * 1024 * 1024 * 1024 }
    var previewEdge: Int { constrained ? 900 : 1200 }
    var cropPreviewEdge: Int { constrained ? 1536 : 2048 }
    var previewCacheBytes: Int { (constrained ? 6 : 16) * 1024 * 1024 }
    var thumbnailCacheBytes: Int { (constrained ? 4 : 12) * 1024 * 1024 }
    var detectionInterval: Double { constrained ? 0.4 : 0.25 }
}
