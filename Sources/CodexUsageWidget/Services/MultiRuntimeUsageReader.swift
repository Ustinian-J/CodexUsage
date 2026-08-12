import Foundation

final class MultiRuntimeUsageReader {
    private let registry: RuntimeProviderRegistry
    private let aggregator: AgentUsageAggregator

    init(
        registry: RuntimeProviderRegistry = RuntimeProviderRegistry(),
        aggregator: AgentUsageAggregator = AgentUsageAggregator()
    ) {
        self.registry = registry
        self.aggregator = aggregator
    }

    func load(
        statisticsPreference: StatisticsTimeZonePreference = .default,
        generation: UInt64 = 0,
        allowedScopes: Set<RuntimeScope> = Set(RuntimeScope.allCases)
    ) -> MultiRuntimeUsageSnapshot {
        let context = RuntimeLoadContext.live(statisticsPreference: statisticsPreference)
        let runtimeSnapshots = registry.providers.filter { provider in
            allowedScopes.contains(provider.scope)
        }.map { provider in
            provider.loadSnapshot(context: context)
        }
        let refreshedAt = Date()
        let aggregate = aggregator.aggregate(runtimeSnapshots, at: refreshedAt)
        return MultiRuntimeUsageSnapshot(
            refreshedAt: refreshedAt,
            runtimes: runtimeSnapshots,
            aggregate: aggregate,
            statisticsIdentity: StatisticsIdentity(
                preference: context.statistics.preference,
                resolvedIdentifier: context.statistics.resolvedIdentifier,
                generation: generation,
                now: context.now
            )
        )
    }

    func loadTaskBoard(
        scope: RuntimeScope,
        statisticsPreference: StatisticsTimeZonePreference = .default
    ) -> TaskBoard? {
        let context = RuntimeLoadContext.live(statisticsPreference: statisticsPreference)
        return registry.provider(for: scope)?.loadTaskBoard(context: context)
    }
}
