import SwiftUI

enum LibraryViewMode: String, CaseIterable, Identifiable {
    case grid = "Grid"
    case list = "List"

    var id: String { rawValue }
}

enum LibraryShelf: String, CaseIterable, Identifiable {
    case tracked = "Tracked"
    case planning = "Planning"

    var id: String { rawValue }
}

@MainActor
@Observable
final class LibraryViewModel {
    private struct RequestScope: Equatable {
        let mediaType: String
        let filter: MediaFilterState
    }

    var mediaType = "movie"
    var mediaTypes = LibraryViewModel.libraryMediaTypes(from: APIConstants.fallbackMediaTypes)
    var query = ""
    var filter = MediaFilterState()
    var filterOptions: MediaFilterOptionsResponse = .empty
    var viewMode: LibraryViewMode = .grid
    var shelf: LibraryShelf = .tracked
    var items: [LibraryItem] = []
    var totalCount = 0
    var isBootstrapping = true
    var isLoadingInitial = false
    var isLoadingNextPage = false
    var errorMessage: String?
    var nextPageErrorMessage: String?

    private let mediaRepository: MediaRepository
    private let trackingRepository: TrackingRepository
    private let filterOptionsRepository: FilterOptionsRepository
    private let onUnauthorized: () -> Void
    private var nextPage: String?
    private var requestGeneration = 0
    private var didBootstrap = false
    private var presentedScope: RequestScope?

    init(
        mediaRepository: MediaRepository,
        trackingRepository: TrackingRepository,
        filterOptionsRepository: FilterOptionsRepository? = nil,
        onUnauthorized: @escaping () -> Void
    ) {
        self.mediaRepository = mediaRepository
        self.trackingRepository = trackingRepository
        self.filterOptionsRepository = filterOptionsRepository ?? APIFilterOptionsRepository(client: AppEnvironment.apiClient)
        self.onUnauthorized = onUnauthorized
    }

    var hasMorePages: Bool {
        nextPage != nil
    }

    var paginationTaskID: String? {
        nextPage
    }

    var displayedItems: [LibraryItem] {
        items.filter { item in
            switch shelf {
            case .tracked:
                !Self.isPlanning(item)
            case .planning:
                Self.isPlanning(item)
            }
        }
    }

    static func libraryMediaTypes(from mediaTypes: [String]) -> [String] {
        let filtered = mediaTypes.filter { !["episode", "season"].contains($0) }
        return filtered.isEmpty ? APIConstants.fallbackMediaTypes.filter { !["episode", "season"].contains($0) } : filtered
    }

    static func isPlanning(_ item: LibraryItem) -> Bool {
        item.tracking.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "planning"
    }

    private var statusFilter: String? {
        shelf == .planning ? "Planning" : "tracked"
    }

    func bootstrap(selectedMediaType: String? = nil) async {
        guard !didBootstrap else { return }
        didBootstrap = true
        defer {
            if Task.isCancelled {
                didBootstrap = false
            } else {
                isBootstrapping = false
            }
        }
        await loadMeta(selectedMediaType: selectedMediaType)
        guard !Task.isCancelled else { return }
        await loadFilterOptions()
        guard !Task.isCancelled else { return }
        await reload()
    }

    func loadMeta(selectedMediaType: String? = nil) async {
        do {
            let meta = try await mediaRepository.meta()
            mediaTypes = Self.libraryMediaTypes(from: meta.mediaTypes)
        } catch is CancellationError {
            return
        } catch {
            mediaTypes = Self.libraryMediaTypes(from: APIConstants.fallbackMediaTypes)
        }

        if let selectedMediaType, mediaTypes.contains(selectedMediaType) {
            mediaType = selectedMediaType
        } else if !mediaTypes.contains(mediaType) {
            mediaType = mediaTypes.first ?? "movie"
        }
    }

    func selectMediaType(_ type: String, searchText: String? = nil) async {
        let selectedQuery = searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? query
        guard mediaType != type || query != selectedQuery else { return }
        mediaType = type
        query = selectedQuery
        filter.genres = []
        filter.languages = []
        filter.excludedGenres = []
        filter.excludedLanguages = []
        filter.year = nil
        filter.yearMin = nil
        filter.yearMax = nil
        await loadFilterOptions()
        await reload()
    }

