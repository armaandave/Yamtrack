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
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach([StatsPeriod.allTime] + StatsPeriod.recentYears()) { period in
                        let isSelected = viewModel.selectedPeriod == period

                        Button {
                            Task { await viewModel.selectPeriod(period) }
                        } label: {
                            HStack(spacing: 6) {
                                if viewModel.isLoading, isSelected {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .tint(.white)
                                }
                                Text(period.title)
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.52))
                            .padding(.horizontal, 15)
                            .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            isSelected
                                ? .regular.tint(.white.opacity(0.08)).interactive()
                                : .clear.interactive(),
                            in: Capsule()
                        )
                        .accessibilityLabel("Show stats for \(period.title)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, 2)
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
            mediaPicker(summary)

            if scope.isEmpty {
                StatsEmptyView(
                    title: "No \(scope.title.lowercased()) stats yet",
                    message: "Choose another media type or period to explore your history."
                )
            } else {
                StatsHero(
                    scope: scope,
                    period: viewModel.selectedPeriod,
                    mediaType: selectedMediaType,
                    accent: accent
                )

                if selectedMediaType == nil {
                    personSection(summary, accent: StatsPalette.allMedia)
                }

                if selectedMediaType == nil {
                    mediaMixSection(summary)
                }

                ratingSection(scope, accent: accent)
                releaseYearSection(scope, accent: accent)
                tasteSections(scope)
                mediaGrids(scope)
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

    private func mediaPicker(_ summary: StatsSummary) -> some View {
        let advertised = summary.mediaTypes.map(\.mediaType)
        let extra = advertised.filter { !APIConstants.fallbackMediaTypes.contains($0) }

        return MediaSearchLensPicker(
            selectedType: Binding(
                get: { selectedMediaType ?? "" },
                set: { selectedMediaType = $0.isEmpty ? nil : $0 }
            ),
            availableTypes: APIConstants.fallbackMediaTypes + extra,
            horizontalPadding: 0,
            fitsAllTypes: true,
            allowsEmptySelection: true,
            isCompact: true
        ) { selectedType in
            withAnimation(.snappy(duration: 0.2)) {
                selectedMediaType = selectedType.isEmpty ? nil : selectedType
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Media type")
        .accessibilityValue(
            selectedMediaType.map { MediaTypeTheme.theme(for: $0).displayName } ?? "All Media"
        )
        .accessibilityAction(named: "Show All Media") {
            selectedMediaType = nil
        }
    }

    @ViewBuilder
    private func mediaMixSection(_ summary: StatsSummary) -> some View {
        let slices = summary.mediaTypes.compactMap { item -> SWStatsSlice? in
            let value = summary.range.isAllTime ? item.completedCount : item.uniqueLoggedCount
            guard value > 0 else { return nil }
            return SWStatsSlice(
                id: item.mediaType,
                title: MediaTypeTheme.theme(for: item.mediaType).displayName,
                value: value,
                color: StatsPalette.accent(for: item.mediaType)
            )
        }

        if !slices.isEmpty {
            StatsSection(
                title: "Media mix",
                subtitle: summary.range.isAllTime ? "Completed titles by type" : "Unique logged titles by type"
            ) {
                StatsDonutSurface(slices: slices, centerTitle: summary.range.isAllTime ? "COMPLETED" : "LOGGED")
            }
        }
    }

    @ViewBuilder
    private func ratingSection(_ scope: StatsScopeSnapshot, accent: Color) -> some View {
        if scope.ratingPoints.contains(where: { $0.count > 0 }) {
            StatsSection(title: "Your ratings", subtitle: "Every half-step on Spine's 10-point scale") {
                StatsSurface {
                    SWStatsRatingChart(
                        points: scope.ratingPoints,
                        average: scope.numericAverageRating,
                        tint: accent
                    )
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
    private func tasteSections(_ scope: StatsScopeSnapshot) -> some View {
        if !scope.topGenres.isEmpty || !scope.topLanguages.isEmpty {
            StatsSection(title: "Taste", subtitle: "Patterns from locally stored media metadata") {
                if !scope.topGenres.isEmpty {
                    StatsTasteGroup(
                        title: "Genres",
                        items: Array(scope.topGenres.prefix(8)),
                        coverage: scope.metadataCoverage.genreItems,
                        total: scope.metadataCoverage.totalItems
                    )
                }

                if !scope.topLanguages.isEmpty {
                    StatsTasteGroup(
                        title: "Languages",
                        items: Array(scope.topLanguages.prefix(8)),
                        coverage: scope.metadataCoverage.languageItems,
                        total: scope.metadataCoverage.totalItems
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func mediaGrids(_ scope: StatsScopeSnapshot) -> some View {
        if !scope.topRated.isEmpty {
            StatsSection(title: "Top rated", subtitle: "Your highest ratings in this scope") {
                StatsPosterGrid(
                    items: scope.topRated.map {
                        StatsPosterItem(
                            media: $0.media,
                            caption: StatsCopy.rating($0.rating, for: $0.media),
                            systemName: "star.fill",
                            tint: .yellow
                        )
                    }
                ) { media in
                    selectedRef = media.ref
                }
            }
        }

        if !scope.mostLogged.isEmpty {
            StatsSection(title: "Most logged", subtitle: "The stories you returned to most") {
                StatsPosterGrid(
                    items: scope.mostLogged.map {
                        StatsPosterItem(
                            media: $0.media,
                            caption: "\($0.logCount) \($0.logCount == 1 ? "log" : "logs")",
                            systemName: "arrow.trianglehead.2.clockwise",
                            tint: .white.opacity(0.82)
                        )
                    }
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
    let completedCount: Int
    let diaryEntryCount: Int
    let uniqueLoggedCount: Int
    let reviewCount: Int
    let repeatCount: Int
    let ratedCount: Int
    let numericAverageRating: Double?
    let likedCount: Int
    let ratingPoints: [SWStatsRatingPoint]
    let releaseYears: [StatsReleaseYearBucket]
    let topGenres: [StatsNamedCount]
    let topLanguages: [StatsNamedCount]
    let metadataCoverage: StatsMetadataCoverage
    let topRated: [StatsTopRatedItem]
    let mostLogged: [StatsMostLoggedItem]
    let isAllTime: Bool

    init(summary: StatsSummary, mediaType: String?) {
        isAllTime = summary.range.isAllTime
        if let mediaType {
            let theme = MediaTypeTheme.theme(for: mediaType)
            title = theme.displayName
            subtitle = "A focused view of your \(theme.displayName.lowercased())"
            if let media = summary.mediaTypeSummary(for: mediaType) {
                let points = SWStatsRatingChart.normalizedPoints(
                    from: media.ratingDistribution,
                    mediaType: mediaType
                )
                completedCount = media.completedCount
                diaryEntryCount = media.diaryEntryCount
                uniqueLoggedCount = media.uniqueLoggedCount
                reviewCount = media.reviewCount
                repeatCount = media.repeatCount
                ratedCount = media.ratedCount
                numericAverageRating = SWStatsRatingChart.averageRating(from: points)
                likedCount = media.likedCount
                ratingPoints = points
                releaseYears = media.releaseYears
                topGenres = media.topGenres
                topLanguages = media.topLanguages
                metadataCoverage = media.metadataCoverage
                topRated = media.topRated
                mostLogged = media.mostLogged
            } else {
                completedCount = 0
                diaryEntryCount = 0
                uniqueLoggedCount = 0
                reviewCount = 0
                repeatCount = 0
                ratedCount = 0
                numericAverageRating = nil
                likedCount = 0
                ratingPoints = []
                releaseYears = []
                topGenres = []
                topLanguages = []
                metadataCoverage = .empty
                topRated = []
                mostLogged = []
            }
        } else {
            let typedPoints = SWStatsRatingChart.normalizedPoints(from: summary.mediaTypes)
            let points = typedPoints.contains { $0.count > 0 }
                ? typedPoints
                : SWStatsRatingChart.normalizedPoints(
                    from: summary.ratingDistribution,
                    mediaType: nil
                )
            title = "All Media"
            subtitle = "Your full media life, without mixing incompatible units"
            completedCount = summary.overview.completedCount
            diaryEntryCount = summary.overview.diaryEntryCount
            uniqueLoggedCount = summary.overview.uniqueLoggedCount
            reviewCount = summary.overview.reviewCount
            repeatCount = summary.overview.repeatCount
            ratedCount = summary.overview.ratedCount
            numericAverageRating = SWStatsRatingChart.averageRating(from: points)
            likedCount = summary.overview.likedCount
            ratingPoints = points
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
        return completedCount == 0
            && diaryEntryCount == 0
            && uniqueLoggedCount == 0
            && ratedCount == 0
            && topRated.isEmpty
            && mostLogged.isEmpty
    }
}

private struct StatsHero: View {
    let scope: StatsScopeSnapshot
    let period: StatsPeriod
    let mediaType: String?
    let accent: Color

    private var primaryCount: Int {
        scope.isAllTime ? scope.completedCount : scope.uniqueLoggedCount
    }

    private var primaryLabel: String {
        scope.isAllTime ? "titles completed" : "unique titles logged"
    }

    private var theme: MediaTypeTheme {
        MediaTypeTheme.theme(for: mediaType ?? APIConstants.allMedia)
    }

    private var metrics: [StatsHeroMetricItem] {
        var items = [
            StatsHeroMetricItem(title: "Logs", value: scope.diaryEntryCount.formatted()),
            StatsHeroMetricItem(
                title: "Average",
                value: scope.numericAverageRating?.formatted(.number.precision(.fractionLength(1))) ?? "—"
            ),
            StatsHeroMetricItem(title: "Rated", value: scope.ratedCount.formatted()),
            StatsHeroMetricItem(title: "Reviews", value: scope.reviewCount.formatted()),
            StatsHeroMetricItem(title: "Repeats", value: scope.repeatCount.formatted()),
        ]
        if scope.isAllTime {
            items.append(StatsHeroMetricItem(title: "Likes", value: scope.likedCount.formatted()))
        }
        return items
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Group {
                    if mediaType == nil {
                        Image(systemName: "globe")
                            .font(.system(size: 14, weight: .bold))
                    } else {
                        MediaTypeGlyph(theme: theme, size: 14)
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(accent.opacity(0.18), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(scope.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(period.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                }

                Spacer()

                Text(scope.isAllTime ? "ALL TIME" : "THIS PERIOD")
                    .font(.system(size: 9, weight: .black))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.42))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryCount.formatted())
                    .font(.system(size: 48, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(primaryLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.52))
            }

            Divider()
                .overlay(.white.opacity(0.08))

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(metrics) { metric in
                    StatsHeroMetric(value: metric.value, title: metric.title)
                }
            }
        }
        .padding(20)
        .background(.white.opacity(0.025), in: shape)
        .glassEffect(.regular.tint(.white.opacity(0.035)), in: shape)
        .overlay {
            shape.strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
    }
}

private struct StatsHeroMetricItem: Identifiable {
    let title: String
    let value: String

    var id: String { title }
}

private struct StatsHeroMetric: View {
    let value: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
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
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white.opacity(0.62))
                    .tracking(0.8)
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
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.022), in: shape)
            .glassEffect(.regular.tint(.white.opacity(0.025)), in: shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.08), lineWidth: 1)
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
    private let columns = [GridItem(.adaptive(minimum: 148), spacing: 10)]

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(items) { item in
                    let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)

                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: item.systemName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(item.tint)
                            .frame(width: 30, height: 30)
                            .background(item.tint.opacity(0.13), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.value)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.74)
                            Text(item.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.46))
                                .lineLimit(1)
                            if let detail = item.detail {
                                Text(detail)
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.3))
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    .background(.white.opacity(0.025), in: shape)
                    .glassEffect(.regular.tint(.white.opacity(0.025)), in: shape)
                    .overlay {
                        shape.strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.title), \(item.value)\(item.detail.map { ", \($0)" } ?? "")")
                }
            }
        }
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

private struct StatsTasteGroup: View {
    let title: String
    let items: [StatsNamedCount]
    let coverage: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .tracking(0.6)
                Spacer()
                if total > 0 {
                    Text("\(coverage.formatted()) / \(total.formatted()) TITLES")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 9, weight: .black))
            .foregroundStyle(.white.opacity(0.38))

            GlassEffectContainer(spacing: 8) {
                FlowLayout(spacing: 8) {
                    ForEach(items) { item in
                        HStack(spacing: 7) {
                            Text(item.name)
                                .lineLimit(1)
                            Text(item.count.formatted())
                                .fontWeight(.black)
                                .foregroundStyle(.white.opacity(0.5))
                                .monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 11)
                        .frame(minHeight: 36)
                        .background(.white.opacity(0.025), in: Capsule())
                        .glassEffect(.clear, in: Capsule())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(item.name), \(item.count)")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StatsPosterItem: Identifiable {
    let media: MediaSummary
    let caption: String
    let systemName: String
    let tint: Color

    var id: MediaSummary.ID { media.id }
}

private struct StatsPosterGrid: View {
    let items: [StatsPosterItem]
    let action: (MediaSummary) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: PosterSlot.carousel.size.width, maximum: 120), spacing: 12),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(items) { item in
                Button {
                    action(item.media)
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        ZStack(alignment: .bottomLeading) {
                            MediaArtwork(
                                url: item.media.displayPosterURL,
                                title: item.media.title,
                                slot: .carousel,
                                mediaType: item.media.ref.mediaType,
                                orientation: item.media.posterOrientation
                            )

                            Label(item.caption, systemImage: item.systemName)
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(item.tint)
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .frame(minHeight: 25)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay {
                                    Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                                }
                                .padding(6)
                        }
                        .shadow(color: .black.opacity(0.26), radius: 8, y: 4)

                        Text(item.media.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(2)
                    }
                    .frame(width: PosterSlot.carousel.size.width, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.media.title), \(item.caption)")
                .accessibilityHint("Opens media details")
            }
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
    static func days(_ value: Int) -> String {
        "\(value.formatted())d"
    }

    static func rating(_ rawValue: String?, for media: MediaSummary) -> String {
        guard let rawValue, let value = Double(rawValue), value.isFinite else { return "Rated" }
        let usesFiveStarScale = media.ref.usesFiveStarRatingScale && value <= 5
        let formatted = value.formatted(.number.precision(.fractionLength(0 ... 1)))
        return "\(formatted) / \(usesFiveStarScale ? 5 : 10)"
    }
}

private enum StatsPalette {
    static let allMedia = Color(red: 0.78, green: 0.80, blue: 0.84)

    static func accent(for mediaType: String?) -> Color {
        mediaType.map { MediaTypeTheme.theme(for: $0).statsColor } ?? allMedia
    }
}
