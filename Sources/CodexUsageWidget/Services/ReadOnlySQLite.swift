import Foundation

enum ReadOnlySQLiteError: Error, Equatable {
    case launchFailed(String)
    case queryFailed(Int32, String)
    case timedOut
    case outputTooLarge
    case invalidJSON
}

func runReadOnlySQLiteJSON(
    sqlitePath: String,
    dbPath: String,
    query: String
) -> Result<[[String: Any]], ReadOnlySQLiteError> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: sqlitePath)
    process.arguments = ["-readonly", "-json", dbPath, query]

    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    let stdout = CodexBoundedPipeCollector(maximumBytes: 64 * 1024 * 1024)
    let stderr = CodexBoundedPipeCollector(maximumBytes: 16 * 1024)
    stdout.start(output.fileHandleForReading)
    stderr.start(error.fileHandleForReading)
    defer { stdout.cancel(); stderr.cancel() }
    do {
        try process.run()
    } catch {
        return .failure(.launchFailed(error.localizedDescription))
    }

    guard finished.wait(timeout: .now() + 10) == .success else {
        if process.isRunning { process.terminate() }
        if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        return .failure(.timedOut)
    }
    guard let data = stdout.result(timeout: .seconds(1)) else { return .failure(.outputTooLarge) }
    let errorData = stderr.result(timeout: .seconds(1)) ?? Data()

    guard process.terminationStatus == 0 else {
        let message = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failure(.queryFailed(process.terminationStatus, message))
    }
    guard !data.isEmpty else { return .success([]) }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return .failure(.invalidJSON)
    }

    return .success(json)
}
