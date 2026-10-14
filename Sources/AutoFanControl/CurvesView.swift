import SwiftUI
import FanCore

struct CurvesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editor: CurveEditor?
    @State private var fanID = ""
    @State private var pendingPreset: UUID?
    @State private var showDiscard = false
    @State private var selectedPoint: UUID?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var fan: Fan? { model.fans.first(where: { $0.id == fanID }) ?? model.fans.first }
    private var validationError: String? {
        guard let editor else { return nil }
        do { try editor.draft.validate(fans: model.fans); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        Group {
            if model.fans.isEmpty {
                ContentUnavailableView {
                    Label("Detect your fans first", systemImage: "fan")
                } description: {
                    Text("Fan curves use the limits reported by your Mac. Connect the helper in General to discover supported hardware.")
                } actions: { Button("Open General") { model.selection = .general } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        PageHeading(title: "Find your balance.", subtitle: "Shape the response. Keep the control.")
                        presetControls
                        if let fan, let editor {
                            readings(fan)
                            HStack {
                                Picker("Fan", selection: $fanID) { ForEach(model.fans) { Text($0.name).tag($0.id) } }.frame(maxWidth: 260)
                                Spacer()
                                Text("\(Int(fan.minimumRPM))–\(Int(fan.maximumRPM)) RPM").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text("Temperature response").font(.headline)
                                    Spacer()
                                    Text(model.configuration.snapToGrid ? "1°C / 100 RPM snapping" : "Free positioning").font(.caption).foregroundStyle(.secondary)
                                }
                                CurveGraph(editor: Binding(get: { self.editor ?? editor }, set: { self.editor = $0 }), fan: fan,
                                           snap: model.configuration.snapToGrid, selectedPoint: $selectedPoint,
                                           temperature: model.status.active ? model.status.sample?.temperatureC : nil)
                                    .frame(height: 260)
                                Text("Drag a point, use arrow keys on a selected point, or enter exact values below.").font(.caption).foregroundStyle(.secondary)
                            }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                            pointTable(fan, editor)
                            if let validationError {
                                Label(validationError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            } else {
                                Label("Maximum RPM reached by 85°C", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Restore Preset Defaults") { self.editor?.restoreDefaults(fans: model.fans) }
                                Button("Copy to Other Fans") { self.editor?.copy(from: fan, fans: model.fans) }.disabled(model.fans.count < 2)
                                Spacer()
                                Button("Cancel") { self.editor?.cancel() }.disabled(!editor.isDirty).keyboardShortcut(.cancelAction)
                                Button("Apply") { apply() }.buttonStyle(.borderedProminent).disabled(!editor.isDirty || validationError != nil).keyboardShortcut("s", modifiers: .command)
                            }.controlSize(.regular)
                            Text(editor.isDirty ? "Unapplied changes. Active control continues using the saved curve." : "Changes reach hardware only after Apply and while a configured app is running.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(28)
                }
            }
        }
        .onAppear { if editor == nil { if let preset = model.configuration.presets.first { editor = CurveEditor(preset) }; fanID = model.fans.first?.id ?? "" } }
        .onChange(of: model.hardware) { _, _ in editor = model.configuration.presets.first.map(CurveEditor.init); fanID = model.fans.first?.id ?? "" }
        .confirmationDialog("Discard unapplied changes?", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { if let pendingPreset { load(pendingPreset) } }
            Button("Keep Editing", role: .cancel) { pendingPreset = nil }
        }
    }
    private var presetControls: some View {
        HStack(spacing: 14) {
            Picker("Preset", selection: Binding(get: { editor?.draft.id ?? UUID() }, set: { id in
                if editor?.isDirty == true { pendingPreset = id; showDiscard = true } else { load(id) }
            })) { ForEach(model.configuration.presets) { Text($0.name).tag($0.id) } }.frame(maxWidth: 270)
            if let editor {
                Button("Duplicate", systemImage: "plus.square.on.square") { load(model.duplicatePreset(editor.original)) }
                    .disabled(editor.isDirty).help("Create a custom preset from the saved curve")
                if editor.draft.kind == .custom {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        model.removePreset(editor.draft.id)
                        if let first = model.configuration.presets.first { load(first.id) }
                    }.disabled(model.configuration.rules.contains(where: { $0.presetID == editor.draft.id }))
                }
            }
            Spacer(minLength: 0)
        }.padding(12).modifier(ControlSurface(reduceTransparency: reduceTransparency))
    }
    private func readings(_ fan: Fan) -> some View {
        HStack(spacing: 30) {
            VStack(alignment: .leading, spacing: 6) {
                Text("HOTTEST CPU / GPU").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if model.status.active, let sample = model.status.sample {
                    Text("\(sample.temperatureC, specifier: "%.0f")°C").font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit()
                } else { Text("Apple Automatic").font(.title3.weight(.medium)) }
            }
            ForEach(model.fans) { fan in
                VStack(alignment: .leading, spacing: 6) {
                    Text(fan.name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    if model.status.active, let rpm = model.status.sample?.actualRPM[fan.id] {
                        Text("\(Int(rpm)) RPM").font(.title3.weight(.medium)).monospacedDigit()
                    } else { Text("Apple Automatic").font(.callout).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 2)
    }
    private func pointTable(_ fan: Fan, _ editor: CurveEditor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if editor.draft.kind == .custom {
                TextField("Preset name", text: Binding(get: { self.editor?.draft.name ?? "" }, set: { self.editor?.draft.name = $0 })).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Curve Points").font(.headline)
                Spacer()
                Button("Add Point", systemImage: "plus") { self.editor?.addPoint(fan: fan) }
            }
            Grid(horizontalSpacing: 18, verticalSpacing: 9) {
                GridRow {
                    Text("Point").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Temperature (°C)")
                    Text("Target (RPM)")
                    Color.clear.frame(width: 24, height: 1)
                }.font(.caption).foregroundStyle(.secondary)
                if let index = editor.draft.curves.firstIndex(where: { $0.fanID == fan.id }) {
                    ForEach(Array(editor.draft.curves[index].points.enumerated()), id: \.element.id) { offset, point in
                        GridRow {
                            HStack {
                                Circle().fill(selectedPoint == point.id ? Color.accentColor : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                                Text(String(format: "%02d", offset + 1)).monospacedDigit()
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            TextField("Point \(offset + 1) temperature", value: pointBinding(fanID: fan.id, pointID: point.id, temperature: true), format: .number.precision(.fractionLength(0...1)))
                                .textFieldStyle(.roundedBorder).frame(width: 150)
                            TextField("Point \(offset + 1) RPM", value: pointBinding(fanID: fan.id, pointID: point.id, temperature: false), format: .number.precision(.fractionLength(0...1)))
                                .textFieldStyle(.roundedBorder).frame(width: 150)
                            Button("Remove point \(offset + 1)", systemImage: "minus.circle") { self.editor?.removePoint(fanID: fan.id, pointID: point.id) }
                                .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(editor.draft.curves[index].points.count <= 2)
                        }
                    }
                }
            }
        }
    }
    private func pointBinding(fanID: String, pointID: UUID, temperature: Bool) -> Binding<Double> {
        Binding(get: {
            guard let p = editor?.draft.curves.first(where: { $0.fanID == fanID })?.points.first(where: { $0.id == pointID }) else { return 0 }
            return temperature ? p.temperatureC : p.targetRPM
        }, set: { value in
            guard let c = editor?.draft.curves.firstIndex(where: { $0.fanID == fanID }),
                  let p = editor?.draft.curves[c].points.firstIndex(where: { $0.id == pointID }) else { return }
            if temperature { editor?.draft.curves[c].points[p].temperatureC = value }
            else { editor?.draft.curves[c].points[p].targetRPM = value }
            selectedPoint = pointID
        })
    }
    private func load(_ id: UUID) { if let preset = model.configuration.presets.first(where: { $0.id == id }) { editor = CurveEditor(preset); selectedPoint = nil } }
    private func apply() {
        do { if let preset = try editor?.apply(fans: model.fans) { model.savePreset(preset) } }
        catch { model.error = error.localizedDescription }
    }
}
private struct ControlSurface: ViewModifier {
    var reduceTransparency: Bool
    func body(content: Content) -> some View {
        if reduceTransparency { content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)) }
        else { GlassEffectContainer { content.glassEffect(.regular, in: .rect(cornerRadius: 12)) } }
    }
}
