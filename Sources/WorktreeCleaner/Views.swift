import SwiftUI
import WorktreeCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("recentHours") private var recentHours = 6
    @State private var confirmingRemoval = false
    @State private var buildFolderTarget: Worktree?

    var body: some View {
        let cutoff = AppModel.recentCutoff(hours: recentHours)
        VStack(spacing: 0) {
            SummaryBar(cutoff: cutoff)
            Divider()
            if let result = model.result {
                ScrollView {
                    GroupsView(result: result, cutoff: cutoff, buildFolderTarget: $buildFolderTarget)
                        .padding(16)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(model.progress.isEmpty ? "Scanning…" : model.progress).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            ActionBar(confirmingRemoval: $confirmingRemoval)
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await model.scan() } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .disabled(model.busy)
                    .help("Scan again (⌘R)")
            }
        }
        .task { if model.result == nil { await model.scan() } }
        .confirmationDialog(removalTitle, isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove \(model.selection.count == 1 ? "Worktree" : "\(model.selection.count) Worktrees")", role: .destructive) {
                Task { await model.removeSelected() }
            }
        } message: {
            Text("Frees about \(Format.bytes(model.selected.reduce(0) { $0 + $1.totalBytes })). Each folder is deleted, including its build folder. Branches and commits stay in git. Each worktree is checked again first and skipped if anything changed.")
        }
        .confirmationDialog(
            "Delete the build folder of \(buildFolderTarget?.name ?? "")?",
            isPresented: Binding(get: { buildFolderTarget != nil }, set: { if !$0 { buildFolderTarget = nil } }),
            titleVisibility: .visible,
            presenting: buildFolderTarget
        ) { worktree in
            Button("Delete Build Folder", role: .destructive) { Task { await model.removeBuildFolder(worktree) } }
        } message: { worktree in
            Text("Frees about \(Format.bytes(worktree.buildBytes)). Sources and unsaved changes stay. The next build in this worktree starts over, helped by the shared compiler cache.")
        }
    }

    private var removalTitle: String {
        model.selection.count == 1 ? "Remove 1 worktree?" : "Remove \(model.selection.count) worktrees?"
    }
}

struct SummaryBar: View {
    @Environment(AppModel.self) private var model
    let cutoff: Date