    func setSearchQuery(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != trimmed else { return }
        query = trimmed
        await reload()
    }

    func clearSearch() async {
        guard !query.isEmpty else { return }
        query = ""
        await reload()
    }

    func reload() async {
        requestGeneration += 1
        let generation = requestGeneration
        let scope = currentRequestScope
        let preservesLastGoodContent = presentedScope == scope && !items.isEmpty

        if !preservesLastGoodContent {
            items = []
            totalCount = 0
            nextPage = nil
        }
        presentedScope = scope
        errorMessage = nil
        nextPageErrorMessage = nil
        isLoadingInitial = true
        isLoadingNextPage = false
        defer {
            if generation == requestGeneration, scope == currentRequestScope {
                isLoadingInitial = false
            }
        }

        do {
            let response = try await trackingRepository.list(mediaType: scope.mediaType, page: nil, filter: scope.filter)
            guard generation == requestGeneration, scope == currentRequestScope else { return }
            apply(response, replacingItems: true)
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration, scope == currentRequestScope else { return }
            errorMessage = error.localizedDescription
            handleUnauthorized(error)
        }
    }

    func loadNextPageIfNeeded(currentItem: LibraryItem) async {
        let visibleItems = displayedItems
        guard let thresholdIndex = visibleItems.index(visibleItems.endIndex, offsetBy: -8, limitedBy: visibleItems.startIndex) ?? visibleItems.indices.first,
              let currentIndex = visibleItems.firstIndex(where: { $0.id == currentItem.id }),
              currentIndex >= thresholdIndex else {
            return
        }
        await loadNextPage()
    }

    func loadNextPage() async {
        guard !isLoadingInitial, !isLoadingNextPage, let page = nextPage else { return }

        let generation = requestGeneration
        let scope = currentRequestScope
        isLoadingNextPage = true
        nextPageErrorMessage = nil
        defer {
            if generation == requestGeneration, scope == currentRequestScope {
                isLoadingNextPage = false
            }
        }

        do {
            let response = try await trackingRepository.list(mediaType: scope.mediaType, page: page, filter: scope.filter)
            guard generation == requestGeneration, scope == currentRequestScope else { return }
            apply(response, replacingItems: false)
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration, scope == currentRequestScope else { return }
            nextPageErrorMessage = error.localizedDescription
            handleUnauthorized(error)
        }
    }

    private func apply(_ response: PagedResponse<LibraryItem>, replacingItems: Bool) {
        totalCount = response.count
        nextPage = APIPageCursor.nextPage(from: response.next)

        if replacingItems {
            items = response.results
            return
        }

        let existingIDs = Set(items.map(\.id))
        items += response.results.filter { !existingIDs.contains($0.id) }
    }

    func loadFilterOptions() async {
        prepareForScopeChangeIfNeeded()
        do {
            let scope = currentRequestScope
            let options = try await filterOptionsRepository.options(
                scope: .tracking(mediaType: scope.mediaType),
                filter: scope.filter
            )
            guard scope == currentRequestScope else { return }
            filterOptions = options
        } catch is CancellationError {
            return
        } catch {
            filterOptions = .empty
        }
    }

    private var currentRequestScope: RequestScope {
        var requestFilter = filter
        requestFilter.q = query
        requestFilter.status = statusFilter
        return RequestScope(mediaType: mediaType, filter: requestFilter)
    }

    private func prepareForScopeChangeIfNeeded() {
        let scope = currentRequestScope
        guard presentedScope != scope else { return }

        requestGeneration += 1
        presentedScope = scope
        items = []
        totalCount = 0
        nextPage = nil
        errorMessage = nil
        nextPageErrorMessage = nil
        isLoadingInitial = true
        isLoadingNextPage = false
    }

    private func handleUnauthorized(_ error: Error) {
        if case APIError.unauthorized = error {
            onUnauthorized()
        }
    }
}

struct LibraryView: View {
    @State private var viewModel: LibraryViewModel
    @State private var searchDraftText = ""
    @State private var selectedGridMedia: MediaBrowsingSelection?
    @Binding private var requestedShelf: LibraryShelf?

