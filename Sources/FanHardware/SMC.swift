import Foundation
import CSMC
import FanCore
import IOKit

public final class SMC {
    private var connection: UInt32 = 0
    public init() throws {
        let result = af_smc_open(&connection)
        guard result == 0 else { throw FanError.hardware("Cannot open AppleSMC (\(result)). Hardware access is unavailable.") }
    }
    deinit { af_smc_close(connection) }
    public func read(_ key: String) throws -> (type: String, bytes: [UInt8]) {
        var type: UInt32 = 0, length: UInt32 = 0, bytes = [UInt8](repeating: 0, count: 32)
        let result = af_smc_read(connection, key, &type, &length, &bytes)
        guard result == 0 else { throw FanError.hardware("SMC read \(key) failed (\(result)).") }
        let typeString = String(bytes: [UInt8((type >> 24) & 255), UInt8((type >> 16) & 255), UInt8((type >> 8) & 255), UInt8(type & 255)], encoding: .ascii) ?? ""
        return (typeString, Array(bytes.prefix(Int(length))))
    }
    public func number(_ key: String) throws -> Double {
        let value = try read(key), b = value.bytes
        let number: Double
        switch (value.type, b.count) {
        case ("flt ", 4): number = Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        case ("fpe2", 2): number = Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case ("sp78", 2): number = Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case ("ui8 ", 1): number = Double(b[0])
        case ("ui16", 2): number = Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case ("ui32", 4): number = Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default: throw FanError.hardware("Unsupported numeric type \(value.type) for \(key).")
        }
        guard number.isFinite else { throw FanError.hardware("Non-finite SMC value for \(key).") }
        return number
    }
    // This primitive is internal to FanHardware; clients only get bounded fan operations.
    func write(_ key: String, number: Double) throws {
        guard geteuid() == 0, number.isFinite, number >= 0, number <= 20_000 else { throw FanError.hardware("Fan writes require the privileged helper and a bounded value.") }
        let info = try read(key)
        let bytes: [UInt8]
        switch (info.type, info.bytes.count) {
        case ("flt ", 4):
            let bits = Float(number).bitPattern
            bytes = [UInt8(bits & 255), UInt8((bits >> 8) & 255), UInt8((bits >> 16) & 255), UInt8(bits >> 24)]
        case ("fpe2", 2):
            guard number < 16384 else { throw FanError.hardware("RPM exceeds fixed-point representation.") }
            let raw = UInt16((number * 4).rounded()); bytes = [UInt8(raw >> 8), UInt8(raw & 255)]
        case ("ui8 ", 1) where number <= 1: bytes = [UInt8(number)]
        default: throw FanError.hardware("Unsupported writable SMC type for \(key).")
        }
        let result = af_smc_write(connection, key, UInt32(bytes.count), bytes)
        guard result == 0 else { throw FanError.hardware("SMC write \(key) rejected (\(result)).") }
    }
    public func temperatureCandidates() throws -> [String: Double] {
        let count = try number("#KEY")
        guard count >= 0, count <= 30_000 else { throw FanError.hardware("Invalid SMC key count.") }
        var result: [String: Double] = [:]
        for index in 0..<UInt32(count) {
            var bytes = [CChar](repeating: 0, count: 5)
            guard af_smc_key(connection, index, &bytes) == 0 else { continue }
            let key = String(cString: bytes)
            if key.hasPrefix("T"), let value = try? number(key), (5...115).contains(value) { result[key] = value }
        }
        return result
    }
}

public struct ValidationRecord: Codable {
    public var version = 1
    public var identity: HardwareIdentity
    public var cpuSensors: [String]
    public var gpuSensors: [String]
    public var validatedAt: Date
    public var operatingSystem: String
    public init(identity: HardwareIdentity, cpuSensors: [String], gpuSensors: [String]) {
        self.identity = identity; self.cpuSensors = cpuSensors; self.gpuSensors = gpuSensors
        self.validatedAt = Date(); operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    }
    public static let url = URL(fileURLWithPath: "/Library/Application Support/AutoFanControl/hardware-validation.json")
}

