import SwiftUI
import WorktreeCore

struct LogEntry: Identifiable {
    let id = UUID()
    let text: String
    let ok: Bool
}

// What one removal run did, for the simple screen's "done" state.
struct CleanSummary {
    var attempted = 0
    var removed = 0
    var freed: Int64 = 0
    var skipped: [String] = []   // "name: reason"
    var prunedRecords = 0
}

@MainActor
@Observable
final class AppModel {
    var result: ScanResult?
    var scanning = false
    var progress = ""
    var selection: Set<String> = []
    var working: String?   // what is being removed right now
    var workDone = 0
    var workTotal = 0
    var lastClean: CleanSummary?
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
        lastClean = nil
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

    // One-click clean: every worktree in the safe group, then git's records of missing folders.
    func clean(cutoff: Date) async {
        guard !busy else { return }
        var summary = await remove(members(of: .safe, cutoff: cutoff))
        summary.prunedRecords = await pruneMissing()
        lastClean = summary
    }

    func removeSelected() async {
        _ = await remove(selected.sorted { $0.totalBytes > $1.totalBytes })
    }

    // Removes each worktree after Cleaner re-checks it; anything that changed since the scan is skipped.
    private func remove(_ targets: [Worktree]) async -> CleanSummary {
        var summary = CleanSummary(attempted: targets.count)
        workTotal = targets.count
        workDone = 0
        for (index, worktree) in targets.enumerated() {
            working = "Removing \(index + 1) of \(targets.count): \(worktree.name)"
            let outcome = await Cleaner.removeWorktree(worktree)
            record(outcome, action: "Removed", worktree)
            switch outcome {
            case .done(let bytes):
                summary.freed += bytes
                summary.removed += 1
                result?.worktrees.removeAll { $0.id == worktree.id }
            case .skipped(let reason), .failed(let reason):
                summary.skipped.append("\(worktree.name): \(reason)")
            }
            selection.remove(worktree.id)
            workDone = index + 1
        }
        if targets.count > 1 {
            log.insert(LogEntry(text: "Removed \(summary.removed) of \(targets.count) worktrees, about \(Format.bytes(summary.freed))", ok: summary.removed == targets.count), at: 0)
        }
        working = nil
        freeBytes = Report.freeBytes()
        return summary
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

    // Returns how many records were tidied.
    @discardableResult
    func pruneMissing() async -> Int {
        let missing = (result?.worktrees ?? []).filter(\.missing)
        let repos = Set(missing.map(\.repo))
        guard !repos.isEmpty else { return 0 }
        var pruned = 0
        working = "Pruning git's records"
        for repo in repos.sorted(by: { $0.path < $1.path }) {
            switch await Cleaner.prune(repo) {
            case .done:
                log.insert(LogEntry(text: "Pruned missing worktree records in \(repo.name)", ok: true), at: 0)
                pruned += missing.filter { $0.repo == repo }.count
                result?.worktrees.removeAll { $0.missing && $0.repo == repo }
            case .skipped(let reason), .failed(let reason):
                log.insert(LogEntry(text: "Could not prune \(repo.name): \(reason)", ok: false), at: 0)
            }
        }
        working = nil
        return pruned
    }

    private func record(_ outcome: Outcome, action: String, _ worktree: Worktree) {
        switch outcome {
        case .done(let bytes): log.insert(LogEntry(text: "\(action) \(worktree.name) (\(Format.bytes(bytes)))", ok: true), at: 0)
        case .skipped(let reason): log.insert(LogEntry(text: "Skipped \(worktree.name): \(reason)", ok: false), at: 0)
        case .failed(let reason): log.insert(LogEntry(text: "Failed on \(worktree.name): \(reason)", ok: false), at: 0)
        }
    }
}
