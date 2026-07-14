import SwiftUI

struct StatsView: View {
    @State private var viewModel: StatsViewModel
    @State private var selectedMediaType: String?
    @State private var selectedRef: MediaRef?

    private let mediaRepository: MediaRepository
    private let trackingRepository: TrackingRepository
    private let diaryRepository: DiaryRepository
    private let listRepository: ListRepository
    private let currentUserId: Int?
    private let selectedTab: AppTab
    private let onSelectTab: (AppTab) -> Void
    private let onUnauthorized: () -> Void

    init(
        profileRepository: ProfileRepository,
        mediaRepository: MediaRepository,
        trackingRepository: TrackingRepository,
        diaryRepository: DiaryRepository,
        listRepository: ListRepository,
        currentUserId: Int? = nil,
        selectedTab: AppTab = .profile,
        onSelectTab: @escaping (AppTab) -> Void = { _ in },
        username: String? = nil,
        onUnauthorized: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: StatsViewModel(
            profileRepository: profileRepository,
            username: username,
            onUnauthorized: onUnauthorized
        ))
        self.mediaRepository = mediaRepository
        self.trackingRepository = trackingRepository
        self.diaryRepository = diaryRepository
        self.listRepository = listRepository
        self.currentUserId = currentUserId
        self.selectedTab = selectedTab
        self.onSelectTab = onSelectTab
        self.onUnauthorized = onUnauthorized
    }

    var body: some View {
        ZStack {
            SpinePageBackground()

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 22) {
                    periodPicker
                    stateContent
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 40)
            }
            .refreshable {
                await viewModel.reload()
            }
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task {
            if case .initial = viewModel.state {
                await viewModel.load()
            }
        }
        .fullScreenCover(item: $selectedRef, onDismiss: { selectedRef = nil }) { ref in
            MediaDetailView(
                ref: ref,
                mediaRepository: mediaRepository,
                trackingRepository: trackingRepository,
                diaryRepository: diaryRepository,
                listRepository: listRepository,
                currentUserId: currentUserId,
                selectedTab: selectedTab,
                onSelectTab: onSelectTab,
                onUnauthorized: onUnauthorized
            )
        }
    }

    private var periodPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([StatsPeriod.allTime] + StatsPeriod.recentYears()) { period in
                    Button {
                        Task { await viewModel.selectPeriod(period) }
                    } label: {
                        HStack(spacing: 6) {
                            if viewModel.isLoading, viewModel.selectedPeriod == period {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.white)
                            }
                            Text(period.title)
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(viewModel.selectedPeriod == period ? 0.96 : 0.48))
                        .padding(.horizontal, 13)
                        .frame(height: 34)
                        .background(
                            viewModel.selectedPeriod == period ? Color.white.opacity(0.13) : Color.white.opacity(0.035),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .stroke(.white.opacity(viewModel.selectedPeriod == period ? 0.16 : 0.055), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show stats for \(period.title)")
                    .accessibilityAddTraits(viewModel.selectedPeriod == period ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.state {
        case .initial, .loading:
            StatsLoadingView()
                .spineContentTransition(value: StatsContentPhase.loading)
        case let .loaded(summary):
            statsContent(summary)
                .spineContentTransition(value: StatsContentPhase.loaded(viewModel.selectedPeriod.id))
        case .empty:
            StatsEmptyView(
                title: "Your stats are waiting",
                message: "Track or log something in this period to start seeing your media story."
            )
            .spineContentTransition(value: StatsContentPhase.empty)
        case let .error(message):
            StatsErrorView(message: message) {
                Task { await viewModel.retry() }
            }
            .spineContentTransition(value: StatsContentPhase.error)
        }
    }

    private func statsContent(_ summary: StatsSummary) -> some View {
        let scope = StatsScopeSnapshot(summary: summary, mediaType: selectedMediaType)
        let accent = StatsPalette.accent(for: selectedMediaType)

        return VStack(alignment: .leading, spacing: 26) {
            StatsHero(summary: summary, period: viewModel.selectedPeriod)

            personSection(summary, accent: StatsPalette.allMedia)

            mediaScopePicker(summary)

            if scope.isEmpty {
                StatsEmptyView(
                    title: "No \(scope.title.lowercased()) stats yet",
                    message: "Choose another media type or period to explore your history."
                )
            } else {
                scopeOverview(scope, summary: summary, accent: accent)

                if selectedMediaType == nil {
                    mediaMixSection(summary)
                }

                statusSection(scope, accent: accent)
                ratingSection(scope, accent: accent)
                releaseYearSection(scope, accent: accent)
                tasteSections(scope, accent: accent)
                mediaRails(scope, accent: accent)
            }
        }
    }

    @ViewBuilder
    private func personSection(_ summary: StatsSummary, accent: Color) -> some View {
        let activityPoints = summary.activity.days.compactMap { day -> SWStatsActivityPoint? in
            guard let date = day.parsedDate else { return nil }
            return SWStatsActivityPoint(date: date, count: day.count)
        }
        let weekday = summary.activity.mostActiveWeekday

        StatsSection(title: "Your rhythm", subtitle: "Diary activity for \(viewModel.selectedPeriod.title)") {
            StatsMetricGrid(items: [
                StatsMetricItem(
                    title: "Active days",
                    value: summary.overview.activeDays.formatted(),
                    systemName: "calendar",
                    tint: accent
                ),
                StatsMetricItem(
                    title: "Current streak",
                    value: StatsCopy.days(summary.overview.currentStreakDays),
                    systemName: "flame.fill",
                    tint: .orange
                ),
                StatsMetricItem(
                    title: "Longest streak",
                    value: StatsCopy.days(summary.overview.longestStreakDays),
                    systemName: "trophy.fill",
                    tint: .yellow
                ),
                StatsMetricItem(
                    title: "Most active",
                    value: weekday?.name ?? "—",
                    detail: weekday.map { "\($0.percentage.formatted(.number.precision(.fractionLength(0...1))))% of active days" },
                    systemName: "clock.fill",
                    tint: .mint
                ),
            ])

            if !activityPoints.isEmpty {
                StatsSurface {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("ACTIVITY HISTORY")
                            Spacer()
                            Text("\(summary.overview.diaryEntryCount.formatted()) LOGS")
                                .monospacedDigit()
                        }
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white.opacity(0.42))
                        .tracking(0.7)

                        SWStatsActivityHeatmap(
                            points: activityPoints,
                            tint: accent,
                            startDate: summary.range.parsedStartDate,
                            endDate: summary.range.parsedEndDate ?? (summary.range.isAllTime ? .now : nil)
                        )
                    }
                }
            }
        }
    }

    private func mediaScopePicker(_ summary: StatsSummary) -> some View {
        StatsSection(title: "Explore your media", subtitle: "Switch scope without losing your place") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    StatsScopeButton(
                        title: "All Media",
                        count: summary.range.isAllTime ? summary.overview.trackedCount : summary.overview.uniqueLoggedCount,
                        systemName: "square.grid.2x2.fill",
                        tint: StatsPalette.allMedia,
                        isSelected: selectedMediaType == nil
                    ) {
                        withAnimation(.snappy(duration: 0.2)) {
                            selectedMediaType = nil
                        }
                    }

                    ForEach(summary.mediaTypes) { mediaType in
                        let theme = MediaTypeTheme.theme(for: mediaType.mediaType)
                        StatsScopeButton(
                            title: theme.displayName,
                            count: summary.range.isAllTime ? mediaType.trackedCount : mediaType.uniqueLoggedCount,
                            mediaTheme: theme,
                            tint: StatsPalette.accent(for: mediaType.mediaType),
                            isSelected: selectedMediaType == mediaType.mediaType
                        ) {
                            withAnimation(.snappy(duration: 0.2)) {
                                selectedMediaType = mediaType.mediaType
                            }
                        }
                    }
                }
            }
        }
    }

    private func scopeOverview(_ scope: StatsScopeSnapshot, summary: StatsSummary, accent: Color) -> some View {
        let primaryTitle = summary.range.isAllTime ? "Tracked" : "Unique logged"
        let primaryValue = summary.range.isAllTime ? scope.trackedCount : scope.uniqueLoggedCount

        return StatsSection(title: scope.title, subtitle: scope.subtitle) {
            StatsMetricGrid(items: [
                StatsMetricItem(title: primaryTitle, value: primaryValue.formatted(), systemName: "rectangle.stack.fill", tint: accent),
                StatsMetricItem(
                    title: "Completed",
                    value: scope.completedCount.formatted(),
                    detail: summary.range.isAllTime ? nil : "Current library",
                    systemName: "checkmark.circle.fill",
                    tint: .green
                ),
                StatsMetricItem(title: "Logs", value: scope.diaryEntryCount.formatted(), systemName: "calendar.badge.checkmark", tint: .cyan),
                StatsMetricItem(
                    title: "Average rating",
                    value: scope.numericAverageRating.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—",
                    detail: scope.ratedCount > 0 ? "\(scope.ratedCount.formatted()) rated" : nil,
                    systemName: "star.fill",
                    tint: .yellow
                ),
                StatsMetricItem(title: "Rated", value: scope.ratedCount.formatted(), systemName: "star.bubble.fill", tint: .yellow),
                StatsMetricItem(title: "Reviews", value: scope.reviewCount.formatted(), systemName: "text.bubble.fill", tint: .indigo),
                StatsMetricItem(title: "Repeat logs", value: scope.repeatCount.formatted(), systemName: "arrow.trianglehead.2.clockwise", tint: .pink),
                StatsMetricItem(
                    title: "Likes",
                    value: scope.likedCount.formatted(),
                    detail: summary.range.isAllTime ? nil : "Current library",
                    systemName: "heart.fill",
                    tint: .red
                ),
            ])
        }
    }

    @ViewBuilder
    private func mediaMixSection(_ summary: StatsSummary) -> some View {
        let slices = summary.mediaTypes.compactMap { item -> SWStatsSlice? in
            let value = summary.range.isAllTime ? item.trackedCount : item.uniqueLoggedCount
            guard value > 0 else { return nil }
            return SWStatsSlice(
                id: item.mediaType,
                title: MediaTypeTheme.theme(for: item.mediaType).displayName,
                value: value,
                color: StatsPalette.accent(for: item.mediaType)
            )
        }

        if !slices.isEmpty {
            StatsSection(title: "Media mix", subtitle: summary.range.isAllTime ? "Your tracked library by type" : "Unique logged titles by type") {
                StatsDonutSurface(slices: slices, centerTitle: "TITLES")
            }
        }
    }

    @ViewBuilder
    private func statusSection(_ scope: StatsScopeSnapshot, accent: Color) -> some View {
        let slices = StatsCopy.statusOrder.compactMap { key -> SWStatsSlice? in
            guard let value = scope.statuses[key], value > 0 else { return nil }
            return SWStatsSlice(
                id: key,
                title: StatsCopy.statusTitle(key),
                value: value,
                color: StatsPalette.status(key, fallback: accent)
            )
        }

        if !slices.isEmpty {
            StatsSection(title: "Current library status", subtitle: "Live tracking state, independent of the selected year") {
                StatsDonutSurface(slices: slices, centerTitle: "TRACKED")
            }
        }
    }

    @ViewBuilder
    private func ratingSection(_ scope: StatsScopeSnapshot, accent: Color) -> some View {
        let points = scope.ratingDistribution.compactMap { bucket -> SWStatsRatingPoint? in
            guard let rating = bucket.numericRating else { return nil }
            return SWStatsRatingPoint(rating: rating, count: bucket.count)
        }

        if points.contains(where: { $0.count > 0 }) {
            StatsSection(title: "Your ratings", subtitle: "Every half-step on Spine's 10-point scale") {
                StatsSurface {
                    SWStatsRatingChart(points: points, average: scope.numericAverageRating, tint: accent)
                        .frame(height: 205)
                }
            }
        }
    }

    @ViewBuilder
    private func releaseYearSection(_ scope: StatsScopeSnapshot, accent: Color) -> some View {
        if !scope.releaseYears.isEmpty {
            StatsSection(title: "Across the years", subtitle: "Release years represented in your logs") {
                StatsSurface {
                    SWStatsYearChart(
                        points: scope.releaseYears.map { SWStatsYearPoint(year: $0.year, count: $0.count) },
                        tint: accent
                    )
                    .frame(height: 190)
                }
            }
        }
    }

    @ViewBuilder
    private func tasteSections(_ scope: StatsScopeSnapshot, accent: Color) -> some View {
        if !scope.topGenres.isEmpty || !scope.topLanguages.isEmpty {
            StatsSection(title: "Taste", subtitle: "Patterns from locally stored media metadata") {
                if !scope.topGenres.isEmpty {
                    StatsRankedSurface(
                        title: "TOP GENRES",
                        items: Array(scope.topGenres.prefix(8)),
                        coverage: scope.metadataCoverage.genreItems,
                        total: scope.metadataCoverage.totalItems,
                        tint: accent
                    )
                }

                if !scope.topLanguages.isEmpty {
                    StatsRankedSurface(
                        title: "TOP LANGUAGES",
                        items: Array(scope.topLanguages.prefix(8)),
                        coverage: scope.metadataCoverage.languageItems,
                        total: scope.metadataCoverage.totalItems,
                        tint: StatsPalette.language
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func mediaRails(_ scope: StatsScopeSnapshot, accent: Color) -> some View {
        if !scope.topRated.isEmpty {
            StatsSection(title: "Top rated", subtitle: "Your highest ratings in this scope") {
                StatsPosterRail(
                    items: scope.topRated.map {
                        StatsPosterItem(
                            media: $0.media,
                            caption: $0.rating.map { "\($0) / 10" } ?? "RATED"
                        )
                    },
                    accent: accent
                ) { media in
                    selectedRef = media.ref
                }
            }
        }

        if !scope.mostLogged.isEmpty {
            StatsSection(title: "Most logged", subtitle: "The stories you returned to most") {
                StatsPosterRail(
                    items: scope.mostLogged.map {
                        StatsPosterItem(
                            media: $0.media,
                            caption: "\($0.logCount) \($0.logCount == 1 ? "LOG" : "LOGS")"
                        )
                    },
                    accent: accent
                ) { media in
                    selectedRef = media.ref
                }
            }
        }
    }
}

private enum StatsContentPhase: Hashable {
    case loading
    case loaded(String)
    case empty
    case error
}

private struct StatsScopeSnapshot {
    let title: String
    let subtitle: String
    let trackedCount: Int
    let completedCount: Int
    let diaryEntryCount: Int
    let uniqueLoggedCount: Int
    let reviewCount: Int
    let repeatCount: Int
    let ratedCount: Int
    let numericAverageRating: Double?
    let likedCount: Int
    let statuses: [String: Int]
    let ratingDistribution: [StatsRatingBucket]
    let releaseYears: [StatsReleaseYearBucket]
    let topGenres: [StatsNamedCount]
    let topLanguages: [StatsNamedCount]
    let metadataCoverage: StatsMetadataCoverage
    let topRated: [StatsTopRatedItem]
    let mostLogged: [StatsMostLoggedItem]
    let isAllTime: Bool

    init(summary: StatsSummary, mediaType: String?) {
        isAllTime = summary.range.isAllTime
        if let mediaType, let media = summary.mediaTypeSummary(for: mediaType) {
            let theme = MediaTypeTheme.theme(for: mediaType)
            title = theme.displayName
            subtitle = "A focused view of your \(theme.displayName.lowercased())"
            trackedCount = media.trackedCount
            completedCount = media.completedCount
            diaryEntryCount = media.diaryEntryCount
            uniqueLoggedCount = media.uniqueLoggedCount
            reviewCount = media.reviewCount
            repeatCount = media.repeatCount
            ratedCount = media.ratedCount
            numericAverageRating = media.numericAverageRating
            likedCount = media.likedCount
            statuses = media.statuses
            ratingDistribution = media.ratingDistribution
            releaseYears = media.releaseYears
            topGenres = media.topGenres
            topLanguages = media.topLanguages
            metadataCoverage = media.metadataCoverage
            topRated = media.topRated
            mostLogged = media.mostLogged
        } else {
            title = "All Media"
            subtitle = "Your full media life, without mixing incompatible units"
            trackedCount = summary.overview.trackedCount
            completedCount = summary.overview.completedCount
            diaryEntryCount = summary.overview.diaryEntryCount
            uniqueLoggedCount = summary.overview.uniqueLoggedCount
            reviewCount = summary.overview.reviewCount
            repeatCount = summary.overview.repeatCount
            ratedCount = summary.overview.ratedCount
            numericAverageRating = summary.overview.numericAverageRating
            likedCount = summary.overview.likedCount
            statuses = summary.mediaTypes.reduce(into: [:]) { result, media in
                for (status, count) in media.statuses {
                    result[status, default: 0] += count
                }
            }
            ratingDistribution = summary.ratingDistribution
            releaseYears = summary.releaseYears
            topGenres = summary.topGenres
            topLanguages = summary.topLanguages
            metadataCoverage = summary.metadataCoverage
            topRated = summary.topRated
            mostLogged = summary.mostLogged
        }
    }

    var isEmpty: Bool {
        if !isAllTime {
            return diaryEntryCount == 0
                && uniqueLoggedCount == 0
                && reviewCount == 0
                && repeatCount == 0
                && ratedCount == 0
                && topRated.isEmpty
                && mostLogged.isEmpty
        }
        return trackedCount == 0
            && diaryEntryCount == 0
            && uniqueLoggedCount == 0
            && ratedCount == 0
            && likedCount == 0
            && topRated.isEmpty
            && mostLogged.isEmpty
    }
}

private struct StatsHero: View {
    let summary: StatsSummary
    let period: StatsPeriod

    private var primaryCount: Int {
        summary.range.isAllTime ? summary.overview.trackedCount : summary.overview.uniqueLoggedCount
    }

    private var primaryLabel: String {
        summary.range.isAllTime ? "tracked titles" : "unique titles logged"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            StatsPalette.allMedia.opacity(0.3),
                            Color(red: 0.12, green: 0.12, blue: 0.14),
                            Color.black.opacity(0.92),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(StatsPalette.allMedia.opacity(0.16))
                .frame(width: 190, height: 190)
                .blur(radius: 28)
                .offset(x: 52, y: 62)

            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 92, weight: .black))
                .foregroundStyle(.white.opacity(0.06))
                .offset(x: -14, y: -12)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(period.title.uppercased(), systemImage: "sparkles")
                        .font(.system(size: 10, weight: .black))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.62))
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Your media life")
                        .font(.system(size: 29, weight: .black))
                        .foregroundStyle(.white)

                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(primaryCount.formatted())
                            .font(.system(size: 42, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(primaryLabel)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .foregroundStyle(.white)
                }

                HStack(spacing: 18) {
                    StatsHeroMetric(value: summary.overview.diaryEntryCount.formatted(), title: "LOGS")
                    StatsHeroMetric(
                        value: summary.overview.numericAverageRating.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—",
                        title: "AVG RATING"
                    )
                    StatsHeroMetric(value: summary.overview.activeDays.formatted(), title: "ACTIVE DAYS")
                }
            }
            .padding(20)
        }
        .frame(minHeight: 242)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 9)
        .accessibilityElement(children: .combine)
    }
}

