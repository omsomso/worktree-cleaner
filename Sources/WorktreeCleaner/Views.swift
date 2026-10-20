import SwiftUI
import WorktreeCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("recentHours") private var recentHours = 6
    @AppStorage("showDetails") private var showDetails = false
    @AppStorage("skipCleanConfirmation") private var skipCleanConfirmation = false
    @State private var confirmingRemoval = false
    @State private var confirmingClean = false
    @State private var buildFolderTarget: Worktree?

    var body: some View {
        let cutoff = AppModel.recentCutoff(hours: recentHours)
        let safe = model.members(of: .safe, cutoff: cutoff)
        Group {
            if showDetails {
                DetailsView(cutoff: cutoff, confirmingRemoval: $confirmingRemoval, buildFolderTarget: $buildFolderTarget)
            } else {
                SimpleView(cutoff: cutoff, showDetails: $showDetails) {
                    if skipCleanConfirmation { Task { await model.clean(cutoff: cutoff) } } else { confirmingClean = true }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $showDetails) {
                    Text("Simple").tag(false)
                    Text("Details").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Switch between the simple screen and the full list")
            }
            ToolbarItem {
                Button { Task { await model.scan() } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .disabled(model.busy)
                    .help("Scan again (⌘R)")
            }
        }
        .task { if model.result == nil { await model.scan() } }
        .confirmationDialog(
            "Clean \(safe.count) finished worktree\(safe.count == 1 ? "" : "s")?",
            isPresented: $confirmingClean,
            titleVisibility: .visible
        ) {
            Button("Clean") { Task { await model.clean(cutoff: cutoff) } }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Frees about \(Format.bytes(safe.reduce(0) { $0 + $1.totalBytes })). Their work is already merged. Each one is checked again first and skipped if anything changed. Branches and commits stay in git.")
        }
        .dialogSuppressionToggle(isSuppressed: $skipCleanConfirmation)
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

// The full list: every group, per-worktree facts, selection and removal.
struct DetailsView: View {
    @Environment(AppModel.self) private var model
    let cutoff: Date
    @Binding var confirmingRemoval: Bool
    @Binding var buildFolderTarget: Worktree?

    var body: some View {
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
    }
}

// The default screen: how much can be freed and one Clean button. Details are a click away.
struct SimpleView: View {
    @Environment(AppModel.self) private var model
    let cutoff: Date
    @Binding var showDetails: Bool
    let onClean: () -> Void

    static let teal = Color(red: 0.08, green: 0.50, blue: 0.48)

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            hero
                .frame(maxWidth: 440)
                .multilineTextAlignment(.center)
                .animation(.smooth, value: stateKey)
            Spacer(minLength: 24)
            if model.result != nil {
                Divider()
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var safe: [Worktree] { model.members(of: .safe, cutoff: cutoff) }

    private var stateKey: Int {
        if model.working != nil { return 1 }
        if model.lastClean != nil { return 2 }
        if model.result == nil { return 0 }
        return safe.isEmpty ? 3 : 4
    }

    @ViewBuilder private var hero: some View {
        if model.working != nil {
            VStack(spacing: 14) {
                AppIcon(size: 88)
                Text("Cleaning…").font(.title.weight(.semibold))
                ProgressView(value: Double(model.workDone), total: Double(max(model.workTotal, 1)))
                    .frame(width: 280)
                    .tint(Self.teal)
                Text(model.working ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if let summary = model.lastClean {
            DoneView(summary: summary, showDetails: $showDetails)
        } else if model.result == nil {
            VStack(spacing: 14) {
                AppIcon(size: 88)
                Text("Checking your worktrees…").font(.title2.weight(.semibold))
                ProgressView().controlSize(.small)
                Text(model.progress).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if safe.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Self.teal)
                Text("All clean").font(.largeTitle.weight(.bold))
                Text("No finished worktrees to remove right now.").foregroundStyle(.secondary)
            }
        } else {
            let bytes = safe.reduce(0) { $0 + $1.totalBytes }
            VStack(spacing: 10) {
                AppIcon(size: 88)
                Text(Format.bytes(bytes))
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("can be freed from \(safe.count) finished worktree\(safe.count == 1 ? "" : "s")")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button(action: onClean) {
                    Text("Clean").font(.title3.weight(.semibold)).frame(width: 170)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .tint(Self.teal)
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy)
                .padding(.top, 14)
                Text("Their work is already merged. Build caches stay.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    // Free space, and a one-line note about anything that needs a look.
    private var footer: some View {
        HStack(spacing: 14) {
            Label(model.freeBytes.map { "\(Format.bytes($0)) free" } ?? "—", systemImage: "internaldrive")
                .foregroundStyle(.secondary)
            if let note {
                Text(note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button("Show Details") { showDetails = true }
                .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // Everything Clean leaves alone (recently used, unsaved or unmerged work, Claude's); Details says why.
    private var note: String? {
        let kept = [WorktreeGroup.recent, .keep, .managed].reduce(0) { $0 + model.members(of: $1, cutoff: cutoff).count }
        var parts: [String] = []
        if kept > 0 { parts.append("\(kept) other worktree\(kept == 1 ? "" : "s") kept") }
        if let warnings = model.result?.warnings, !warnings.isEmpty { parts.append("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : "· " + parts.joined(separator: " · ")
    }
}

struct DoneView: View {
    @Environment(AppModel.self) private var model
    let summary: CleanSummary
    @Binding var showDetails: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, SimpleView.teal)
            Text("Freed \(Format.bytes(summary.freed))")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(removedLine).font(.title3).foregroundStyle(.secondary)
            if !summary.skipped.isEmpty {
                VStack(spacing: 4) {
                    Text("Skipped \(summary.skipped.count) because \(summary.skipped.count == 1 ? "it" : "they") changed since the scan:")
                        .foregroundStyle(.orange)
                    ForEach(summary.skipped.prefix(3), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if summary.skipped.count > 3 {
                        Button("and \(summary.skipped.count - 3) more…") { showDetails = true }.buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.top, 4)
            }
            Button("Done") { model.lastClean = nil }
                .controlSize(.large)
                .padding(.top, 10)
        }
    }

    private var removedLine: String {
        var line = "\(summary.removed) worktree\(summary.removed == 1 ? "" : "s") removed"
        if summary.prunedRecords > 0 { line += ", \(summary.prunedRecords) stale record\(summary.prunedRecords == 1 ? "" : "s") tidied" }
        return line
    }
}

struct AppIcon: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
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

// Development aid: WORKTREE_CLEANER_SNAPSHOT=/path/name.png scans, then writes name.png (details)
// and name-simple, -ready, -cleaning, -done and -allclean.png (the simple screen's states), then quits.
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
            let base = file.hasSuffix(".png") ? String(file.dropLast(4)) : file
            render(VStack(spacing: 0) {
                SummaryBar(cutoff: cutoff)
                Divider()
                GroupsView(result: result, cutoff: cutoff, buildFolderTarget: .constant(nil)).padding(16)
                Divider()
                ActionBar(confirmingRemoval: .constant(false))
            }
            .environment(model)
            .frame(width: 980)
            .background(Color(nsColor: .windowBackgroundColor)), to: file)
            render(simple(model, cutoff), to: base + "-simple.png")
            render(simple(model, .distantFuture), to: base + "-ready.png")      // every merged, clean worktree counts as safe
            render(simple(model, .distantPast), to: base + "-allclean.png")     // nothing counts as safe
            model.working = "Removing 3 of 12: example-worktree"
            model.workDone = 3
            model.workTotal = 12
            render(simple(model, cutoff), to: base + "-cleaning.png")
            model.working = nil
            model.lastClean = CleanSummary(attempted: 12, removed: 11, freed: 64_200_000_000,
                                           skipped: ["example-worktree: it now has uncommitted or untracked files"], prunedRecords: 6)
            render(simple(model, cutoff), to: base + "-done.png")
            NSApp.terminate(nil)
        }
    }

    static func simple(_ model: AppModel, _ cutoff: Date) -> some View {
        SimpleView(cutoff: cutoff, showDetails: .constant(false), onClean: {})
            .environment(model)
            .frame(width: 760, height: 560)
    }

    // Draws the view in an offscreen window so native controls render as they do on screen.
    static func render(_ view: some View, to file: String) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write(Data("Snapshot not rendered: \(file)\n".utf8))
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
            FileHandle.standardError.write(Data("Snapshot written to \(file)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Snapshot not written: \(error.localizedDescription)\n".utf8))
        }
    }
}
