import SwiftUI
import AppKit
import ServiceManagement
import FanCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: $model.selection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 230)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.status.active ? "Active" : "Apple Automatic", systemImage: model.status.active ? "fan.fill" : "checkmark.shield")
                        .font(.caption.weight(.medium))
                    Text(model.preview ? "Preview mode" : "App-triggered cooling").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
        } detail: {
            Group {
                switch model.selection {
                case .apps: AppsView()
                case .curves: CurvesView()
                case .general: GeneralView()
                }
            }
            .navigationTitle(model.selection.rawValue)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(model.paused ? "Resume Automation" : "Pause Automation", systemImage: model.paused ? "play" : "pause") { model.togglePause() }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .alert("Auto Fan Control", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct PageHeading: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct StatusCard: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: model.status.active ? "fan.fill" : "checkmark.shield").font(.title2).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.stateTitle).font(.headline)
                Text(model.stateDetail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}
struct AppsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "Cooling that follows your apps.", subtitle: "Choose a curve for each app. Apple takes over when you’re done.")
                StatusCard()
                HStack {
                    Text("App Rules").font(.title3.weight(.semibold))
                    Text("\(model.configuration.rules.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Apps…", systemImage: "plus") { model.addApp() }.buttonStyle(.borderedProminent).disabled(model.fans.isEmpty)
                }
                if model.configuration.rules.isEmpty {
                    ContentUnavailableView {
                        Label("Your apps, your cooling", systemImage: "app.badge")
                    } description: {
                        Text(model.fans.isEmpty ? "Connect the helper in General to detect fan limits, then add your apps." : "Add a game or demanding app and choose Gaming, Performance, or your own curve.")
                    } actions: {
                        if model.fans.isEmpty { Button("Open General") { model.selection = .general } }
                        else { Button("Add Your First App…") { model.addApp() } }
                    }.frame(minHeight: 230)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.configuration.rules) { rule in
                            RuleRow(rule: rule)
                            if rule.id != model.configuration.rules.last?.id { Divider().padding(.leading, 60) }
                        }
                    }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                }
                Label("When multiple apps run, each fan uses the highest requested RPM. Background and minimized apps count too.", systemImage: "square.stack.3d.up")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(28)
        }
    }
}
struct RuleRow: View {
    @EnvironmentObject private var model: AppModel
    let rule: AppRule
    var body: some View {
        HStack(spacing: 12) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 34, height: 34).accessibilityHidden(true)
            } else { Image(systemName: "app.fill").font(.system(size: 30)).foregroundStyle(.secondary).frame(width: 34).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(rule.name).font(.headline)
                    if model.activeRules.contains(where: { $0.id == rule.id }) { Text("Running").font(.caption2).foregroundStyle(.green) }
                }
                Text(rule.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(rule.bundleID)
            }
            Spacer(minLength: 4)
            Picker("Preset for \(rule.name)", selection: Binding(get: { rule.presetID }, set: { var updated = rule; updated.presetID = $0; model.changeRule(updated) })) {
                ForEach(model.configuration.presets) { Text($0.name).tag($0.id) }
            }.labelsHidden().frame(width: 150)
            Toggle("Enable \(rule.name)", isOn: Binding(get: { rule.enabled }, set: { var updated = rule; updated.enabled = $0; model.changeRule(updated) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
            Button("Remove \(rule.name)", systemImage: "minus.circle") { model.removeRule(rule.id) }.labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
        }.padding(16)
    }
}

struct GeneralView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section {
                LabeledContent("Model", value: model.hardware?.model ?? "Not detected")
                LabeledContent("Control", value: model.stateTitle)
                Text(model.hardwareMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if model.preview { Label("Preview values are illustrative. No fans are controlled.", systemImage: "eye") }
                ForEach(model.fans) { fan in LabeledContent(fan.name, value: "\(Int(fan.minimumRPM))–\(Int(fan.maximumRPM)) RPM") }
            } header: { Text("Hardware") }
            Section {
                LabeledContent("Privileged Helper", value: model.helperRegistration)
                HStack {
                    Button("Register Helper") { model.registerHelper() }.disabled(model.preview)
                    Button("Connect / Refresh") { model.refreshRegistration(); Task { await model.connectHelper() } }.disabled(model.preview)
                    Button("System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
                Text("Register the signed helper, then allow it in Login Items & Extensions. Hardware commissioning must succeed before automation can start.").font(.caption).foregroundStyle(.secondary)
                Button("Unregister Helper", role: .destructive) { Task { await model.unregisterHelper() } }.disabled(!model.helperConnected || model.preview)
            } header: { Text("Setup") }
            Section {
                if model.configuration.reviewedHardware {
                    Label("Fan limits and curves reviewed for this hardware", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Inspect every fan’s curve before enabling automation. Hardware or fan-limit changes require another review.")
                    HStack {
                        Button("Review Fan Curves") { model.selection = .curves }.disabled(model.fans.isEmpty)
                        Button("I’ve Reviewed All Curves") { model.reviewHardware() }.disabled(model.fans.isEmpty)
                    }
                }
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLogin)).disabled(model.preview)
                Toggle("Snap curve points to 1°C and 100 RPM", isOn: Binding(get: { model.configuration.snapToGrid }, set: { model.configuration.snapToGrid = $0; model.persist() }))
            } header: { Text("Automation") }
            Section {
                Text("Gaming balances noise and cooling. Performance ramps earlier. Presets adjust fan targets only; CPU and GPU power settings stay under macOS control.")
                Text("When inactive, Auto Fan Control stops sensor polling and control timers. Closing this window keeps app observation running in the menu bar.")
            } header: { Text("About Auto Fan Control") }.font(.callout).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