public final class SMCHardware: FanHardwareAccess {
    public let identity: HardwareIdentity
    public private(set) var isValidated = false
    public private(set) var validationMessage = "Hardware response and CPU/GPU sensors need validation."
    private let smc: SMC
    private var modes: [String: String] = [:]
    private var sensors: [String] = []
    private var expectedTargets: [String: (rpm: Double, written: TimeInterval)] = [:]
    public init() throws {
        smc = try SMC()
        let count = try smc.number("FNum")
        guard count >= 1, count <= 8, count.rounded() == count else { throw FanError.hardware("No supported fans detected.") }
        var fans: [Fan] = []
        for index in 0..<Int(count) {
            let id = "F\(index)"
            let fan = Fan(id: id, name: "Fan \(index + 1) · \(id)", minimumRPM: try smc.number(id + "Mn"), maximumRPM: try smc.number(id + "Mx"))
            guard fan.valid else { throw FanError.hardware("Invalid limits for \(id).") }
            fans.append(fan)
            for key in [id + "Md", id + "md"] where modes[id] == nil {
                if let value = try? smc.read(key), value.type == "ui8 ", value.bytes.count == 1 { modes[id] = key }
            }
        }
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        var machine = "unavailable"
        if service != 0 {
            if let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String { machine = value }
            IOObjectRelease(service)
        }
        identity = HardwareIdentity(model: String(cString: model), machineID: machine, fans: fans)
        loadValidation()
    }
    private func loadValidation() {
        let url = ValidationRecord.url
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o022 == 0,
              let record = try? JSONDecoder().decode(ValidationRecord.self, from: Data(contentsOf: url)),
              record.version == 1, record.identity == identity,
              record.operatingSystem == ProcessInfo.processInfo.operatingSystemVersionString,
              !record.cpuSensors.isEmpty, !record.gpuSensors.isEmpty,
              record.cpuSensors.allSatisfy({ $0.count == 4 && $0.hasPrefix("T") }),
              record.gpuSensors.allSatisfy({ $0.count == 4 && $0.hasPrefix("T") }),
              modes.count == identity.fans.count, identity.machineID != "unavailable" else { return }
        sensors = Array(Set(record.cpuSensors + record.gpuSensors)).sorted()
        isValidated = true; validationMessage = "Validated \(record.validatedAt.formatted(date: .abbreviated, time: .shortened))"
    }
    public func diagnostic() throws -> [String: String] {
        var values = ["model": identity.model, "validation": validationMessage]
        for fan in identity.fans {
            values[fan.id] = "\(fan.minimumRPM)–\(fan.maximumRPM) RPM; actual \(try smc.number(fan.id + "Ac")); mode key \(modes[fan.id] ?? "unavailable")"
        }
        for (key, value) in try smc.temperatureCandidates() { values[key] = String(format: "%.1f °C (unvalidated sensor)", value) }
        return values
    }
    public func readSample(now: TimeInterval) throws -> Sample {
        guard !sensors.isEmpty else { throw FanError.hardware("CPU/GPU sensor mapping is not validated.") }
        let temperatures = try sensors.map { key -> Double in
            let value = try smc.number(key)
            guard (5...115).contains(value) else { throw FanError.hardware("Invalid temperature from \(key).") }
            return value
        }
        var rpm: [String: Double] = [:]
        for fan in identity.fans {
            rpm[fan.id] = try smc.number(fan.id + "Ac")
            if let expected = expectedTargets[fan.id], let mode = modes[fan.id] {
                guard try smc.number(mode) == 1 else { throw FanError.hardware("System reclaimed fan control for \(fan.id).") }
                if now - expected.written >= 2 {
                    let target = try smc.number(fan.id + "Tg")
                    guard abs(target - expected.rpm) <= 100 else { throw FanError.hardware("Target readback disagrees for \(fan.id).") }
                }
            }
        }
        return Sample(temperatureC: temperatures.max()!, actualRPM: rpm, timestamp: now)
    }
    public func setTarget(fan: Fan, rpm: Double) throws {
        guard isValidated, identity.fans.contains(fan), rpm.isFinite,
              rpm >= fan.minimumRPM, rpm <= fan.maximumRPM,
              let mode = modes[fan.id] else { throw FanError.hardware("Fan control has not been validated for this hardware.") }
        // Do not use diagnostic/unlock keys to fight the system thermal manager.
        try smc.write(fan.id + "Tg", number: rpm)
        if try smc.number(mode) != 1 { try smc.write(mode, number: 1) }
        guard try smc.number(mode) == 1 else { throw FanError.hardware("Manual mode was not accepted for \(fan.id).") }
        try smc.write(fan.id + "Tg", number: rpm)
        expectedTargets[fan.id] = (rpm, ProcessInfo.processInfo.systemUptime)
    }
    public func restoreAutomatic() throws {
        expectedTargets = [:]
        var failures: [String] = []
        for fan in identity.fans {
            do {
                guard let mode = modes[fan.id] else { throw FanError.hardware("Unknown mode key for \(fan.id).") }
                let value = try smc.number(mode)
                if value != 0 && value != 3 { try smc.write(mode, number: 0) }
                let restored = try smc.number(mode)
                guard restored == 0 || restored == 3 else { throw FanError.hardware("Automatic mode unconfirmed for \(fan.id).") }
            } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw FanError.hardware(failures.joined(separator: " ")) }
    }
    /// Explicit, local root-only commissioning. Never exposed over XPC.
    /// Select sensors after verifying their CPU/GPU identities against the target hardware.
    public func validateHardware(cpu: [String], gpu: [String], heartbeat: () throws -> Void = {}) throws -> ValidationRecord {
        guard geteuid() == 0, !cpu.isEmpty, !gpu.isEmpty, identity.machineID != "unavailable",
              (cpu + gpu).allSatisfy({ $0.count == 4 && $0.hasPrefix("T") }),
              Set(cpu).isDisjoint(with: Set(gpu)), modes.count == identity.fans.count else {
            throw FanError.invalid("Validation requires root, distinct CPU and GPU sensor keys, and all fan mode keys.")
        }
        sensors = Array(Set(cpu + gpu)); isValidated = false
        try restoreAutomatic()
        defer { try? restoreAutomatic(); isValidated = false }
        _ = try readSample(now: ProcessInfo.processInfo.systemUptime)
        // A bounded test ramps every fan to maximum, then verifies actual response and restoration.
        isValidated = true
        do {
            for fan in identity.fans { try setTarget(fan: fan, rpm: fan.maximumRPM) }
            var converged = false
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 1)
                try heartbeat()
                guard ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical else {
                    throw FanError.hardware("Validation interrupted by thermal pressure.")
                }
                let sample = try readSample(now: ProcessInfo.processInfo.systemUptime)
                if identity.fans.allSatisfy({ (sample.actualRPM[$0.id] ?? 0) >= $0.maximumRPM * 0.9 }) { converged = true; break }
            }
            guard converged else { throw FanError.hardware("Fan response did not reach 90% of the requested maximum within 20 seconds.") }
            try restoreAutomatic()
            // Confirm automatic mode remains in place, not just one transient readback.
            Thread.sleep(forTimeInterval: 1)
            try restoreAutomatic()
        } catch {
            do { try restoreAutomatic() } catch { throw FanError.hardware("VALIDATION FAILED AND AUTOMATIC RESTORATION IS UNCONFIRMED: \(error.localizedDescription)") }
            throw error
        }
        return ValidationRecord(identity: identity, cpuSensors: cpu, gpuSensors: gpu)
    }
}
