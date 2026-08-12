import Darwin
import Foundation

enum SkillFileAccessPolicy {
    static let maximumByteCount = 1 * 1024 * 1024

    static func validatedPath(
        _ rawPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let homePath = homeDirectory.standardizedFileURL.path
        let expanded = rawPath.hasPrefix("~/")
            ? homePath + String(rawPath.dropFirst())
            : rawPath
        guard expanded.hasPrefix("/") else { return nil }

        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard url.lastPathComponent == "SKILL.md",
              isInsideApprovedRoot(url.path, homePath: homePath),
              url.resolvingSymlinksInPath().path == url.path
        else { return nil }

        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_size >= 0,
              info.st_size <= maximumByteCount
        else { return nil }
        return url.path
    }

    static func read(
        path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Data? {
        guard let validated = validatedPath(path, homeDirectory: homeDirectory) else { return nil }
        let descriptor = Darwin.open(validated, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_size >= 0,
              info.st_size <= maximumByteCount
        else { return nil }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: maximumByteCount + 1),
              data.count <= maximumByteCount
        else { return nil }
        return data
    }

    private static func isInsideApprovedRoot(_ path: String, homePath: String) -> Bool {
        let roots = [
            homePath + "/.codex/skills",
            homePath + "/.codex/plugins/cache",
            homePath + "/.agents/skills"
        ]
        return roots.contains { path.hasPrefix($0 + "/") }
    }
}
