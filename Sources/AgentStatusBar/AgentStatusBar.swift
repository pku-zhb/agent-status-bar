import AppKit
import Foundation

@main
struct AgentStatusBar {
    static func main() {
        if CommandLine.arguments.contains("--once") {
            printSnapshot()
            return
        }
        if CommandLine.arguments.contains("--debug-ps") {
            debugPs()
            return
        }
        if CommandLine.arguments.contains("--credits") {
            printCredits()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        _ = delegate
    }

    private static func printSnapshot() {
        let snapshot = AgentScanner().scan()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(snapshot),
              let text = String(data: data, encoding: .utf8) else {
            fputs("failed to encode snapshot\n", stderr)
            Foundation.exit(1)
        }

        print(text)
    }

    private static func debugPs() {
        guard let result = ProcessRunner.run("/bin/ps", ["-axo", "pid,ppid,comm,args"], timeout: 3) else {
            print("ps failed to start")
            return
        }
        print("exit=\(result.exitCode)")
        if !result.stderr.isEmpty {
            print("stderr:\n\(result.stderr)")
        }
        print("stdout:\n\(result.stdout)")
    }

    private static func printCredits() {
        let snapshot = CreditScanner().scan()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(snapshot),
              let text = String(data: data, encoding: .utf8) else {
            fputs("failed to encode credit snapshot\n", stderr)
            Foundation.exit(1)
        }

        print(text)
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplicationIcon()
        controller = MenuBarController()
    }

    private func configureApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApplication.shared.applicationIconImage = icon
    }
}
