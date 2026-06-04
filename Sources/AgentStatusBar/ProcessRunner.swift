import Foundation

struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 5,
        stdin: String? = nil,
        closeStdinAfter: TimeInterval = 0,
        environment: [String: String]? = nil
    ) -> CommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = stdin == nil ? nil : Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        if let stdin, let stdinPipe {
            let writer = stdinPipe.fileHandleForWriting
            writer.write(Data(stdin.utf8))
            if closeStdinAfter > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + closeStdinAfter) {
                    writer.closeFile()
                }
            } else {
                writer.closeFile()
            }
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
