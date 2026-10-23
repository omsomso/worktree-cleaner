import Foundation

// One entry of `git worktree list --porcelain`.
public struct WorktreeEntry: Equatable, Sendable {
    public var path: String
    public var head = ""
    public var branch: String?
    public var locked = false
    public var prunable = false
    public var bare = false
}

public enum WorktreeScanner {
    // Folders that hold build output, dependencies or git data rather than the user's own edits.
    static let skippedFolders: Set<String> = ["build", ".build", ".git", "node_modules", "third_party", "DerivedData", ".swiftpm"]

    // Each root itself and its direct subfolders, when they have their own .git folder.
    public static func findRepos(in roots: [String]) -> [String] {
        let files = FileManager.default
        var found = Set<String>()
        for root in roots {
            let root = (root as NSString).expandingTildeInPath
            var candidates = [root]
            if let children = try? files.contentsOfDirectory(atPath: root) {
                candidates += children.map { (root as NSString).appendingPathComponent($0) }
            }
            for folder in candidates {
                var isFolder: ObjCBool = false
                if files.fileExists(atPath: folder + "/.git", isDirectory: &isFolder), isFolder.boolValue {
                    found.insert(folder)
                }
            }
        }
        return found.sorted()
    }

    public static func scan(_ options: ScanOptions, progress: (@Sendable (String) -> Void)? = nil) async -> ScanResult {
        var warnings: [String] = []
        var repos: [Repo] = []
        var listed: [Worktree] = []
        var pullRequests: [String: [String: PullRequest]] = [:]

        for path in findRepos(in: options.roots) {
            let name = (path as NSString).lastPathComponent
            progress?("Reading \(name)")
            let entries = await listEntries(repo: path)
            guard let entries else {
                warnings.append("\(name): git could not list its worktrees")
                continue
            }
            if !entries.isEmpty, options.fetch, await Shell.git(["remote", "get-url", "origin"], in: path).ok {
                progress?("Fetching \(name)")
                let fetch = await Shell.git(["fetch", "origin", "--quiet"], in: path, timeout: 60)
                if !fetch.ok {
                    warnings.append("\(name): fetch failed, so merge checks use the last fetched state. \(fetch.errorText)")
                }
            }
            let repo = Repo(path: path, base: await baseRef(repo: path))
            repos.append(repo)
            if repo.base == nil, !entries.isEmpty {
                warnings.append("\(name): no main branch found, so its worktrees are kept")
            }
            listed += entries.map { $0.worktree(repo) }
            if !entries.isEmpty, options.useGitHub {
                progress?("Looking up pull requests for \(name)")
                if let prs = await self.pullRequests(repo: path) { pullRequests[path] = prs }
            }
        }

        let total = listed.count
        progress?("Checking worktrees · 0 of \(total)")
        let directories = await workingDirectories()
        var worktrees = await concurrentMap(listed, limit: 6, onEach: { done in
            progress?("Checking worktrees · \(done) of \(total)")
        }) { await inspect($0, workingDirectories: directories) }
        for index in worktrees.indices {
            if let branch = worktrees[index].branch {
                worktrees[index].pullRequest = pullRequests[worktrees[index].repo.path]?[branch]
            }
        }
        progress?("Measuring build caches")
        let caches = await sharedCaches(repos: repos)
        return ScanResult(worktrees: worktrees, repos: repos, caches: caches, warnings: warnings, scannedAt: Date())
    }

    // Reads the worktree again from git, right before acting on it. Nil when git no longer lists it.
    public static func recheck(_ worktree: Worktree) async -> Worktree? {
        guard let entries = await listEntries(repo: worktree.repo.path),
              let entry = entries.first(where: { $0.path == worktree.path }) else { return nil }
        let repo = Repo(path: worktree.repo.path, base: await baseRef(repo: worktree.repo.path))
        return await inspect(entry.worktree(repo), workingDirectories: await workingDirectories(), measure: false)
    }

    public static func parseWorktreeList(_ text: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("worktree ") {
                if let current { entries.append(current) }
                current = WorktreeEntry(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "locked" || line.hasPrefix("locked ") {
                current?.locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current?.prunable = true
            } else if line == "bare" {
                current?.bare = true
            }
        }
        if let current { entries.append(current) }
        return entries
    }

    // The linked worktrees of a repository; the main checkout (always listed first) is left out.
    static func listEntries(repo: String) async -> [WorktreeEntry]? {
        let result = await Shell.git(["worktree", "list", "--porcelain"], in: repo)
        guard result.ok else { return nil }
        return Array(parseWorktreeList(result.output).dropFirst().filter { !$0.bare })
    }

    // origin's default branch when known, otherwise the first of the usual names that exists.
    public static func baseRef(repo: String) async -> String? {
        let remoteHead = await Shell.git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repo)
        if remoteHead.ok, !remoteHead.text.isEmpty { return remoteHead.text }
        for candidate in ["origin/main", "origin/master", "main", "master"] {
            if await Shell.git(["rev-parse", "--verify", "--quiet", candidate + "^{commit}"], in: repo).ok { return candidate }
        }
        return nil
    }

