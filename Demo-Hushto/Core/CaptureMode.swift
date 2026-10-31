import Foundation

/// One scan pipeline handles documents, boards and displays.
enum CaptureMode: String, CaseIterable, Codable, Identifiable {
    case video = "동영상", photo = "사진", scan = "스캔"
    var id: Self { self }
    var savesToPhotoLibrary: Bool { self != .scan }
    var needsCorrection: Bool { self == .scan }
    static func restored(_ value: String) -> Self {
        if ["문서", "칠판", "스크린"].contains(value) { return .scan }
        return Self(rawValue: value) ?? .photo
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if ["문서", "칠판", "스크린"].contains(value) { self = .scan }
        else if let mode = Self(rawValue: value) { self = mode }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown capture mode") }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A drag moves the track under the fixed center window; no time-based advance.
enum CaptureModeDragRules {
    static func position(start: Double, translation: Double, step: Double) -> Double {
        let last = Double(CaptureMode.allCases.count - 1)
        let origin = start.isFinite ? min(last, max(0, start)) : 1
        guard translation.isFinite, step.isFinite, step > 0 else { return origin }
        return min(last, max(0, origin - translation / step))
    }
    static func index(start: Int, translation: Double, step: Double) -> Int {
        Int(position(start: Double(start), translation: translation, step: step).rounded())
    }
}
