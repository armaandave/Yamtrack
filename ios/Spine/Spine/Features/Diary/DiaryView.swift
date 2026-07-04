import SwiftUI

@MainActor
@Observable
final class DiaryViewModel {
    var entries: [DiaryEntry] = []
    var filter: MediaFilterState
    var filterOptions: MediaFilterOptionsResponse = .empty
    var isLoading = false
    var isLoadingNextPage = false
    var errorMessage: String?
    var nextPageErrorMessage: String?

    private let diaryRepository: DiaryRepository
    private let filterOptionsRepository: FilterOptionsRepository
    private let onUnauthorized: () -> Void
    private var nextPage: String?
    private var requestGeneration = 0

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

    func load() async {
        requestGeneration += 1
        let generation = requestGeneration
        let requestFilter = diaryRequestFilter
        entries = []
        nextPage = nil
        isLoading = true
        errorMessage = nil
        nextPageErrorMessage = nil

        do {
            let response = try await diaryRepository.page(filter: requestFilter, page: nil)
            guard generation == requestGeneration, requestFilter == diaryRequestFilter else { return }
            entries = response.results
            nextPage = APIPageCursor.nextPage(from: response.next)
            isLoading = false
        } catch {
            guard generation == requestGeneration, requestFilter == diaryRequestFilter else { return }
            errorMessage = error.localizedDescription
            isLoading = false
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
        guard !isLoading, !isLoadingNextPage, let page = nextPage else { return }
        let generation = requestGeneration
        let requestFilter = diaryRequestFilter
        isLoadingNextPage = true
        nextPageErrorMessage = nil

        do {
            let response = try await diaryRepository.page(filter: requestFilter, page: page)
            guard generation == requestGeneration, requestFilter == diaryRequestFilter else { return }
            let existingIDs = Set(entries.map(\.id))
            entries += response.results.filter { !existingIDs.contains($0.id) }
            nextPage = APIPageCursor.nextPage(from: response.next)
            isLoadingNextPage = false
        } catch {
            guard generation == requestGeneration, requestFilter == diaryRequestFilter else { return }
            nextPageErrorMessage = error.localizedDescription
            isLoadingNextPage = false
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }

    func loadFilterOptions() async {
        guard filter.itemId == nil else { return }
        do {
            filterOptions = try await filterOptionsRepository.options(scope: .diary, filter: diaryRequestFilter)
        } catch {
            filterOptions = .empty
        }
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

                        if viewModel.isLoading {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity, minHeight: 320)
                        } else if let error = viewModel.errorMessage {
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
                await viewModel.load()
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
        if viewModel.isLoadingNextPage {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        } else if let last = viewModel.entries.last {
            Color.clear
                .frame(height: 1)
                .task {
                    await viewModel.loadNextPageIfNeeded(currentEntry: last)
                }
        }
    }
}

struct DiaryView: View {
    @State private var viewModel: DiaryViewModel

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

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        header
                        mediaPicker

                        if viewModel.isLoading {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity, minHeight: 320)
                        } else if let error = viewModel.errorMessage {
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
                            DiaryEntryList(entries: viewModel.entries) { entry in
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
            .toolbarBackground(.hidden, for: .navigationBar)
            .task {
                await viewModel.loadFilterOptions()
                await viewModel.load()
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
        }
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
                Task {
                    await viewModel.loadFilterOptions()
                    await viewModel.load()
                }
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
            Task {
                await viewModel.loadFilterOptions()
                await viewModel.load()
            }
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
        if viewModel.isLoadingNextPage {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        } else if let error = viewModel.nextPageErrorMessage {
            DiaryStateCard(title: "Could not load more", systemImage: "exclamationmark.triangle", message: error)
        } else if let last = viewModel.entries.last {
            Color.clear
                .frame(height: 1)
                .task {
                    await viewModel.loadNextPageIfNeeded(currentEntry: last)
                }
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
