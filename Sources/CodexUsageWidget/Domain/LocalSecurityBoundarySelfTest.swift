import Darwin
import Foundation

enum LocalSecurityBoundarySelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CodexS-security-self-test-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        do {
            let skill = home.appendingPathComponent(".codex/skills/test/SKILL.md")
            try fileManager.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("safe".utf8).write(to: skill)
            expect(
                SkillFileAccessPolicy.validatedPath(skill.path, homeDirectory: home) == skill.path,
                "approved Skill path must be accepted"
            )
            expect(
                SkillFileAccessPolicy.read(path: skill.path, homeDirectory: home) == Data("safe".utf8),
                "approved Skill content must be read"
            )

            let arbitrary = home.appendingPathComponent("private/SKILL.md")
            try fileManager.createDirectory(at: arbitrary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: arbitrary)
            expect(
                SkillFileAccessPolicy.validatedPath(arbitrary.path, homeDirectory: home) == nil,
                "arbitrary Home files must be rejected"
            )

            let outside = root.appendingPathComponent("outside/SKILL.md")
            try fileManager.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: outside)
            let link = home.appendingPathComponent(".agents/skills/link/SKILL.md")
            try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)
            expect(
                SkillFileAccessPolicy.validatedPath(link.path, homeDirectory: home) == nil,
                "Skill symlinks must be rejected"
            )

            let maximum = home.appendingPathComponent(".agents/skills/maximum/SKILL.md")
            try fileManager.createDirectory(at: maximum.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: SkillFileAccessPolicy.maximumByteCount).write(to: maximum)
            expect(
                SkillFileAccessPolicy.read(path: maximum.path, homeDirectory: home)?.count
                    == SkillFileAccessPolicy.maximumByteCount,
                "a Skill at the exact size limit must remain readable"
            )

            let oversized = home.appendingPathComponent(".agents/skills/large/SKILL.md")
            try fileManager.createDirectory(at: oversized.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: SkillFileAccessPolicy.maximumByteCount + 1).write(to: oversized)
            expect(
                SkillFileAccessPolicy.read(path: oversized.path, homeDirectory: home) == nil,
                "oversized Skill files must be rejected"
            )

            let logs = root.appendingPathComponent("logs", isDirectory: true)
            expect(SecureDebugLogWriter.append(Data("one\n".utf8), baseDirectory: logs), "secure log append must succeed")
            expect(SecureDebugLogWriter.append(Data("two\n".utf8), baseDirectory: logs), "secure log second append must succeed")
            let log = logs.appendingPathComponent("CodexS/debug.log")
            expect((try? String(contentsOf: log, encoding: .utf8)) == "one\ntwo\n", "secure log must append")
            var logInfo = stat()
            expect(lstat(log.path, &logInfo) == 0 && logInfo.st_mode & 0o777 == 0o600, "secure log mode must be 0600")
            var directoryInfo = stat()
            expect(
                lstat(log.deletingLastPathComponent().path, &directoryInfo) == 0
                    && directoryInfo.st_mode & 0o777 == 0o700,
                "secure log directory mode must be 0700"
            )

            let hostile = root.appendingPathComponent("hostile", isDirectory: true)
            let hostileDirectory = hostile.appendingPathComponent("CodexS", isDirectory: true)
            try fileManager.createDirectory(at: hostileDirectory, withIntermediateDirectories: true)
            let victim = root.appendingPathComponent("victim.txt")
            try Data("unchanged".utf8).write(to: victim)
            try fileManager.createSymbolicLink(
                at: hostileDirectory.appendingPathComponent("debug.log"),
                withDestinationURL: victim
            )
            expect(
                !SecureDebugLogWriter.append(Data("attack".utf8), baseDirectory: hostile),
                "secure log must reject symlink targets"
            )
            expect((try? String(contentsOf: victim, encoding: .utf8)) == "unchanged", "symlink target must remain unchanged")
        } catch {
            failures.append("security self-test setup failed: \(error.localizedDescription)")
        }

        if failures.isEmpty {
            print("local security boundary self-test passed")
            return true
        }
        for failure in failures { print("local security boundary self-test failed: \(failure)") }
        return false
    }
}
