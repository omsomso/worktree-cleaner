import Foundation

public struct Repo: Sendable, Hashable {
    public let path: String
    // The branch work counts as merged into, e.g. "origin/main". Nil when none could be found.
    public let base: String?

    public var name: String { (path as NSString).lastPathComponent }
}

public enum Owner: String, Sendable {
    case claudeApp   // made by the Claude desktop app; the app removes it when its session is archived
    case claude      // another folder under .claude/worktrees
    case codex       // under ~/.codex/worktrees
    case other

    public var label: String {
        switch self {
        case .claudeApp: "Claude app"
        case .claude: "Claude"
        case .codex: "Codex"
        case .other: "Manual"
        }
    }

    public static func of(path: String) -> Owner {
        if path.contains("/.claude/worktrees/") {
            let name = (path as NSString).lastPathComponent
            // The app names its worktrees like "funny-bhabha-a49e91".
            return name.range(of: #"^[a-z]+-[a-z]+-[0-9a-f]{6}$"#, options: .regularExpression) != nil ? .claudeApp : .claude
        }
        if path.contains("/.codex/worktrees/") { return .codex }
        return .other
    }
}

public enum MergeState: Equatable, Sendable {
    case merged                 // every commit is already on the base branch
    case squashMerged           // the commits differ, but merging them would change nothing
    case notMerged(ahead: Int)  // commits not on the base branch
    case unknown(String)

    public var isMerged: Bool { self == .merged || self == .squashMerged }
}

public struct PullRequest: Sendable, Hashable, Decodable {
    public let number: Int
    public let state: String
    public let headRefName: String
}

public enum WorktreeGroup: Int, CaseIterable, Sendable, Identifiable {
    case safe, recent, managed, keep, missing

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .safe: "Safe to remove"
        case .recent: "Merged, but used recently"
        case .managed: "Claude app worktrees"
        case .keep: "Keep"
        case .missing: "Missing folders"
        }
    }

    public var explanation: String {
        switch self {
        case .safe: "All work is on the base branch, nothing is unsaved, and nothing has changed recently."
        case .recent: "All work is merged, but files changed recently or a program is using the folder. Check before removing."
        case .managed: "Merged and clean, but the Claude app manages these. Archive the session in Claude; the app reuses or removes the worktree."
        case .keep: "Unmerged commits, uncommitted or untracked files, or locked. Removing would lose work."
        case .missing: "Git still lists these, but their folders are gone. Pruning only tidies git's records."
        }
    }

    public var canRemove: Bool { self == .safe || self == .recent }
}

public struct Worktree: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let repo: Repo
    public let branch: String?   // nil when the worktree has a detached HEAD
    public let head: String
    public let locked: Bool
    public let missing: Bool

    public var merge: MergeState = .unknown("not checked")
    public var checkError: String?   // a check that could not run; the worktree is then kept
    public var changedFiles = 0
    public var untrackedFiles = 0
    public var inUse = false
    public var lastChange: Date?
    public var totalBytes: Int64 = 0
    public var buildBytes: Int64 = 0
    public var pullRequest: PullRequest?

    public init(path: String, repo: Repo, branch: String?, head: String, locked: Bool, missing: Bool) {
        self.path = path
        self.repo = repo
        self.branch = branch
        self.head = head
        self.locked = locked
        self.missing = missing
    }

    public var owner: Owner { Owner.of(path: path) }
    public var isClean: Bool { changedFiles == 0 && untrackedFiles == 0 }

    // ~/.codex/worktrees/<task>/VSTS is better known by its task name.
    public var name: String {
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == repo.name { return url.deletingLastPathComponent().lastPathComponent }
        return url.lastPathComponent
    }

    public func group(recentCutoff: Date) -> WorktreeGroup {
        if missing { return .missing }
        if locked || checkError != nil || !merge.isMerged || !isClean { return .keep }
        if owner == .claudeApp { return .managed }
        // An unknown last change counts as recent: better to ask than to guess.
        if inUse || (lastChange ?? .distantFuture) > recentCutoff { return .recent }
        return .safe
    }
}

public struct CacheInfo: Sendable, Identifiable {
    public let label: String
    public let path: String
    public let bytes: Int64
    public var id: String { path }
}

public struct ScanOptions: Sendable {
    public var roots: [String]
    public var fetch: Bool
    public var useGitHub: Bool

    public init(roots: [String], fetch: Bool = true, useGitHub: Bool = true) {
        self.roots = roots
        self.fetch = fetch
        self.useGitHub = useGitHub
    }
}

public struct ScanResult: Sendable {
    public var worktrees: [Worktree]
    public var repos: [Repo]
    public var caches: [CacheInfo]
    public var warnings: [String]
    public var scannedAt: Date
}
