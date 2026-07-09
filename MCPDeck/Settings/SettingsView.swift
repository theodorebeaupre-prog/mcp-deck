import SwiftUI
import MCPDeckCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Health checks") {
                Toggle("Check all servers at launch", isOn: $model.autoCheckOnLaunch)
                LabeledContent("Timeout") {
                    HStack {
                        Slider(value: $model.checkTimeout, in: 2...30, step: 1) {
                            Text("Timeout")
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        Text("\(Int(model.checkTimeout)) s")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            Section {
                if model.uniqueServers.isEmpty {
                    Text("No servers found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.uniqueServers, id: \.healthKey) { entry in
                        Toggle(entry.name, isOn: Binding(
                            get: { !model.excludedFromAutoCheck.contains(entry.healthKey) },
                            set: { include in
                                if include {
                                    model.excludedFromAutoCheck.remove(entry.healthKey)
                                } else {
                                    model.excludedFromAutoCheck.insert(entry.healthKey)
                                }
                            }
                        ))
                    }
                }
            } header: {
                Text("Checked at launch")
            } footer: {
                Text("Unchecked servers are skipped by the automatic launch check. Manual checks always work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
