import SwiftUI
import Charts

/// Fan curve chart with draggable points.
struct CurveEditor: View {
    @Binding var curve: Curve
    var liveTemp: Double?
    var editable: Bool
    @State private var dragging: UUID?
    @State private var selected: UUID?

    private static let tempRange = 30.0...100.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chart.frame(height: 180)
            if editable {
                HStack {
                    Button("Add Point", action: addPoint)
                        .disabled(curve.points.count >= Curve.maxPoints)
                    Button("Remove Point", action: removeSelected)
                        .disabled(selectedPoint == nil || curve.points.count <= Curve.minPoints)
                    Spacer()
                    if let p = selectedPoint {
                        Text("\(Int(p.temp))° → \(Int((p.percent * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var selectedPoint: CurvePoint? { curve.points.first { $0.id == selected } }

    private var chart: some View {
        let points = curve.points.sorted { $0.temp < $1.temp }
        return Chart {
            ForEach(points) { p in
                LineMark(x: .value("°C", p.temp), y: .value("%", p.percent * 100))
                    .interpolationMethod(.linear)
                PointMark(x: .value("°C", p.temp), y: .value("%", p.percent * 100))
                    .symbolSize(dragging == p.id ? 120 : (selected == p.id ? 90 : 60))
            }
            if let t = liveTemp {
                RuleMark(x: .value("Now", min(max(t, Self.tempRange.lowerBound), Self.tempRange.upperBound)))
                    .foregroundStyle(.orange.opacity(0.6))
                    .annotation(position: .top) { Text("\(Int(t))°").font(.caption2) }
            }
        }
        .chartXScale(domain: Self.tempRange)
        .chartYScale(domain: 0...100)
        .chartXAxisLabel("Temperature °C")
        .chartYAxisLabel("Fan %")
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(editable ? drag(proxy: proxy, geo: geo) : nil)
            }
        }
    }

    private func drag(proxy: ChartProxy, geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard let frame = proxy.plotFrame else { return }
                let origin = geo[frame].origin
                let loc = CGPoint(x: v.location.x - origin.x, y: v.location.y - origin.y)
                guard let (t, pct) = proxy.value(at: loc, as: (Double, Double).self) else { return }

                if dragging == nil {   // pick nearest point on drag start
                    dragging = curve.points.min { abs($0.temp - t) + abs($0.percent * 100 - pct) / 2
                                                < abs($1.temp - t) + abs($1.percent * 100 - pct) / 2 }?.id
                    selected = dragging
                }
                guard let id = dragging, let i = curve.points.firstIndex(where: { $0.id == id }) else { return }
                curve.points[i].temp = min(max(t.rounded(), Self.tempRange.lowerBound), Self.tempRange.upperBound)
                curve.points[i].percent = min(max((pct / 100 * 20).rounded() / 20, 0), 1)   // 5% steps
            }
            .onEnded { _ in dragging = nil }
    }

    /// Splits the widest temperature gap, on the existing line.
    private func addPoint() {
        let p = curve.points.sorted { $0.temp < $1.temp }
        guard p.count < Curve.maxPoints else { return }
        let gap = zip(p, p.dropFirst()).max { $0.1.temp - $0.0.temp < $1.1.temp - $1.0.temp }
        let temp = gap.map { (($0.0.temp + $0.1.temp) / 2).rounded() } ?? 60
        let new = CurvePoint(temp: temp, percent: curve.percent(at: temp))
        curve.points.append(new)
        selected = new.id
    }

    private func removeSelected() {
        guard curve.points.count > Curve.minPoints, let id = selected else { return }
        curve.points.removeAll { $0.id == id }
        selected = nil
    }
}
