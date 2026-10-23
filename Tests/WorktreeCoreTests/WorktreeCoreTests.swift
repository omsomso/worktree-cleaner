import Foundation
import Testing
@testable import WorktreeCore

// A throwaway repository in a temporary folder; worktrees are added next to it.
final class Fixture {
    let root: String
    let repo: String

    init() throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        root = temporary.appendingPathComponent("worktree-cleaner-tests-\(UUID().uuidString)").path
        repo = root + "/project"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main")
        git("config", "user.name", "Test")
        git("config", "user.email", "test@example.com")
        git("config", "commit.gpgsign", "false")
        write("README.md", "hello\n")
        write(".gitignore", "build/\n")
        commit("start")
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func git(_ arguments: String..., in folder: String? = nil) -> CommandResult {
        let result = Shell.runBlocking("git", ["-C", folder ?? repo] + arguments)
        precondition(result.ok, "git \(arguments.joined(separator: " ")) failed: \(result.errors)")
        return result
    }

    func write(_ name: String, _ text: String, in folder: String? = nil) {
        let path = (folder ?? repo) + "/" + name
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func commit(_ message: String, in folder: String? = nil) {
        git("add", "-A", in: folder)
        git("commit", "-q", "-m", message, in: folder)
    }

    // A worktree on a new branch that starts from main.
    @discardableResult
    func addWorktree(_ name: String, branch: String) -> String {
        let path = root + "/" + name
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        git("worktree", "add", "-q", "-b", branch, path, "main")
        return path
    }

    func scan() async -> [String: Worktree] {
        let result = await WorktreeScanner.scan(ScanOptions(roots: [root], fetch: false, useGitHub: false))
        return Dictionary(uniqueKeysWithValues: result.worktrees.map { ($0.name, $0) })
    }
}

let future = Date().addingTimeInterval(3600)   // as cutoff: nothing counts as recent
let past = Date().addingTimeInterval(-3600)    // as cutoff: anything changed in the last hour is recent

func isDone(_ outcome: Outcome) -> Bool {
    if case .done = outcome { return true }
    return false
}

@Test func groupsEveryKindOfWorktree() async throws {
    let fixture = try Fixture()
    let merged = fixture.addWorktree("merged", branch: "feat-merged")
    fixture.write("a.txt", "a\n", in: merged)
    fixture.commit("a", in: merged)
    fixture.git("merge", "-q", "--ff-only", "feat-merged")

    let squashed = fixture.addWorktree("squashed", branch: "feat-squash")
    fixture.write("b.txt", "b\n", in: squashed)
    fixture.commit("b", in: squashed)
    fixture.write("b.txt", "b\n")
    fixture.commit("b, squashed")

    let open = fixture.addWorktree("open", branch: "feat-open")
    fixture.write("c.txt", "c\n", in: open)
    fixture.commit("c", in: open)

    let dirty = fixture.addWorktree("dirty", branch: "feat-dirty")
    fixture.write("README.md", "edited\n", in: dirty)
    let untracked = fixture.addWorktree("untracked", branch: "feat-untracked")
    fixture.write("notes.txt", "mine\n", in: untracked)
    fixture.addWorktree("locked", branch: "feat-locked")
    fixture.git("worktree", "lock", fixture.root + "/locked")
    fixture.addWorktree(".claude/worktrees/brave-curie-1a2b3c", branch: "claude-app")
    let gone = fixture.addWorktree("gone", branch: "feat-gone")
    try FileManager.default.removeItem(atPath: gone)

    let found = await fixture.scan()
    #expect(found.count == 8)
    #expect(found["merged"]?.merge == .merged)
    #expect(found["squashed"]?.merge == .squashMerged)
    #expect(found["open"]?.merge == .notMerged(ahead: 1))
    #expect(found["dirty"]?.changedFiles == 1)
    #expect(found["untracked"]?.untrackedFiles == 1)

    #expect(found["merged"]?.group(recentCutoff: future) == .safe)
    #expect(found["squashed"]?.group(recentCutoff: future) == .safe)
    #expect(found["merged"]?.group(recentCutoff: past) == .recent)
    #expect(found["open"]?.group(recentCutoff: future) == .keep)
    #expect(found["dirty"]?.group(recentCutoff: future) == .keep)
    #expect(found["untracked"]?.group(recentCutoff: future) == .keep)
    #expect(found["locked"]?.group(recentCutoff: future) == .keep)
    #expect(found["brave-curie-1a2b3c"]?.group(recentCutoff: future) == .managed)
    #expect(found["gone"]?.group(recentCutoff: future) == .missing)
}

@Test func removesOnlyWhatIsSafe() async throws {
    let fixture = try Fixture()
    let merged = fixture.addWorktree("merged", branch: "feat-merged")
    let open = fixture.addWorktree("open", branch: "feat-open")
    fixture.write("c.txt", "c\n", in: open)
    fixture.commit("c", in: open)
    let dirty = fixture.addWorktree("dirty", branch: "feat-dirty")
    fixture.write("README.md", "edited\n", in: dirty)
    let managed = fixture.addWorktree(".claude/worktrees/brave-curie-1a2b3c", branch: "claude-app")

    let found = await fixture.scan()
    #expect(isDone(await Cleaner.removeWorktree(found["merged"]!)))
    #expect(!FileManager.default.fileExists(atPath: merged))
    #expect(fixture.git("branch", "--list", "feat-merged").text.contains("feat-merged"), "the branch stays")

    for (name, path) in [("open", open), ("dirty", dirty), ("brave-curie-1a2b3c", managed)] {
        let outcome = await Cleaner.removeWorktree(found[name]!)
        guard case .skipped = outcome else { Issue.record("\(name) was not skipped: \(outcome)"); continue }
        #expect(FileManager.default.fileExists(atPath: path), "\(name) must stay")
    }
}

@Test func recheckCatchesChangesMadeAfterTheScan() async throws {
    let fixture = try Fixture()
    let worktree = fixture.addWorktree("later", branch: "feat-later")
    let found = await fixture.scan()
    #expect(found["later"]?.group(recentCutoff: future) == .safe)

    fixture.write("new.txt", "new\n", in: worktree)
    fixture.commit("new work", in: worktree)
    let outcome = await Cleaner.removeWorktree(found["later"]!)
    guard case .skipped(let reason) = outcome else { Issue.record("expected a skip, got \(outcome)"); return }
    #expect(reason.contains("commits"))
    #expect(FileManager.default.fileExists(atPath: worktree))
}

@Test func keepsWorktreesThatAProgramIsUsing() async throws {
    let fixture = try Fixture()
    let worktree = fixture.addWorktree("busy", branch: "feat-busy")
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    sleeper.currentDirectoryURL = URL(fileURLWithPath: worktree + "/")
    try sleeper.run()
    defer { sleeper.terminate() }

    let found = await fixture.scan()
    #expect(found["busy"]?.inUse == true)
    #expect(found["busy"]?.group(recentCutoff: future) == .recent)
    let outcome = await Cleaner.removeWorktree(found["busy"]!)
    guard case .skipped = outcome else { Issue.record("expected a skip, got \(outcome)"); return }
    #expect(FileManager.default.fileExists(atPath: worktree))
}

@Test func removesWorktreesThatContainSubmodules() async throws {
    let fixture = try Fixture()
    let library = fixture.root + "/library"
    try FileManager.default.createDirectory(atPath: library, withIntermediateDirectories: true)
    fixture.git("init", "-q", "-b", "main", in: library)
    fixture.git("config", "user.name", "Test", in: library)
    fixture.git("config", "user.email", "test@example.com", in: library)
    fixture.write("lib.txt", "lib\n", in: library)
    fixture.commit("lib", in: library)
    fixture.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", library, "third_party/library")
    fixture.commit("add library")

    let worktree = fixture.addWorktree("with-submodule", branch: "feat-sub")
    fixture.git("-c", "protocol.file.allow=always", "submodule", "update", "-q", "--init", in: worktree)
    #expect(FileManager.default.fileExists(atPath: worktree + "/third_party/library/lib.txt"))
    #expect(!Shell.runBlocking("git", ["-C", fixture.repo, "worktree", "remove", worktree]).ok, "plain git refuses")

    let found = await fixture.scan()
    #expect(found["with-submodule"]?.group(recentCutoff: future) == .safe)
    #expect(isDone(await Cleaner.removeWorktree(found["with-submodule"]!)))
    #expect(!FileManager.default.fileExists(atPath: worktree))
}

@Test func deletesOnlyTheBuildFolder() async throws {
    let fixture = try Fixture()
    let worktree = fixture.addWorktree("open", branch: "feat-open")
    fixture.write("c.txt", "c\n", in: worktree)
    fixture.commit("c", in: worktree)
    fixture.write("build/output.o", String(repeating: "x", count: 10_000), in: worktree)

    let found = await fixture.scan()
    #expect(found["open"]?.group(recentCutoff: future) == .keep, "build output does not count as unsaved work")
    #expect((found["open"]?.buildBytes ?? 0) > 0)
    guard case .done = await Cleaner.removeBuildFolder(found["open"]!, otherWorktrees: []) else {
        Issue.record("the build folder was not deleted"); return
    }
    #expect(!FileManager.default.fileExists(atPath: worktree + "/build"))
    #expect(FileManager.default.fileExists(atPath: worktree + "/c.txt"))
}

@Test func prunesRecordsOfMissingFolders() async throws {
    let fixture = try Fixture()
    let gone = fixture.addWorktree("gone", branch: "feat-gone")
    try FileManager.default.removeItem(atPath: gone)
    let found = await fixture.scan()
    #expect(found["gone"]?.missing == true)
    #expect(await Cleaner.prune(found["gone"]!.repo) == .done(freed: 0))
    #expect(await fixture.scan().isEmpty)
}

@Test func reportsProgressForEachWorktree() async throws {
    let fixture = try Fixture()
    fixture.addWorktree("one", branch: "feat-one")
    fixture.addWorktree("two", branch: "feat-two")
    let messages = MessageLog()
    _ = await WorktreeScanner.scan(ScanOptions(roots: [fixture.root], fetch: false, useGitHub: false)) { messages.add($0) }
    let all = messages.all
    #expect(all.contains("Reading project"))
    #expect(all.contains("Checking worktrees · 0 of 2"))
    #expect(all.contains("Checking worktrees · 1 of 2"))
    #expect(all.contains("Checking worktrees · 2 of 2"))
    #expect(all.last == "Measuring build caches")
}

final class MessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func add(_ message: String) { lock.lock(); messages.append(message); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return messages }
}

@Test func parsesPorcelainOutput() {
    let text = """
    worktree /repo
    HEAD aaa
    branch refs/heads/main

    worktree /elsewhere/feature
    HEAD bbb
    branch refs/heads/feature/x
    locked reason

    worktree /tmp/old
    HEAD ccc
    detached
    prunable gitdir file points to non-existent location

    """
    let entries = WorktreeScanner.parseWorktreeList(text)
    #expect(entries.count == 3)
    #expect(entries[1] == WorktreeEntry(path: "/elsewhere/feature", head: "bbb", branch: "feature/x", locked: true))
    #expect(entries[2].branch == nil && entries[2].prunable)
}

@Test func recognisesWhoMadeAWorktree() {
    #expect(Owner.of(path: "/r/VSTS/.claude/worktrees/funny-bhabha-a49e91") == .claudeApp)
    #expect(Owner.of(path: "/r/VSTS/.claude/worktrees/bands-display-polish") == .claude)
    #expect(Owner.of(path: "/Users/x/.codex/worktrees/drum-lab/VSTS") == .codex)
    #expect(Owner.of(path: "/Users/x/CodexProjects/VSTS-ui-refresh") == .other)
}
