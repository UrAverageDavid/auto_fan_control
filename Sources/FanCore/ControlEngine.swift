import Foundation

public struct Sample: Codable, Equatable, Sendable {
    public var temperatureC: Double
    public var actualRPM: [String: Double]
    public var timestamp: TimeInterval
    public init(temperatureC: Double, actualRPM: [String: Double], timestamp: TimeInterval) {
        self.temperatureC = temperatureC; self.actualRPM = actualRPM; self.timestamp = timestamp
    }
}
public struct ControlStatus: Codable, Sendable {
    public var active = false
    public var message = "Apple Automatic"
    public var sample: Sample?
    public var targets: [String: Double] = [:]
    public var restorationVerified = false
    public init() {}
}
public protocol FanHardwareAccess: AnyObject {
    var identity: HardwareIdentity { get }
    var isValidated: Bool { get }
    func readSample(now: TimeInterval) throws -> Sample
    func setTarget(fan: Fan, rpm: Double) throws
    /// Must attempt every fan even if one fails, and verify automatic mode.
    func restoreAutomatic() throws
}

/// Owned by one serial executor in the helper. The client never supplies temperatures or raw RPM writes.
public final class ControlEngine {
    public private(set) var status = ControlStatus()
    private let hardware: FanHardwareAccess
    private var presets: [Preset] = []
    private var leaseDeadline: TimeInterval = 0
    private var lowerSamples: [String: Int] = [:]
    public init(hardware: FanHardwareAccess) { self.hardware = hardware }
    public func startOrRenew(presets: [Preset], identity: HardwareIdentity, now: TimeInterval, thermalSafe: Bool) throws {
        if status.active && now >= leaseDeadline {
            stop(reason: "Session lease expired before renewal. Apple Automatic restored.")
            throw FanError.unavailable(status.message)
        }
        guard hardware.isValidated, identity == hardware.identity else {
            stop(reason: "Hardware validation or curve review required.")
            throw FanError.unavailable(status.message)
        }
        guard thermalSafe, !presets.isEmpty, presets.count <= 64 else {
            stop(reason: "Control request is empty or thermal pressure is elevated.")
            throw FanError.invalid(status.message)
        }
        do { for preset in presets { try preset.validate(fans: hardware.identity.fans) } }
        catch { stop(reason: error.localizedDescription); throw error }
        self.presets = presets
        leaseDeadline = now + 5
        if !status.active {
            status.active = true; status.message = "Active"; status.restorationVerified = false
            tick(now: now, thermalSafe: thermalSafe)
            if !status.active { throw FanError.hardware(status.message) }
        }
    }
    public func tick(now: TimeInterval, thermalSafe: Bool) {
        guard status.active else { return }
        guard now < leaseDeadline else { stop(reason: "Session expired. Apple Automatic restored."); return }
        guard thermalSafe else { stop(reason: "Thermal pressure elevated. Apple Automatic restored."); return }
        do {
            let sample = try hardware.readSample(now: now)
            guard sample.temperatureC.isFinite, (0...115).contains(sample.temperatureC),
                  sample.timestamp <= now, now - sample.timestamp <= 2,
                  hardware.identity.fans.allSatisfy({ fan in
                      guard let rpm = sample.actualRPM[fan.id] else { return false }
                      return rpm.isFinite && rpm >= 0 && rpm <= fan.maximumRPM * 1.2
                  }) else { throw FanError.hardware("Invalid or stale sensor reading.") }
            for fan in hardware.identity.fans {
                let demands = presets.compactMap { $0.curves.first(where: { $0.fanID == fan.id })?.rpm(at: sample.temperatureC, fan: fan) }
                guard let demand = demands.max() else { throw FanError.invalid("Missing fan curve.") }
                let requested = fan.clamp(demand.rounded())
                let previous = status.targets[fan.id]
                if let previous, requested < previous {
                    lowerSamples[fan.id, default: 0] += 1
                    guard lowerSamples[fan.id, default: 0] >= 5 else { continue }
                } else { lowerSamples[fan.id] = 0 }
                if previous != requested {
                    try hardware.setTarget(fan: fan, rpm: requested)
                    status.targets[fan.id] = requested
                }
                lowerSamples[fan.id] = 0
            }
            status.sample = sample
        } catch { stop(reason: error.localizedDescription) }
    }
    public func stop(reason: String = "Apple Automatic") {
        status.active = false; presets = []; lowerSamples = [:]; leaseDeadline = 0
        status.sample = nil; status.targets = [:]
        do { try hardware.restoreAutomatic(); status.restorationVerified = true; status.message = reason }
        catch { status.restorationVerified = false; status.message = "Automatic restoration could not be verified: \(error.localizedDescription)" }
    }
}