private struct StatsHeroMetric: View {
    let value: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.white.opacity(0.36))
                .tracking(0.6)
        }
    }
}

private struct StatsSection<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 19, weight: .black))
                    .foregroundStyle(.white.opacity(0.92))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatsSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.07), lineWidth: 1)
            }
    }
}

private struct StatsMetricItem: Identifiable {
    let title: String
    let value: String
    var detail: String? = nil
    let systemName: String
    let tint: Color

    var id: String { title }
}

private struct StatsMetricGrid: View {
    let items: [StatsMetricItem]
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: item.systemName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(item.tint)
                        .frame(width: 30, height: 30)
                        .background(item.tint.opacity(0.13), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.value)
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                        Text(item.title)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.44))
                            .lineLimit(1)
                        if let detail = item.detail {
                            Text(detail)
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.28))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .background(.white.opacity(0.038), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.065), lineWidth: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.title), \(item.value)\(item.detail.map { ", \($0)" } ?? "")")
            }
        }
    }
}

private struct StatsScopeButton: View {
    let title: String
    let count: Int
    var systemName: String?
    var mediaTheme: MediaTypeTheme?
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Group {
                    if let mediaTheme {
                        MediaTypeGlyph(theme: mediaTheme, size: 16)
                    } else if let systemName {
                        Image(systemName: systemName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 38, height: 38)
                .background(isSelected ? tint.opacity(0.36) : Color.white.opacity(0.055), in: Circle())
                .overlay {
                    Circle().stroke(isSelected ? tint.opacity(0.7) : .white.opacity(0.06), lineWidth: 1)
                }

                VStack(spacing: 1) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(isSelected ? 0.9 : 0.52))
                        .lineLimit(1)
                    Text(count.formatted())
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.white.opacity(0.3))
                        .monospacedDigit()
                }
            }
            .frame(width: 76, height: 86)
            .background(isSelected ? tint.opacity(0.1) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? tint.opacity(0.4) : .white.opacity(0.055), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct StatsDonutSurface: View {
    let slices: [SWStatsSlice]
    let centerTitle: String

    var body: some View {
        StatsSurface {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    chart
                    legend
                }
                VStack(spacing: 16) {
                    chart
                    legend
                }
            }
        }
    }

    private var chart: some View {
        SWStatsDonutChart(slices: slices, centerTitle: centerTitle)
            .frame(width: 158, height: 158)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(slices) { slice in
                HStack(spacing: 8) {
                    Circle()
                        .fill(slice.color)
                        .frame(width: 8, height: 8)
                    Text(slice.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(slice.value.formatted())
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white.opacity(0.44))
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatsRankedSurface: View {
    let title: String
    let items: [StatsNamedCount]
    let coverage: Int
    let total: Int
    let tint: Color

    var body: some View {
        StatsSurface {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(title)
                    Spacer()
                    if total > 0 {
                        Text("\(coverage.formatted()) / \(total.formatted()) ITEMS")
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 10, weight: .black))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.38))

                SWStatsRankedBars(
                    items: items.map { SWStatsRankedBarItem(id: $0.name, title: $0.name, value: $0.count) },
                    tint: tint
                )
            }
        }
    }
}