    var body: some View {
        let all = model.result?.worktrees ?? []
        let safe = model.members(of: .safe, cutoff: cutoff)
        HStack(spacing: 28) {
            Stat(title: "Free on disk", value: model.freeBytes.map(Format.bytes) ?? "—")
            Stat(title: "In \(all.count) worktrees", value: Format.bytes(all.reduce(0) { $0 + $1.totalBytes }))
            Stat(title: "Safe to remove", value: Format.bytes(safe.reduce(0) { $0 + $1.totalBytes }), tint: .green)
            Spacer()
            if model.scanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.progress).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if let scanned = model.result?.scannedAt {
                Text("Scanned \(scanned, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct Stat: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
        }
    }
}

struct GroupsView: View {
    @Environment(AppModel.self) private var model
    let result: ScanResult
    let cutoff: Date
    @Binding var buildFolderTarget: Worktree?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
            if result.worktrees.isEmpty {
                Text("No worktrees found besides the main checkouts.").foregroundStyle(.secondary)
            }
            ForEach(WorktreeGroup.allCases) { group in
                let members = model.members(of: group, cutoff: cutoff)
                if !members.isEmpty {
                    GroupSection(group: group, members: members, buildFolderTarget: $buildFolderTarget)
                }
            }
            if !result.caches.isEmpty {
                CachesSection(caches: result.caches)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GroupSection: View {
    @Environment(AppModel.self) private var model
    let group: WorktreeGroup
    let members: [Worktree]
    @Binding var buildFolderTarget: Worktree?

    var body: some View {
        let ids = Set(members.map(\.id))
        let allSelected = ids.isSubset(of: model.selection)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.title).font(.title3.weight(.semibold))
                Text(group == .missing ? "\(members.count)" : "\(members.count) · \(Format.bytes(members.reduce(0) { $0 + $1.totalBytes }))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if group.canRemove {
                    Button(allSelected ? "Select None" : "Select All") {
                        if allSelected { model.selection.subtract(ids) } else { model.selection.formUnion(ids) }
                    }
                    .buttonStyle(.link)
                    .disabled(model.busy)
                }
                if group == .missing {
                    Button("Prune Records") { Task { await model.pruneMissing() } }
                        .disabled(model.busy)
                }
            }
            Text(group.explanation).font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(members) { worktree in
                    WorktreeRow(worktree: worktree, group: group, buildFolderTarget: $buildFolderTarget)
                    if worktree.id != members.last?.id { Divider().padding(.leading, 12) }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

struct WorktreeRow: View {
    @Environment(AppModel.self) private var model
    let worktree: Worktree
    let group: WorktreeGroup
    @Binding var buildFolderTarget: Worktree?

    private var isSelected: Bool { model.selection.contains(worktree.id) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if group.canRemove {
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(model.busy)
            } else {
                Image(systemName: icon).foregroundStyle(iconTint).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(worktree.name).fontWeight(.medium)
                    Badge(text: worktree.owner.label, tint: .secondary)
                    Text(worktree.branch ?? "detached HEAD").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(Format.home(worktree.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    ForEach(badges, id: \.text) { Badge(text: $0.text, tint: $0.tint) }
                }
            }
            Spacer(minLength: 12)
            if !worktree.missing {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.bytes(worktree.totalBytes)).font(.body.monospacedDigit()).fontWeight(.medium)
                    if worktree.buildBytes > 0 {
                        Text("build \(Format.bytes(worktree.buildBytes))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("changed \(Format.ago(worktree.lastChange))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if group.canRemove && !model.busy { toggle() } }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path) }
                .disabled(worktree.missing)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(worktree.path, forType: .string)
            }
            Divider()
            Button("Delete Build Folder…") { buildFolderTarget = worktree }
                .disabled(worktree.missing || worktree.buildBytes == 0 || model.busy)
        }
    }

    private func toggle() {
        if isSelected { model.selection.remove(worktree.id) } else { model.selection.insert(worktree.id) }
    }

    private var icon: String {
        switch group {
        case .managed: "sparkles"
        case .keep: "lock"
        case .missing: "questionmark.folder"
        default: "folder"
        }
    }

    private var iconTint: Color {
        group == .keep ? .orange : .secondary
    }

    private var badges: [(text: String, tint: Color)] {
        if worktree.missing { return [("folder missing", .secondary)] }
        var badges: [(text: String, tint: Color)] = []
        badges.append((Format.merge(worktree.merge, base: worktree.repo.base), worktree.merge.isMerged ? .green : .orange))
        if worktree.changedFiles > 0 { badges.append(("\(worktree.changedFiles) changed", .orange)) }
        if worktree.untrackedFiles > 0 { badges.append(("\(worktree.untrackedFiles) untracked", .orange)) }
        if worktree.inUse { badges.append(("in use", .blue)) }
        if worktree.locked { badges.append(("locked", .orange)) }
        if let problem = worktree.checkError { badges.append((problem, .red)) }
        if let pr = worktree.pullRequest { badges.append(("PR #\(pr.number) \(pr.state.lowercased())", pr.state == "OPEN" ? .blue : .secondary)) }
        return badges
    }
}

struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct CachesSection: View {
    let caches: [CacheInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Build caches").font(.title3.weight(.semibold))
            Text("These make builds fast. This tool never removes them.").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(caches) { cache in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cache.label)
                            Text(Format.home(cache.path)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Format.bytes(cache.bytes)).monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    if cache.id != caches.last?.id { Divider().padding(.leading, 12) }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

struct ActionBar: View {
    @Environment(AppModel.self) private var model
    @Binding var confirmingRemoval: Bool
    @State private var showingHistory = false

    var body: some View {
        HStack(spacing: 10) {
            if let working = model.working {
                ProgressView().controlSize(.small)
                Text(working).lineLimit(1)
            } else if let last = model.log.first {
                Image(systemName: last.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(last.ok ? .green : .orange)
                Text(last.text).lineLimit(1).truncationMode(.tail)
                Button("History") { showingHistory.toggle() }
                    .buttonStyle(.link)
                    .popover(isPresented: $showingHistory) { HistoryView() }
            }
            Spacer()
            if !model.selection.isEmpty {
                Text("\(model.selection.count) selected · \(Format.bytes(model.selected.reduce(0) { $0 + $1.totalBytes }))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Remove Selected…") { confirmingRemoval = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.selection.isEmpty || model.busy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.log) { entry in
                    Label(entry.text, systemImage: entry.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(entry.ok ? Color.primary : Color.orange)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
        }
        .frame(width: 520, height: 280)
    }
}

struct SettingsView: View {
    @AppStorage("roots") private var roots = "~/CodexProjects"
    @AppStorage("fetch") private var fetch = true
    @AppStorage("useGitHub") private var useGitHub = true
    @AppStorage("recentHours") private var recentHours = 6

    var body: some View {
        Form {
            Section {
                TextEditor(text: $roots)
                    .font(.body.monospaced())
                    .frame(height: 72)
            } header: {
                Text("Folders to scan")
            } footer: {
                Text("One per line. Each folder and its direct subfolders are checked for git repositories. Their worktrees are found wherever they live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Fetch from origin before checking", isOn: $fetch)
                Toggle("Look up pull requests with gh", isOn: $useGitHub)
                Stepper("Recent means changed in the last \(recentHours) hour\(recentHours == 1 ? "" : "s")", value: $recentHours, in: 0...168)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}

// Development aid: WORKTREE_CLEANER_SNAPSHOT=/path/file.png scans, renders the report area to a PNG, then quits.
@MainActor
enum Snapshot {
    static func runIfRequested(_ model: AppModel) {
        guard let file = ProcessInfo.processInfo.environment["WORKTREE_CLEANER_SNAPSHOT"] else { return }
        Task { @MainActor in
            await model.scan()
            // The window starts its own scan on appear; wait for whichever one is running.
            while model.scanning || model.result == nil { try? await Task.sleep(for: .milliseconds(200)) }
            guard let result = model.result else { return }
            let cutoff = AppModel.recentCutoff(hours: UserDefaults.standard.integer(forKey: "recentHours"))
            if let first = model.members(of: .safe, cutoff: cutoff).first { model.selection = [first.id] }
            let view = VStack(spacing: 0) {
                SummaryBar(cutoff: cutoff)
                Divider()
                GroupsView(result: result, cutoff: cutoff, buildFolderTarget: .constant(nil)).padding(16)
                Divider()
                ActionBar(confirmingRemoval: .constant(false))
            }
            .environment(model)
            .frame(width: 980)
            .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                do {
                    try png.write(to: URL(fileURLWithPath: file))
                    FileHandle.standardError.write(Data("Snapshot written to \(file)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("Snapshot not written: \(error.localizedDescription)\n".utf8))
                }
            } else {
                FileHandle.standardError.write(Data("Snapshot not rendered\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }
}
