import Foundation

private final class CountingRuntimeProvider: RuntimeUsageProvider {
    let scope: RuntimeScope
    private(set) var snapshotLoadCount = 0

    init(scope: RuntimeScope) {
        self.scope = scope
    }

    func loadSnapshot(context: RuntimeLoadContext) -> RuntimeUsageSnapshot {
        snapshotLoadCount += 1
        return RuntimeUsageSnapshot(
            scope: scope,
            snapshot: .empty,
            status: .localOnly,
            quotaSourceLabel: "test",
            usageSourceLabel: "test"
        )
    }

    func loadTaskBoard(context: RuntimeLoadContext) -> TaskBoard? { nil }
}

enum RuntimeProviderScopeSelfTest {
    static func run() -> Bool {
        let codex = CountingRuntimeProvider(scope: .codex)
        let claude = CountingRuntimeProvider(scope: .claudeCode)
        let reader = MultiRuntimeUsageReader(
            registry: RuntimeProviderRegistry(providers: [codex, claude])
        )

        let filtered = reader.load(allowedScopes: [.codex])
        guard codex.snapshotLoadCount == 1,
              claude.snapshotLoadCount == 0,
              filtered.runtimes.map(\.scope) == [.codex]
        else {
            print("runtime provider scope self-test failed: hidden provider was read")
            return false
        }

        let all = reader.load()
        guard codex.snapshotLoadCount == 2,
              claude.snapshotLoadCount == 1,
              Set(all.runtimes.map(\.scope)) == Set(RuntimeScope.allCases)
        else {
            print("runtime provider scope self-test failed: enabled providers were not read")
            return false
        }

        guard runtimeScopedStatisticsCacheKey(
            resolvedIdentifier: "Asia/Shanghai",
            scopes: [.codex]
        ) != runtimeScopedStatisticsCacheKey(
            resolvedIdentifier: "Asia/Shanghai",
            scopes: [.codex, .claudeCode]
        ) else {
            print("runtime provider scope self-test failed: cache keys ignored runtime visibility")
            return false
        }
        guard runtimeScopedStatisticsCacheKey(
            resolvedIdentifier: filtered.statisticsIdentity.resolvedIdentifier,
            scopes: filtered.runtimes.map(\.scope)
        ) == runtimeScopedStatisticsCacheKey(
            resolvedIdentifier: filtered.statisticsIdentity.resolvedIdentifier,
            scopes: [.codex]
        ) else {
            print("runtime provider scope self-test failed: cache write/read keys diverged")
            return false
        }

        print("runtime provider scope self-test passed")
        return true
    }
}
