import MacPerfMonitorCore
import SwiftUI

/// A compact mirrored network-throughput chart for the menu-bar dropdown:
/// download rises upward from a centre line (green), upload drops downward (red),
/// both scaled to their shared peak so the two directions always read clearly —
/// unlike a single overlaid line where upload disappears under a much larger
/// download. Uses the same line + soft-area body as `MenuTrendChart` so all the
/// menu-bar headers share one visual style, with the shared peak rate labelled at
/// the top-left as the marked axis. Canvas-drawn, cheap to redraw at 1 Hz.
struct NetworkUpDownChart: View {
    let download: [Double]
    let upload: [Double]
    var sampleCapacity: Int? = nil

    var body: some View {
        let peak = max(download.max() ?? 0, upload.max() ?? 0, 1)
        let upper = peak * 1.2
        return MenuBitmapChart(
            model: .init(
                series: [
                    .init(values: download, color: NetworkStyle.download),
                    .init(values: upload, color: NetworkStyle.upload, downward: true),
                ],
                domain: -upper...upper, capacity: sampleCapacity, ticks: [0],
                caption: t("%@ peak", ByteFormat.rate(peak)))
        )
        .accessibilityHidden(true)
    }
}
