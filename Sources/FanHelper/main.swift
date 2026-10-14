import Foundation
import FanCore
import FanHardware
import FanIPC
import IOKit
import IOKit.pwr_mgt
import CSMC

final class HelperService: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "local.autofancontrol.hardware", qos: .userInitiated)
    let hardware: SMCHardware
    let engine: ControlEngine
    private let team: String
    private var timer: DispatchSourceTimer?
    private var owner: UUID?
    private var sleeping = false
    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var powerConnection: io_connect_t = 0
    init(hardware: SMCHardware, team: String) {
        self.hardware = hardware; self.engine = ControlEngine(hardware: hardware); self.team = team
        super.init()
        engine.stop() // Includes restoration verification before accepting a session.
        powerConnection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &powerPort, { context, connection, message, argument in
            guard let context else { return }
            let service = Unmanaged<HelperService>.fromOpaque(context).takeUnretainedValue()
            if message == af_power_will_sleep() {
                service.queue.sync { service.sleeping = true; service.stop("Sleeping. Apple Automatic restored.") }
                IOAllowPowerChange(service.powerConnection, Int(bitPattern: argument))
            } else if message == af_power_can_sleep() {
                IOAllowPowerChange(service.powerConnection, Int(bitPattern: argument))
            } else if message == af_power_did_wake() {
                service.queue.async { service.sleeping = false }
            }
        }, &powerNotifier)
        if let powerPort, let source = IONotificationPortGetRunLoopSource(powerPort)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { if !self.thermalSafe { self.stop("Thermal pressure elevated. Apple Automatic restored.") } }
        }
    }
    var thermalSafe: Bool { !sleeping && ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        connection.setCodeSigningRequirement(HelperConstants.requirement(identifier: HelperConstants.appID, team: team))
        let id = UUID()
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = Endpoint(service: self, id: id)
        connection.invalidationHandler = { [weak self] in self?.queue.async { [weak self] in
            guard let self, self.owner == id else { return }; self.stop("Client disconnected. Apple Automatic restored.")
        } }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        return true
    }
    func update(id: UUID, data: Data) throws -> ControlStatus {
        guard data.count <= 256_000 else { throw FanError.invalid("Session request exceeds the size limit.") }
        guard owner == nil || owner == id else { throw FanError.unavailable("Another app instance owns the control session.") }
        let request = try JSONDecoder().decode(SessionRequest.self, from: data)
        guard powerConnection != 0 else { throw FanError.unavailable("Sleep monitoring could not be installed.") }
        do {
            try engine.startOrRenew(presets: request.presets, identity: request.identity, now: ProcessInfo.processInfo.systemUptime, thermalSafe: thermalSafe)
            owner = id
            if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.engine.tick(now: ProcessInfo.processInfo.systemUptime, thermalSafe: self.thermalSafe)
                    if !self.engine.status.active { self.cancelTimer(); self.owner = nil }
                }
                self.timer = timer; timer.resume()
            }
            return engine.status
        } catch { stop(error.localizedDescription); throw error }
    }
    func cancelTimer() { timer?.cancel(); timer = nil }
    func stop(_ reason: String = "Apple Automatic") { engine.stop(reason: reason); cancelTimer(); owner = nil }
}
final class Endpoint: NSObject, FanHelperProtocol {
    let service: HelperService
    let id: UUID
    init(service: HelperService, id: UUID) { self.service = service; self.id = id }
    func capabilities(reply: @escaping (Data?, String?) -> Void) {
        service.queue.async { reply(try? JSONEncoder().encode(Capabilities(identity: self.service.hardware.identity, validated: self.service.hardware.isValidated, message: self.service.hardware.validationMessage)), nil) }
    }
    func startOrUpdate(_ request: Data, reply: @escaping (Data?, String?) -> Void) {
        service.queue.async {
            do { reply(try JSONEncoder().encode(self.service.update(id: self.id, data: request)), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }
    func status(reply: @escaping (Data?, String?) -> Void) {
        service.queue.async { reply(try? JSONEncoder().encode(self.service.engine.status), nil) }
    }
    func restoreAutomatic(reply: @escaping (Data?, String?) -> Void) {
        service.queue.async {
            self.service.stop()
            reply(try? JSONEncoder().encode(self.service.engine.status), nil)
        }
    }
}

guard geteuid() == 0, let team = HelperConstants.teamID() else {
    fputs("FanHelper requires root and an Apple-issued code-signing identity.\n", stderr); exit(1)
}
do {
    let lock = try HardwareLock()
    let service = HelperService(hardware: try SMCHardware(), team: team)
    let listener = NSXPCListener(machServiceName: HelperConstants.service)
    listener.delegate = service
    // Catch normal service termination. Crash/disconnection recovery is handled by launchd startup and the lease.
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: service.queue)
    termination.setEventHandler { service.stop(); exit(service.engine.status.restorationVerified ? 0 : 1) }; termination.resume()
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: service.queue)
    interrupt.setEventHandler { service.stop(); exit(service.engine.status.restorationVerified ? 0 : 1) }; interrupt.resume()
    listener.resume()
    withExtendedLifetime((service, listener, termination, interrupt, lock)) { RunLoop.main.run() }
} catch { fputs("FanHelper: \(error.localizedDescription)\n", stderr); exit(1) }
