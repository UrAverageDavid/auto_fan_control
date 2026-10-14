import XCTest
@testable import FanCore

final class FanCoreTests: XCTestCase {
    let fan = Fan(id: "F0", name: "Left", minimumRPM: 2000, maximumRPM: 7000)
    let second = Fan(id: "F1", name: "Right", minimumRPM: 1000, maximumRPM: 9000)
    func testInterpolationAndEndpoints() throws {
        let curve = Preset.defaults(.gaming, fans: [fan]).curves[0]
        XCTAssertEqual(curve.rpm(at: -20, fan: fan), 2000)
        XCTAssertEqual(curve.rpm(at: 50, fan: fan), 2625)
        XCTAssertEqual(curve.rpm(at: 60, fan: fan), 3250)
        XCTAssertEqual(curve.rpm(at: 80, fan: fan), 6000)
        XCTAssertEqual(curve.rpm(at: 140, fan: fan), 7000)
        XCTAssertEqual(curve.rpm(at: .nan, fan: fan), 7000)
        try curve.validate(for: fan)
    }
    func testDefaultPercentagesAndScaling() throws {
        let preset = Preset.defaults(.performance, fans: [fan, second])
        XCTAssertEqual(preset.curves[0].points.map(\.targetRPM), [3000, 4500, 6000, 7000])
        let scaled = preset.curves[0].scaled(from: fan, to: second)
        XCTAssertEqual(scaled.points.map(\.targetRPM), [2600, 5000, 7400, 9000])
        try scaled.validate(for: second)
        try preset.validate(fans: [fan, second])
    }
    func testInvalidCurves() {
        let invalid: [[CurvePoint]] = [
            [CurvePoint(85, 7000)],
            [CurvePoint(40, 2000), CurvePoint(40, 7000)],
            [CurvePoint(60, 2000), CurvePoint(40, 7000)],
            [CurvePoint(40, 4000), CurvePoint(60, 3000), CurvePoint(85, 7000)],
            [CurvePoint(40, 1999), CurvePoint(85, 7000)],
            [CurvePoint(40, 2000), CurvePoint(85, 7001)],
            [CurvePoint(40, 2000), CurvePoint(86, 7000)],
            [CurvePoint(40, .nan), CurvePoint(85, 7000)],
            [CurvePoint(.infinity, 2000), CurvePoint(85, 7000)],
            [CurvePoint(-1, 2000), CurvePoint(85, 7000)]
        ]
        for points in invalid { XCTAssertThrowsError(try FanCurve(fanID: fan.id, points: points).validate(for: fan)) }
        var duplicate = Preset.defaults(.gaming, fans: [fan]).curves[0]
        duplicate.points[1].id = duplicate.points[0].id
        XCTAssertThrowsError(try duplicate.validate(for: fan))
        XCTAssertThrowsError(try Preset.defaults(.gaming, fans: [fan]).validate(fans: [fan, second]))
    }
    func testInstancesAndReconciliation() {
        let rule = AppRule(bundleID: "game.test", name: "Game", presetID: UUID())
        var running = RunningApps()
        running.launch(pid: 1, bundleID: "game.test"); running.launch(pid: 2, bundleID: "game.test")
        XCTAssertEqual(running.matching([rule]).count, 1)
        running.terminate(pid: 1)
        XCTAssertEqual(running.matching([rule]).count, 1)
        running.terminate(pid: 2)
        XCTAssertTrue(running.matching([rule]).isEmpty)
        running.reconcile([9: "game.test"])
        XCTAssertEqual(running.matching([rule]).count, 1)
        var disabled = rule; disabled.enabled = false
        XCTAssertTrue(running.matching([disabled]).isEmpty)
        running.reconcile([:]); XCTAssertTrue(running.matching([rule]).isEmpty)
    }
    func testEditorDraftApplyCancelAndDefaults() throws {
        let original = Preset.defaults(.gaming, fans: [fan])
        var editor = CurveEditor(original)
        let point = original.curves[0].points[1]
        editor.move(fan: fan, pointID: point.id, temperature: 61.4, rpm: 3591, snap: true)
        XCTAssertEqual(editor.draft.curves[0].points[1].temperatureC, 61)
        XCTAssertEqual(editor.draft.curves[0].points[1].targetRPM, 3600)
        XCTAssertEqual(editor.original, original)
        XCTAssertTrue(editor.isDirty)
        editor.cancel(); XCTAssertEqual(editor.draft, original)
        editor.draft.curves[0].points[1].targetRPM = 3500 // Numeric-table edit, reflected by the graph's same model.
        XCTAssertEqual(try editor.apply(fans: [fan]).curves[0].points[1].targetRPM, 3500)
        XCTAssertFalse(editor.isDirty)
        editor.restoreDefaults(fans: [fan]); XCTAssertEqual(editor.draft.curves[0].points.map(\.targetRPM), original.curves[0].points.map(\.targetRPM))
        XCTAssertTrue(editor.isDirty)
    }
    func testEditorConstraintsKeyboardAndCopy() throws {
        var editor = CurveEditor(.defaults(.gaming, fans: [fan, second]))
        let point = editor.draft.curves[0].points[1]
        editor.move(fan: fan, pointID: point.id, temperature: 400, rpm: -100, snap: false)
        XCTAssertEqual(editor.draft.curves[0].points[1].temperatureC, 74)
        XCTAssertEqual(editor.draft.curves[0].points[1].targetRPM, 2000)
        editor.move(fan: fan, pointID: point.id, temperature: 73, rpm: 2100, snap: false)
        XCTAssertEqual(editor.draft.curves[0].points[1].temperatureC, 73)
        editor.copy(from: fan, fans: [fan, second])
        XCTAssertEqual(editor.draft.curves[1].points[1].targetRPM, 1160)
        try editor.draft.validate(fans: [fan, second])
        editor.addPoint(fan: fan); XCTAssertEqual(editor.draft.curves[0].points.count, 5)
        while editor.draft.curves[0].points.count > 2 { editor.removePoint(fanID: fan.id, pointID: editor.draft.curves[0].points[1].id) }
        editor.removePoint(fanID: fan.id, pointID: editor.draft.curves[0].points[0].id)
        XCTAssertEqual(editor.draft.curves[0].points.count, 2)
        editor.draft.curves[0].points[1].targetRPM = 2000
        XCTAssertThrowsError(try editor.apply(fans: [fan, second]))
    }
    func testStorageRoundTripAndVersionRejection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        XCTAssertTrue(try store.load().presets.isEmpty)
        var config = Configuration(); config.hardware = HardwareIdentity(model: "Test", machineID: "1", fans: [fan])
        config.presets = [.defaults(.gaming, fans: [fan])]
        config.rules = [AppRule(bundleID: "game.test", name: "Game", presetID: config.presets[0].id)]
        try store.save(config); XCTAssertEqual(try store.load(), config)
        config.version = 2; try store.save(config)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
    }
    func testHighestDemandIsSelectedIndependentlyPerFan() throws {
        let hardware = FakeHardware(fans: [fan, second])
        let controller = ControlEngine(hardware: hardware)
        var a = Preset.defaults(.gaming, fans: [fan, second])
        var b = Preset.defaults(.gaming, fans: [fan, second])
        a.curves[0].points[1].targetRPM = 4500
        b.curves[1].points[1].targetRPM = 5000
        hardware.temperature = 60
        try controller.startOrRenew(presets: [a, b], identity: hardware.identity, now: 0, thermalSafe: true)
        XCTAssertEqual(controller.status.targets, ["F0": 4500, "F1": 5000])
    }
    func testImmediateRaiseFiveLowerSamplesAndUnchangedWrites() throws {
        let hardware = FakeHardware(fans: [fan])
        let controller = ControlEngine(hardware: hardware)
        let preset = Preset.defaults(.gaming, fans: [fan])
        hardware.temperature = 60
        try controller.startOrRenew(presets: [preset], identity: hardware.identity, now: 0, thermalSafe: true)
        controller.tick(now: 1, thermalSafe: true); XCTAssertEqual(hardware.writes.count, 1)
        hardware.temperature = 80; controller.tick(now: 2, thermalSafe: true)
        XCTAssertEqual(hardware.writes.last?.1, 6000)
        hardware.temperature = 40
        for n in 3...6 {
            try controller.startOrRenew(presets: [preset], identity: hardware.identity, now: Double(n), thermalSafe: true)
            controller.tick(now: Double(n), thermalSafe: true)
            XCTAssertEqual(hardware.writes.count, 2)
        }
        controller.tick(now: 7, thermalSafe: true)
        XCTAssertEqual(hardware.writes.count, 3)
        XCTAssertEqual(hardware.writes.last?.1, 2000)
    }
    func testLowerDemandCounterResetsAfterHigherSample() throws {
        let hardware = FakeHardware(fans: [fan])
        let engine = ControlEngine(hardware: hardware), preset = Preset.defaults(.gaming, fans: [fan])
        hardware.temperature = 80
        try engine.startOrRenew(presets: [preset], identity: hardware.identity, now: 0, thermalSafe: true)
        hardware.temperature = 40; engine.tick(now: 1, thermalSafe: true); engine.tick(now: 2, thermalSafe: true)
        hardware.temperature = 80; engine.tick(now: 3, thermalSafe: true)
        hardware.temperature = 40; engine.tick(now: 4, thermalSafe: true)
        XCTAssertEqual(hardware.writes.count, 1)
    }
    func testLeaseExpiryAndNoIdlePolling() throws {
        let hardware = FakeHardware(fans: [fan])
        let controller = ControlEngine(hardware: hardware)
        controller.tick(now: 0, thermalSafe: true); XCTAssertEqual(hardware.reads, 0)
        try controller.startOrRenew(presets: [.defaults(.gaming, fans: [fan])], identity: hardware.identity, now: 0, thermalSafe: true)
        controller.tick(now: 5, thermalSafe: true)
        XCTAssertFalse(controller.status.active); XCTAssertEqual(hardware.restores, 1)
        XCTAssertTrue(controller.status.restorationVerified); XCTAssertNil(controller.status.sample)
        let reads = hardware.reads
        controller.tick(now: 6, thermalSafe: true); XCTAssertEqual(hardware.reads, reads)
    }
    func testLateRenewalCannotExtendAnExpiredSession() throws {
        let hardware = FakeHardware(fans: [fan]), engine: ControlEngine
        engine = ControlEngine(hardware: hardware)
        let preset = Preset.defaults(.gaming, fans: [fan])
        try engine.startOrRenew(presets: [preset], identity: hardware.identity, now: 0, thermalSafe: true)
        XCTAssertThrowsError(try engine.startOrRenew(presets: [preset], identity: hardware.identity, now: 5, thermalSafe: true))
        XCTAssertFalse(engine.status.active); XCTAssertTrue(engine.status.restorationVerified)
        XCTAssertEqual(hardware.writes.count, 1)
    }
    func testInvalidAndStaleSensorsRestore() throws {
        for problem in ["nan", "stale", "missing", "read failure", "future", "negative RPM"] {
            let hardware = FakeHardware(fans: [fan]), engine: ControlEngine
            engine = ControlEngine(hardware: hardware)
            try engine.startOrRenew(presets: [.defaults(.gaming, fans: [fan])], identity: hardware.identity, now: 0, thermalSafe: true)
            hardware.problem = problem; engine.tick(now: 1, thermalSafe: true)
            XCTAssertFalse(engine.status.active, problem); XCTAssertTrue(engine.status.restorationVerified, problem)
            XCTAssertEqual(hardware.restores, 1, problem)
        }
    }
    func testWriteFailureThermalPressureAndRestorationFailure() throws {
        let hardware = FakeHardware(fans: [fan]), engine: ControlEngine
        engine = ControlEngine(hardware: hardware)
        hardware.failWrite = true
        XCTAssertThrowsError(try engine.startOrRenew(presets: [.defaults(.gaming, fans: [fan])], identity: hardware.identity, now: 0, thermalSafe: true))
        XCTAssertFalse(engine.status.active); XCTAssertEqual(hardware.restores, 1)
        hardware.failWrite = false
        try engine.startOrRenew(presets: [.defaults(.gaming, fans: [fan])], identity: hardware.identity, now: 1, thermalSafe: true)
        engine.tick(now: 2, thermalSafe: false)
        XCTAssertFalse(engine.status.active); XCTAssertEqual(hardware.restores, 2)
        hardware.failRestore = true; engine.stop()
        XCTAssertFalse(engine.status.restorationVerified)
        XCTAssertTrue(engine.status.message.contains("could not be verified"))
    }
    func testUnsupportedChangedHardwareAndInvalidRequestsNeverWrite() {
        let hardware = FakeHardware(fans: [fan]), engine: ControlEngine
        engine = ControlEngine(hardware: hardware)
        hardware.isValidated = false
        XCTAssertThrowsError(try engine.startOrRenew(presets: [.defaults(.gaming, fans: [fan])], identity: hardware.identity, now: 0, thermalSafe: true))
        hardware.isValidated = true
        var changed = hardware.identity; changed.machineID = "changed"
        XCTAssertThrowsError(try engine.startOrRenew(presets: [.defaults(.gaming, fans: [fan])], identity: changed, now: 0, thermalSafe: true))
        XCTAssertThrowsError(try engine.startOrRenew(presets: [], identity: hardware.identity, now: 0, thermalSafe: true))
        XCTAssertThrowsError(try engine.startOrRenew(presets: [.defaults(.gaming, fans: [second])], identity: hardware.identity, now: 0, thermalSafe: true))
        XCTAssertTrue(hardware.writes.isEmpty)
    }
    func testPauseExitQuitSleepAndHelperRestartRestore() throws {
        for reason in ["Pause", "Last app exited", "Quit", "Sleep", "Client disconnected", "Helper startup"] {
            let hardware = FakeHardware(fans: [fan]), engine: ControlEngine
            engine = ControlEngine(hardware: hardware)
            if reason != "Helper startup" { try engine.startOrRenew(presets: [.defaults(.gaming, fans: [fan])], identity: hardware.identity, now: 0, thermalSafe: true) }
            engine.stop(reason: reason)
            XCTAssertEqual(hardware.restores, 1); XCTAssertFalse(engine.status.active)
            XCTAssertNil(engine.status.sample); XCTAssertTrue(engine.status.targets.isEmpty)
        }
    }
}

