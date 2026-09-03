import SwiftUI

/// The phone-side companion UI. The real experience is on the glasses; this
/// screen is for triggering a capture, watching status, and configuration.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                statusCard

                Spacer()

                solveButton

                if case .presenting(let solution) = model.coordinator.state {
                    presentingSummary(solution)
                }
                if case .failed(let message) = model.coordinator.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("AR Problem Solver")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                model.wearables.connectionSummary,
                systemImage: model.wearables.isAuthorized ? "eyeglasses" : "eyeglasses.slash"
            )
            .foregroundStyle(model.wearables.isAuthorized ? .green : .secondary)

            Label(
                model.hasAPIKey ? "Claude API key set" : "No Claude API key",
                systemImage: model.hasAPIKey ? "key.fill" : "key.slash"
            )
            .foregroundStyle(model.hasAPIKey ? .green : .orange)

            if model.wearables.requiresGlassesAppUpdate || model.wearables.requiresFirmwareUpdate {
                Button("Open Meta AI to update") {
                    Task {
                        if model.wearables.requiresGlassesAppUpdate {
                            await model.wearables.openGlassesAppUpdate()
                        } else {
                            await model.wearables.openFirmwareUpdate()
                        }
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var solveButton: some View {
        let state = model.coordinator.state
        Button {
            Task { await model.coordinator.solve() }
        } label: {
            HStack {
                if state.isBusy { ProgressView().tint(.white) }
                Text(buttonTitle(for: state))
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .buttonStyle(.borderedProminent)
        .disabled(state.isBusy || !model.wearables.isAuthorized)
    }

    private func buttonTitle(for state: SolverCoordinator.State) -> String {
        switch state {
        case .idle, .failed: return "Capture & Solve"
        case .capturing: return "Capturing photo…"
        case .thinking: return "Asking Claude…"
        case .presenting: return "On the glasses"
        }
    }

    private func presentingSummary(_ solution: Solution) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(solution.problem).font(.headline)
            Text("\(solution.steps.count) steps — navigate with the wristband")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("End session") { model.coordinator.reset() }
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
