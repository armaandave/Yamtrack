import SwiftUI

@MainActor
@Observable
final class DiaryViewModel {
    var entries: [DiaryEntry] = [] {
        didSet {
            monthSections = DiaryMonthSection.sections(from: entries)
        }
    }
    private(set) var monthSections: [DiaryMonthSection] = []
    private(set) var monthIndex: [DiaryMonthSummary] = []
    var filter: MediaFilterState
    var filterOptions: MediaFilterOptionsResponse = .empty
    var isBootstrapping = true
    var isLoading = false
    var isLoadingNextPage = false
    var isLoadingMonthIndex = false
    var isLoadingMonth = false
    var errorMessage: String?
    var nextPageErrorMessage: String?
    var monthIndexErrorMessage: String?

    private let diaryRepository: DiaryRepository
    private let filterOptionsRepository: FilterOptionsRepository
    private let onUnauthorized: () -> Void
    private var nextPage: String?
    private var requestGeneration = 0
    private var monthIndexGeneration = 0
    private var didLoad = false
    private var isInitialLoadInFlight = false
    private(set) var loadedMonth: String?
    private var presentedFilter: MediaFilterState?

    var hasMorePages: Bool {
        nextPage != nil
    }

    init(
        diaryRepository: DiaryRepository,
        filter: DiaryFilter? = nil,
        filterOptionsRepository: FilterOptionsRepository? = nil,
        onUnauthorized: @escaping () -> Void
    ) {
        self.diaryRepository = diaryRepository
        self.filterOptionsRepository = filterOptionsRepository ?? APIFilterOptionsRepository(client: AppEnvironment.apiClient)
        var mediaFilter = MediaFilterState()
        mediaFilter.tag = filter?.tag
        mediaFilter.itemId = filter?.itemId
        mediaFilter.hasReview = filter?.hasReview ?? false
        mediaFilter.liked = filter?.liked ?? false
        self.filter = mediaFilter
        self.onUnauthorized = onUnauthorized
    }

    func loadIfNeeded(loadsFilterOptions: Bool = false) async {
        guard !didLoad, !isInitialLoadInFlight else { return }
        isInitialLoadInFlight = true
        defer { isInitialLoadInFlight = false }

        if loadsFilterOptions {
            await loadFilterOptions()
            guard !Task.isCancelled else { return }
        }
        async let entriesLoad: Void = load()
        async let monthsLoad: Void = loadMonthIndex()
        _ = await (entriesLoad, monthsLoad)
    }

