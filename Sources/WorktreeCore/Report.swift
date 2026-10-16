import Foundation

public enum Format {
    public static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false   // "0 bytes", not "Zero KB"
        return formatter.string(fromByteCount: count)
    }

    public static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "unknown" }
        if abs(date.timeIntervalSince(now)) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    public static func home(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    public static func merge(_ state: MergeState, base: String?) -> String {
        switch state {
        case .merged: "merged"
        case .squashMerged: "squash-merged"
        case .notMerged(let ahead): "\(ahead) commit\(ahead == 1 ? "" : "s") not on \(base ?? "main")"
        case .unknown(let reason): "merge unknown (\(reason))"
        }
    }

    // Short facts about a worktree, most important first.
    public static func facts(_ worktree: Worktree) -> [String] {
        var facts: [String] = []
        if worktree.missing { return ["folder missing"] }
        facts.append(merge(worktree.merge, base: worktree.repo.base))
        if worktree.changedFiles > 0 { facts.append("\(worktree.changedFiles) changed file\(worktree.changedFiles == 1 ? "" : "s")") }
        if worktree.untrackedFiles > 0 { facts.append("\(worktree.untrackedFiles) untracked file\(worktree.untrackedFiles == 1 ? "" : "s")") }
        if worktree.inUse { facts.append("in use") }
        if worktree.locked { facts.append("locked") }
        if let problem = worktree.checkError { facts.append(problem) }
        if let pr = worktree.pullRequest { facts.append("PR #\(pr.number) \(pr.state.lowercased())") }
        return facts
    }
}

public enum Report {
    // Plain-text report, grouped like the app's window.
    public static func text(_ result: ScanResult, recentCutoff: Date, freeBytes: Int64?) -> String {
        var lines: [String] = []
        let all = result.worktrees
        lines.append("Worktree report, \(result.scannedAt.formatted(date: .abbreviated, time: .shortened))")
        if let freeBytes { lines.append("Free on disk: \(Format.bytes(freeBytes))") }
        lines.append("Worktrees: \(all.count), \(Format.bytes(all.reduce(0) { $0 + $1.totalBytes }))")
        for warning in result.warnings { lines.append("Warning: \(warning)") }
        for group in WorktreeGroup.allCases {
            let members = all.filter { $0.group(recentCutoff: recentCutoff) == group }.sorted { $0.totalBytes > $1.totalBytes }
            guard !members.isEmpty else { continue }
            let size = members.reduce(0) { $0 + $1.totalBytes }
            lines.append("")
            lines.append(group == .missing ? "\(group.title) (\(members.count))" : "\(group.title) (\(members.count), \(Format.bytes(size)))")
            for worktree in members where group == .missing {
                lines.append("  \(worktree.name)  [\(worktree.branch ?? "detached")]  \(Format.home(worktree.path))")
            }
            for worktree in members where group != .missing {
                let build = worktree.buildBytes > 0 ? " (build \(Format.bytes(worktree.buildBytes)))" : ""
                let branch = worktree.branch ?? "detached"
                lines.append("  \(Format.bytes(worktree.totalBytes))\(build)  \(worktree.name)  [\(worktree.owner.label), \(branch)]  \(Format.facts(worktree).joined(separator: ", "))  changed \(Format.ago(worktree.lastChange))")
                lines.append("      \(Format.home(worktree.path))")
            }
        }
        if !result.caches.isEmpty {
            lines.append("")
            lines.append("Build caches (never removed by this tool)")
            for cache in result.caches { lines.append("  \(Format.bytes(cache.bytes))  \(cache.label)  \(Format.home(cache.path))") }
        }
        return lines.joined(separator: "\n")
    }

    public static func freeBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
