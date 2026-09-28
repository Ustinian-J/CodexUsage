import Cocoa

struct CodexEnvironmentResolver {
    let dataDirectory: URL
    let cacheDirectory: URL
    let executablePath: String?

    private static let versionLock = NSLock()
    private static var versions: [String: (Date?, String)] = [:]

    func executableVersion() -> String {
        guard let path = executablePath else { return "unknown" }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        Self.versionLock.lock()
        defer { Self.versionLock.unlock() }
        if let cached = Self.versions[path], cached.0 == modified { return cached.1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let stdout = CodexBoundedPipeCollector(maximumBytes: 1024)
        let stderr = CodexBoundedPipeCollector(maximumBytes: 1024)
        stdout.start(output.fileHandleForReading); stderr.start(error.fileHandleForReading)
        defer { stdout.cancel(); stderr.cancel() }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        var version = "unknown"
        if (try? process.run()) != nil {
            if exited.wait(timeout: .now() + 1) == .success,
               let data = stdout.result(timeout: .milliseconds(100)),
               let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.range(of: #"^codex(-cli)? [0-9][0-9A-Za-z.+-]*$"#, options: .regularExpression) != nil { version = text }
            else if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        Self.versions[path] = (modified, version)
        return version
    }

    init(context: RuntimeLoadContext, variables: [String: String] = ProcessInfo.processInfo.environment) {
        dataDirectory = variables["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? context.homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        cacheDirectory = context.cacheDirectory
        var candidates: [String] = []
        if let override = variables["CODEXUSAGE_CODEX_EXECUTABLE"] {
            executablePath = FileManager.default.isExecutableFile(atPath: override) ? override : nil
            return
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            candidates.append(app.appendingPathComponent("Contents/Resources/codex").path)
        }
        candidates += ["/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"]
        candidates += (variables["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        executablePath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
