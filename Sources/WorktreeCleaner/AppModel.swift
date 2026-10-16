import SwiftUI
import WorktreeCore

struct LogEntry: Identifiable {
    let id = UUID()
    let text: String
    let ok: Bool
}

@MainActor
@Observable
final class AppModel {
    var result: ScanResult?
    var scanning = false
    var progress = ""
    var selection: Set<String> = []
    var working: String?   // what is being removed right now
    var log: [LogEntry] = []
    var freeBytes: Int64? = Report.freeBytes()

    static let defaults: [String: Any] = ["roots": "~/CodexProjects", "fetch": true, "useGitHub": true, "recentHours": 6]

    var busy: Bool { scanning || working != nil }

    static func recentCutoff(hours: Int) -> Date {
        Date().addingTimeInterval(-Double(hours) * 3600)
    }

    func members(of group: WorktreeGroup, cutoff: Date) -> [Worktree] {
        (result?.worktrees ?? [])
            .filter { $0.group(recentCutoff: cutoff) == group }
            .sorted { $0.totalBytes > $1.totalBytes }
    }

    var selected: [Worktree] {
        (result?.worktrees ?? []).filter { selection.contains($0.id) }
    }

    func scan() async {
        guard !busy else { return }
        scanning = true
        progress = "Starting"
        let defaults = UserDefaults.standard
        let roots = (defaults.string(forKey: "roots") ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let options = ScanOptions(roots: roots, fetch: defaults.bool(forKey: "fetch"), useGitHub: defaults.bool(forKey: "useGitHub"))
        let scanned = await WorktreeScanner.scan(options) { message in
            Task { @MainActor in self.progress = message }
        }
        result = scanned
        // A selection only survives a rescan while the worktree can still be removed.
        let cutoff = Self.recentCutoff(hours: defaults.integer(forKey: "recentHours"))
        let removable = Set(scanned.worktrees.filter { $0.group(recentCutoff: cutoff).canRemove }.map(\.id))
        selection.formIntersection(removable)
        freeBytes = Report.freeBytes()
        scanning = false
        progress = ""
    }

    func removeSelected() async {
        let targets = selected.sorted { $0.totalBytes > $1.totalBytes }
        var freed: Int64 = 0
        var removed = 0
        for (index, worktree) in targets.enumerated() {
            working = "Removing \(index + 1) of \(targets.count): \(worktree.name)"
            let outcome = await Cleaner.removeWorktree(worktree)
            record(outcome, action: "Removed", worktree)
            if case .done(let bytes) = outcome {
                freed += bytes
                removed += 1
                result?.worktrees.removeAll { $0.id == worktree.id }
            }
            selection.remove(worktree.id)
        }
        if targets.count > 1 {
            log.insert(LogEntry(text: "Removed \(removed) of \(targets.count) worktrees, about \(Format.bytes(freed))", ok: removed == targets.count), at: 0)
        }
        working = nil
        freeBytes = Report.freeBytes()
    }

    func removeBuildFolder(_ worktree: Worktree) async {
        working = "Deleting the build folder of \(worktree.name)"
        let outcome = await Cleaner.removeBuildFolder(worktree, otherWorktrees: result?.worktrees.map(\.path) ?? [])
        record(outcome, action: "Deleted the build folder of", worktree)
        if case .done(let bytes) = outcome, let index = result?.worktrees.firstIndex(where: { $0.id == worktree.id }) {
            result?.worktrees[index].totalBytes -= bytes
            result?.worktrees[index].buildBytes = 0
        }
        working = nil
        freeBytes = Report.freeBytes()
    }

    func pruneMissing() async {
        let repos = Set((result?.worktrees ?? []).filter(\.missing).map(\.repo))
        working = "Pruning git's records"
        for repo in repos.sorted(by: { $0.path < $1.path }) {
            switch await Cleaner.prune(repo) {
            case .done:
                log.insert(LogEntry(text: "Pruned missing worktree records in \(repo.name)", ok: true), at: 0)
                result?.worktrees.removeAll { $0.missing && $0.repo == repo }
            case .skipped(let reason), .failed(let reason):
                log.insert(LogEntry(text: "Could not prune \(repo.name): \(reason)", ok: false), at: 0)
            }
        }
        working = nil
    }

    private func record(_ outcome: Outcome, action: String, _ worktree: Worktree) {
        switch outcome {
        case .done(let bytes): log.insert(LogEntry(text: "\(action) \(worktree.name) (\(Format.bytes(bytes)))", ok: true), at: 0)
        case .skipped(let reason): log.insert(LogEntry(text: "Skipped \(worktree.name): \(reason)", ok: false), at: 0)
        case .failed(let reason): log.insert(LogEntry(text: "Failed on \(worktree.name): \(reason)", ok: false), at: 0)
        }
    }
}
