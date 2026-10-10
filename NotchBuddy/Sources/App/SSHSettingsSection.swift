#if !APPSTORE
import SwiftUI

// MARK: - Settings → Agents → SSH
//
// One row per host of ~/.ssh/config: a tunnel switch (SSHTunnels) and the
// hook install for that host, with the same diff-then-confirm flow as the
// other agents. Nothing is written to the host's settings.json before the
// user clicks the confirm button.

struct SSHSettingsSection: View {
    @ObservedObject private var tunnels = SSHTunnels.shared
    @State private var hosts: [String] = SSHTunnels.configHosts()
    @State private var diffHost: String?
    @State private var pendingDiff = ""
    @State private var busyHost: String?
    @State private var message = ""

    var body: some View {
        GroupBox(String(localized: "Claude Code over SSH")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("~/.ssh/config · " + String(localized: "key authentication only"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)

                if hosts.isEmpty {
                    Text(String(localized: "No host in ~/.ssh/config."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                ForEach(hosts, id: \.self) { host in
                    row(host)
                }

                if let host = diffHost {
                    Text(host).font(.system(size: 11, weight: .semibold))
                    ScrollView {
                        Text(pendingDiff)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirm(host) }
                            .buttonStyle(.borderedProminent)
                            .disabled(busyHost != nil)
                        Button(String(localized: "Cancel")) { diffHost = nil; pendingDiff = "" }
                            .buttonStyle(.bordered)
                    }
                }

                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(6)
        }
        .onAppear { hosts = SSHTunnels.configHosts() }
    }

    private func row(_ host: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor(host))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(host).font(.system(size: 12, design: .monospaced))
                Text(statusText(host))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if busyHost == host { ProgressView().controlSize(.small) }
            Button(String(localized: tunnels.hookInstalled[host] == true ? "Update hook" : "Install hook")) {
                prepare(host)
            }
            .buttonStyle(.bordered)
            .disabled(busyHost != nil)
            Toggle("", isOn: Binding(
                get: { tunnels.enabledHosts.contains(host) },
                set: { tunnels.setEnabled($0, host: host) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private func dotColor(_ host: String) -> Color {
        switch tunnels.status[host] ?? .off {
        case .connected:  return .green
        case .connecting: return .orange
        case .failed:     return .red
        case .off:        return Color.secondary.opacity(0.4)
        }
    }

    private func statusText(_ host: String) -> String {
        switch tunnels.status[host] ?? .off {
        case .connected:          return String(localized: "Tunnel up")
        case .connecting:         return String(localized: "Connecting…")
        case .failed(let reason): return reason
        case .off:                return String(localized: "Tunnel off")
        }
    }

    private func prepare(_ host: String) {
        busyHost = host
        message = ""
        Task {
            defer { busyHost = nil }
            do {
                let diff = try await tunnels.prepareInstall(host: host)
                if diff.isEmpty {
                    diffHost = nil
                    message = "\(host): " + String(localized: "hooks already installed.")
                } else {
                    diffHost = host
                    pendingDiff = diff
                }
            } catch {
                message = "\(host): \(error.localizedDescription)"
            }
        }
    }

    private func confirm(_ host: String) {
        busyHost = host
        Task {
            defer { busyHost = nil }
            do {
                message = try await tunnels.confirmInstall(host: host)
                diffHost = nil
                pendingDiff = ""
            } catch {
                message = "\(host): \(error.localizedDescription)"
            }
        }
    }
}
#endif
