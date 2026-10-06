import SwiftUI

struct SensorsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading) {
            // The table is created only once there are rows. Filling an empty table right after
            // it appears makes AppKit report a reentrant table-view update.
            if model.snapshot.raw.isEmpty {
                Text("Reading sensors…").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.snapshot.raw) {
                    TableColumn("Key", value: \.id)
                    TableColumn("Group", value: \.kind)
                    TableColumn("Value") { Text(model.format(temp: $0.value)).monospacedDigit() }
                }
            }
            Text("Raw SMC temperature keys. Presets follow the CPU and GPU groups; Hottest is the highest of both.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { model.setRawSensors(true) }
        .onDisappear { model.setRawSensors(false) }
    }
}
