import Foundation

public struct Fan: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var minimumRPM: Double
    public var maximumRPM: Double
    public init(id: String, name: String, minimumRPM: Double, maximumRPM: Double) {
        self.id = id; self.name = name; self.minimumRPM = minimumRPM; self.maximumRPM = maximumRPM
    }
    public var valid: Bool { minimumRPM.isFinite && maximumRPM.isFinite && minimumRPM >= 0 && maximumRPM > minimumRPM && maximumRPM <= 20_000 }
    public func clamp(_ rpm: Double) -> Double { min(maximumRPM, max(minimumRPM, rpm)) }
}

public struct HardwareIdentity: Codable, Equatable, Sendable {
    public var model: String
    public var machineID: String
    public var fans: [Fan]
    public init(model: String, machineID: String, fans: [Fan]) { self.model = model; self.machineID = machineID; self.fans = fans }
}

public struct CurvePoint: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var temperatureC: Double
    public var targetRPM: Double
    public init(_ temperatureC: Double, _ targetRPM: Double, id: UUID = UUID()) {
        self.id = id; self.temperatureC = temperatureC; self.targetRPM = targetRPM
    }
}

public struct FanCurve: Codable, Equatable, Sendable {
    public var fanID: String
    public var points: [CurvePoint]
    public init(fanID: String, points: [CurvePoint]) { self.fanID = fanID; self.points = points }
    public func validate(for fan: Fan) throws {
        guard fan.valid, fanID == fan.id, (2...32).contains(points.count), Set(points.map(\.id)).count == points.count else {
            throw FanError.invalid("Each fan needs 2–32 distinct curve points and valid hardware limits.")
        }
        for (index, point) in points.enumerated() {
            guard point.temperatureC.isFinite, point.targetRPM.isFinite,
                  (0...110).contains(point.temperatureC), (fan.minimumRPM...fan.maximumRPM).contains(point.targetRPM) else {
                throw FanError.invalid("Temperatures must be 0–110°C and RPM must stay within this fan’s limits.")
            }
            if index > 0 {
                guard points[index - 1].temperatureC < point.temperatureC,
                      points[index - 1].targetRPM <= point.targetRPM else {
                    throw FanError.invalid("Temperatures must increase and RPM must never decrease.")
                }
            }
        }
        guard points.contains(where: { $0.temperatureC <= 85 && $0.targetRPM >= fan.maximumRPM }) else {
            throw FanError.invalid("Reach maximum RPM at or before 85°C.")
        }
    }
    public func rpm(at temperature: Double, fan: Fan) -> Double {
        guard temperature.isFinite, !points.isEmpty else { return fan.maximumRPM }
        if temperature <= points[0].temperatureC { return fan.clamp(points[0].targetRPM) }
        for i in 1..<points.count where temperature <= points[i].temperatureC {
            let a = points[i - 1], b = points[i]
            let width = b.temperatureC - a.temperatureC
            guard width > 0 else { return fan.maximumRPM }
            return fan.clamp(a.targetRPM + (b.targetRPM - a.targetRPM) * (temperature - a.temperatureC) / width)
        }
        return fan.clamp(points.last!.targetRPM)
    }
    public func scaled(from source: Fan, to destination: Fan) -> FanCurve {
        FanCurve(fanID: destination.id, points: points.map {
            let fraction = source.valid ? ($0.targetRPM - source.minimumRPM) / (source.maximumRPM - source.minimumRPM) : 1
            return CurvePoint($0.temperatureC, destination.clamp(destination.minimumRPM + fraction * (destination.maximumRPM - destination.minimumRPM)))
        })
    }
}

public enum PresetKind: String, Codable, CaseIterable, Sendable { case gaming, performance, custom }
public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: PresetKind
    public var curves: [FanCurve]
    public init(id: UUID = UUID(), name: String, kind: PresetKind, curves: [FanCurve]) {
        self.id = id; self.name = name; self.kind = kind; self.curves = curves
    }
    public static func defaults(_ kind: PresetKind, fans: [Fan], id: UUID = UUID()) -> Preset {
        let fractions: [Double] = kind == .performance ? [0.2, 0.5, 0.8, 1] : [0, 0.25, 0.6, 1]
        return Preset(id: id, name: kind == .performance ? "Performance" : "Gaming", kind: kind,
                      curves: fans.map { fan in FanCurve(fanID: fan.id, points: zip([40.0, 60, 75, 85], fractions).map {
                          CurvePoint($0.0, fan.minimumRPM + $0.1 * (fan.maximumRPM - fan.minimumRPM))
                      }) })
    }
    public func validate(fans: [Fan]) throws {
        guard !fans.isEmpty, Set(curves.map(\.fanID)) == Set(fans.map(\.id)), curves.count == fans.count else {
            throw FanError.invalid("A preset must include exactly one curve for every detected fan.")
        }
        for fan in fans { try curves.first(where: { $0.fanID == fan.id })!.validate(for: fan) }
    }
}

public struct AppRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleID: String
    public var name: String
    public var presetID: UUID
    public var enabled: Bool
    public init(bundleID: String, name: String, presetID: UUID, enabled: Bool = true) {
        id = UUID(); self.bundleID = bundleID; self.name = name; self.presetID = presetID; self.enabled = enabled
    }
}
public struct Configuration: Codable, Equatable, Sendable {
    public var version = 1
    public var hardware: HardwareIdentity?
    public var presets: [Preset] = []
    public var rules: [AppRule] = []
    public var reviewedHardware = false
    public var snapToGrid = true
    public init() {}
}
public enum FanError: Error, LocalizedError {
    case invalid(String), hardware(String), unavailable(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s), .hardware(let s), .unavailable(let s): return s }
    }
}

public struct RunningApps: Sendable {
    public private(set) var instances: [Int32: String] = [:]
    public init() {}
    public mutating func launch(pid: Int32, bundleID: String) { instances[pid] = bundleID }
    public mutating func terminate(pid: Int32) { instances.removeValue(forKey: pid) }
    public mutating func reconcile(_ processes: [Int32: String]) { instances = processes }
    public func matching(_ rules: [AppRule]) -> [AppRule] {
        let bundles = Set(instances.values)
        return rules.filter { $0.enabled && bundles.contains($0.bundleID) }
    }
}