    static func inspect(_ worktree: Worktree, workingDirectories: [String], measure: Bool = true) async -> Worktree {
        var result = worktree
        guard !worktree.missing else { return result }
        let path = worktree.path
        async let merge = mergeState(head: worktree.head, repo: worktree.repo)
        async let status = Shell.git(["status", "--porcelain", "--ignore-submodules=none"], in: path)
        async let total: Int64 = measure ? diskUsage(path) : 0
        async let build: Int64 = measure ? diskUsage((path as NSString).appendingPathComponent("build")) : 0
        async let changed: Date? = measure ? lastChange(in: path) : nil

        result.merge = await merge
        let statusResult = await status
        if statusResult.ok {
            let lines = statusResult.output.split(separator: "\n")
            result.untrackedFiles = lines.filter { $0.hasPrefix("??") }.count
            result.changedFiles = lines.count - result.untrackedFiles
        } else {
            result.checkError = "git status failed: \(statusResult.errorText)"
        }
        if case .unknown(let reason) = result.merge, result.checkError == nil {
            result.checkError = "merge check failed: \(reason)"
        }
        result.inUse = isInUse(path, workingDirectories: workingDirectories)
        result.totalBytes = await total
        result.buildBytes = await build
        result.lastChange = await changed
        return result
    }

    static func mergeState(head: String, repo: Repo) async -> MergeState {
        guard let base = repo.base else { return .unknown("no base branch") }
        let ancestor = await Shell.git(["merge-base", "--is-ancestor", head, base], in: repo.path)
        if ancestor.status == 0 { return .merged }
        guard ancestor.status == 1 else { return .unknown(ancestor.errorText) }
        // Squash and rebase merges leave different commits behind: check whether merging would change anything.
        async let baseTree = Shell.git(["rev-parse", base + "^{tree}"], in: repo.path)
        async let mergedTree = Shell.git(["merge-tree", "--write-tree", base, head], in: repo.path)
        let (baseResult, mergedResult) = await (baseTree, mergedTree)
        let merged = mergedResult.output.split(separator: "\n").first.map(String.init) ?? ""
        if baseResult.ok, !merged.isEmpty, merged == baseResult.text { return .squashMerged }
        let ahead = await Shell.git(["rev-list", "--count", base + ".." + head], in: repo.path)
        return .notMerged(ahead: Int(ahead.text) ?? 0)
    }

    // Working folders of every running process this user can see (terminals, agents, builds).
    public static func workingDirectories() async -> [String] {
        let result = await Shell.run("/usr/sbin/lsof", ["-d", "cwd", "-Fn"])
        return result.output.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    static func isInUse(_ path: String, workingDirectories: [String]) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return workingDirectories.contains { folder in
            [path, resolved].contains { folder == $0 || folder.hasPrefix($0 + "/") }
        }
    }

    public static func diskUsage(_ path: String) async -> Int64 {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let result = await Shell.run("du", ["-sk", path])
        let kilobytes = result.output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.flatMap { Int64($0) } ?? 0
        return kilobytes * 1024
    }

    // Newest modification time of the user's files, ignoring build output, dependencies and git data.
    public static func lastChange(in path: String) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, errorHandler: { _, _ in true }) else { return nil }
        var newest: Date?
        while let url = walker.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skippedFolders.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            if let date = values?.contentModificationDate, date > (newest ?? .distantPast) { newest = date }
        }
        return newest
    }

    static func pullRequests(repo: String) async -> [String: PullRequest]? {
        let remote = await Shell.git(["remote", "get-url", "origin"], in: repo)
        guard remote.ok, remote.text.contains("github.com") else { return nil }
        let result = await Shell.run("gh", ["pr", "list", "--state", "all", "--limit", "500", "--json", "number,state,headRefName"], in: repo, timeout: 30)
        guard result.ok, let list = try? JSONDecoder().decode([PullRequest].self, from: Data(result.output.utf8)) else { return nil }
        var byBranch: [String: PullRequest] = [:]
        for pr in list where byBranch[pr.headRefName] == nil { byBranch[pr.headRefName] = pr }   // newest first
        return byBranch
    }

    // Caches that make builds fast. Shown for reference; this tool never removes them.
    static func sharedCaches(repos: [Repo]) async -> [CacheInfo] {
        var caches: [CacheInfo] = []
        let ccache = await Shell.run("ccache", ["-k", "cache_dir"])
        if ccache.ok, !ccache.text.isEmpty, FileManager.default.fileExists(atPath: ccache.text) {
            caches.append(CacheInfo(label: "ccache (shared compiler cache)", path: ccache.text, bytes: await diskUsage(ccache.text)))
        }
        for repo in repos {
            let build = (repo.path as NSString).appendingPathComponent("build")
            let bytes = await diskUsage(build)
            if bytes >= 10_000_000 {   // leave out near-empty build folders
                caches.append(CacheInfo(label: "\(repo.name) main checkout build folder", path: build, bytes: bytes))
            }
        }
        return caches
    }
}

extension WorktreeEntry {
    func worktree(_ repo: Repo) -> Worktree {
        Worktree(path: path, repo: repo, branch: branch, head: head, locked: locked, missing: prunable)
    }
}

// Runs `transform` on every item with at most `limit` running at once, keeping the input order.
// `onEach` gets the number finished so far, after each item.
func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], limit: Int, onEach: ((Int) -> Void)? = nil, _ transform: @escaping @Sendable (T) async -> R) async -> [R] {
    await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        while next < min(limit, items.count) {
            let index = next
            group.addTask { (index, await transform(items[index])) }
            next += 1
        }
        var finished = 0
        for await (index, value) in group {
            results[index] = value
            finished += 1
            onEach?(finished)
            if next < items.count {
                let index = next
                group.addTask { (index, await transform(items[index])) }
                next += 1
            }
        }
        return results.compactMap { $0 }
    }
}