private struct StatsPosterItem: Identifiable {
    let media: MediaSummary
    let caption: String

    var id: MediaSummary.ID { media.id }
}

private struct StatsPosterRail: View {
    let items: [StatsPosterItem]
    let accent: Color
    let action: (MediaSummary) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    Button {
                        action(item.media)
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            MediaArtwork(
                                url: item.media.displayPosterURL,
                                title: item.media.title,
                                slot: .carousel,
                                mediaType: item.media.ref.mediaType,
                                orientation: item.media.posterOrientation
                            )
                            .overlay(alignment: .bottom) {
                                LinearGradient(
                                    colors: [.clear, accent.opacity(0.3)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 38)
                                .clipShape(RoundedRectangle(cornerRadius: PosterSlot.carousel.cornerRadius, style: .continuous))
                            }
                            .shadow(color: .black.opacity(0.3), radius: 10, y: 5)

                            Text(item.caption)
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(accent.opacity(0.9))
                                .tracking(0.5)
                                .lineLimit(1)

                            Text(item.media.title)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(2)
                        }
                        .frame(width: PosterSlot.carousel.size.width, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.media.title), \(item.caption)")
                    .accessibilityHint("Opens media details")
                }
            }
            .padding(.trailing, 12)
        }
    }
}

private struct StatsLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.white.opacity(0.07))
                .frame(height: 242)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.white.opacity(0.055))
                        .frame(height: 76)
                }
            }

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.05))
                .frame(height: 210)
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading stats")
    }
}

