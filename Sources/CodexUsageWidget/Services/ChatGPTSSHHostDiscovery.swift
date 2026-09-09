import Darwin
import Foundation

struct ChatGPTProcessRecord: Equatable {
    let processID: Int32
    let parentProcessID: Int32
    let arguments: String
}

enum ChatGPTSSHHostDiscoveryError: Error {
    case unavailable
    case invalidOutput
}

enum ChatGPTSSHHostDiscovery {
    private static let chatGPTExecutable = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
    private static let sshExecutable = "/usr/bin/ssh"
    private static let maximumOutputBytes = 4 * 1_024 * 1_024
    private static let optionsWithValues: Set<String> = [
        "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l",
        "-m", "-O", "-o", "-P", "-p", "-Q", "-R", "-S", "-W", "-w"
    ]

    static func discover() -> Result<[String], ChatGPTSSHHostDiscoveryError> {
        guard FileManager.default.isExecutableFile(atPath: "/bin/ps") else {
            return .failure(.unavailable)
        }
        guard case let .success(snapshotData) = runPS(
            arguments: ["-axo", "pid=,ppid=,ucomm="],
            maximumBytes: maximumOutputBytes
        ), let snapshotText = String(data: snapshotData, encoding: .utf8)
        else { return .failure(.invalidOutput) }
        let snapshot = parseProcessList(snapshotText)
        let sshProcessIDs = chatGPTSSHProcessIDs(in: snapshot)
        guard !sshProcessIDs.isEmpty else { return .success([]) }
        let processList = sshProcessIDs.map(String.init).joined(separator: ",")
        guard case let .success(commandData) = runPS(
            arguments: ["-ww", "-p", processList, "-o", "pid=,args="],
            maximumBytes: 256 * 1_024
        ), let commandText = String(data: commandData, encoding: .utf8)
        else { return .failure(.invalidOutput) }
        return .success(hosts(inSSHCommandList: commandText, allowedProcessIDs: Set(sshProcessIDs)))
    }

    private static func runPS(
        arguments: [String],
        maximumBytes: Int
    ) -> Result<Data, ChatGPTSSHHostDiscoveryError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let outputCollector = CodexBoundedPipeCollector(maximumBytes: maximumOutputBytes)
        let errorCollector = CodexBoundedPipeCollector(maximumBytes: 64 * 1_024)
        outputCollector.start(output.fileHandleForReading)
        errorCollector.start(error.fileHandleForReading)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            outputCollector.cancel()
            errorCollector.cancel()
            return .failure(.unavailable)
        }
        if exited.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            outputCollector.cancel()
            errorCollector.cancel()
            return .failure(.unavailable)
        }
        guard process.terminationStatus == 0,
              let outputData = outputCollector.result(timeout: .seconds(1)),
              let errorData = errorCollector.result(timeout: .seconds(1)),
              errorData.isEmpty
        else { return .failure(.invalidOutput) }
        return .success(outputData)
    }

    static func parseProcessList(_ output: String) -> [ChatGPTProcessRecord] {
        output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \Character.isWhitespace)
            guard fields.count == 3,
                  let processID = Int32(fields[0]),
                  let parentProcessID = Int32(fields[1])
            else { return nil }
            return ChatGPTProcessRecord(
                processID: processID,
                parentProcessID: parentProcessID,
                arguments: String(fields[2])
            )
        }
    }

    static func hosts(in records: [ChatGPTProcessRecord]) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.processID, $0) })
        let chatGPTRoots = Set(records.compactMap { record -> Int32? in
            isChatGPTExecutable(firstArgument(in: record.arguments)) ? record.processID : nil
        })
        guard !chatGPTRoots.isEmpty else { return [] }

        var seen = Set<String>()
        return records.compactMap { record -> String? in
            guard isSSHExecutable(firstArgument(in: record.arguments)),
                  hasAncestor(record.parentProcessID, in: chatGPTRoots, recordsByID: byID),
                  let host = sshHost(in: record.arguments),
                  seen.insert(host.lowercased()).inserted
            else { return nil }
            return host
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func hosts(inSSHCommandList output: String, allowedProcessIDs: Set<Int32>) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \Character.isNewline).compactMap { line -> String? in
            let fields = line.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
            guard fields.count == 2,
                  let processID = Int32(fields[0]),
                  allowedProcessIDs.contains(processID),
                  let host = sshHost(in: String(fields[1])),
                  seen.insert(host.lowercased()).inserted
            else { return nil }
            return host
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func sshHost(in commandLine: String) -> String? {
        var tokens = commandLine.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard tokens.first == sshExecutable else { return nil }
        tokens.removeFirst()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                return index < tokens.count ? CodexRemoteHost.validated(tokens[index]) : nil
            }
            if !token.hasPrefix("-") || token == "-" {
                return CodexRemoteHost.validated(token)
            }
            if optionsWithValues.contains(token) {
                index += 2
            } else {
                index += 1
            }
        }
        return nil
    }

    private static func firstArgument(in commandLine: String) -> String? {
        commandLine.split(whereSeparator: \Character.isWhitespace).first.map(String.init)
    }

    private static func chatGPTSSHProcessIDs(in records: [ChatGPTProcessRecord]) -> [Int32] {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.processID, $0) })
        let roots = Set(records.compactMap { record -> Int32? in
            isChatGPTExecutable(firstArgument(in: record.arguments)) ? record.processID : nil
        })
        return records.compactMap { record in
            isSSHExecutable(firstArgument(in: record.arguments))
                && hasAncestor(record.parentProcessID, in: roots, recordsByID: byID)
                ? record.processID : nil
        }.sorted()
    }

    private static func isChatGPTExecutable(_ value: String?) -> Bool {
        value == chatGPTExecutable || value == "ChatGPT"
    }

    private static func isSSHExecutable(_ value: String?) -> Bool {
        value == sshExecutable || value == "ssh"
    }

    private static func hasAncestor(
        _ initialProcessID: Int32,
        in roots: Set<Int32>,
        recordsByID: [Int32: ChatGPTProcessRecord]
    ) -> Bool {
        var processID = initialProcessID
        var visited = Set<Int32>()
        while processID > 0, visited.insert(processID).inserted {
            if roots.contains(processID) { return true }
            guard let record = recordsByID[processID] else { return false }
            processID = record.parentProcessID
        }
        return false
    }
}
