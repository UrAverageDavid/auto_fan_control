import SwiftUI
import AppKit

@main struct AutoFanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        AppDelegate.model = model
    }
    var body: some Scene {
        MenuBarExtra {
            MenuPopover().environmentObject(model)
        } label: {
            Image(systemName: model.status.active ? "fan.fill" : "fan")
                .accessibilityLabel("Auto Fan Control, \(model.stateTitle)")
        }
        .menuBarExtraStyle(.window)
        Window("Auto Fan Control", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .defaultSize(width: 1040, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                OpenSettingsCommand()
            }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.accessory); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await Self.model?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.title == "Auto Fan Control" })?.makeKeyAndOrderFront(nil) }
        return true
    }
}
struct OpenSettingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Settings…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut(",") }
}
struct MenuPopover: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "fan").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto Fan Control").font(.headline)
                    Text(model.stateTitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(model.status.active ? Color.green : Color.secondary).frame(width: 7, height: 7).accessibilityHidden(true)
            }
            Text(model.stateDetail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.status.active, let sample = model.status.sample {
                HStack { Text("Hottest CPU / GPU"); Spacer(); Text("\(sample.temperatureC, specifier: "%.0f")°C").monospacedDigit() }
                ForEach(model.fans) { fan in
                    HStack { Text(fan.name); Spacer(); Text("\(Int(sample.actualRPM[fan.id] ?? 0)) RPM").monospacedDigit() }.font(.caption)
                }
            }
            if !model.activeRules.isEmpty {
                Divider()
                ForEach(model.activeRules) { rule in
                    HStack { Text(rule.name); Spacer(); Text(model.configuration.presets.first(where: { $0.id == rule.presetID })?.name ?? "Missing preset").foregroundStyle(.secondary) }.font(.caption)
                }
            }
            Divider()
            HStack {
                Button(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play" : "pause") { model.togglePause() }
                Spacer()
                Button("Settings", systemImage: "gearshape") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
                Button("Quit") { NSApp.terminate(nil) }
            }.controlSize(.small)
        }.padding(20).frame(width: 350)
    }
}
