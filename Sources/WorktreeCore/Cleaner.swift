import Foundation

public enum Outcome: Sendable, Equatable {
    case done(freed: Int64)
    case skipped(String)
    case failed(String)
}

public enum Cleaner {
    // Re-checks the worktree right before deleting it, then removes it with git.
    // Branches and commits stay in the repository; only the folder and git's record of it go.
    public static func removeWorktree(_ worktree: Worktree) async -> Outcome {
        guard worktree.path != worktree.repo.path else { return .skipped("it is the main checkout") }
        guard worktree.owner != .claudeApp else { return .skipped("the Claude app manages it; archive its session in Claude") }
        guard let fresh = await WorktreeScanner.recheck(worktree) else { return .skipped("git no longer lists it") }
        if fresh.missing { return .skipped("its folder is already gone") }
        if fresh.locked { return .skipped("it is locked") }
        if let problem = fresh.checkError { return .skipped(problem) }
        guard fresh.merge.isMerged else { return .skipped("it now has commits that are not on \(fresh.repo.base ?? "the main branch")") }
        guard fresh.isClean else { return .skipped("it now has uncommitted or untracked files") }
        guard !fresh.inUse else { return .skipped("a program (a terminal, agent or build) is using the folder") }
        // --force because git refuses worktrees that contain submodules; the checks above replace its own.
        let result = await Shell.git(["worktree", "remove", "--force", fresh.path], in: fresh.repo.path)
        return result.ok ? .done(freed: worktree.totalBytes) : .failed(result.errorText)
    }

    // Deletes only the worktree's build folder, keeping its sources and any unsaved work.
    public static func removeBuildFolder(_ worktree: Worktree, otherWorktrees: [String]) async -> Outcome {
        let build = (worktree.path as NSString).appendingPathComponent("build")
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: build, isDirectory: &isFolder), isFolder.boolValue else {
            return .skipped("it has no build folder")
        }
        if otherWorktrees.contains(where: { $0.hasPrefix(build + "/") }) {
            return .skipped("another worktree lives inside its build folder")
        }
        if WorktreeScanner.isInUse(worktree.path, workingDirectories: await WorktreeScanner.workingDirectories()) {
            return .skipped("a program (a terminal, agent or build) is using the folder")
        }
        let tracked = await Shell.git(["ls-files", "--", "build"], in: worktree.path)
        guard tracked.ok else { return .failed(tracked.errorText) }
        guard tracked.text.isEmpty else { return .skipped("git tracks files inside its build folder") }
        let bytes = await WorktreeScanner.diskUsage(build)
        do {
            try FileManager.default.removeItem(atPath: build)
        } catch {
            return .failed(error.localizedDescription)
        }
        return .done(freed: bytes)
    }

    // Drops git's records of worktrees whose folders no longer exist.
    public static func prune(_ repo: Repo) async -> Outcome {
        let result = await Shell.git(["worktree", "prune"], in: repo.path)
        return result.ok ? .done(freed: 0) : .failed(result.errorText)
    }
}