private struct StatsEmptyView: View {
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: "chart.bar.xaxis", description: Text(message))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 300)
    }
}

private struct StatsErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Could not load stats",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .foregroundStyle(.white)

            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(StatsPalette.allMedia)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

private enum StatsCopy {
    static let statusOrder = ["completed", "in_progress", "planning", "paused", "dropped"]

    static func statusTitle(_ value: String) -> String {
        switch value {
        case "completed": "Completed"
        case "in_progress": "In Progress"
        case "planning": "Planning"
        case "paused": "Paused"
        case "dropped": "Dropped"
        default: value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func days(_ value: Int) -> String {
        "\(value.formatted())d"
    }
}

private enum StatsPalette {
    static let allMedia = Color(red: 0.30, green: 0.77, blue: 0.95)
    static let language = Color(red: 0.99, green: 0.57, blue: 0.23)

    static func accent(for mediaType: String?) -> Color {
        switch mediaType {
        case "movie": Color(red: 0.98, green: 0.49, blue: 0.24)
        case "tv": Color(red: 0.25, green: 0.70, blue: 0.96)
        case "anime": Color(red: 0.93, green: 0.39, blue: 0.67)
        case "manga": Color(red: 0.34, green: 0.82, blue: 0.58)
        case "game": Color(red: 0.50, green: 0.47, blue: 0.96)
        case "book": Color(red: 0.91, green: 0.69, blue: 0.25)
        case "comic": Color(red: 0.93, green: 0.34, blue: 0.35)
        default: allMedia
        }
    }

    static func status(_ status: String, fallback: Color) -> Color {
        switch status {
        case "completed": Color(red: 0.28, green: 0.80, blue: 0.52)
        case "in_progress": Color(red: 0.27, green: 0.69, blue: 0.96)
        case "planning": Color(red: 0.63, green: 0.48, blue: 0.95)
        case "paused": Color(red: 0.98, green: 0.67, blue: 0.25)
        case "dropped": Color(red: 0.91, green: 0.34, blue: 0.36)
        default: fallback
        }
    }
}
