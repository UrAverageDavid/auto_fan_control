import AppKit
import SwiftUI
import ServiceManagement
import FanCore
import FanHardware
import FanIPC

@MainActor final class AppModel: ObservableObject {
    @Published var configuration = Configuration()
    @Published var hardware: HardwareIdentity?
    @Published var hardwareMessage = "Discovering hardware…"
    @Published var validated = false
    @Published var helperConnected = false
    @Published var paused = false
    @Published var sleeping = false
    @Published var activeRules: [AppRule] = []
    @Published var status = ControlStatus()
    @Published var error: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var helperRegistration = "Not registered"
    @Published var selection: Section = .apps
    let preview: Bool
    private let store: JSONConfigurationStore
    private let client = HelperClient()
    private var runningApps = RunningApps()
    private var observers: [NSObjectProtocol] = []
    private var leaseTimer: Timer?
    private var requestInFlight = false
    private var generation = 0
    private var storageHealthy = true
    private let service = SMAppService.daemon(plistName: HelperConstants.plist)
    enum Section: String, CaseIterable, Identifiable { case apps = "Apps", curves = "Fan Curves", general = "General"; var id: String { rawValue }
        var symbol: String { switch self { case .apps: "square.grid.2x2"; case .curves: "chart.xyaxis.line"; case .general: "gearshape" } }
    }
    init() {
        preview = CommandLine.arguments.contains("--preview")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = JSONConfigurationStore(url: preview ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AutoFanControl-preview-\(ProcessInfo.processInfo.processIdentifier).json") : support.appendingPathComponent("AutoFanControl/configuration.json"))
        do { configuration = try store.load() } catch { self.error = error.localizedDescription; storageHealthy = false }
        if preview {
            adopt(HardwareIdentity(model: "Preview · illustrative hardware", machineID: "preview", fans: [Fan(id: "F0", name: "Fan 1 · F0", minimumRPM: 2000, maximumRPM: 7000), Fan(id: "F1", name: "Fan 2 · F1", minimumRPM: 2200, maximumRPM: 7200)]))
            hardwareMessage = "Preview only. No hardware access or control."
            configuration.rules = [AppRule(bundleID: "com.blizzard.starcraft2", name: "StarCraft II", presetID: configuration.presets[0].id)]
        } else {
            do { let hardware = try SMCHardware(); adopt(hardware.identity); hardwareMessage = hardware.validationMessage }
            catch { hardwareMessage = error.localizedDescription }
        }
        client.disconnected = { [weak self] in
            guard let self else { return }
            self.helperConnected = false; self.validated = false; self.cancelLease()
            self.status = ControlStatus(); self.status.message = "Helper disconnected. Automatic restoration is unconfirmed; the helper lease expires after five seconds."
        }
        observeApps()
        refreshRegistration()
        if !preview && service.status == .enabled { Task { await connectHelper() } }
    }
    var fans: [Fan] { hardware?.fans ?? [] }
    var canControl: Bool { !preview && storageHealthy && helperConnected && validated && configuration.reviewedHardware && !paused && !sleeping }
    var stateTitle: String {
        if preview { return "Preview · Apple Automatic" }
        if status.active { return "Custom control active" }
        if status.message != "Apple Automatic" && !status.restorationVerified { return "Control needs attention" }
        if paused { return "Paused · Apple Automatic" }
        return "Apple Automatic"
    }
    var stateDetail: String {
        if status.message != "Apple Automatic" && status.message != "Active" { return status.message }
        if paused { return "Automation is paused. Resume when you’re ready." }
        if !helperConnected { return "Connect the helper in General to enable automation." }
        if !validated { return hardwareMessage }
        if !configuration.reviewedHardware { return "Review fan limits and curves before enabling automation." }
        if activeRules.isEmpty { return "Waiting for one of your configured apps to run." }
        return activeRules.map(\.name).joined(separator: ", ")
    }
    func adopt(_ identity: HardwareIdentity) {
        hardware = identity
        if configuration.hardware != identity {
            let old = configuration.hardware
            if configuration.presets.isEmpty {
                configuration.presets = [.defaults(.gaming, fans: identity.fans), .defaults(.performance, fans: identity.fans)]
            } else {
                configuration.presets = configuration.presets.map { preset in
                    var result = preset
                    result.curves = identity.fans.map { fan in
                        if let source = old?.fans.first(where: { $0.id == fan.id }), let curve = preset.curves.first(where: { $0.fanID == source.id }) {
                            return curve.scaled(from: source, to: fan)
                        }
                        return Preset.defaults(preset.kind, fans: [fan]).curves[0]
                    }
                    return result
                }
            }
            configuration.hardware = identity; configuration.reviewedHardware = false; persist()
        }
    }
    func persist() {
        guard storageHealthy else { return }
        do { try store.save(configuration) }
        catch { self.error = "Could not save settings: \(error.localizedDescription)"; storageHealthy = false; stop() }
    }
    func savePreset(_ preset: Preset) {
        guard let i = configuration.presets.firstIndex(where: { $0.id == preset.id }) else { return }
        configuration.presets[i] = preset; persist(); reconcile()
    }
    func duplicatePreset(_ preset: Preset) -> UUID {
        var copy = preset; copy.id = UUID(); copy.kind = .custom; copy.name = preset.name + " Copy"
        configuration.presets.append(copy); persist(); return copy.id
    }
    func removePreset(_ id: UUID) {
        guard let preset = configuration.presets.first(where: { $0.id == id }), preset.kind == .custom,
              !configuration.rules.contains(where: { $0.presetID == id }) else { return }
        configuration.presets.removeAll { $0.id == id }; persist()
    }
    func addApp() {
        guard let preset = configuration.presets.first else { error = "Detect fan limits before adding app rules."; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.prompt = "Add Apps"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { error = "The selected app has no bundle identifier."; continue }
            guard !configuration.rules.contains(where: { $0.bundleID == id }) else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? url.deletingPathExtension().lastPathComponent
            configuration.rules.append(AppRule(bundleID: id, name: name, presetID: preset.id))
        }
        persist(); reconcile()
    }
    func changeRule(_ rule: AppRule) {
        guard let index = configuration.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        configuration.rules[index] = rule; persist(); reconcile()
    }
    func removeRule(_ id: UUID) { configuration.rules.removeAll { $0.id == id }; persist(); reconcile() }
    func togglePause() { paused.toggle(); reconcile() }
    func reviewHardware() {
        do {
            guard hardware != nil else { return }
            for preset in configuration.presets { try preset.validate(fans: fans) }
            configuration.reviewedHardware = true; persist(); reconcile()
        } catch { self.error = error.localizedDescription }
    }
    private func observeApps() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reconcile() } })
        }
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.sleeping = true; self?.stop() } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.sleeping = false; self?.reconcile() } })
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reconcile() } })
        reconcile()
    }
    func reconcile() {
        var processes: [Int32: String] = [:]
        for app in NSWorkspace.shared.runningApplications { if let bundleID = app.bundleIdentifier { processes[app.processIdentifier] = bundleID } }
        runningApps.reconcile(processes); activeRules = runningApps.matching(configuration.rules)
        guard canControl, !activeRules.isEmpty,
              ProcessInfo.processInfo.thermalState != .serious, ProcessInfo.processInfo.thermalState != .critical else { stop(); return }
        if leaseTimer == nil {
            leaseTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in await self?.renew() } }
            leaseTimer?.tolerance = 0.1
        }
        Task { await renew() }
    }
    private func renew() async {
        guard !requestInFlight, canControl, !activeRules.isEmpty, let hardware else { return }
        let ids = Set(activeRules.map(\.presetID))
        let presets = configuration.presets.filter { ids.contains($0.id) }
        guard presets.count == ids.count else { error = "An app rule references a missing preset."; stop(); return }
        requestInFlight = true
        let current = generation
        defer { requestInFlight = false }
        do {
            let result = try await client.update(SessionRequest(identity: hardware, presets: presets))
            guard current == generation else { return }
            status = result
            if !result.active { cancelLease() }
        } catch {
            guard current == generation else { return }
            cancelLease(); status = ControlStatus(); status.message = error.localizedDescription
            if let restored = try? await client.restore(), current == generation { status.restorationVerified = restored.restorationVerified }
        }
    }
    private func cancelLease() { generation += 1; leaseTimer?.invalidate(); leaseTimer = nil }
    func stop() {
        let wasActive = leaseTimer != nil || status.active
        cancelLease()
        guard wasActive else { return }
        status = ControlStatus()
        let current = generation
        Task {
            do { let restored = try await client.restore(); if current == generation { status = restored } }
            catch { if current == generation { status.message = "Automatic restoration is unconfirmed: \(error.localizedDescription)" } }
        }
    }
    func connectHelper() async {
        do {
            let caps = try await client.capabilities()
            helperConnected = true; validated = caps.validated; hardwareMessage = caps.message; adopt(caps.identity)
            status = try await client.restore(); reconcile()
        } catch { self.error = error.localizedDescription; helperConnected = false; validated = false }
    }
    func registerHelper() {
        do { try service.register(); refreshRegistration(); if service.status == .enabled { Task { await connectHelper() } } }
        catch { self.error = error.localizedDescription; refreshRegistration() }
    }
    func unregisterHelper() async {
        paused = true; stop()
        do { _ = try await client.restore(); try await service.unregister(); client.disconnect(); helperConnected = false; validated = false; refreshRegistration() }
        catch { self.error = error.localizedDescription }
    }
    func refreshRegistration() {
        switch service.status {
        case .enabled: helperRegistration = "Enabled"
        case .requiresApproval: helperRegistration = "Approval required in System Settings"
        case .notRegistered: helperRegistration = "Not registered"
        case .notFound: helperRegistration = "Helper is missing from this app bundle"
        @unknown default: helperRegistration = "Unknown"
        }
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; launchAtLogin = enabled }
        catch { self.error = error.localizedDescription; launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
    func shutdown() async {
        cancelLease()
        if helperConnected { _ = try? await client.restore() }
        client.disconnect()
    }
}