    private let mediaRepository: MediaRepository
    private let trackingRepository: TrackingRepository
    private let diaryRepository: DiaryRepository
    private let listRepository: ListRepository
    private let filterOptionsRepository: FilterOptionsRepository
    private let mediaLensStore: MediaLensStore
    private let currentUserId: Int?
    private let selectedTab: AppTab
    private let onSelectTab: (AppTab) -> Void
    private let onUnauthorized: () -> Void

    @MainActor
    init(
        mediaRepository: MediaRepository,
        trackingRepository: TrackingRepository,
        diaryRepository: DiaryRepository,
        listRepository: ListRepository? = nil,
        filterOptionsRepository: FilterOptionsRepository? = nil,
        mediaLensStore: MediaLensStore? = nil,
        currentUserId: Int? = nil,
        requestedShelf: Binding<LibraryShelf?> = .constant(nil),
        selectedTab: AppTab = .library,
        onSelectTab: @escaping (AppTab) -> Void = { _ in },
        onUnauthorized: @escaping () -> Void = {}
    ) {
        _requestedShelf = requestedShelf
        self.mediaRepository = mediaRepository
        self.trackingRepository = trackingRepository
        self.diaryRepository = diaryRepository
        self.listRepository = listRepository ?? AppRepositories.current().lists
        self.filterOptionsRepository = filterOptionsRepository ?? AppRepositories.current().filterOptions
        self.mediaLensStore = mediaLensStore ?? MediaLensStore()
        self.currentUserId = currentUserId
        self.selectedTab = selectedTab
        self.onSelectTab = onSelectTab
        self.onUnauthorized = onUnauthorized
        _viewModel = State(initialValue: LibraryViewModel(
            mediaRepository: mediaRepository,
            trackingRepository: trackingRepository,
            filterOptionsRepository: self.filterOptionsRepository,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SpinePageBackground()

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header
                        content
                            .spineContentTransition(value: contentPhase)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
                .refreshable {
                    await viewModel.reload()
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .task {
                consumeRequestedShelf()
                await viewModel.bootstrap(selectedMediaType: mediaLensStore.selectedMediaType)
                validateSelectedMediaType()
            }
            .task(id: searchDraftText) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await viewModel.setSearchQuery(searchDraftText)
            }
            .onChange(of: requestedShelf) {
                consumeRequestedShelf()
            }
            .onChange(of: viewModel.shelf) {
                Task {
                    await viewModel.loadFilterOptions()
                    await viewModel.reload()
                }
            }
            .onChange(of: mediaLensStore.selectedMediaType) {
                Task { await viewModel.selectMediaType(mediaLensStore.selectedMediaType, searchText: searchDraftText) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .letterboxdImportDidSucceed)) { _ in
                Task { await viewModel.reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .storygraphImportDidSucceed)) { _ in
                Task { await viewModel.reload() }
            }
        }
        .fullScreenCover(item: $selectedGridMedia, onDismiss: { selectedGridMedia = nil }) { selection in
            MediaDetailView(
                ref: selection.ref,
                browsingContext: selection.context,
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

    private func consumeRequestedShelf() {
        guard let requestedShelf else { return }
        viewModel.shelf = requestedShelf
        self.requestedShelf = nil
    }

    private var selectedMediaTypeBinding: Binding<String> {
        Binding(
            get: { mediaLensStore.selectedMediaType },
            set: { mediaLensStore.setMediaType($0) }
        )
    }

    private func validateSelectedMediaType() {
        guard !viewModel.mediaTypes.contains(mediaLensStore.selectedMediaType) else { return }
        mediaLensStore.setMediaType(viewModel.mediaTypes.first ?? "movie")
        viewModel.mediaType = mediaLensStore.selectedMediaType
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Library")
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(.white)
            }

            mediaPicker

            MediaSearchBar(
                text: $searchDraftText,
                selectedMediaType: selectedMediaTypeBinding,
                isLensExpanded: .constant(false),
                availableTypes: viewModel.mediaTypes,
                horizontalPadding: 0,
                showsMediaLens: false,
                onLensTap: {},
                onLensSelect: { _ in },
                onSearch: { text in
                    Task { await viewModel.setSearchQuery(text) }
                },
                onClear: {
                    Task { await viewModel.clearSearch() }
                }
            )

            HStack(spacing: 12) {
                Picker("Shelf", selection: $viewModel.shelf) {
                    ForEach(LibraryShelf.allCases) { shelf in
                        Text(shelf.rawValue).tag(shelf)
                    }
                }
                .pickerStyle(.segmented)

                LibraryViewModeToggle(selection: $viewModel.viewMode)

                MediaFilterButton(
                    filter: $viewModel.filter,
                    scope: .tracking(mediaType: viewModel.mediaType),
                    options: viewModel.filterOptions,
                    mediaTypes: viewModel.mediaTypes
                ) {
                    Task {
                        await viewModel.loadFilterOptions()
                        await viewModel.reload()
                    }
                }
            }
        }
        .padding(.bottom, 14)
    }

    private var mediaPicker: some View {
        MediaSearchLensPicker(
            selectedType: selectedMediaTypeBinding,
            availableTypes: viewModel.mediaTypes,
            horizontalPadding: 0,
            fitsAllTypes: true,
            isCompact: true
        ) { _ in }
    }

    @ViewBuilder
    private var content: some View {
        let displayedItems = viewModel.displayedItems
        if viewModel.isBootstrapping || (viewModel.isLoadingInitial && viewModel.items.isEmpty) {
            LibrarySkeleton(mode: viewModel.viewMode)
        } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
            LibraryStateCard(
                title: "Could not load library",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Retry"
            ) {
                Task { await viewModel.reload() }
            }
        } else if let error = viewModel.nextPageErrorMessage, displayedItems.isEmpty {
            LibraryStateCard(
                title: "Could not load more library items",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Retry"
            ) {
                Task { await viewModel.loadNextPage() }
            }
        } else if displayedItems.isEmpty, viewModel.hasMorePages || viewModel.isLoadingNextPage {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, minHeight: 260)
                .task(id: viewModel.paginationTaskID) {
                    await viewModel.loadNextPage()
                }
        } else if displayedItems.isEmpty {
            LibraryStateCard(
                title: emptyTitle,
                systemImage: viewModel.shelf == .planning ? "bookmark" : "books.vertical",
                message: emptyMessage
            )
        } else {
            switch viewModel.viewMode {
            case .grid:
                libraryGrid(displayedItems)
            case .list:
                libraryList(displayedItems)
            }

            paginationFooter
        }
    }