    func load() async {
        requestGeneration += 1
        let generation = requestGeneration
        let requestFilter = diaryRequestFilter
        let preservesLastGoodContent = presentedFilter == requestFilter && !entries.isEmpty
        if !preservesLastGoodContent {
            entries = []
            nextPage = nil
        }
        presentedFilter = requestFilter
        isLoading = true
        errorMessage = nil
        nextPageErrorMessage = nil
        var wasCancelled = false
        defer {
            if generation == requestGeneration, requestFilter == diaryRequestFilter {
                isLoading = false
                if !wasCancelled {
                    isBootstrapping = false
                }
            }
        }

        do {
            let response = try await diaryRepository.page(filter: requestFilter, page: nil)
            guard generation == requestGeneration, requestFilter == diaryRequestFilter else { return }
            entries = response.results
            nextPage = APIPageCursor.nextPage(from: response.next)
            loadedMonth = nil
            didLoad = true
        } catch is CancellationError {
            wasCancelled = true
            return
        } catch {
            guard generation == requestGeneration, requestFilter == diaryRequestFilter else { return }
            errorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }

    func loadNextPageIfNeeded(currentEntry: DiaryEntry) async {
        guard let thresholdIndex = entries.index(entries.endIndex, offsetBy: -6, limitedBy: entries.startIndex) ?? entries.indices.first,
              let currentIndex = entries.firstIndex(where: { $0.id == currentEntry.id }),
              currentIndex >= thresholdIndex else {
            return
        }
        await loadNextPage()
    }

    func loadNextPage() async {
        guard !isLoading, !isLoadingNextPage, !isLoadingMonth, let page = nextPage else { return }
        let generation = requestGeneration
        let requestFilter = diaryRequestFilter
        isLoadingNextPage = true
        nextPageErrorMessage = nil
        defer {
            if generation == requestGeneration, requestFilter == diaryRequestFilter {
                isLoadingNextPage = false
            }
        }

        do {
            let response = try await diaryRepository.page(filter: requestFilter, page: page)
            guard generation == requestGeneration, requestFilter == diaryRequestFilter else { return }
            let existingIDs = Set(entries.map(\.id))
            entries += response.results.filter { !existingIDs.contains($0.id) }
            nextPage = APIPageCursor.nextPage(from: response.next)
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration, requestFilter == diaryRequestFilter else { return }
            nextPageErrorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }

    func loadMonthIndex(force: Bool = false) async {
        let requestFilter = diaryRequestFilter
        guard !isLoadingMonthIndex,
              force || monthIndex.isEmpty else { return }
        monthIndexGeneration += 1
        let generation = monthIndexGeneration
        isLoadingMonthIndex = true
        monthIndexErrorMessage = nil
        defer {
            if generation == monthIndexGeneration {
                isLoadingMonthIndex = false
            }
        }

        do {
            let summaries = try await diaryRepository.months(filter: requestFilter)
            guard generation == monthIndexGeneration, requestFilter == diaryRequestFilter else { return }
            monthIndex = summaries
        } catch is CancellationError {
            return
        } catch {
            guard generation == monthIndexGeneration, requestFilter == diaryRequestFilter else { return }
            monthIndexErrorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }

    func loadMonth(_ month: String) async -> Bool {
        if loadedMonth == month { return true }
        guard !isLoadingMonth else { return false }
        requestGeneration += 1
        let generation = requestGeneration
        let requestFilter = diaryRequestFilter
        isLoadingMonth = true
        monthIndexErrorMessage = nil
        defer {
            if generation == requestGeneration {
                isLoadingMonth = false
            }
        }

        do {
            let loadedEntries = try await diaryRepository.entries(filter: requestFilter, month: month)
            guard generation == requestGeneration, requestFilter == diaryRequestFilter else { return false }
            entries = loadedEntries
            nextPage = nil
            loadedMonth = month
            presentedFilter = requestFilter
            didLoad = true
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == requestGeneration, requestFilter == diaryRequestFilter else { return false }
            monthIndexErrorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
            return false
        }
    }

    func loadFilterOptions() async {
        guard filter.itemId == nil else { return }
        prepareForFilterChangeIfNeeded()
        do {
            let requestFilter = diaryRequestFilter
            let options = try await filterOptionsRepository.options(scope: .diary, filter: requestFilter)
            guard requestFilter == diaryRequestFilter else { return }
            filterOptions = options
        } catch is CancellationError {
            return
        } catch {
            filterOptions = .empty
        }
    }

    private func prepareForFilterChangeIfNeeded() {
        let requestFilter = diaryRequestFilter
        guard presentedFilter != requestFilter else { return }

        requestGeneration += 1
        monthIndexGeneration += 1
        presentedFilter = requestFilter
        entries = []
        monthIndex = []
        nextPage = nil
        loadedMonth = nil
        errorMessage = nil
        nextPageErrorMessage = nil
        monthIndexErrorMessage = nil
        isLoading = true
        isLoadingNextPage = false
        isLoadingMonthIndex = false
        isLoadingMonth = false
    }

    private var diaryRequestFilter: MediaFilterState {
        var requestFilter = filter
        if filter.mediaType == "tv" {
            requestFilter.mediaType = nil
            requestFilter.mediaTypes = ["tv", "season"]
        }
        return requestFilter
    }
}

struct MediaDiaryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: DiaryViewModel
    @State private var edgeDragOffset: CGFloat = 0

    private let title: String
    private let artworkOverride: DiaryEntryArtworkOverride
    private let diaryRepository: DiaryRepository
    private let mediaRepository: MediaRepository
    private let trackingRepository: TrackingRepository
    private let currentUserId: Int?
    private let selectedTab: AppTab
    private let onSelectTab: (AppTab) -> Void
    private let onUnauthorized: () -> Void

    init(
        title: String,
        itemId: Int,
        posterURL: String?,
        posterOrientation: PosterOrientation?,
        diaryRepository: DiaryRepository,
        mediaRepository: MediaRepository,
        trackingRepository: TrackingRepository,
        currentUserId: Int? = nil,
        selectedTab: AppTab = .diary,
        onSelectTab: @escaping (AppTab) -> Void = { _ in },
        onUnauthorized: @escaping () -> Void = {}
    ) {
        self.title = title
        self.artworkOverride = DiaryEntryArtworkOverride(url: posterURL, orientation: posterOrientation)
        self.diaryRepository = diaryRepository
        self.mediaRepository = mediaRepository
        self.trackingRepository = trackingRepository
        self.currentUserId = currentUserId
        self.selectedTab = selectedTab
        self.onSelectTab = onSelectTab
        self.onUnauthorized = onUnauthorized
        _viewModel = State(initialValue: DiaryViewModel(
            diaryRepository: diaryRepository,
            filter: DiaryFilter(itemId: itemId),
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SpinePageBackground()

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        header

                        Group {
                            if viewModel.isBootstrapping || (viewModel.isLoading && viewModel.entries.isEmpty) {
                                ProgressView()
                                    .tint(.white)
                                    .frame(maxWidth: .infinity, minHeight: 320)
                            } else if let error = viewModel.errorMessage, viewModel.entries.isEmpty {
                                DiaryStateCard(
                                    title: "Could not load logs",
                                    systemImage: "exclamationmark.triangle",
                                    message: error
                                )
                            } else if viewModel.entries.isEmpty {
                                DiaryStateCard(
                                    title: "No logs",
                                    systemImage: "calendar",
                                    message: "Logs for this media will appear here."
                                )
                            } else {
                                DiaryEntryList(entries: viewModel.entries, artworkOverride: artworkOverride) { entry in
                                    DiaryLogDetailView(
                                        entryId: entry.id,
                                        diaryRepository: diaryRepository,
                                        mediaRepository: mediaRepository,
                                        trackingRepository: trackingRepository,
                                        currentUserId: currentUserId,
                                        selectedTab: selectedTab,
                                        onSelectTab: onSelectTab,
                                        onUnauthorized: onUnauthorized
                                    )
                                }
                                paginationFooter
                            }
                        }
                        .spineContentTransition(value: contentPhase)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
                .refreshable {
                    await viewModel.load()
                }
            }
            .overlay(alignment: .top) {
                DiaryTopSafeAreaScrim()
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .navigationBarBackButtonHidden()
            .offset(x: edgeDragOffset)
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: 28)
                    .contentShape(Rectangle())
                    .gesture(edgeSwipeBackGesture)
            }
            .task {
                await viewModel.loadIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .letterboxdImportDidSucceed)) { _ in
                Task { await viewModel.load() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .storygraphImportDidSucceed)) { _ in
                Task { await viewModel.load() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .diaryEntriesDidChange)) { _ in
                Task { await viewModel.load() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mediaStateDidChange)) { _ in
                Task { await viewModel.load() }
            }
        }
    }

