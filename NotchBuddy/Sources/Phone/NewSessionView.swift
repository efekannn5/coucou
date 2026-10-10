import SwiftUI

/// Starts a Claude Code session from the iPhone, in a folder the Mac listed
/// (on the Mac or on an SSH host): pick the project, write what to do, and
/// Face ID sends it. The Mac runs it in the background, like a message to
/// an open session, and the new session opens here.
struct NewSessionView: View {
    let link: PhoneLink
    /// Called with the new session's pill once the Mac has the message.
    let started: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var projectId: String?
    /// A folder picked in the folder browser, instead of a project.
    @State private var custom: (host: RunHost, path: String)?
    @State private var text = ""
    @State private var options = RunOptions()
    @State private var sending = false
    @State private var error: String?
    @State private var dictation = Dictation()
    @FocusState private var focused: Bool

    private var project: RunProject? { link.projects.first { $0.id == projectId } }

    /// The Mac first, then each SSH host, in the order last used; hosts
    /// with no project yet too.
    private var places: [(place: String, projects: [RunProject])] {
        var order: [String] = []
        for project in link.projects where !order.contains(project.place) { order.append(project.place) }
        for host in link.hosts where !order.contains(host.place) { order.append(host.place) }
        order.sort { ($0 == "Mac" ? 0 : 1) < ($1 == "Mac" ? 0 : 1) }
        return order.map { place in (place, link.projects.filter { $0.place == place }) }
    }

    private func host(for place: String) -> RunHost? {
        if let host = link.hosts.first(where: { $0.place == place }) { return host }
        // A Mac that doesn't list its hosts yet: from its projects.
        return link.projects.first { $0.place == place }.map { RunHost(place: $0.place, hostName: $0.hostName) }
    }

    /// Above the latest project of a place (its projects folder), else home.
    private func browseStart(_ projects: [RunProject]) -> String {
        guard let latest = projects.first else { return "~" }
        return FolderListing.parent(of: latest.cwd) ?? "~"
    }

    private var canStart: Bool {
        (project != nil || custom != nil) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(places, id: \.place) { group in
                    Section {
                        ForEach(group.projects) { project in
                            Button {
                                projectId = project.id
                                custom = nil
                                focused = true
                                Haptics.impact()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: project.isRemote ? "server.rack" : "laptopcomputer")
                                        .foregroundStyle(project.isRemote ? Color(hex: "#A3E635") : .secondary)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(project.name).foregroundStyle(.primary)
                                        Text(project.cwd)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                    Spacer()
                                    if project.id == projectId {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                        if let picked = custom, picked.host.place == group.place {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: picked.path).lastPathComponent)
                                    Text(picked.path)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                            }
                        }
                        if let host = host(for: group.place) {
                            NavigationLink {
                                FolderBrowserView(link: link, host: host, start: browseStart(group.projects)) { path in
                                    custom = (host, path)
                                    projectId = nil
                                }
                            } label: {
                                Label("Choose a folder…", systemImage: "folder.badge.plus")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    } header: {
                        Text(group.place == "Mac" ? "This Mac" : group.place)
                    }
                }

                Section {
                    TextField("What should Claude do?", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                    Button {
                        Task { await dictation.toggle(startingFrom: text) }
                    } label: {
                        Label(dictation.isRecording ? "Stop dictation" : "Dictate",
                              systemImage: dictation.isRecording ? "waveform" : "mic.fill")
                            .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                    }
                } header: {
                    Text("Instruction")
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                }

                Section("Options") {
                    Picker("Model", selection: $options.model) {
                        Text("Default").tag("")
                        ForEach(RunOptions.models, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    Toggle("Plan first, change nothing", isOn: $options.planFirst)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dictation.stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await start() }
                    } label: {
                        if sending { ProgressView() } else { Text("Start").bold() }
                    }
                    .disabled(!canStart)
                }
            }
            .onAppear {
                if projectId == nil && custom == nil { projectId = link.projects.first?.id }
            }
            .onChange(of: dictation.transcript) { _, words in
                if dictation.isRecording { text = dictation.prefix + words }
            }
        }
    }

    private func start() async {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        let folderName: String
        let isRemote: Bool
        let placeName: String
        if let custom {
            folderName = URL(fileURLWithPath: custom.path).lastPathComponent
            isRemote = custom.host.isRemote
            placeName = custom.host.place
        } else if let project {
            folderName = project.name
            isRemote = project.isRemote
            placeName = project.place
        } else {
            return
        }
        dictation.stop()
        focused = false
        sending = true
        defer { sending = false }
        error = nil
        let place = isRemote ? placeName : "your Mac"
        guard await OwnerCheck.confirm(reason: "Start Claude Code in \(folderName) on \(place)") else {
            error = "Face ID didn't confirm. Nothing was sent."
            Haptics.warning()
            return
        }
        let newPill: String?
        if let custom {
            newPill = await link.startSession(instruction, on: custom.host, in: custom.path, options: options)
        } else if let project {
            newPill = await link.startSession(instruction, in: project, options: options)
        } else {
            newPill = nil
        }
        if let pillId = newPill {
            Haptics.success()
            dismiss()
            started(pillId)
        } else {
            error = link.lastPong ?? "Couldn't reach iCloud."
            Haptics.error()
        }
    }
}