    private var contentPhase: SpineContentPhase {
        let hasContent = !viewModel.displayedItems.isEmpty
        let hasPaginationError = viewModel.nextPageErrorMessage != nil
        return .resolve(
            isLoading: viewModel.isBootstrapping
                || viewModel.isLoadingInitial
                || (!hasContent && !hasPaginationError && (viewModel.hasMorePages || viewModel.isLoadingNextPage)),
            hasContent: hasContent,
            hasError: viewModel.errorMessage != nil || hasPaginationError
        )
    }

    private var emptyTitle: String {
        if !viewModel.query.isEmpty {
            return "No \(MediaTypeTheme.theme(for: viewModel.mediaType).displayName.lowercased()) found"
        }
        let mediaName = MediaTypeTheme.theme(for: viewModel.mediaType).displayName.lowercased()
        switch viewModel.shelf {
        case .tracked:
            return "No tracked \(mediaName)"
        case .planning:
            return "No planned \(mediaName)"
        }
    }

    private var emptyMessage: String {
        if !viewModel.query.isEmpty {
            return "No matches for \"\(viewModel.query)\" in \(viewModel.shelf.rawValue.lowercased())."
        }
        switch viewModel.shelf {
        case .tracked:
            return "Consumed, logged, watched, read, or played media will appear here."
        case .planning:
            return "Planning items stay separate from the rest of your library."
        }
    }

