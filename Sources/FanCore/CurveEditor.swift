import Foundation

/// The graph and numeric table both edit this draft. Only apply() changes the stored preset.
public struct CurveEditor {
    public private(set) var original: Preset
    public var draft: Preset
    public init(_ preset: Preset) { original = preset; draft = preset }
    public var isDirty: Bool { draft != original }
    public mutating func cancel() { draft = original }
    public mutating func apply(fans: [Fan]) throws -> Preset {
        try draft.validate(fans: fans)
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FanError.invalid("Give the preset a name.") }
        original = draft
        return draft
    }
    public mutating func restoreDefaults(fans: [Fan]) {
        let defaults = Preset.defaults(draft.kind == .performance ? .performance : .gaming, fans: fans, id: draft.id)
        draft.curves = defaults.curves
    }
    public mutating func move(fan: Fan, pointID: UUID, temperature: Double, rpm: Double, snap: Bool) {
        guard temperature.isFinite, rpm.isFinite,
              let c = draft.curves.firstIndex(where: { $0.fanID == fan.id }),
              let p = draft.curves[c].points.firstIndex(where: { $0.id == pointID }) else { return }
        let points = draft.curves[c].points
        let low = p == 0 ? 0 : points[p - 1].temperatureC + 1
        let high = p == points.count - 1 ? 110 : points[p + 1].temperatureC - 1
        guard low <= high else { return }
        let minimum = p == 0 ? fan.minimumRPM : points[p - 1].targetRPM
        let maximum = p == points.count - 1 ? fan.maximumRPM : points[p + 1].targetRPM
        draft.curves[c].points[p].temperatureC = min(high, max(low, snap ? temperature.rounded() : temperature))
        draft.curves[c].points[p].targetRPM = min(maximum, max(minimum, fan.clamp(snap ? (rpm / 100).rounded() * 100 : rpm)))
    }
    public mutating func addPoint(fan: Fan) {
        guard let c = draft.curves.firstIndex(where: { $0.fanID == fan.id }), draft.curves[c].points.count < 32 else { return }
        let points = draft.curves[c].points
        guard points.count >= 2,
              let i = (1..<points.count).max(by: { points[$0].temperatureC - points[$0 - 1].temperatureC < points[$1].temperatureC - points[$1 - 1].temperatureC }),
              points[i].temperatureC - points[i - 1].temperatureC >= 2 else { return }
        draft.curves[c].points.insert(CurvePoint((points[i].temperatureC + points[i - 1].temperatureC) / 2,
                                                 (points[i].targetRPM + points[i - 1].targetRPM) / 2), at: i)
    }
    public mutating func removePoint(fanID: String, pointID: UUID) {
        guard let c = draft.curves.firstIndex(where: { $0.fanID == fanID }), draft.curves[c].points.count > 2 else { return }
        draft.curves[c].points.removeAll { $0.id == pointID }
    }
    public mutating func copy(from source: Fan, fans: [Fan]) {
        guard let curve = draft.curves.first(where: { $0.fanID == source.id }) else { return }
        for fan in fans where fan.id != source.id {
            draft.curves.removeAll { $0.fanID == fan.id }
            draft.curves.append(curve.scaled(from: source, to: fan))
        }
    }
}
