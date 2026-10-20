import SwiftUI
import WorktreeCore

@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            Usage: WorktreeCleaner                 open the app
                   WorktreeCleaner --report [--root PATH]... [--no-fetch] [--no-github] [--recent-hours N]
                                                   print the grouped report and exit (never removes anything)
            """)
            return
        }
        if arguments.contains("--report") {
            CommandLineReport.run(arguments)
            return
        }
        WorktreeCleanerApp.main()
    }
}

struct WorktreeCleanerApp: App {
    @State private var model = AppModel()

    init() {
        UserDefaults.standard.register(defaults: AppModel.defaults)
    }

    var body: some Scene {
        Window("Worktree Cleaner", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 620, minHeight: 480)
                .onAppear { Snapshot.runIfRequested(model) }
        }
        .defaultSize(width: 780, height: 600)
        Settings {
            SettingsView()
        }
    }
}

// `--report`: the same scan as the window, printed as text. Read-only.
enum CommandLineReport {
    static func run(_ arguments: [String]) {
        var roots: [String] = []
        var hours = 6
        for (index, argument) in arguments.enumerated() where index + 1 < arguments.count {
            if argument == "--root" { roots.append(arguments[index + 1]) }
            if argument == "--recent-hours" { hours = Int(arguments[index + 1]) ?? hours }
        }
        let options = ScanOptions(
            roots: roots.isEmpty ? ["~/CodexProjects"] : roots,
            fetch: !arguments.contains("--no-fetch"),
            useGitHub: !arguments.contains("--no-github")
        )
        let output = TextBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let result = await WorktreeScanner.scan(options) { message in
                FileHandle.standardError.write(Data("… \(message)\n".utf8))
            }
            let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
            output.text = Report.text(result, recentCutoff: cutoff, freeBytes: Report.freeBytes())
            done.signal()
        }
        done.wait()
        print(output.text)
    }
}

private final class TextBox: @unchecked Sendable {
    var text = ""
}