    private func libraryGrid(_ items: [LibraryItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
            ForEach(items) { item in
                Button {
                    selectedGridMedia = MediaBrowsingSelection(
                        ref: item.media.ref,
                        within: items.map(\.media.ref)
                    )
                } label: {
                    MediaArtwork(
                        url: item.media.displayPosterURL,
                        title: item.media.title,
                        slot: .tagGrid,
                        mediaType: item.media.ref.mediaType,
                        orientation: item.media.posterOrientation
                    )
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View \(item.media.title)")
                .task {
                    await viewModel.loadNextPageIfNeeded(currentItem: item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func libraryList(_ items: [LibraryItem]) -> some View {
        LazyVStack(spacing: 10) {
            ForEach(items) { item in
                NavigationLink {
                    mediaDestination(for: item)
                } label: {
                    LibraryListRow(item: item)
                }
                .buttonStyle(.plain)
                .task {
                    await viewModel.loadNextPageIfNeeded(currentItem: item)
                }
            }
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if viewModel.isLoadingNextPage {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        } else if let error = viewModel.nextPageErrorMessage {
            LibraryStateCard(
                title: "Could not load more",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Retry"
            ) {
                Task { await viewModel.loadNextPage() }
            }
        } else if viewModel.hasMorePages, let last = viewModel.displayedItems.last {
            Color.clear
                .frame(height: 1)
                .id(last.id)
                .onAppear {
                    Task {
                        await viewModel.loadNextPageIfNeeded(currentItem: last)
                    }
                }
        }
    }

    private func mediaDestination(
        for item: LibraryItem,
        browsingContext: MediaBrowsingContext? = nil
    ) -> some View {
        MediaDetailView(
            ref: item.media.ref,
            browsingContext: browsingContext,
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

private struct LibraryViewModeToggle: View {
    @Binding var selection: LibraryViewMode

    var body: some View {
        HStack(spacing: 2) {
            modeButton(.grid, systemImage: "square.grid.2x2")
            modeButton(.list, systemImage: "list.bullet")
        }
        .padding(3)
        .background(.white.opacity(0.07), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private func modeButton(_ mode: LibraryViewMode, systemImage: String) -> some View {
        Button {
            selection = mode
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(selection == mode ? .black : .white.opacity(0.62))
                .frame(width: 29, height: 29)
                .background(selection == mode ? .white : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.rawValue)
        .accessibilityAddTraits(selection == mode ? [.isButton, .isSelected] : .isButton)
    }
}

private struct LibraryListRow: View {
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 14) {
            MediaArtwork(
                url: item.media.displayPosterURL,
                title: item.media.title,
                slot: .libraryRow,
                mediaType: item.media.ref.mediaType,
                orientation: item.media.posterOrientation
            )
            .shadow(color: .black.opacity(0.24), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.media.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(item.tracking.status ?? "Tracked")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)

                let metadata = metadataText
                if !metadata.isEmpty {
                    Text(metadata)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.32))
        }
        .padding(10)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var metadataText: String {
        var parts: [String] = []
        if let rating = item.tracking.rating {
            parts.append("\(rating) stars")
        }
        if let progress = item.tracking.progress {
            if let progressText = progress.compactDisplayText(preferredMode: ProgressDisplayPreferences.mode(for: item.media.ref)) {
                parts.append(progressText)
            }
        }
        return parts.joined(separator: " - ")
    }
}

private struct LibrarySkeleton: View {
    let mode: LibraryViewMode

    var body: some View {
        switch mode {
        case .grid:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                ForEach(0 ..< 12, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: PosterSlot.tagGrid.cornerRadius, style: .continuous)
                        .fill(.white.opacity(0.08))
                        .frame(width: PosterSlot.tagGrid.size.width, height: PosterSlot.tagGrid.size.height)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .list:
            LazyVStack(spacing: 10) {
                ForEach(0 ..< 6, id: \.self) { _ in
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: PosterSlot.libraryRow.cornerRadius, style: .continuous)
                            .fill(.white.opacity(0.08))
                            .frame(width: PosterSlot.libraryRow.size.width, height: PosterSlot.libraryRow.size.height)

                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white.opacity(0.08))
                                .frame(height: 14)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white.opacity(0.06))
                                .frame(width: 130, height: 12)
                        }
                    }
                    .padding(10)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }
}

private struct LibraryStateCard: View {
    let title: String
    let systemImage: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.54))

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.58))
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.16))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 18)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}
