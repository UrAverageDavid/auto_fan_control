import SwiftUI
import FanCore

struct CurveGraph: View {
    @Binding var editor: CurveEditor
    let fan: Fan
    let snap: Bool
    @Binding var selectedPoint: UUID?
    var temperature: Double?
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focusedPoint: UUID?
    private var points: [CurvePoint] { editor.draft.curves.first(where: { $0.fanID == fan.id })?.points ?? [] }
    var body: some View {
        GeometryReader { geometry in
            let left: CGFloat = 55, top: CGFloat = 12
            let width = max(1, geometry.size.width - left - 20)
            let height = max(1, geometry.size.height - top - 38)
            let range = max(1, fan.maximumRPM - fan.minimumRPM)
            let x: (Double) -> CGFloat = { left + CGFloat(min(110, max(0, $0)) / 110) * width }
            let y: (Double) -> CGFloat = { top + height - CGFloat((fan.clamp($0) - fan.minimumRPM) / range) * height }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for fraction in [0.0, 0.25, 0.5, 0.75, 1] {
                        let rpm = fan.minimumRPM + fraction * range, yy = y(rpm)
                        var grid = Path(); grid.move(to: CGPoint(x: left, y: yy)); grid.addLine(to: CGPoint(x: left + width, y: yy))
                        context.stroke(grid, with: .color(.secondary.opacity(contrast == .increased ? 0.55 : 0.18)), lineWidth: 1)
                        context.draw(Text("\(Int(rpm))").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary), at: CGPoint(x: left - 8, y: yy), anchor: .trailing)
                    }
                    for t in [0.0, 20, 40, 60, 80, 100, 110] {
                        context.draw(Text("\(Int(t))°").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary), at: CGPoint(x: x(t), y: top + height + 18))
                    }
                    var safe = Path(); safe.move(to: CGPoint(x: x(85), y: top)); safe.addLine(to: CGPoint(x: x(85), y: top + height))
                    context.stroke(safe, with: .color(.orange.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    if let temperature {
                        var live = Path(); live.move(to: CGPoint(x: x(temperature), y: top)); live.addLine(to: CGPoint(x: x(temperature), y: top + height))
                        context.stroke(live, with: .color(.green), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                    }
                    if let first = points.first, let last = points.last {
                        var line = Path(); line.move(to: CGPoint(x: x(0), y: y(first.targetRPM)))
                        for point in points where point.temperatureC.isFinite && point.targetRPM.isFinite { line.addLine(to: CGPoint(x: x(point.temperatureC), y: y(point.targetRPM))) }
                        line.addLine(to: CGPoint(x: x(110), y: y(last.targetRPM)))
                        var fill = line; fill.addLine(to: CGPoint(x: x(110), y: top + height)); fill.addLine(to: CGPoint(x: x(0), y: top + height)); fill.closeSubpath()
                        context.fill(fill, with: .linearGradient(Gradient(colors: [.accentColor.opacity(0.16), .accentColor.opacity(0.02)]), startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: top + height)))
                        context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: contrast == .increased ? 3 : 2.5, lineJoin: .round))
                    }
                }.accessibilityHidden(true)
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    Button {
                        selectedPoint = point.id; focusedPoint = point.id
                    } label: {
                        Circle().fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: selectedPoint == point.id ? 4 : 2.5))
                            .frame(width: 12, height: 12).padding(8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focused($focusedPoint, equals: point.id)
                    .position(x: x(point.temperatureC.isFinite ? point.temperatureC : 0), y: y(point.targetRPM.isFinite ? point.targetRPM : fan.maximumRPM))
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("plot")).onChanged { event in
                        selectedPoint = point.id
                        editor.move(fan: fan, pointID: point.id,
                                    temperature: Double((event.location.x - left) / width) * 110,
                                    rpm: fan.minimumRPM + Double((top + height - event.location.y) / height) * range, snap: snap)
                    })
                    .onMoveCommand { direction in
                        selectedPoint = point.id
                        let dt: Double = direction == .left ? -1 : direction == .right ? 1 : 0
                        let dr: Double = direction == .down ? -100 : direction == .up ? 100 : 0
                        editor.move(fan: fan, pointID: point.id, temperature: point.temperatureC + dt, rpm: point.targetRPM + dr, snap: false)
                    }
                    .accessibilityLabel("Point \(index + 1), \(fan.name)")
                    .accessibilityValue("\(point.temperatureC.formatted(.number.precision(.fractionLength(0...1)))) degrees Celsius, \(point.targetRPM.formatted(.number.precision(.fractionLength(0...1)))) RPM")
                    .accessibilityHint("Use arrow keys to change temperature and RPM, or use the numeric fields below.")
                    .accessibilityAdjustableAction { direction in
                        let delta: Double = direction == .increment ? 100 : -100
                        editor.move(fan: fan, pointID: point.id, temperature: point.temperatureC, rpm: point.targetRPM + delta, snap: false)
                    }
                }
            }.coordinateSpace(name: "plot")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Temperature to RPM curve for \(fan.name)")
    }
}
