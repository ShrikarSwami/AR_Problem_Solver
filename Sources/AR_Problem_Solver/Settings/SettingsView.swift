import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = KeychainStore.readAPIKey() ?? ""
    @State private var savedNotice = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Claude API key") {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        KeychainStore.writeAPIKey(apiKey)
                        savedNotice = true
                    }
                    if savedNotice {
                        Text("Saved to Keychain.").font(.caption).foregroundStyle(.green)
                    }
                    if !Secrets.anthropicAPIKey.isEmpty {
                        Text("A build-time key from Secrets.xcconfig is also present; the Keychain key wins.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Glasses") {
                    LabeledContent("Registration", value: "\(model.wearables.registrationState)")
                    if model.wearables.deviceNames.isEmpty {
                        Text("No devices").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.wearables.deviceNames, id: \.self) { Text($0) }
                    }
                    if model.wearables.isRegistered {
                        Button("Disconnect") { Task { await model.wearables.disconnect() } }
                    } else {
                        Button("Connect glasses") { Task { await model.wearables.connect() } }
                    }
                }

                if let error = model.wearables.lastError {
                    Section("Last error") {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
