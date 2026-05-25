import Foundation

struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) -> CommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        let timeoutWork = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        let stdoutData = readAll(stdoutPipe.fileHandleForReading)
        let stderrData = readAll(stderrPipe.fileHandleForReading)
        _ = finished.wait(timeout: .now() + 1)
        timeoutWork.cancel()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    private static func readAll(_ handle: FileHandle) -> Data {
        var result = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                return result
            }
            result.append(chunk)
        }
    }
}
