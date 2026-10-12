import Foundation

enum CodexEnvironmentResolverSelfTest {
    static func run() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-environment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let app = root.appendingPathComponent("Renamed Desktop.app")
            let modern = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
            let wrapper = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
            let legacy = app.appendingPathComponent("Contents/Resources/codex")
            let broken = root.appendingPathComponent("bin/codex")
            for path in [modern, wrapper, legacy, broken] {
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("#!/bin/sh\nexit 1\n".utf8).write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }
            let variables = ["PATH": broken.deletingLastPathComponent().path, "CODEX_HOME": root.appendingPathComponent("data").path]
            func resolved(_ variables: [String: String]) -> CodexEnvironmentResolver {
                CodexEnvironmentResolver(context: .live(), variables: variables, desktopApplications: [app])
            }
            guard resolved(variables).executablePath == modern.path,
                  resolved(variables).dataDirectory.path == variables["CODEX_HOME"] else { return false }
            try FileManager.default.removeItem(at: modern)
            guard resolved(variables).executablePath == wrapper.path else { return false }
            try FileManager.default.removeItem(at: wrapper)
            guard resolved(variables).executablePath == legacy.path else { return false }
            var overridden = variables
            overridden["CODEXUSAGE_CODEX_EXECUTABLE"] = broken.path
            guard resolved(overridden).executablePath == broken.path else { return false }
            print("Codex environment resolver self-test passed")
            return true
        } catch {
            print("Codex environment resolver self-test failed: \(error)")
            return false
        }
    }
}
