import Darwin
import Foundation

enum SecureDebugLogWriter {
    static func append(
        _ data: Data,
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let directory = baseDirectory.appendingPathComponent("CodexS", isDirectory: true)
        guard prepareDirectory(directory) else { return false }

        let path = directory.appendingPathComponent("debug.log").path
        let descriptor = Darwin.open(
            path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else { return false }

        return data.withUnsafeBytes { bytes in
            guard var address = bytes.baseAddress else { return data.isEmpty }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                guard written > 0 else { return false }
                remaining -= written
                address = address.advanced(by: written)
            }
            return true
        }
    }

    private static func prepareDirectory(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                return false
            }
        }

        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              chmod(url.path, 0o700) == 0
        else { return false }
        return true
    }
}
