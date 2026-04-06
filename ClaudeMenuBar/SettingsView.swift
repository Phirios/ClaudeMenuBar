import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var monitor: UsageMonitor
    @State private var selectedInterval: Int = 300

    let intervals: [(String, Int)] = [
        ("1 min", 60),
        ("5 min", 300),
        ("15 min", 900),
        ("30 min", 1800),
    ]

    var body: some View {
        Form {
            Section("Authentication") {
                HStack {
                    Image(systemName: monitor.error == nil && monitor.currentUsage != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(monitor.error == nil && monitor.currentUsage != nil ? .green : .red)
                    Text("Claude Code keychain token")
                        .font(.subheadline)
                }
                Text("Uses your Claude Code login automatically - no config needed.")
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
                Text("Each check uses ~10 tokens (haiku) to read rate limit headers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("About") {
                Text("Claude Menu Bar")
                    .font(.headline)
                Text("Shows Claude Code rate limit usage (5h & 7d) in the menu bar using your existing Claude Code authentication.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 280)
        .onAppear {
            selectedInterval = Int(monitor.refreshInterval)
        }
    }
}
