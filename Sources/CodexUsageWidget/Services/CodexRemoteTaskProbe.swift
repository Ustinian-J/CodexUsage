import Foundation

// Runs the actual observer without opening the UI or modifying saved task state.
enum CodexRemoteTaskProbe {
    static func run() -> Bool {
        guard case let .success(discovery) = ChatGPTSSHHostDiscovery.discover(),
              !discovery.hosts.isEmpty else {
            print("Remote probe: no discoverable desktop task hosts")
            return false
        }
        let lock = NSLock()
        var ready = Set<String>()
        var eventCounts: [String: Int] = [:]
        var excludedCounts: [String: Int] = [:]
        var scanCounts: [String: Int] = [:]
        var checkpoints: [String: Date] = [:]
        var confirmedCounts: [String: Int] = [:]
        var errors: [String: String] = [:]
        let monitors = discovery.hosts.map { host in
            RemoteCodexTaskMonitor(host: host, recoveryCheckpoint: nil) { update in
                lock.lock()
                defer { lock.unlock() }
                switch update {
                case let .events(events, _): eventCounts[host, default: 0] += events.count
                case .excludedThread: excludedCounts[host, default: 0] += 1
                case let .ready(checkpoint, confirmed):
                    ready.insert(host)
                    errors.removeValue(forKey: host)
                    if checkpoints[host] != checkpoint { scanCounts[host, default: 0] += 1 }
                    checkpoints[host] = checkpoint
                    confirmedCounts[host] = confirmed.count
                    print("\(CodexRemoteHost.displayName(host)): verified scan \(scanCounts[host, default: 0])")
                    fflush(stdout)
                case .connecting:
                    ready.remove(host)
                    scanCounts[host] = 0
                    checkpoints.removeValue(forKey: host)
                case let .unavailable(message):
                    ready.remove(host)
                    errors[host] = message
                    print(message)
                    fflush(stdout)
                }
            }
        }
        for monitor in monitors { monitor.authorize() }
        defer { for monitor in monitors { monitor.stop() } }
        let deadline = Date().addingTimeInterval(100)
        while Date() < deadline {
            lock.lock()
            let allReady = ready.count == discovery.hosts.count && discovery.hosts.allSatisfy { scanCounts[$0, default: 0] >= 3 }
            lock.unlock()
            if allReady { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        lock.lock()
        defer { lock.unlock() }
        for host in discovery.hosts {
            print("\(CodexRemoteHost.displayName(host)): \(ready.contains(host) ? "ready" : "unavailable"), verified scans=\(scanCounts[host, default: 0]), task events=\(eventCounts[host, default: 0]), excluded internal threads=\(excludedCounts[host, default: 0]), confirmed turns=\(confirmedCounts[host, default: 0])")
            if let error = errors[host] { print(error) }
        }
        return ready.count == discovery.hosts.count && discovery.hosts.allSatisfy { scanCounts[$0, default: 0] >= 3 } && discovery.issues.isEmpty
    }
}
