import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var monitor: UsageMonitor
    @State private var selectedInterval: Int = 300
    @State private var selectedProvider: AIProvider = .claude

    let intervals: [(String, Int)] = [
        ("1 min", 60),
        ("5 min", 300),
        ("15 min", 900),
        ("30 min", 1800),
    ]

    var body: some View {
        Form {
            Section("Provider") {
                Picker("AI CLI", selection: $selectedProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: selectedProvider) { _, newValue in
                    monitor.selectedProvider = newValue
                }
            }

            Section("Authentication") {
                HStack {
                    Image(systemName: monitor.error == nil && monitor.currentUsage != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(monitor.error == nil && monitor.currentUsage != nil ? .green : .red)
                    Text(monitor.selectedProvider.tokenLabel)
                        .font(.subheadline)
                }
                Text(authDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Refresh Interval") {
                Picker("Check every", selection: $selectedInterval) {
                    ForEach(intervals, id: \.1) { label, val in
                        Text(label).tag(val)
                    }
                }
                .onChange(of: selectedInterval) { _, newValue in
                    monitor.refreshInterval = TimeInterval(newValue)
                }
                Text(refreshDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("About") {
                Text("AI Limit Counter")
                    .font(.headline)
                Text("Shows Claude Code or Codex rate limit usage in the menu bar.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 340)
        .onAppear {
            selectedInterval = Int(monitor.refreshInterval)
            selectedProvider = monitor.selectedProvider
        }
    }

    private var authDescription: String {
        switch monitor.selectedProvider {
        case .claude:
            return "Uses your Claude Code login automatically - no config needed."
        case .codex:
            return "Reads the latest Codex rate-limit event from local session logs."
        }
    }

    private var refreshDescription: String {
        switch monitor.selectedProvider {
        case .claude:
            return "Each check uses ~10 tokens (haiku) to read rate limit headers."
        case .codex:
            return "Codex checks read local logs only and do not make an API request."
        }
    }
}
