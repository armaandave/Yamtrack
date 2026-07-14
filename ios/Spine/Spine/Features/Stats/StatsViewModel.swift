import Foundation

enum StatsViewState: Equatable {
    case initial
    case loading
    case loaded(StatsSummary)
    case empty
    case error(String)
}

@MainActor
@Observable
final class StatsViewModel {
    private struct LoadedSnapshot {
        let period: StatsPeriod
        let summary: StatsSummary
    }

    var state: StatsViewState = .initial
    var selectedPeriod: StatsPeriod

    private let profileRepository: ProfileRepository
    private let username: String?
    private let onUnauthorized: () -> Void
    private var requestGeneration = 0
    private var loadedSnapshot: LoadedSnapshot?

    init(
        profileRepository: ProfileRepository,
        username: String? = nil,
        selectedPeriod: StatsPeriod = .allTime,
        onUnauthorized: @escaping () -> Void
    ) {
        self.profileRepository = profileRepository
        self.username = username
        self.selectedPeriod = selectedPeriod
        self.onUnauthorized = onUnauthorized
    }

    var summary: StatsSummary? {
        guard case let .loaded(summary) = state else { return nil }
        return summary
    }

    var isLoading: Bool {
        state == .loading
    }

    var errorMessage: String? {
        guard case let .error(message) = state else { return nil }
        return message
    }

    func load() async {
        requestGeneration &+= 1
        let generation = requestGeneration
        let requestedPeriod = selectedPeriod
        state = .loading

        do {
            let summary = try await profileRepository.statsSummary(
                username: username,
                period: requestedPeriod
            )
            guard generation == requestGeneration, requestedPeriod == selectedPeriod else { return }

            if summary.isEmpty {
                loadedSnapshot = nil
                state = .empty
            } else {
                loadedSnapshot = LoadedSnapshot(period: requestedPeriod, summary: summary)
                state = .loaded(summary)
            }
        } catch is CancellationError {
            guard generation == requestGeneration, requestedPeriod == selectedPeriod else { return }
            if let loadedSnapshot, loadedSnapshot.period == requestedPeriod {
                state = .loaded(loadedSnapshot.summary)
            } else {
                state = .initial
            }
        } catch {
            guard generation == requestGeneration, requestedPeriod == selectedPeriod else { return }
            state = .error(error.localizedDescription)
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }

    func reload() async {
        await load()
    }

    func retry() async {
        await load()
    }

    func selectPeriod(_ period: StatsPeriod) async {
        guard selectedPeriod != period else {
            if state == .initial {
                await load()
            }
            return
        }
        selectedPeriod = period
        await load()
    }
}
