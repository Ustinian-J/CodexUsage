import Foundation

enum ReadOnlySQLiteError: Error, Equatable {
    case launchFailed(String)
    case queryFailed(Int32, String)
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

    do {
        try process.run()
    } catch {
        return .failure(.launchFailed(error.localizedDescription))
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

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
