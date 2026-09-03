import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = KeychainStore.readAPIKey() ?? ""
    @State private var savedNotice = false
    @State private var connectionCheck: ClaudeConnection?
    @State private var checkingConnection = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        KeychainStore.writeAPIKey(apiKey)
                        apiKey = KeychainStore.readAPIKey() ?? ""
                        savedNotice = true
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if savedNotice {
                        Text("Saved to the Keychain on this device.").font(.caption).foregroundStyle(.green)
                    }
                    if !Secrets.anthropicAPIKey.isEmpty {
                        Text("A build-time key from Secrets.xcconfig is also present; the Keychain key takes priority.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task {
                            checkingConnection = true
                            connectionCheck = await model.checkClaudeConnection()
                            checkingConnection = false
                        }
                    } label: {
                        HStack {
                            if checkingConnection { ProgressView() }
                            Text("Test Claude connection")
                        }
                    }
                    .disabled(checkingConnection)

                    if let check = connectionCheck {
                        Label(check.summary, systemImage: check.isOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(check.isOK ? .green : .red)
                    }
                } header: {
                    Text("Claude API key")
                } footer: {
                    Text("Stored only in this device's Keychain — never synced or committed. This is the recommended way to supply the key. The connection test uses GET /v1/models and is not billed.")
                }

                Section("Glasses") {
                    LabeledContent("Status", value: model.wearables.connectionSummary)
                    ForEach(model.wearables.deviceNames, id: \.self) { Text($0) }
                    if model.wearables.isAuthorized {
                        Button("Disconnect") { Task { await model.wearables.disconnect() } }
                    } else {
                        Button(model.wearables.isConnecting ? "Connecting…" : "Connect glasses") {
                            Task { await model.wearables.connect() }
                        }
                        .disabled(model.wearables.isConnecting)
                    }
                    if model.wearables.requiresGlassesAppUpdate {
                        Button("Update the glasses app in Meta AI") {
                            Task { await model.wearables.openGlassesAppUpdate() }
                        }
                    }
                    if model.wearables.requiresFirmwareUpdate {
                        Button("Update glasses firmware in Meta AI") {
                            Task { await model.wearables.openFirmwareUpdate() }
                        }
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