    private var edgeSwipeBackGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard value.translation.width > 0 else { return }
                edgeDragOffset = value.translation.width
            }
            .onEnded { value in
                if value.translation.width > 90 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        edgeDragOffset = 0
                    }
                }
            }
    }

    private var contentPhase: SpineContentPhase {
        .resolve(
            isLoading: viewModel.isBootstrapping || viewModel.isLoading,
            hasContent: !viewModel.entries.isEmpty,
            hasError: viewModel.errorMessage != nil
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")

                Text(title)
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }

        }
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var paginationFooter: some View {
        VStack(spacing: 0) {
            Group {
                if viewModel.isLoadingNextPage {
                    ProgressView()
                        .tint(.white)
                } else if let error = viewModel.nextPageErrorMessage {
                    DiaryStateCard(title: "Could not load more", systemImage: "exclamationmark.triangle", message: error)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .spineContentTransition(value: paginationPhase)

            Color.clear
                .frame(height: 1)
        }
        .task {
            guard let last = viewModel.entries.last else { return }
            await viewModel.loadNextPageIfNeeded(currentEntry: last)
        }
    }

    private var paginationPhase: String {
        if viewModel.isLoadingNextPage {
            return "loading"
        }
        if viewModel.nextPageErrorMessage != nil {
            return "error"
        }
        return viewModel.hasMorePages ? "available" : "empty"
    }
}

struct DiaryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: DiaryViewModel
    @State private var monthDisplayMode: DiaryMonthDisplayMode = .expanded
    @State private var pendingDiaryAnchor: String?
    @State private var pendingMonthAnchor: String?

    private let diaryRepository: DiaryRepository
    private let mediaRepository: MediaRepository
    private let trackingRepository: TrackingRepository
    private let currentUserId: Int?
    private let selectedTab: AppTab
    private let onSelectTab: (AppTab) -> Void
    private let onUnauthorized: () -> Void

    init(
        diaryRepository: DiaryRepository,
        mediaRepository: MediaRepository,
        trackingRepository: TrackingRepository,
        currentUserId: Int? = nil,
        selectedTab: AppTab = .diary,
        onSelectTab: @escaping (AppTab) -> Void = { _ in },
        onUnauthorized: @escaping () -> Void = {}
    ) {
        self.diaryRepository = diaryRepository
        self.mediaRepository = mediaRepository
        self.trackingRepository = trackingRepository
        self.currentUserId = currentUserId
        self.selectedTab = selectedTab
        self.onSelectTab = onSelectTab
        self.onUnauthorized = onUnauthorized
        _viewModel = State(initialValue: DiaryViewModel(diaryRepository: diaryRepository, onUnauthorized: onUnauthorized))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SpinePageBackground()

                ScrollViewReader { diaryProxy in
                    ScrollViewReader { monthProxy in
                        ZStack {
                            diaryScroll(monthProxy: monthProxy)
                                .opacity(monthDisplayMode == .expanded ? 1 : 0)
                                .allowsHitTesting(monthDisplayMode == .expanded)
                                .accessibilityHidden(monthDisplayMode != .expanded)
                                .zIndex(monthDisplayMode == .expanded ? 1 : 0)

                            monthIndexScroll(diaryProxy: diaryProxy)
                                .opacity(monthDisplayMode == .collapsed ? 1 : 0)
                                .allowsHitTesting(monthDisplayMode == .collapsed)
                                .accessibilityHidden(monthDisplayMode != .collapsed)
                                .zIndex(monthDisplayMode == .collapsed ? 1 : 0)
                        }
                        .onChange(of: viewModel.monthIndex) { _, months in
                            guard !months.isEmpty, let sectionID = pendingMonthAnchor else { return }
                            showMonthIndex(sectionID, proxy: monthProxy)
                        }
                        .onChange(of: viewModel.loadedMonth) { _, month in
                            guard let month, month == pendingDiaryAnchor else { return }
                            showDiary(month, proxy: diaryProxy)
                        }
                    }
                }
            }
            .overlay(alignment: .top) {
                DiaryTopSafeAreaScrim()
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .task {
                await viewModel.loadIfNeeded(loadsFilterOptions: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .letterboxdImportDidSucceed)) { _ in
                Task { await reloadDiary() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .storygraphImportDidSucceed)) { _ in
                Task { await reloadDiary() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .diaryEntriesDidChange)) { _ in
                Task { await reloadDiary() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mediaStateDidChange)) { _ in
                Task { await reloadDiary() }
            }
        }
    }

    private func diaryScroll(monthProxy: ScrollViewProxy) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                header
                mediaPicker
                diaryContent(monthProxy: monthProxy)
                    .spineContentTransition(value: contentPhase)
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .refreshable {
            await reloadDiary()
        }
    }

    @ViewBuilder
    private func diaryContent(monthProxy: ScrollViewProxy) -> some View {
        if viewModel.isBootstrapping || (viewModel.isLoading && viewModel.entries.isEmpty) {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, minHeight: 320)
        } else if let error = viewModel.errorMessage, viewModel.entries.isEmpty {
            DiaryStateCard(
                title: "Could not load diary",
                systemImage: "exclamationmark.triangle",
                message: error
            )
        } else if viewModel.entries.isEmpty {
            DiaryStateCard(
                title: "No diary entries",
                systemImage: "calendar",
                message: "Logs you create from media pages will appear here."
            )
        } else {
            DiaryEntryList(
                monthSections: viewModel.monthSections,
                onMonthHeaderTap: monthIndexAction(proxy: monthProxy)
            ) { entry in
                DiaryLogDetailView(
                    entryId: entry.id,
                    diaryRepository: diaryRepository,
                    mediaRepository: mediaRepository,
                    trackingRepository: trackingRepository,
                    currentUserId: currentUserId,
                    selectedTab: selectedTab,
                    onSelectTab: onSelectTab,
                    onUnauthorized: onUnauthorized
                )
            }
            paginationFooter
        }
    }

    private func monthIndexScroll(diaryProxy: ScrollViewProxy) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                mediaPicker
                DiaryMonthIndex(months: viewModel.monthIndex) { sectionID in
                    if viewModel.loadedMonth == sectionID {
                        showDiary(sectionID, proxy: diaryProxy)
                        return
                    }
                    pendingDiaryAnchor = sectionID
                    Task {
                        if !(await viewModel.loadMonth(sectionID)) {
                            pendingDiaryAnchor = nil
                        }
                    }
                }
                monthIndexFooter
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
    }

    private func monthIndexAction(proxy: ScrollViewProxy) -> (String) -> Void {
        { sectionID in
            pendingMonthAnchor = sectionID
            if viewModel.monthIndex.isEmpty {
                Task { await viewModel.loadMonthIndex() }
            } else {
                showMonthIndex(sectionID, proxy: proxy)
            }
        }
    }

    private func showMonthIndex(_ sectionID: String, proxy: ScrollViewProxy) {
        pendingMonthAnchor = nil
        scrollWithoutAnimation(proxy, to: sectionID)
        withAnimation(monthTransitionAnimation) {
            monthDisplayMode = .collapsed
        }
    }

    private func showDiary(_ sectionID: String, proxy: ScrollViewProxy) {
        pendingDiaryAnchor = nil
        scrollWithoutAnimation(proxy, to: sectionID)
        withAnimation(monthTransitionAnimation) {
            monthDisplayMode = .expanded
        }
    }

    private func scrollWithoutAnimation(_ proxy: ScrollViewProxy, to sectionID: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(sectionID, anchor: .top)
        }
    }

    private var monthTransitionAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: SpineMotion.standardDuration)
    }

    private func reloadDiary(loadsFilterOptions: Bool = false) async {
        pendingDiaryAnchor = nil
        pendingMonthAnchor = nil
        withAnimation(monthTransitionAnimation) {
            monthDisplayMode = .expanded
        }
        if loadsFilterOptions {
            await viewModel.loadFilterOptions()
            guard !Task.isCancelled else { return }
        }
        async let entriesLoad: Void = viewModel.load()
        async let monthsLoad: Void = viewModel.loadMonthIndex(force: true)
        _ = await (entriesLoad, monthsLoad)
    }

    private var contentPhase: SpineContentPhase {
        .resolve(
            isLoading: viewModel.isBootstrapping || viewModel.isLoading,
            hasContent: !viewModel.entries.isEmpty,
            hasError: viewModel.errorMessage != nil
        )
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Diary")
                .font(.system(size: 32, weight: .black))
                .foregroundStyle(.white)

            Spacer()

            MediaFilterButton(
                filter: $viewModel.filter,
                scope: .diary,
                options: viewModel.filterOptions
            ) {
                Task { await reloadDiary(loadsFilterOptions: true) }
            }
        }
        .padding(.bottom, 14)
    }

    private var mediaPicker: some View {
        MediaSearchLensPicker(
            selectedType: selectedMediaTypeBinding,
            availableTypes: APIConstants.fallbackMediaTypes,
            horizontalPadding: 0,
            fitsAllTypes: true,
            allowsEmptySelection: true,
            isCompact: true
        ) { selectedType in
            viewModel.filter.mediaType = selectedType.isEmpty ? nil : selectedType
            Task { await reloadDiary(loadsFilterOptions: true) }
        }
        .padding(.bottom, 14)
    }

    private var selectedMediaTypeBinding: Binding<String> {
        Binding(
            get: { viewModel.filter.mediaType ?? "" },
            set: { viewModel.filter.mediaType = $0.isEmpty ? nil : $0 }
        )
    }

    @ViewBuilder
    private var paginationFooter: some View {
        Group {
            if viewModel.isLoadingNextPage {
                ProgressView()
                    .tint(.white)
            } else if let error = viewModel.nextPageErrorMessage {
                DiaryStateCard(title: "Could not load more", systemImage: "exclamationmark.triangle", message: error)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .task(id: viewModel.entries.last?.id) {
            guard let last = viewModel.entries.last else { return }
            await viewModel.loadNextPageIfNeeded(currentEntry: last)
        }
    }

    @ViewBuilder
    private var monthIndexFooter: some View {
        if viewModel.isLoadingMonth {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
        } else if let error = viewModel.monthIndexErrorMessage {
            DiaryStateCard(title: "Could not load month", systemImage: "exclamationmark.triangle", message: error)
                .padding(.top, 8)
        }
    }
}

struct DiaryTopSafeAreaScrim: View {
    var body: some View {
        GeometryReader { proxy in
            Color(red: 0.07, green: 0.07, blue: 0.065)
                .frame(height: proxy.safeAreaInsets.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
    }
}
