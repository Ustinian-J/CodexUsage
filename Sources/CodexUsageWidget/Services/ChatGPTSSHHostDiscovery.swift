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
    case unsupportedConnection
}

enum ChatGPTSSHHostDiscovery {
    private static let chatGPTExecutable = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
    private static let sshExecutable = "/usr/bin/ssh"
    private static let maximumOutputBytes = 4 * 1_024 * 1_024


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
        // ps does not preserve argv quoting. Refuse connections whose options
        // cannot be reproduced instead of silently monitoring a different host.
        for line in commandText.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), sshProcessIDs.contains(pid),
                  sshHost(in: String(fields[1])) != nil
            else { return .failure(.unsupportedConnection) }
        }
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
        let outputCollector = CodexBoundedPipeCollector(maximumBytes: maximumBytes)
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
        let tokens = commandLine.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard isSSHExecutable(tokens.first) else { return nil }
        var index = 1
        var user: String?
        var port: Int?
        var configurationPath: String?
        func destination(_ token: String) -> String? {
            guard let host = CodexRemoteHost.validatedDestination(token) else { return nil }
            let target: String
            if let user {
                guard !host.contains("@") else { return nil }
                target = user + "@" + host
            } else { target = host }
            return CodexSSHConnection.validated(destination: target, port: port, configurationPath: configurationPath)?.identifier
        }
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                return index + 1 < tokens.count ? destination(tokens[index + 1]) : nil
            }
            if !token.hasPrefix("-") { return destination(token) }
            if token == "-l" || token.hasPrefix("-l") && token.count > 2 {
                let value: String
                if token == "-l" {
                    guard index + 1 < tokens.count else { return nil }
                    index += 1
                    value = tokens[index]
                } else { value = String(token.dropFirst(2)) }
                guard let validated = CodexRemoteHost.validatedDestination(value), !validated.contains("@") else { return nil }
                user = validated
            } else if token == "-p" || token.hasPrefix("-p") && token.count > 2 {
                let value: String
                if token == "-p" {
                    guard index + 1 < tokens.count else { return nil }
                    index += 1
                    value = tokens[index]
                } else { value = String(token.dropFirst(2)) }
                guard value.allSatisfy({ $0.isASCII && $0.isNumber }), let parsed = Int(value), (1...65535).contains(parsed) else { return nil }
                port = parsed
            } else if token == "-F" || token.hasPrefix("-F") && token.count > 2 {
                if token == "-F" {
                    guard index + 1 < tokens.count else { return nil }
                    index += 1
                    configurationPath = tokens[index]
                } else { configurationPath = String(token.dropFirst(2)) }
            } else if token == "-o" || token.hasPrefix("-o") && token.count > 2 {
                let value: String
                if token == "-o" {
                    guard index + 1 < tokens.count else { return nil }
                    index += 1
                    value = tokens[index]
                } else { value = String(token.dropFirst(2)) }
                guard supportsTransportOption(value) else { return nil }
            } else {
                // Identity files and arbitrary -o values
                // need a structured argv source; a ps command string is insufficient.
                guard token.count > 1, token.dropFirst().allSatisfy({ "TtvqnxN46".contains($0) }) else { return nil }
            }
            index += 1
        }
        return nil
    }

    private static func supportsTransportOption(_ value: String) -> Bool {
        let parts = value.lowercased().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        switch parts[0] {
        case "batchmode", "tcpkeepalive":
            return parts[1] == "yes" || parts[1] == "no"
        case "connecttimeout", "serveraliveinterval", "serveralivecountmax":
            // These affect transport liveness, not the connection destination.
            // The observer supplies its own bounded transport policy.
            return !parts[1].isEmpty && parts[1].allSatisfy({ $0.isASCII && $0.isNumber })
                && Int32(parts[1]).map { $0 >= 0 } == true
        default:
            return false
        }
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
        value == chatGPTExecutable || value == "ChatGPT" || value == "Codex"
            || value == "/Applications/Codex.app/Contents/MacOS/Codex"
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