private final class FakeHardware: FanHardwareAccess {
    let identity: HardwareIdentity
    var isValidated = true
    var temperature = 60.0
    var writes: [(String, Double)] = []
    var restores = 0
    var reads = 0
    var problem = ""
    var failWrite = false
    var failRestore = false
    init(fans: [Fan]) { identity = HardwareIdentity(model: "Test", machineID: "test", fans: fans) }
    func readSample(now: TimeInterval) throws -> Sample {
        reads += 1
        if problem == "read failure" { throw FanError.hardware("Read failed") }
        var rpm = Dictionary(uniqueKeysWithValues: identity.fans.map { ($0.id, $0.minimumRPM) })
        if problem == "missing" { rpm = [:] }
        if problem == "negative RPM" { rpm[identity.fans[0].id] = -1 }
        return Sample(temperatureC: problem == "nan" ? .nan : temperature, actualRPM: rpm,
                      timestamp: problem == "stale" ? now - 3 : problem == "future" ? now + 1 : now)
    }
    func setTarget(fan: Fan, rpm: Double) throws {
        if failWrite { throw FanError.hardware("Write rejected") }
        writes.append((fan.id, rpm))
    }
    func restoreAutomatic() throws {
        restores += 1
        if failRestore { throw FanError.hardware("Restore rejected") }
    }
}
