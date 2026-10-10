import SwiftUI

/// Browses the folders of a place (this Mac or an SSH host) to start a new
/// session in any of them. The Mac lists each folder on request, over ssh
/// for a host; nothing is listed ahead of time.
struct FolderBrowserView: View {
    let link: PhoneLink
    let host: RunHost
    /// Where it opens: above the latest project there, else the home folder.
    let start: String
    let picked: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var requestId: String?
    @State private var failed: String?

    /// The Mac's answer to the last request from here.
    private var listing: FolderListing? {
        guard let listing = link.folderListing, listing.requestId == requestId else { return nil }
        return listing
    }

    var body: some View {
        List {
            Section {
                Label(listing?.path ?? path, systemImage: host.isRemote ? "server.rack" : "laptopcomputer")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            Section {
                if let failed {
                    Label(failed, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if let listing, !listing.error.isEmpty {
                    Label(listing.error.prefix(1).uppercased() + listing.error.dropFirst(),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if let up = FolderListing.parent(of: path) { upRow(up) }
                } else if let listing {
                    if let up = FolderListing.parent(of: listing.path) { upRow(up) }
                    ForEach(listing.folders, id: \.self) { name in
                        Button {
                            open(listing.path == "/" ? "/\(name)" : "\(listing.path)/\(name)")
                        } label: {
                            HStack {
                                Label(name, systemImage: "folder.fill")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if listing.folders.isEmpty {
                        Text("No folders inside").foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(host.isRemote ? "Asking \(host.place)…" : "Asking your Mac…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle(host.isRemote ? host.place : "This Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Start here") {
                    guard let listing else { return }
                    picked(listing.path)
                    Haptics.success()
                    dismiss()
                }
                .bold()
                .disabled(listing == nil || !(listing?.error.isEmpty ?? false))
            }
        }
        .task {
            if requestId == nil { open(start) }
        }
    }

    private func upRow(_ up: String) -> some View {
        Button {
            open(up)
        } label: {
            Label(URL(fileURLWithPath: up).lastPathComponent.isEmpty ? "/" : "↑ \(URL(fileURLWithPath: up).lastPathComponent)",
                  systemImage: "arrow.turn.left.up")
                .foregroundStyle(Color.accentColor)
        }
    }

    /// Asks the Mac, then checks iCloud until the list is there (the push
    /// usually brings it first).
    private func open(_ folder: String) {
        path = folder
        failed = nil
        requestId = nil
        Task {
            guard let id = await link.listFolders(place: host.place, path: folder) else {
                failed = link.lastPong ?? "Couldn't reach iCloud."
                return
            }
            requestId = id
            for _ in 0..<15 {
                if listing != nil || requestId != id { return }
                try? await Task.sleep(for: .seconds(1.5))
                if listing != nil || requestId != id { return }
                _ = await link.handlePush()
            }
            if listing == nil, requestId == id { failed = "Your Mac didn't answer. Is Coucou running?" }
        }
    }
}
