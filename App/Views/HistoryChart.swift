import SwiftUI
import Charts

/// The two lines of the history chart. The temperature blocks above it wear the same marks, so
/// they double as its legend.
enum HistorySeries: String, CaseIterable {
    case cpu = "CPU", gpu = "GPU"

    /// A blue and an orange that stay apart for colour-blind readers, stepped for each appearance.
    var color: Color {
        switch self {
        case .cpu: Color(light: 0x2A78D6, dark: 0x3987E5)
        case .gpu: Color(light: 0xEB6834, dark: 0xD95926)
        }
    }

    func value(in sample: HistorySample) -> Double? {
        switch self {
        case .cpu: sample.cpu
        case .gpu: sample.gpu
        }
    }
}

private extension Color {
    init(light: Int, dark: Int) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Temperatures over the last few minutes. No axes: the caption gives the range, and the numbers
/// above give the current values.
struct HistoryChart: View {
    let samples: [HistorySample]
    let format: (Double?) -> String

    var body: some View {
        VStack(spacing: 2) {
            Chart {
                ForEach(HistorySeries.allCases, id: \.self) { series in
                    ForEach(samples) { sample in
                        if let value = series.value(in: sample) {
                            LineMark(x: .value("Time", sample.date), y: .value("°C", value),
                                     series: .value("Sensor", series.rawValue))
                                .foregroundStyle(series.color)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartXScale(domain: window)
            .chartYScale(domain: range.padded)
            .frame(height: 36)
            .accessibilityLabel("Temperature over the last \(Int(AppModel.historyWindow / 60)) minutes")

            HStack {
                Text("Last \(Int(AppModel.historyWindow / 60)) min")
                Spacer()
                Text("\(format(range.low)) – \(format(range.high))").monospacedDigit()
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Always the full window, so the lines grow in from the right as history builds up.
    private var window: ClosedRange<Date> {
        let end = samples.last?.date ?? Date()
        return end.addingTimeInterval(-AppModel.historyWindow)...end
    }

    private var range: (low: Double, high: Double, padded: ClosedRange<Double>) {
        let values = samples.flatMap { [$0.cpu, $0.gpu].compactMap { $0 } }
        guard let low = values.min(), let high = values.max() else { return (0, 0, 0...1) }
        // At least 10° tall, so a steady temperature draws a flat line rather than amplified noise.
        let pad = max((10 - (high - low)) / 2, 1)
        return (low, high, (low - pad)...(high + pad))
    }
}
