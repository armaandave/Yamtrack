import SwiftUI
import UIKit

@MainActor
@Observable
final class MediaDetailViewModel {
    var detail: MediaDetail?
    var reviews: [MediaReview] = []
    var tracking: TrackingState?
    var isLoading = true
    var isLoadingReviews = false
    var isSavingQuickAction = false
    var isSavingProgress = false
    var isSavingLike = false
    var errorMessage: String?
    var reviewsErrorMessage: String?
    var quickActionErrorMessage: String?
    var progressErrorMessage: String?
    var likeErrorMessage: String?

    private let ref: MediaRef
    private let mediaRepository: MediaRepository
    private let trackingRepository: TrackingRepository
    private let diaryRepository: DiaryRepository
    private let onUnauthorized: () -> Void

    init(
        ref: MediaRef,
        mediaRepository: MediaRepository,
        trackingRepository: TrackingRepository,
        diaryRepository: DiaryRepository,
        onUnauthorized: @escaping () -> Void
    ) {
        self.ref = ref
        self.mediaRepository = mediaRepository
        self.trackingRepository = trackingRepository
        self.diaryRepository = diaryRepository
        self.onUnauthorized = onUnauthorized
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await mediaRepository.detail(ref: ref)
            detail = loaded
            reviews = loaded.reviews ?? []
            await loadTrackingIfNeeded(for: loaded)
            await loadReviews()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }

    private func loadTrackingIfNeeded(for detail: MediaDetail) async {
        guard detail.userState?.isTracked == true || detail.userState?.status != nil else {
            tracking = nil
            return
        }
        do {
            tracking = try await trackingRepository.detail(ref: detail.ref)
        } catch APIError.httpStatus(404, _) {
            tracking = nil
        } catch {
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }

    func loadReviews() async {
        isLoadingReviews = true
        reviewsErrorMessage = nil
        defer { isLoadingReviews = false }

        do {
            reviews = try await mediaRepository.reviews(ref: ref)
        } catch {
            reviewsErrorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }

    func toggleLike(for review: MediaReview) async {
        do {
            let state = try await diaryRepository.setLike(entryId: review.id, liked: !review.viewerHasLiked)
            guard let index = reviews.firstIndex(where: { $0.id == review.id }) else { return }
            reviews[index].viewerHasLiked = state.liked
            reviews[index].likeCount = state.likeCount
        } catch {
            reviewsErrorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }

    func toggleMediaLike(for detail: MediaDetail) async -> Bool {
        guard !isSavingLike else { return false }
        isSavingLike = true
        likeErrorMessage = nil
        defer { isSavingLike = false }

        let next = !(detail.userState?.hasLiked ?? false)
        self.detail = detail.replacingHasLiked(next)
        do {
            let response = try await mediaRepository.setLiked(ref: detail.ref, liked: next)
            self.detail = self.detail?.replacingHasLiked(response.liked)
            return true
        } catch {
            self.detail = detail
            likeErrorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
            return false
        }
    }

    func performQuickAction(_ action: MediaDetailQuickAction, for detail: MediaDetail, completedAt: Date = Date()) async -> Bool {
        guard !isSavingQuickAction else { return false }
        isSavingQuickAction = true
        quickActionErrorMessage = nil
        defer { isSavingQuickAction = false }

        do {
            let state: TrackingState
            switch action {
            case .currently:
                state = try await trackingRepository.update(
                    ref: detail.ref,
                    request: TrackingWriteRequest(status: "In progress")
                )
            case .paused:
                state = try await trackingRepository.update(
                    ref: detail.ref,
                    request: TrackingWriteRequest(status: "Paused")
                )
            case .finished:
                if detail.ref.mediaType == "book" {
                    state = try await trackingRepository.completeBook(
                        source: detail.ref.source,
                        mediaId: detail.ref.mediaId,
                        completedAt: completedAt
                    )
                } else {
                    state = try await trackingRepository.consume(ref: detail.ref, consumedAt: completedAt)
                }
            case .stopped:
                state = try await trackingRepository.update(
                    ref: detail.ref,
                    request: TrackingWriteRequest(status: "Dropped")
                )
            }
            tracking = state
            return true
        } catch {
            quickActionErrorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
            return false
        }
    }

    func watchEpisode(_ detail: MediaDetail, watchedAt: Date = Date()) async -> Bool {
        guard
            !isSavingQuickAction,
            let seasonNumber = detail.ref.seasonNumber,
            let episodeNumber = detail.ref.episodeNumber
        else { return false }
        isSavingQuickAction = true
        quickActionErrorMessage = nil
        defer { isSavingQuickAction = false }

        do {
            _ = try await trackingRepository.watchEpisode(
                source: detail.ref.source,
                mediaId: detail.ref.mediaId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                watchedAt: watchedAt
            )
            self.detail = detail.replacingIsTracked(true)

            do {
                let refreshed = try await mediaRepository.detail(ref: detail.ref)
                self.detail = refreshed.replacingIsTracked(true)
            } catch is CancellationError {
                // The watch mutation succeeded; cancellation only stops the best-effort refresh.
            } catch {
                if case APIError.unauthorized = error {
                    onUnauthorized()
                }
            }
            return true
        } catch {
            quickActionErrorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
            return false
        }
    }

    func saveProgress(_ request: ProgressUpdateSaveRequest, for detail: MediaDetail) async -> Bool {
        guard !isSavingProgress else { return false }
        isSavingProgress = true
        progressErrorMessage = nil
        defer { isSavingProgress = false }

        do {
            var state: TrackingState
            if detail.ref.mediaType == "book" {
                state = try await trackingRepository.updateBookProgress(
                    source: detail.ref.source,
                    mediaId: detail.ref.mediaId,
                    progressType: request.mode.apiValue,
                    value: Decimal(request.value),
                    notes: ""
                )
                state = state.replacingProgress(progressState(for: request, detail: detail, fallback: state.progress))
            } else {
                state = try await trackingRepository.update(
                    ref: detail.ref,
                    request: TrackingWriteRequest(
                        status: "In progress",
                        progress: request.value
                    )
                )
                state = state.replacingProgress(progressState(for: request, detail: detail, fallback: state.progress))
            }
            ProgressDisplayPreferences.setMode(request.mode, for: detail.ref)
            tracking = state
            return true
        } catch {
            progressErrorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
            return false
        }
    }

    private func progressState(
        for request: ProgressUpdateSaveRequest,
        detail: MediaDetail,
        fallback: ProgressState?
    ) -> ProgressState {
        let max: Decimal?
        switch request.mode {
        case .percentage:
            max = Decimal(100)
        case .pages:
            max = detail.progressTotalPages.map { Decimal($0) } ?? fallback?.max
        }
        return ProgressState(
            kind: request.mode.apiValue,
            value: Decimal(request.value),
            max: max,
            unit: request.mode.unit
        )
    }

    func applyPosterSave(_ response: PosterSaveResponse) {
        detail = detail?.replacingPoster(with: response)
    }

    func applyBackdropSave(_ response: BackdropSaveResponse) {
        detail = detail?.replacingBackdrop(with: response)
    }

    func applyLogoSave(_ response: LogoSaveResponse) {
        detail = detail?.replacingLogo(with: response)
    }
}

enum MediaDetailQuickAction {
    case currently
    case paused
    case finished
    case stopped
}

private enum MediaDetailSheet: Identifiable {
    case posterMenu
    case bookGameActions
    case addToList

    var id: String {
        switch self {
        case .posterMenu: "posterMenu"
        case .bookGameActions: "bookGameActions"
        case .addToList: "addToList"
        }
    }
}

private struct PresentedDiaryEntry: Identifiable {
    let id: Int
}

private struct PresentedMediaDiary: Identifiable {
    let detail: MediaDetail

    var id: String { detail.ref.id }
    var title: String { "\(detail.displayTitle) Logs" }
}

struct MediaPersonCredit: Hashable {
    let name: String
    let personRef: PersonRef?
}

struct MediaCreditPresentation: Hashable {
    let label: String
    let people: [MediaPersonCredit]

    var heroPeople: [MediaPersonCredit] {
        Array(people.prefix(2))
    }

    var heroMoreCount: Int {
        max(0, people.count - heroPeople.count)
    }

    static func make(for detail: MediaDetail) -> MediaCreditPresentation? {
        guard detail.ref.source == "tmdb" else { return nil }

        let configuration: (pluralKey: String, singularKey: String, singularIDKey: String, singularLabel: String, pluralLabel: String)
        switch detail.ref.mediaType {
        case "movie":
            configuration = ("directors", "director", "director_id", "Director", "Directors")
        case "tv":
            configuration = ("creators", "creator", "creator_id", "Creator", "Creators")
        default:
            return nil
        }

        let people = pluralPeople(in: detail.details?[configuration.pluralKey])
        let resolvedPeople = people.isEmpty
            ? legacyPerson(
                name: detail.details?[configuration.singularKey]?.stringValue,
                id: identifier(in: detail.details?[configuration.singularIDKey])
            ).map { [$0] } ?? []
            : people
        guard !resolvedPeople.isEmpty else { return nil }

        return MediaCreditPresentation(
            label: resolvedPeople.count == 1 ? configuration.singularLabel : configuration.pluralLabel,
            people: resolvedPeople
        )
    }

    private static func pluralPeople(in value: JSONValue?) -> [MediaPersonCredit] {
        guard case let .array(values) = value else { return [] }
        var seen = Set<String>()
        return values.compactMap { value in
            guard case let .object(person) = value,
                  let name = person["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            let id = identifier(in: person["id"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = id.map { "id:\($0)" } ?? "name:\(name.lowercased())"
            guard seen.insert(key).inserted else { return nil }
            return MediaPersonCredit(
                name: name,
                personRef: id.flatMap { $0.isEmpty ? nil : PersonRef(source: "tmdb", id: $0) }
            )
        }
    }

    private static func legacyPerson(name: String?, id: String?) -> MediaPersonCredit? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let id = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaPersonCredit(
            name: name,
            personRef: id.flatMap { $0.isEmpty ? nil : PersonRef(source: "tmdb", id: $0) }
        )
    }

    private static func identifier(in value: JSONValue?) -> String? {
        switch value {
        case let .string(id):
            id
        case let .number(id) where id.rounded() == id:
            String(Int(id))
        default:
            nil
        }
    }
}

private struct MediaDetailChip: Hashable, Identifiable {
    let label: String
    let discoverRequest: MediaDiscoverRequest?

    var id: String {
        [label, discoverRequest?.id ?? "_"].joined(separator: ":")
    }
}

enum MediaArtworkCustomization {
    static func supportsPoster(source: String, mediaType: String) -> Bool {
        if source == "tmdb", ["movie", "tv", "season"].contains(mediaType) {
            return true
        }
        if source == "igdb", mediaType == "game" {
            return true
        }
        return mediaType == "book" && ["openlibrary", "hardcover"].contains(source)
    }

    static func supportsBackdrop(source: String, mediaType: String) -> Bool {
        if source == "tmdb", ["movie", "tv", "season", "episode"].contains(mediaType) {
            return true
        }
        return source == "igdb" && mediaType == "game"
    }

    static func supportsLogo(source: String, mediaType: String) -> Bool {
        if source == "tmdb", ["movie", "tv"].contains(mediaType) {
            return true
        }
        return source == "igdb" && mediaType == "game"
    }
}

enum MediaExternalRatingPresentation {
    static func includes(source: String, mediaType: String) -> Bool {
        let normalizedSource = source.lowercased()
        if normalizedSource == "spine" {
            return false
        }
        if normalizedSource == "tmdb", ["movie", "tv", "season"].contains(mediaType) {
            return false
        }
        return true
    }
}

private struct TopSafeAreaInsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MediaDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var posterTransitionNamespace
    @State private var selectedID: MediaRef.ID?
    @State private var presentedPoster: PosterViewerItem?

    private let ref: MediaRef
    private let browsingContext: MediaBrowsingContext?
    private let mediaRepository: MediaRepository
    private let trackingRepository: TrackingRepository
    private let diaryRepository: DiaryRepository
    private let listRepository: ListRepository
    private let peopleRepository: PeopleRepository
    private let companyRepository: CompanyRepository
    private let currentUserId: Int?
    private let selectedTab: AppTab
    private let onSelectTab: (AppTab) -> Void
    private let onUnauthorized: () -> Void
    private let onReturnToOriginSeason: (() -> Void)?

    init(
        ref: MediaRef,
        browsingContext: MediaBrowsingContext? = nil,
        mediaRepository: MediaRepository,
        trackingRepository: TrackingRepository,
        diaryRepository: DiaryRepository,
        listRepository: ListRepository = AppRepositories.current().lists,
        peopleRepository: PeopleRepository = AppRepositories.current().people,
        companyRepository: CompanyRepository = AppRepositories.current().companies,
        currentUserId: Int? = nil,
        selectedTab: AppTab = .home,
        onSelectTab: @escaping (AppTab) -> Void = { _ in },
        onUnauthorized: @escaping () -> Void = {},
        onReturnToOriginSeason: (() -> Void)? = nil
    ) {
        self.ref = ref
        self.browsingContext = browsingContext
        self.mediaRepository = mediaRepository
        self.trackingRepository = trackingRepository
        self.diaryRepository = diaryRepository
        self.listRepository = listRepository
        self.peopleRepository = peopleRepository
        self.companyRepository = companyRepository
        self.currentUserId = currentUserId
        self.selectedTab = selectedTab
        self.onSelectTab = onSelectTab
        self.onUnauthorized = onUnauthorized
        self.onReturnToOriginSeason = onReturnToOriginSeason
        _selectedID = State(initialValue: browsingContext?.selectedID ?? ref.id)
    }

    var body: some View {
        ZStack {
            Group {
                if let browsingContext, browsingContext.refs.count > 1 {
                    GeometryReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 0) {
                                ForEach(Array(browsingContext.refs.enumerated()), id: \.element.id) { index, pageRef in
                                    detailPage(
                                        ref: pageRef,
                                        shouldLoad: abs(index - selectedIndex(in: browsingContext)) <= 1,
                                        topSafeAreaInset: proxy.safeAreaInsets.top
                                    )
                                    .containerRelativeFrame(.horizontal)
                                    .id(pageRef.id)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollIndicators(.hidden)
                        .scrollTargetBehavior(.paging)
                        .scrollPosition(id: $selectedID)
                        .ignoresSafeArea(edges: .top)
                    }
                } else {
                    detailPage(ref: ref, shouldLoad: true)
                }
            }
            .scrollDisabled(presentedPoster != nil)
            .accessibilityHidden(presentedPoster != nil)

            if let presentedPoster {
                PosterViewer(
                    item: presentedPoster,
                    namespace: posterTransitionNamespace,
                    onDismiss: dismissPoster
                )
                .zIndex(100)
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }

    private func selectedIndex(in context: MediaBrowsingContext) -> Int {
        context.refs.firstIndex(where: { $0.id == selectedID }) ?? 0
    }

    private func detailPage(
        ref: MediaRef,
        shouldLoad: Bool,
        topSafeAreaInset: CGFloat? = nil
    ) -> some View {
        MediaDetailPageView(
            ref: ref,
            shouldLoad: shouldLoad,
            topSafeAreaInset: topSafeAreaInset,
            mediaRepository: mediaRepository,
            trackingRepository: trackingRepository,
            diaryRepository: diaryRepository,
            listRepository: listRepository,
            peopleRepository: peopleRepository,
            companyRepository: companyRepository,
            currentUserId: currentUserId,
            selectedTab: selectedTab,
            posterTransitionNamespace: posterTransitionNamespace,
            presentedPosterID: presentedPoster?.id,
            onOpenPoster: presentPoster,
            onSelectTab: onSelectTab,
            onUnauthorized: onUnauthorized,
            onReturnToOriginSeason: onReturnToOriginSeason
        )
    }

    private func presentPoster(_ poster: PosterViewerItem) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.88)) {
            presentedPoster = poster
        }
    }

    private func dismissPoster() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9)) {
            presentedPoster = nil
        }
    }
}

private struct MediaDetailPageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel: MediaDetailViewModel
    @State private var presentedSheet: MediaDetailSheet?
    @State private var presentedRef: MediaRef?
    @State private var presentedMediaSelection: MediaBrowsingSelection?
    @State private var presentedDiaryEntry: PresentedDiaryEntry?
    @State private var presentedMediaDiary: PresentedMediaDiary?
    @State private var presentedDiscover: MediaDiscoverRequest?
    @State private var presentedPerson: PersonRef?
    @State private var presentedCompany: CompanyRef?
    @State private var isPosterPickerPresented = false
    @State private var isBackdropPickerPresented = false
    @State private var isLogoPickerPresented = false
    @State private var pendingPosterSave: PosterSaveResponse?
    @State private var pendingBackdropSave: BackdropSaveResponse?
    @State private var pendingLogoSave: LogoSaveResponse?
    @State private var isLogPresented = false
    @State private var progressUpdateDetail: MediaDetail?
    @State private var isQuickActionAlertPresented = false
    @State private var isLikeAlertPresented = false
    @State private var showsTitleLogo = true
    @State private var topSafeAreaInset: CGFloat = 0
    @State private var edgeDragOffset: CGFloat = 0

    private let mediaRepository: MediaRepository
    private let trackingRepository: TrackingRepository
    private let diaryRepository: DiaryRepository
    private let listRepository: ListRepository
    private let peopleRepository: PeopleRepository
    private let companyRepository: CompanyRepository
    private let currentUserId: Int?
    private let selectedTab: AppTab
    private let posterTransitionNamespace: Namespace.ID
    private let presentedPosterID: PosterViewerItem.ID?
    private let onOpenPoster: (PosterViewerItem) -> Void
    private let onSelectTab: (AppTab) -> Void
    private let onUnauthorized: () -> Void
    private let onReturnToOriginSeason: (() -> Void)?
    private let ref: MediaRef
    private let shouldLoad: Bool
    private let topSafeAreaInsetOverride: CGFloat?

    init(
        ref: MediaRef,
        shouldLoad: Bool,
        topSafeAreaInset: CGFloat? = nil,
        mediaRepository: MediaRepository,
        trackingRepository: TrackingRepository,
        diaryRepository: DiaryRepository,
        listRepository: ListRepository = AppRepositories.current().lists,
        peopleRepository: PeopleRepository = AppRepositories.current().people,
        companyRepository: CompanyRepository = AppRepositories.current().companies,
        currentUserId: Int? = nil,
        selectedTab: AppTab = .home,
        posterTransitionNamespace: Namespace.ID,
        presentedPosterID: PosterViewerItem.ID?,
        onOpenPoster: @escaping (PosterViewerItem) -> Void,
        onSelectTab: @escaping (AppTab) -> Void = { _ in },
        onUnauthorized: @escaping () -> Void = {},
        onReturnToOriginSeason: (() -> Void)? = nil
    ) {
        self.ref = ref
        self.shouldLoad = shouldLoad
        topSafeAreaInsetOverride = topSafeAreaInset
        self.mediaRepository = mediaRepository
        self.trackingRepository = trackingRepository
        self.diaryRepository = diaryRepository
        self.listRepository = listRepository
        self.peopleRepository = peopleRepository
        self.companyRepository = companyRepository
        self.currentUserId = currentUserId
        self.selectedTab = selectedTab
        self.posterTransitionNamespace = posterTransitionNamespace
        self.presentedPosterID = presentedPosterID
        self.onOpenPoster = onOpenPoster
        self.onSelectTab = onSelectTab
        self.onUnauthorized = onUnauthorized
        self.onReturnToOriginSeason = onReturnToOriginSeason
        _viewModel = State(initialValue: MediaDetailViewModel(
            ref: ref,
            mediaRepository: mediaRepository,
            trackingRepository: trackingRepository,
            diaryRepository: diaryRepository,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        ZStack(alignment: .top) {
            SpinePageBackground()

            ScrollView(showsIndicators: false) {
                pageScrollContent
                    .spineContentTransition(value: contentPhase)
            }
            .scrollContentBackground(.hidden)
            .ignoresSafeArea(edges: .top)

            topButtons
                .padding(.horizontal, 16)
                .padding(.top, resolvedTopSafeAreaInset + 6)

            if progressUpdateDetail == nil {
                MediaDetailBottomBar(selectedTab: selectedTab, onSelectTab: navigateToTab)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .navigationBarBackButtonHidden()
        .offset(x: edgeDragOffset)
        .overlay(alignment: .leading) {
            if presentedPosterID == nil {
                Color.clear
                    .frame(width: 28)
                    .contentShape(Rectangle())
                    .gesture(edgeSwipeBackGesture)
            }
        }
        .overlay {
            if let detail = progressUpdateDetail {
                ProgressUpdateSheet(
                    detail: detail,
                    progress: currentProgress(detail),
                    isSaving: viewModel.isSavingProgress,
                    errorMessage: viewModel.progressErrorMessage,
                    onSave: { request in
                        await viewModel.saveProgress(request, for: detail)
                    },
                    onDismiss: {
                        progressUpdateDetail = nil
                    },
                    onLogFinished: {
                        progressUpdateDetail = nil
                        isLogPresented = true
                    }
                )
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: TopSafeAreaInsetKey.self, value: proxy.safeAreaInsets.top)
            }
        }
        .onPreferenceChange(TopSafeAreaInsetKey.self) { topSafeAreaInset = $0 }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .posterMenu:
                PosterMenuSheet(
                    posterLabel: "Customize Poster",
                    showsSeasonOption: parentSeasonRef(viewModel.detail) != nil,
                    showsTVShowOption: parentTVRef(viewModel.detail) != nil,
                    showsPosterOption: canCustomizePoster(viewModel.detail),
                    showsBackdropOption: canCustomizeBackdrop(viewModel.detail),
                    showsLogoOption: canCustomizeLogo(viewModel.detail),
                    onViewSeason: {
                        guard let ref = parentSeasonRef(viewModel.detail) else { return }
                        presentedSheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            navigateToParent(ref)
                        }
                    },
                    onViewTVShow: {
                        guard let ref = parentTVRef(viewModel.detail) else { return }
                        presentedSheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            presentedRef = ref
                        }
                    },
                    onAddToList: {
                        presentedSheet = .addToList
                    },
                    onCustomizePoster: {
                        presentedSheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            isPosterPickerPresented = true
                        }
                    },
                    onCustomizeBackdrop: {
                        presentedSheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            isBackdropPickerPresented = true
                        }
                    },
                    onCustomizeLogo: {
                        presentedSheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            isLogoPickerPresented = true
                        }
                    }
                )
                .presentationDetents([.height(posterMenuHeight(for: viewModel.detail))])
                .presentationDragIndicator(.visible)
            case .bookGameActions:
                if let detail = viewModel.detail {
                    BookGameActionSheet(
                        mediaType: detail.ref.mediaType,
                        status: currentStatus(detail),
                        isSaving: viewModel.isSavingQuickAction,
                        errorMessage: viewModel.quickActionErrorMessage,
                        onAction: { action in
                            await performQuickAction(action, for: detail, dismissSheet: true)
                        },
                        onUpdateProgress: {
                            openProgressUpdate(for: detail)
                        },
                        onLog: {
                            presentedSheet = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                isLogPresented = true
                            }
                        }
                    )
                    .presentationDetents([.height(224)])
                    .presentationDragIndicator(.visible)
                }
            case .addToList:
                if let detail = viewModel.detail {
                    AddToListSheet(
                        ref: detail.ref,
                        listRepository: listRepository,
                        onUnauthorized: onUnauthorized
                    )
                }
            }
        }
        .alert("Tracking Update Failed", isPresented: $isQuickActionAlertPresented) {
            Button("OK") {
                viewModel.quickActionErrorMessage = nil
            }
        } message: {
            Text(viewModel.quickActionErrorMessage ?? "")
        }
        .alert("Like Update Failed", isPresented: $isLikeAlertPresented) {
            Button("OK") {
                viewModel.likeErrorMessage = nil
            }
        } message: {
            Text(viewModel.likeErrorMessage ?? "")
        }
        .fullScreenCover(isPresented: $isBackdropPickerPresented, onDismiss: applyPendingBackdropSave) {
            if let detail = viewModel.detail {
                BackdropPickerView(
                    ref: detail.ref,
                    mediaRepository: mediaRepository,
                    onUnauthorized: onUnauthorized
                ) { response in
                    pendingBackdropSave = response
                    presentedSheet = nil
                }
            }
        }
        .fullScreenCover(isPresented: $isLogoPickerPresented, onDismiss: applyPendingLogoSave) {
            if let detail = viewModel.detail {
                LogoPickerView(
                    ref: detail.ref,
                    mediaRepository: mediaRepository,
                    onUnauthorized: onUnauthorized
                ) { response in
                    pendingLogoSave = response
                    presentedSheet = nil
                }
            }
        }
        .fullScreenCover(isPresented: $isLogPresented) {
            if let detail = viewModel.detail {
                MediaLogView(
                    detail: detail,
                    trackingRepository: trackingRepository,
                    diaryRepository: diaryRepository,
                    onUnauthorized: onUnauthorized
                ) {
                    Task {
                        await viewModel.load()
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $isPosterPickerPresented, onDismiss: applyPendingPosterSave) {
            if let detail = viewModel.detail {
                PosterPickerView(
                    ref: detail.ref,
                    mediaRepository: mediaRepository,
                    title: "Customize Poster",
                    showsLanguageFilter: !isBook(detail) && detail.ref.mediaType != "game",
                    contentMode: isBook(detail) ? .fit : .fill,
                    onUnauthorized: onUnauthorized
                ) { response in
                    pendingPosterSave = response
                    presentedSheet = nil
                }
            }
        }
        .fullScreenCover(item: $presentedRef) { ref in
            MediaDetailView(
                ref: ref,
                mediaRepository: mediaRepository,
                trackingRepository: trackingRepository,
                diaryRepository: diaryRepository,
                listRepository: listRepository,
                peopleRepository: peopleRepository,
                companyRepository: companyRepository,
                currentUserId: currentUserId,
                selectedTab: selectedTab,
                onSelectTab: onSelectTab,
                onUnauthorized: onUnauthorized
            )
        }
        .fullScreenCover(item: $presentedMediaSelection) { selection in
            MediaDetailView(
                ref: selection.ref,
                browsingContext: selection.context,
                mediaRepository: mediaRepository,
                trackingRepository: trackingRepository,
                diaryRepository: diaryRepository,
                listRepository: listRepository,
                peopleRepository: peopleRepository,
                companyRepository: companyRepository,
                currentUserId: currentUserId,
                selectedTab: selectedTab,
                onSelectTab: onSelectTab,
                onUnauthorized: onUnauthorized,
                onReturnToOriginSeason: {
                    presentedMediaSelection = nil
                }
            )
        }
        .fullScreenCover(item: $presentedPerson) { person in
            PersonDetailView(
                ref: person,
                peopleRepository: peopleRepository,
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
        .fullScreenCover(item: $presentedCompany) { company in
            CompanyDetailView(
                ref: company,
                companyRepository: companyRepository,
                mediaRepository: mediaRepository,
                trackingRepository: trackingRepository,
                diaryRepository: diaryRepository,
                listRepository: listRepository,
                peopleRepository: peopleRepository,
                currentUserId: currentUserId,
                selectedTab: selectedTab,
                onSelectTab: onSelectTab,
                onUnauthorized: onUnauthorized
            )
        }
        .fullScreenCover(item: $presentedDiaryEntry) { entry in
            DiaryLogDetailNavigationCover(
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
        .fullScreenCover(item: $presentedMediaDiary) { diary in
            if let itemId = diary.detail.ref.itemId {
                MediaDiaryView(
                    title: diary.title,
                    itemId: itemId,
                    posterURL: diary.detail.displayPosterURL,
                    posterOrientation: diary.detail.posterOrientation,
                    diaryRepository: diaryRepository,
                    mediaRepository: mediaRepository,
                    trackingRepository: trackingRepository,
                    currentUserId: currentUserId,
                    selectedTab: selectedTab,
                    onSelectTab: onSelectTab,
                    onUnauthorized: onUnauthorized
                )
            }
        }
        .fullScreenCover(item: $presentedDiscover) { request in
            MediaDiscoverView(
                request: request,
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
        .task(id: shouldLoad) {
            if shouldLoad, viewModel.detail == nil {
                await viewModel.load()
            }
        }
        .onChange(of: viewModel.detail?.id) {
            showsTitleLogo = true
        }
    }

    @ViewBuilder
    private var pageScrollContent: some View {
        Group {
            if viewModel.isLoading, viewModel.detail == nil {
                if ref.mediaType == "episode" {
                    EpisodeDetailLoadingView()
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, minHeight: 520)
                }
            } else if let detail = viewModel.detail {
                VStack(spacing: 0) {
                    hero(detail)
                        .padding(.top, -resolvedTopSafeAreaInset)
                    content(detail)
                }
            } else if let error = viewModel.errorMessage, viewModel.detail == nil {
                VStack(spacing: 18) {
                    ContentUnavailableView("Could not load media", systemImage: "exclamationmark.triangle", description: Text(error))
                        .foregroundStyle(.white)
                    Button("Try Again") {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.16))
                }
                .padding()
                .frame(maxWidth: .infinity, minHeight: 520)
            }
        }
        .padding(.bottom, 116)
    }

    private var contentPhase: SpineContentPhase {
        .resolve(
            isLoading: viewModel.isLoading,
            hasContent: viewModel.detail != nil,
            hasError: viewModel.errorMessage != nil
        )
    }

    private func applyPendingPosterSave() {
        guard let response = pendingPosterSave else { return }
        pendingPosterSave = nil
        viewModel.applyPosterSave(response)
    }

    private func applyPendingBackdropSave() {
        guard let response = pendingBackdropSave else { return }
        pendingBackdropSave = nil
        viewModel.applyBackdropSave(response)
    }

    private func applyPendingLogoSave() {
        guard let response = pendingLogoSave else { return }
        pendingLogoSave = nil
        viewModel.applyLogoSave(response)
        showsTitleLogo = true
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

    private var topButtons: some View {
        HStack {
            CircleIconButton(systemName: "chevron.left", label: "Back") {
                dismiss()
            }
            Spacer()
            if viewModel.detail != nil {
                CircleIconButton(systemName: "ellipsis", label: "More") {
                    presentedSheet = .posterMenu
                }
            }
        }
    }

    private var resolvedTopSafeAreaInset: CGFloat {
        topSafeAreaInsetOverride ?? topSafeAreaInset
    }

    private func posterMenuHeight(for detail: MediaDetail?) -> CGFloat {
        let optionalRows = [
            parentSeasonRef(detail) != nil,
            parentTVRef(detail) != nil,
            canCustomizePoster(detail),
            canCustomizeBackdrop(detail),
            canCustomizeLogo(detail),
        ].filter { $0 }.count
        return 80 + CGFloat(optionalRows * 68)
    }

    private func canCustomizePoster(_ detail: MediaDetail?) -> Bool {
        guard let detail else { return false }
        return MediaArtworkCustomization.supportsPoster(
            source: detail.ref.source,
            mediaType: detail.ref.mediaType
        )
    }

    private func canCustomizeBackdrop(_ detail: MediaDetail?) -> Bool {
        guard let detail else { return false }
        return MediaArtworkCustomization.supportsBackdrop(
            source: detail.ref.source,
            mediaType: detail.ref.mediaType
        )
    }

    private func canCustomizeLogo(_ detail: MediaDetail?) -> Bool {
        guard let detail else { return false }
        return MediaArtworkCustomization.supportsLogo(
            source: detail.ref.source,
            mediaType: detail.ref.mediaType
        )
    }

    private func isBook(_ detail: MediaDetail) -> Bool {
        detail.ref.mediaType == "book"
    }

    private func parentTVRef(_ detail: MediaDetail?) -> MediaRef? {
        guard let detail, ["season", "episode"].contains(detail.ref.mediaType) else { return nil }
        return MediaRef(
            itemId: nil,
            source: detail.ref.source,
            mediaType: "tv",
            mediaId: detail.ref.mediaId,
            seasonNumber: nil,
            episodeNumber: nil
        )
    }

    private func parentSeasonRef(_ detail: MediaDetail?) -> MediaRef? {
        guard
            let detail,
            detail.ref.mediaType == "episode",
            let seasonNumber = detail.ref.seasonNumber
        else { return nil }
        return MediaRef(
            itemId: nil,
            source: detail.ref.source,
            mediaType: "season",
            mediaId: detail.ref.mediaId,
            seasonNumber: seasonNumber,
            episodeNumber: nil
        )
    }

    private func navigateToParent(_ ref: MediaRef) {
        if ref.mediaType == "season", let onReturnToOriginSeason {
            onReturnToOriginSeason()
        } else {
            presentedRef = ref
        }
    }

    private func usesBookGameActions(_ detail: MediaDetail) -> Bool {
        ["book", "game", "music"].contains(detail.ref.mediaType)
    }

    private func trackAction(for detail: MediaDetail) {
        if usesBookGameActions(detail) {
            presentedSheet = .bookGameActions
        } else {
            isLogPresented = true
        }
    }

    private func eyeAction(for detail: MediaDetail) {
        if detail.ref.mediaType == "episode" {
            guard detail.userState?.isTracked != true else { return }
            Task {
                let succeeded = await viewModel.watchEpisode(detail)
                if !succeeded {
                    isQuickActionAlertPresented = true
                }
            }
            return
        }
        guard usesBookGameActions(detail) else { return }
        Task {
            await performQuickAction(.finished, for: detail, dismissSheet: false)
        }
    }

    private func performQuickAction(_ action: MediaDetailQuickAction, for detail: MediaDetail, dismissSheet: Bool) async {
        if await viewModel.performQuickAction(action, for: detail) {
            if dismissSheet {
                presentedSheet = nil
            }
            await viewModel.load()
        } else if !dismissSheet {
            isQuickActionAlertPresented = true
        }
    }

    private func likeAction(for detail: MediaDetail) {
        Task {
            let succeeded = await viewModel.toggleMediaLike(for: detail)
            if !succeeded {
                isLikeAlertPresented = true
            }
        }
    }

    private func openProgressUpdate(for detail: MediaDetail) {
        viewModel.progressErrorMessage = nil
        presentedSheet = nil
        progressUpdateDetail = detail
    }

    private func openPosterPicker(for detail: MediaDetail) {
        guard canCustomizePoster(detail) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isPosterPickerPresented = true
    }

    private func openBackdropPicker(for detail: MediaDetail) {
        guard canCustomizeBackdrop(detail) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isBackdropPickerPresented = true
    }

    private func openLogoPicker(for detail: MediaDetail) {
        guard canCustomizeLogo(detail), detail.displayLogoURL != nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isLogoPickerPresented = true
    }

    private func navigateToTab(_ tab: AppTab) {
        onSelectTab(tab)
        if !dismissPresentedViewControllerStack() {
            dismiss()
        }
    }

    private func isShowingTitleLogo(_ detail: MediaDetail) -> Bool {
        showsTitleLogo && supportsTitleLogo(detail)
    }

    @ViewBuilder
    private func hero(_ detail: MediaDetail) -> some View {
        if detail.ref.mediaType == "episode" {
            episodeHero(detail)
        } else {
            ZStack(alignment: .top) {
                HeroArtwork(detail: detail)
                    .frame(height: heroHeight(for: detail))

                if let backdropURL = backdropURLString(for: detail) {
                    BackdropArtwork(urlString: backdropURL)
                        .frame(height: resolvedTopSafeAreaInset + MediaDetailLayout.backdropHeight)
                        .onLongPressGesture {
                            openBackdropPicker(for: detail)
                        }
                }

                heroHeader(detail)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 18)
                    .padding(.top, resolvedTopSafeAreaInset + heroPosterTopOffset(for: detail))
                    .frame(minHeight: heroHeight(for: detail), alignment: .top)
            }
        }
    }

    @ViewBuilder
    private func episodeHero(_ detail: MediaDetail) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) {
                EpisodeHeroArtwork(
                    urlString: detail.episodeStillURL,
                    title: detail.title
                )
                .frame(height: resolvedTopSafeAreaInset + MediaDetailLayout.episodeAccessibilityArtworkHeight)
                .onLongPressGesture {
                    openBackdropPicker(for: detail)
                }

                episodeHeroContent(detail, overlaysArtwork: false)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 24)
            }
        } else {
            ZStack(alignment: .bottomLeading) {
                EpisodeHeroArtwork(
                    urlString: detail.episodeStillURL,
                    title: detail.title
                )
                .frame(height: resolvedTopSafeAreaInset + MediaDetailLayout.episodeHeroHeight)
                .onLongPressGesture {
                    openBackdropPicker(for: detail)
                }

                episodeHeroContent(detail, overlaysArtwork: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
            .frame(height: resolvedTopSafeAreaInset + MediaDetailLayout.episodeHeroHeight)
        }
    }

    private func episodeHeroContent(_ detail: MediaDetail, overlaysArtwork: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(episodeEyebrow(detail))
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white.opacity(0.7))
                .textCase(.uppercase)
                .tracking(0.7)

            Text(detail.title)
                .font(.largeTitle.weight(.black))
                .foregroundStyle(.white)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                .minimumScaleFactor(0.72)
                .accessibilityAddTraits(.isHeader)

            if let context = episodeParentContext(detail) {
                Group {
                    if let parent = parentSeasonRef(detail) ?? parentTVRef(detail) {
                        Button {
                            navigateToParent(parent)
                        } label: {
                            episodeParentLabel(context)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View \(context)")
                    } else {
                        episodeParentLabel(context)
                    }
                }
            }

            episodeMetadata(detail)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) {
                    episodeRatings(detail)
                    Spacer(minLength: 8)
                    episodeActionRail(detail)
                }

                VStack(alignment: .leading, spacing: 12) {
                    episodeRatings(detail)
                    episodeActionRail(detail)
                }
            }
        }
        .padding(.top, overlaysArtwork ? 56 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func episodeParentLabel(_ context: String) -> some View {
        HStack(spacing: 6) {
            Text(context)
                .font(.subheadline.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white.opacity(0.78))
    }

    @ViewBuilder
    private func episodeMetadata(_ detail: MediaDetail) -> some View {
        let values = [
            formattedDate(detailString(detail, "air_date") ?? detail.releaseDate),
            detailString(detail, "runtime"),
        ].compactMap { $0?.nilIfEmpty }

        if !values.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        if index > 0 {
                            Circle()
                                .fill(.white.opacity(0.42))
                                .frame(width: 3, height: 3)
                        }
                        Text(value)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(values, id: \.self) { value in
                        Text(value)
                    }
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.66))
        }
    }

    @ViewBuilder
    private func episodeRatings(_ detail: MediaDetail) -> some View {
        let chips = ratingChips(detail)
        let hasIMDbRating = (detail.externalRatings ?? []).contains {
            $0.source.caseInsensitiveCompare("IMDb") == .orderedSame && !$0.value.isEmpty
        }

        VStack(alignment: .leading, spacing: 8) {
            RatingChipRow(chips: chips, stacked: true)
            if !hasIMDbRating, let destination = episodeIMDbURL(detail) {
                IMDbExternalLinkPill(destination: destination)
            }
        }
    }

    private func episodeActionRail(_ detail: MediaDetail) -> some View {
        let isWatched = detail.userState?.isTracked == true
        return ActionRail(
            isTracked: isWatched,
            isLiked: detail.userState?.hasLiked ?? false,
            isHorizontal: true,
            trackLabel: "Log episode",
            eyeLabel: isWatched ? "Episode watched" : "Mark episode watched",
            isEyeSelected: isWatched,
            isEyeDisabled: isWatched,
            isEyeLoading: viewModel.isSavingQuickAction,
            isLikeLoading: viewModel.isSavingLike,
            onTrack: { trackAction(for: detail) },
            onLike: { likeAction(for: detail) },
            onEye: { eyeAction(for: detail) }
        )
    }

    private func episodeEyebrow(_ detail: MediaDetail) -> String {
        let season = detail.ref.seasonNumber.map { "S\($0)" }
        let episode = detail.ref.episodeNumber.map { "E\($0)" }
        return [season, episode].compactMap { $0 }.joined(separator: " · ")
    }

    private func episodeParentContext(_ detail: MediaDetail) -> String? {
        let showTitle = detailString(detail, "show_title")
            ?? detailString(detail, "series_title")
            ?? detailString(detail, "parent_title")
            ?? detail.subtitle
        let seasonTitle = detailString(detail, "season_title")
            ?? detail.ref.seasonNumber.map { "Season \($0)" }
        return [showTitle, seasonTitle]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    private func episodeIMDbURL(_ detail: MediaDetail) -> URL? {
        if let destination = detail.externalRatings?.first(where: {
            $0.source.caseInsensitiveCompare("IMDb") == .orderedSame
        })?.destinationURL {
            return destination
        }
        for key in ["imdb_url", "imdb_link"] {
            if let value = detailString(detail, key), let destination = URL(string: value) {
                return destination
            }
        }
        return nil
    }

    private func titleDisplay(
        detail: MediaDetail,
        title: String,
        showsLogo: Binding<Bool>,
        font: Font,
        lineLimit: Int?,
        minimumScaleFactor: CGFloat,
        maxLogoHeight: CGFloat
    ) -> some View {
        MediaTitleDisplay(
            detail: detail,
            title: title,
            showsLogo: showsLogo,
            font: font,
            lineLimit: lineLimit,
            minimumScaleFactor: minimumScaleFactor,
            maxLogoHeight: maxLogoHeight,
            onTap: parentTVRef(detail).map { ref in
                { presentedRef = ref }
            },
            onLongPress: canCustomizeLogo(detail) && detail.displayLogoURL != nil
                ? { openLogoPicker(for: detail) }
                : nil
        )
    }

    @ViewBuilder
    private func heroHeader(_ detail: MediaDetail) -> some View {
        if backdropURLString(for: detail) != nil {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 11) {
                    titleDisplay(
                        detail: detail,
                        title: detail.displayTitle,
                        showsLogo: $showsTitleLogo,
                        font: .system(size: 32, weight: .black),
                        lineLimit: 3,
                        minimumScaleFactor: 0.72,
                        maxLogoHeight: 44
                    )

                    if let credits = gameDeveloperCredits(detail) {
                        companyCreditBylineView(credits)
                    } else if let credits = MediaCreditPresentation.make(for: detail) {
                        creditBylineView(credits)
                    } else if let byline = byline(detail) {
                        bylineView(byline, detail: detail, lineLimit: 2)
                    }

                    genreChips(detail, wrapsAfterThird: true)
                    RatingChipRow(chips: ratingChips(detail), stacked: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)

                VStack(spacing: 14) {
                    heroPoster(detail)

                    ActionRail(
                        isTracked: currentStatus(detail) != nil,
                        isLiked: detail.userState?.hasLiked ?? false,
                        isHorizontal: true,
                        trackLabel: usesBookGameActions(detail) ? "Track" : nil,
                        eyeLabel: usesBookGameActions(detail) ? bookGameCopy(for: detail.ref.mediaType).finished : nil,
                        isEyeLoading: usesBookGameActions(detail) && viewModel.isSavingQuickAction,
                        isLikeLoading: viewModel.isSavingLike,
                        onTrack: { trackAction(for: detail) },
                        onLike: { likeAction(for: detail) },
                        onEye: { eyeAction(for: detail) }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        } else {
            VStack(spacing: 0) {
                heroPoster(detail)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 16)

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 11) {
                        titleDisplay(
                            detail: detail,
                            title: detail.displayTitle,
                            showsLogo: $showsTitleLogo,
                            font: .system(size: 33, weight: .heavy),
                            lineLimit: nil,
                            minimumScaleFactor: 0.66,
                            maxLogoHeight: 48
                        )

                        if let credits = gameDeveloperCredits(detail) {
                            companyCreditBylineView(credits)
                        } else if let credits = MediaCreditPresentation.make(for: detail) {
                            creditBylineView(credits)
                        } else if let byline = byline(detail) {
                            bylineView(byline, detail: detail, lineLimit: 1)
                        }

                        genreChips(detail, wrapsAfterThird: false)
                        RatingChipRow(chips: ratingChips(detail), stacked: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ActionRail(
                        isTracked: currentStatus(detail) != nil,
                        isLiked: detail.userState?.hasLiked ?? false,
                        isHorizontal: false,
                        trackLabel: usesBookGameActions(detail) ? "Track" : nil,
                        eyeLabel: usesBookGameActions(detail) ? bookGameCopy(for: detail.ref.mediaType).finished : nil,
                        isEyeLoading: usesBookGameActions(detail) && viewModel.isSavingQuickAction,
                        isLikeLoading: viewModel.isSavingLike,
                        onTrack: { trackAction(for: detail) },
                        onLike: { likeAction(for: detail) },
                        onEye: { eyeAction(for: detail) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func heroPoster(_ detail: MediaDetail) -> some View {
        let poster = PosterViewerItem(detail: detail)
        let artwork = MediaArtwork(
            url: detail.displayPosterURL,
            title: detail.title,
            slot: .hero,
            mediaType: detail.ref.mediaType,
            orientation: detail.posterOrientation
        )
        .shadow(color: .black.opacity(0.48), radius: 22, y: 12)
        .onLongPressGesture {
            openPosterPicker(for: detail)
        }

        if presentedPosterID == detail.ref.id {
            Color.clear
                .frame(width: PosterSlot.hero.size.width, height: PosterSlot.hero.size.height)
        } else if let poster {
            artwork
                .matchedGeometryEffect(
                    id: detail.ref.id,
                    in: posterTransitionNamespace,
                    isSource: true
                )
                .onTapGesture {
                    onOpenPoster(poster)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("View poster for \(detail.displayTitle)")
                .accessibilityHint("Opens the poster full screen")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    onOpenPoster(poster)
                }
                .accessibilityIdentifier("media-detail.poster")
        } else {
            artwork
        }
    }

    private func bylineView(_ byline: String, detail: MediaDetail, lineLimit: Int) -> some View {
        let alignment: Alignment = isShowingTitleLogo(detail) ? .center : .leading
        let textAlignment: TextAlignment = isShowingTitleLogo(detail) ? .center : .leading

        return Group {
            if let personRef = bylinePersonRef(detail) {
                Button {
                    presentedPerson = personRef
                } label: {
                    bylineText(byline, lineLimit: lineLimit, alignment: textAlignment)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View \(byline)")
            } else {
                bylineText(byline, lineLimit: lineLimit, alignment: textAlignment)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func bylineText(_ byline: String, lineLimit: Int, alignment: TextAlignment) -> some View {
        Text(byline)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(lineLimit)
            .multilineTextAlignment(alignment)
    }

    private func creditBylineView(_ credits: MediaCreditPresentation) -> some View {
        let alignment: Alignment = showsTitleLogo ? .center : .leading
        let textAlignment: TextAlignment = showsTitleLogo ? .center : .leading

        return VStack(alignment: textAlignment == .center ? .center : .leading, spacing: 2) {
            ForEach(credits.heroPeople, id: \.self) { person in
                personCreditText(person, alignment: textAlignment)
            }
            if credits.heroMoreCount > 0 {
                Text("+\(credits.heroMoreCount) more")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.44))
            }
        }
        .multilineTextAlignment(textAlignment)
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    @ViewBuilder
    private func personCreditText(_ person: MediaPersonCredit, alignment: TextAlignment) -> some View {
        if let personRef = person.personRef {
            Button {
                presentedPerson = personRef
            } label: {
                bylineText(person.name, lineLimit: 1, alignment: alignment)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(person.name)")
        } else {
            bylineText(person.name, lineLimit: 1, alignment: alignment)
        }
    }

    private func companyCreditBylineView(_ credits: [MediaCompanyCredit]) -> some View {
        let alignment: Alignment = showsTitleLogo ? .center : .leading
        let textAlignment: TextAlignment = showsTitleLogo ? .center : .leading
        let visibleCredits = Array(credits.prefix(2))
        let moreCount = max(0, credits.count - visibleCredits.count)

        return VStack(alignment: textAlignment == .center ? .center : .leading, spacing: 2) {
            ForEach(visibleCredits) { credit in
                Button {
                    presentedCompany = credit.ref
                } label: {
                    bylineText(credit.name, lineLimit: 1, alignment: textAlignment)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View \(credit.name)")
            }
            if moreCount > 0 {
                Text("+\(moreCount) more")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.44))
            }
        }
        .multilineTextAlignment(textAlignment)
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func backdropURLString(for detail: MediaDetail) -> String? {
        return detail.displayBackdropURL
    }

    private func heroHeight(for detail: MediaDetail) -> CGFloat {
        if backdropURLString(for: detail) != nil {
            return MediaDetailLayout.heroHeight + MediaDetailLayout.backdropTopSpacing
        }
        return MediaDetailLayout.legacyHeroHeight
    }

    private func heroPosterTopOffset(for detail: MediaDetail) -> CGFloat {
        MediaDetailLayout.heroPosterTopOffset + (backdropURLString(for: detail) == nil ? 0 : MediaDetailLayout.backdropTopSpacing)
    }

    private func content(_ detail: MediaDetail) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            SynopsisText(text: synopsisPreview(detail))
            trackingSummarySection(detail)
            if detail.ref.mediaType != "episode" || (detail.community?.ratingCount ?? 0) > 0 {
                SpineRatingDistributionSection(community: detail.community)
            }

            if detail.ref.mediaType == "tv" {
                seasonsSection(detail)
                CreditSection(title: creditTitle(detail), cast: castCredits(detail), crew: crewCredits(detail)) { person in
                    presentedPerson = person
                }
            } else {
                CreditSection(title: creditTitle(detail), cast: castCredits(detail), crew: crewCredits(detail)) { person in
                    presentedPerson = person
                }
                if detail.ref.mediaType != "episode" {
                    seasonsSection(detail)
                }
            }

            MediaFactsSection(
                rows: detailRows(detail),
                onPersonSelected: { person in
                    presentedPerson = person
                },
                onCompanySelected: { company in
                    presentedCompany = company
                }
            )
            if detail.ref.mediaType == "season" {
                EpisodesSection(episodes: detail.episodes ?? []) { episode in
                    presentEpisode(episode, from: detail)
                }
            }
            ReviewsSection(reviews: viewModel.reviews, isLoading: viewModel.isLoadingReviews, error: viewModel.reviewsErrorMessage)
            RecommendationsSection(sections: relatedSections(detail)) { item in
                presentedRef = item.ref
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func presentEpisode(_ episode: EpisodeSummary, from season: MediaDetail) {
        guard let seasonNumber = season.ref.seasonNumber else { return }
        let refs = (season.episodes ?? []).map {
            MediaRef(
                itemId: nil,
                source: season.ref.source,
                mediaType: "episode",
                mediaId: season.ref.mediaId,
                seasonNumber: seasonNumber,
                episodeNumber: $0.episodeNumber
            )
        }
        let selected = MediaRef(
            itemId: nil,
            source: season.ref.source,
            mediaType: "episode",
            mediaId: season.ref.mediaId,
            seasonNumber: seasonNumber,
            episodeNumber: episode.episodeNumber
        )
        presentedMediaSelection = MediaBrowsingSelection(ref: selected, within: refs)
    }

    @ViewBuilder
    private func trackingSummarySection(_ detail: MediaDetail) -> some View {
        TrackingSummarySection(
            detail: detail,
            tracking: viewModel.tracking,
            userState: detail.userState,
            onOpenDiaryEntry: {
                Task {
                    await openTrackingDiary(for: detail)
                }
            },
            onUpdateProgress: {
                openProgressUpdate(for: detail)
            }
        )
    }

    private func openTrackingDiary(for detail: MediaDetail) async {
        if isMultipleLogMedia(detail), detail.ref.itemId != nil {
            presentedMediaDiary = PresentedMediaDiary(detail: detail)
            return
        }

        if let entryId = detail.userState?.diaryEntryId {
            presentedDiaryEntry = PresentedDiaryEntry(id: entryId)
            return
        }

        do {
            if let entry = try await diaryRepository.list().first(where: { matches($0.media.ref, detail.ref) }) {
                presentedDiaryEntry = PresentedDiaryEntry(id: entry.id)
            }
        } catch {
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }

    private func matches(_ lhs: MediaRef, _ rhs: MediaRef) -> Bool {
        lhs.source == rhs.source
            && lhs.mediaType == rhs.mediaType
            && lhs.mediaId == rhs.mediaId
            && lhs.seasonNumber == rhs.seasonNumber
            && lhs.episodeNumber == rhs.episodeNumber
    }

    private func isMultipleLogMedia(_ detail: MediaDetail) -> Bool {
        (detail.userState?.diaryCount ?? 0) > 1
    }

    private func seasonsSection(_ detail: MediaDetail) -> some View {
        SeasonsSection(seasons: detail.seasons ?? []) { season in
            presentedRef = MediaRef(
                itemId: nil,
                source: detail.ref.source,
                mediaType: "season",
                mediaId: detail.ref.mediaId,
                seasonNumber: season.seasonNumber,
                episodeNumber: nil
            )
        }
    }

    private func genreChips(_ detail: MediaDetail, wrapsAfterThird: Bool) -> some View {
        let chips = primaryChips(detail)

        if !wrapsAfterThird {
            return AnyView(
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(chips.prefix(6))) { chip in
                            genreChip(chip)
                        }
                    }
                }
                .mask(alignment: .trailing) {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.88),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            )
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(chips.prefix(3))) { chip in
                            genreChip(chip)
                        }
                    }
                }
                .mask(alignment: .trailing) {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.88),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

                if chips.count > 3 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(chips.dropFirst(3))) { chip in
                                genreChip(chip)
                            }
                        }
                    }
                    .mask(alignment: .trailing) {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.88),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                }
            }
        )
    }

    private func genreChip(_ chip: MediaDetailChip) -> some View {
        Group {
            if let request = chip.discoverRequest {
                Button {
                    presentedDiscover = request
                } label: {
                    chipLabel(chip.label)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Browse \(chip.label)")
            } else {
                chipLabel(chip.label)
            }
        }
    }

    private func chipLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.82))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: MediaDetailLayout.genrePillHeight)
            .background(.white.opacity(0.12), in: Capsule())
    }

    private func primaryChips(_ detail: MediaDetail) -> [MediaDetailChip] {
        var chips = [MediaDetailChip(label: mediaTypeChipLabel(detail.ref.mediaType), discoverRequest: nil)]
        if let year = year(detail) {
            chips.append(MediaDetailChip(label: year, discoverRequest: discoverRequest(detail, filter: .year(String(year.prefix(4))))))
        }
        if let seasonLabel = seasonChipLabel(detail) {
            chips.append(MediaDetailChip(label: seasonLabel, discoverRequest: nil))
        }
        if ["movie", "tv"].contains(detail.ref.mediaType), let runtime = detailString(detail, "runtime"), !runtime.isEmpty {
            chips.append(MediaDetailChip(label: runtime, discoverRequest: nil))
        }
        if let contentRating = contentRating(detail) {
            chips.append(MediaDetailChip(label: contentRating, discoverRequest: nil))
        }
        if ["tv", "anime"].contains(detail.ref.mediaType), let episodes = detailString(detail, "episodes") {
            chips.append(MediaDetailChip(label: "\(episodes) episodes", discoverRequest: nil))
        }
        if detail.ref.mediaType == "book", let pages = detailString(detail, "number_of_pages") ?? detailString(detail, "pages") {
            chips.append(MediaDetailChip(label: "\(pages) pages", discoverRequest: nil))
        }
        if detail.ref.mediaType == "anime", let format = detailString(detail, "format") {
            chips.append(MediaDetailChip(label: format, discoverRequest: nil))
        }
        if detail.ref.mediaType == "game", let platform = detailArray(detail, "platforms").first {
            chips.append(MediaDetailChip(label: platform, discoverRequest: discoverRequest(detail, filter: .platform(platform))))
        }
        for genre in detailArray(detail, "genres") {
            chips.append(MediaDetailChip(label: genre, discoverRequest: discoverRequest(detail, filter: .genre(genre))))
        }

        var seen = Set<String>()
        let uniqueChips = chips.filter { chip in
            seen.insert(chip.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted
        }
        return uniqueChips
    }

    private func discoverRequest(_ detail: MediaDetail, filter: MediaDiscoverRequest.Filter) -> MediaDiscoverRequest? {
        MediaDiscoverRequest.detailPillRequest(ref: detail.ref, filter: filter)
    }

    private func contentRating(_ detail: MediaDetail) -> String? {
        if detail.ref.mediaType == "game" {
            return detailString(detail, "age_rating") ?? detailArray(detail, "age_ratings").first
        }
        guard ["movie", "tv"].contains(detail.ref.mediaType) else { return nil }
        guard let rating = detailString(detail, "rating"), !rating.isEmpty else { return nil }
        return rating
    }

    private func mediaTypeChipLabel(_ mediaType: String) -> String {
        switch mediaType {
        case "tv":
            "TV"
        case "season":
            "TV"
        default:
            mediaType.capitalized
        }
    }

    private func seasonChipLabel(_ detail: MediaDetail) -> String? {
        guard let seasonNumber = detail.ref.seasonNumber, detail.ref.mediaType == "season" else { return nil }
        return "Season \(seasonNumber)"
    }

    private func currentStatus(_ detail: MediaDetail) -> String? {
        viewModel.tracking?.status ?? detail.userState?.status
    }

    private func currentRating(_ detail: MediaDetail) -> String? {
        viewModel.tracking?.rating ?? detail.userState?.rating
    }

    private func currentProgress(_ detail: MediaDetail) -> ProgressState? {
        viewModel.tracking?.progress ?? detail.userState?.progress
    }

    private func ratingChips(_ detail: MediaDetail) -> [RatingChip] {
        var chips: [RatingChip] = []
        if let rating = detail.community?.averageRating, !rating.isEmpty {
            chips.append(RatingChip(
                source: "SP",
                value: "\(rating.starRatingValue)/5",
                assetName: nil,
                providerName: "Spine",
                voteCount: detail.community?.ratingCount,
                voteCountLabel: "ratings"
            ))
        }
        for rating in sortedExternalRatings(detail.externalRatings ?? []) where !rating.value.isEmpty {
            if !MediaExternalRatingPresentation.includes(
                source: rating.source,
                mediaType: detail.ref.mediaType
            ) {
                continue
            }
            chips.append(RatingChip(
                source: rating.source.ratingAbbreviation,
                value: rating.displayValue,
                assetName: rating.ratingAssetName,
                providerName: rating.source,
                destination: rating.destinationURL,
                voteCount: rating.voteCount,
                voteCountLabel: rating.source.ratingCountLabel
            ))
        }
        if let rating = currentRating(detail), !rating.isEmpty {
            chips.append(RatingChip(source: "You", value: rating.starRatingLabel, assetName: nil))
        }
        return chips
    }

    private func sortedExternalRatings(_ ratings: [ExternalRating]) -> [ExternalRating] {
        ratings.enumerated().sorted { lhs, rhs in
            let lhsOrder = externalRatingOrder(lhs.element.source)
            let rhsOrder = externalRatingOrder(rhs.element.source)
            return lhsOrder == rhsOrder ? lhs.offset < rhs.offset : lhsOrder < rhsOrder
        }.map {
            $0.element
        }
    }

    private func externalRatingOrder(_ source: String) -> Int {
        switch source.lowercased() {
        case "letterboxd": 0
        case "rotten tomatoes": 1
        case "imdb": 2
        case "metacritic": 3
        case "igdb": 4
        default: 5
        }
    }

    private func byline(_ detail: MediaDetail) -> String? {
        if let author = authors(detail).first {
            return author
        }
        for key in ["director", "creator", "developer", "publisher"] {
            if let value = detailString(detail, key) {
                return value
            }
        }
        if let person = detailArray(detail, "people").first {
            return person
        }
        return detail.subtitle
    }

    private func bylinePersonRef(_ detail: MediaDetail) -> PersonRef? {
        if detail.ref.mediaType == "book" {
            return bookAuthorCredits(detail).first?.personRef
        }
        guard detail.ref.source == "tmdb" else { return nil }
        let key = detail.ref.mediaType == "movie" ? "director_id" : detail.ref.mediaType == "tv" ? "creator_id" : nil
        guard let key,
              detailString(detail, key.replacingOccurrences(of: "_id", with: "")) != nil,
              let id = detailString(detail, key),
              !id.isEmpty
        else { return nil }
        return PersonRef(source: "tmdb", id: id)
    }

    private func synopsisPreview(_ detail: MediaDetail) -> String {
        detail.displaySynopsis ?? "No synopsis available yet."
    }

    private func detailRows(_ detail: MediaDetail) -> [DetailFactRow] {
        let mediaType = detail.ref.mediaType
        var rows: [DetailFactRow] = [
            DetailFactRow(label: "Status", value: detailString(detail, "status")),
            DetailFactRow(label: "Format", value: detailString(detail, "format")),
        ]

        switch mediaType {
        case "movie":
            rows += [
                DetailFactRow(label: "Release Date", value: formattedReleaseDate(detail)),
                DetailFactRow(label: "Runtime", value: detailString(detail, "runtime")),
                DetailFactRow(label: "Certification", value: detailString(detail, "rating")),
                creditDetailRow(MediaCreditPresentation.make(for: detail)),
                DetailFactRow(label: "Box Office", value: moneyString(detail, "revenue")),
            ]
        case "tv", "season":
            rows += [
                DetailFactRow(label: "First Aired", value: formattedDate(detailString(detail, "first_air_date") ?? detail.releaseDate)),
                DetailFactRow(label: "Last Aired", value: formattedDate(detailString(detail, "last_air_date"))),
                DetailFactRow(label: "Runtime", value: detailString(detail, "runtime")),
                DetailFactRow(label: "Certification", value: detailString(detail, "rating")),
                DetailFactRow(label: "Seasons", value: detailString(detail, "seasons")),
                DetailFactRow(label: "Episodes", value: detailString(detail, "episodes")),
                creditDetailRow(MediaCreditPresentation.make(for: detail)),
            ]
        case "episode":
            rows += [
                DetailFactRow(label: "Aired", value: formattedDate(detailString(detail, "air_date") ?? detail.releaseDate)),
                DetailFactRow(label: "Runtime", value: detailString(detail, "runtime")),
                DetailFactRow(label: "Season", value: detailString(detail, "season_title") ?? detail.ref.seasonNumber.map { "Season \($0)" }),
                DetailFactRow(label: "Episode", value: detail.ref.episodeNumber.map(String.init)),
                DetailFactRow(label: "Production Code", value: detailString(detail, "production_code")),
            ]
        case "anime":
            rows += [
                DetailFactRow(label: "Episodes", value: detailString(detail, "episodes")),
                DetailFactRow(label: "Aired", value: detailString(detail, "season")),
                DetailFactRow(label: "Broadcast", value: detailString(detail, "broadcast")),
                DetailFactRow(label: "Source", value: detailString(detail, "source")),
            ]
        case "manga":
            rows += [
                DetailFactRow(label: "Chapters", value: detailString(detail, "number_of_chapters")),
                DetailFactRow(label: "Latest Chapter", value: detailString(detail, "latest_chapter_translated")),
                DetailFactRow(label: "Year", value: detailString(detail, "year")),
            ]
        case "game":
            rows += [
                DetailFactRow(label: "Release Date", value: formattedReleaseDate(detail)),
                DetailFactRow(label: "Age Rating", value: detailString(detail, "age_rating") ?? detailArray(detail, "age_ratings").joinedOrNil),
                DetailFactRow(label: "Collection", value: detailString(detail, "collection")),
                DetailFactRow(label: "Franchise", value: detailString(detail, "franchise") ?? detailArray(detail, "franchises").joinedOrNil),
                companyDetailRow(label: "Developer", detail: detail, role: .developed),
                companyDetailRow(label: "Publisher", detail: detail, role: .published),
                DetailFactRow(label: "Themes", value: detailArray(detail, "themes").joinedOrNil),
                DetailFactRow(label: "Time to Beat", value: timeToBeatString(detail)),
            ]
        case "comic":
            rows += [
                DetailFactRow(label: "Publisher", value: detailString(detail, "publisher")),
                DetailFactRow(label: "Issues", value: detailString(detail, "issues_count")),
                DetailFactRow(label: "Last Issue", value: lastIssueString(detail)),
            ]
        case "book":
            rows += [
                DetailFactRow(label: "Pages", value: detailString(detail, "number_of_pages") ?? detailString(detail, "pages")),
                DetailFactRow(label: "Publish Date", value: formattedDate(detailString(detail, "publish_date") ?? detailString(detail, "published_date") ?? detailString(detail, "release_date"))),
                DetailFactRow(label: "Physical Format", value: detailString(detail, "physical_format")),
            ]
        default:
            rows.append(DetailFactRow(label: "Release Date", value: formattedReleaseDate(detail)))
        }

        for (label, key) in [
            ("Authors", "authors"),
            ("Genres", "genres"),
            ("Studios", "studios"),
            ("Country", "country"),
            ("Languages", "languages"),
            ("Platforms", "platforms"),
            ("Companies", "companies"),
            ("Publishers", "publishers"),
            ("ISBN", "isbn"),
        ] {
            if mediaType == "book", key == "authors" {
                continue
            }
            let values = detailArray(detail, key)
            if !values.isEmpty {
                rows.append(DetailFactRow(label: label, value: values.joined(separator: ", ")))
            }
        }
        return rows.filter { !$0.isEmpty }
    }

    private func creditDetailRow(_ credits: MediaCreditPresentation?) -> DetailFactRow {
        DetailFactRow(label: credits?.label ?? "", people: credits?.people ?? [])
    }

    @MainActor
    private func gameDeveloperCredits(_ detail: MediaDetail) -> [MediaCompanyCredit]? {
        let credits = companyCredits(detail, role: .developed)
        return credits.isEmpty ? nil : credits
    }

    @MainActor
    private func companyDetailRow(label: String, detail: MediaDetail, role: CompanyCatalogRole) -> DetailFactRow {
        let credits = companyCredits(detail, role: role)
        if !credits.isEmpty {
            return DetailFactRow(label: label, companies: credits)
        }
        let legacyKey = role == .developed ? "developer" : "publisher"
        return DetailFactRow(label: label, value: detailString(detail, legacyKey))
    }

    @MainActor
    private func companyCredits(_ detail: MediaDetail, role: CompanyCatalogRole? = nil) -> [MediaCompanyCredit] {
        let credits = (detail.details?["company_credits"]?.arrayValue ?? []).compactMap(MediaCompanyCredit.init(json:))
        guard let role else { return credits }
        return credits.filter { $0.hasRole(role) }
    }

    private func creditTitle(_ detail: MediaDetail) -> String {
        switch detail.ref.mediaType {
        case "book":
            "Authors"
        case "comic":
            "People"
        default:
            "Cast & Crew"
        }
    }

    private func castCredits(_ detail: MediaDetail) -> [CreditDisplay] {
        if detail.ref.mediaType == "book" {
            return bookAuthorCredits(detail)
        }
        let supportsPeoplePages = detail.ref.source == "tmdb" && ["movie", "tv", "episode"].contains(detail.ref.mediaType)
        let credits = (detail.cast ?? []).map {
            CreditDisplay(
                name: $0.name,
                subtitle: $0.character,
                imageUrl: $0.imageUrl,
                personRef: supportsPeoplePages && !$0.id.isEmpty ? PersonRef(source: "tmdb", id: $0.id) : nil
            )
        }
        if credits.isEmpty, detail.ref.mediaType == "comic" {
            return detailArray(detail, "people").map { CreditDisplay(name: $0, subtitle: nil, imageUrl: nil, personRef: nil) }
        }
        return credits
    }

    private func crewCredits(_ detail: MediaDetail) -> [CreditDisplay] {
        let supportsPeoplePages = detail.ref.source == "tmdb" && ["movie", "tv", "episode"].contains(detail.ref.mediaType)
        return (detail.crew ?? []).map {
            CreditDisplay(
                name: $0.name,
                subtitle: $0.role,
                imageUrl: $0.imageUrl,
                personRef: supportsPeoplePages && !$0.id.isEmpty ? PersonRef(source: "tmdb", id: $0.id) : nil
            )
        }
    }

    private func year(_ detail: MediaDetail) -> String? {
        if detail.ref.mediaType == "tv" {
            let start = detailString(detail, "first_air_date") ?? detail.releaseDate
            let end = detailString(detail, "last_air_date")
            guard let startYear = start?.yearPrefix else { return nil }
            let status = detailString(detail, "status")?.lowercased()
            if let status, ["ended", "canceled", "cancelled"].contains(status), let endYear = end?.yearPrefix, endYear != startYear {
                return "\(startYear)-\(endYear)"
            }
            return startYear
        }
        let value = detail.releaseDate ?? detailString(detail, "release_date") ?? detailString(detail, "first_air_date") ?? detailString(detail, "start_date") ?? detailString(detail, "publish_date")
        guard let value, value.count >= 4 else { return nil }
        return String(value.prefix(4))
    }

    private func authors(_ detail: MediaDetail) -> [String] {
        detailArray(detail, "authors")
    }

    private func bookAuthorCredits(_ detail: MediaDetail) -> [CreditDisplay] {
        guard detail.ref.mediaType == "book" else { return [] }
        let rawAuthors = detail.details?["authors"]?.arrayValue ?? []
        let credits = rawAuthors.compactMap { value -> CreditDisplay? in
            if let object = value.objectValue {
                guard let name = object["name"]?.displayString, !name.isEmpty else { return nil }
                let source = object["source"]?.displayString ?? bookAuthorSourceFallback(detail)
                let personId = object["person_id"]?.displayString ?? object["id"]?.displayString
                let ref = bookAuthorRef(source: source, personId: personId ?? name)
                return CreditDisplay(name: name, subtitle: "Author", imageUrl: bookAuthorImageURL(object), personRef: ref)
            }
            guard let name = value.displayString, !name.isEmpty else { return nil }
            return CreditDisplay(
                name: name,
                subtitle: "Author",
                imageUrl: nil,
                personRef: bookAuthorRef(source: bookAuthorSourceFallback(detail), personId: name)
            )
        }
        return credits.isEmpty ? authors(detail).map {
            CreditDisplay(
                name: $0,
                subtitle: "Author",
                imageUrl: nil,
                personRef: bookAuthorRef(source: bookAuthorSourceFallback(detail), personId: $0)
            )
        } : credits
    }

    private func bookAuthorSourceFallback(_ detail: MediaDetail) -> String? {
        ["hardcover", "openlibrary"].contains(detail.ref.source) ? detail.ref.source : nil
    }

    private func bookAuthorRef(source: String?, personId: String?) -> PersonRef? {
        guard let source, let personId, !source.isEmpty, !personId.isEmpty else { return nil }
        return PersonRef(source: source, id: personId)
    }

    private func bookAuthorImageURL(_ object: [String: JSONValue]) -> String? {
        object["image_url"]?.displayString
            ?? object["image"]?.displayString
            ?? object["profile_url"]?.displayString
            ?? object["cached_image"]?.displayString
    }

    private func releaseDate(_ detail: MediaDetail) -> String? {
        detail.releaseDate
            ?? detailString(detail, "release_date")
            ?? detailString(detail, "first_air_date")
            ?? detailString(detail, "start_date")
            ?? detailString(detail, "publish_date")
            ?? detailString(detail, "published_date")
    }

    private func formattedReleaseDate(_ detail: MediaDetail) -> String? {
        formattedDate(releaseDate(detail))
    }

    private func formattedDate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return Self.longDateFormatter.string(from: raw) ?? raw
    }

    private func moneyString(_ detail: MediaDetail, _ key: String) -> String? {
        guard let value = detail.details?[key]?.numberValue, value > 0 else { return detailString(detail, key) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value))
    }

    private func timeToBeatString(_ detail: MediaDetail) -> String? {
        guard let object = detail.details?["time_to_beat"]?.objectValue else { return detailString(detail, "time_to_beat") }
        let keys = [
            ("normally", "Main"),
            ("hastily", "Rush"),
            ("completely", "Complete"),
        ]
        let parts = keys.compactMap { key, label -> String? in
            guard let value = object[key]?.numberValue, value > 0 else { return nil }
            return "\(label) \(Int(value / 3600))h"
        }
        return parts.joinedOrNil
    }

    private func lastIssueString(_ detail: MediaDetail) -> String? {
        let name = detailString(detail, "last_issue_name")
        let number = detailString(detail, "last_issue_number")
        return [name, number.map { "#\($0)" }].compactMap { $0 }.joined(separator: " ").nilIfEmpty
    }

    private static let longDateFormatter: LongDateFormatter = LongDateFormatter()

    private func detailString(_ detail: MediaDetail, _ key: String) -> String? {
        detail.details?[key]?.displayString
    }

    private func detailArray(_ detail: MediaDetail, _ key: String) -> [String] {
        detail.details?[key]?.displayStrings ?? []
    }

    private func relatedSections(_ detail: MediaDetail) -> [RelatedMediaSection] {
        let sections: [RelatedMediaSection]
        if let relatedSections = detail.relatedSections, !relatedSections.isEmpty {
            sections = relatedSections
        } else if let related = detail.related {
            sections = related.compactMap { key, value in
                guard key != "seasons", let values = value.arrayValue else { return nil }
                let items = values.compactMap { rawRelatedSummary($0, parent: detail) }
                guard !items.isEmpty else { return nil }
                let isCollection = detail.ref.mediaType == "movie" && key != "recommendations"
                let id = isCollection ? "collection" : key
                let title = isCollection ? "Collection" : key.replacingOccurrences(of: "_", with: " ").capitalized
                return RelatedMediaSection(id: id, title: title, items: items)
            }
        } else {
            return []
        }
        let normalized: [RelatedMediaSection] = sections.compactMap { section -> RelatedMediaSection? in
            if section.id == "all_related" {
                return nil
            }
            return section
        }
        return normalized.sorted { lhs, rhs in
            if lhs.id == "collection", rhs.id != "collection" { return true }
            if rhs.id == "collection", lhs.id != "collection" { return false }
            return false
        }
    }

    private func rawRelatedSummary(_ value: JSONValue, parent: MediaDetail) -> MediaSummary? {
        guard let object = value.objectValue else { return nil }
        let source = object["source"]?.displayString ?? parent.ref.source
        let mediaType = object["media_type"]?.displayString ?? parent.ref.mediaType
        guard let mediaId = object["media_id"]?.displayString ?? object["id"]?.displayString,
              let title = object["title"]?.displayString ?? object["name"]?.displayString else { return nil }
        return MediaSummary(
            ref: MediaRef(
                itemId: nil,
                source: source,
                mediaType: mediaType,
                mediaId: mediaId,
                seasonNumber: object["season_number"]?.intValue,
                episodeNumber: object["episode_number"]?.intValue
            ),
            title: title,
            subtitle: object["year"]?.displayString,
            overview: object["overview"]?.displayString,
            imageUrl: object["image_url"]?.displayString ?? object["image"]?.displayString,
            posterUrl: object["poster_url"]?.displayString,
            customPosterUrl: object["custom_poster_url"]?.displayString,
            posterOrientation: PosterOrientation(rawValue: object["poster_orientation"]?.displayString ?? "") ?? .unknown,
            posterAccentColor: object["poster_accent_color"]?.displayString,
            releaseDate: object["release_date"]?.displayString ?? object["first_air_date"]?.displayString,
            defaultSource: source,
            userState: nil
        )
    }
}

@discardableResult
private func dismissPresentedViewControllerStack() -> Bool {
    guard
        let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController,
        root.presentedViewController != nil
    else {
        return false
    }

    root.dismiss(animated: true)
    return true
}

private enum MediaDetailLayout {
    static let heroPosterWidth: CGFloat = 191
    static let heroHeight: CGFloat = 455
    static let legacyHeroHeight: CGFloat = 535
    static let episodeHeroHeight: CGFloat = 520
    static let episodeAccessibilityArtworkHeight: CGFloat = 280
    static let heroPosterTopOffset: CGFloat = 108
    static let backdropTopSpacing: CGFloat = 137.5
    static let backdropHeight: CGFloat = 352.34375
    static let genrePillHeight: CGFloat = 31
    static let ratingBadgeSize: CGFloat = 24
    static let ratingPillVerticalPadding: CGFloat = 6
    static var ratingPillHeight: CGFloat { ratingBadgeSize + ratingPillVerticalPadding * 2 }
    static let recommendationPosterSize = CGSize(width: 100, height: 150)
    static let recommendationCardHeight: CGFloat = 190
    static let seasonPosterSize = CGSize(width: 90, height: 135)
}

enum SpinePalette {
    static let pageBackground = Color(red: 0.07, green: 0.07, blue: 0.065)
}

struct SpinePageBackground: View {
    var body: some View {
        SpinePalette.pageBackground
            .ignoresSafeArea()
    }
}

private struct CircleIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.34), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private func bookGameCopy(for mediaType: String) -> (currently: String, finished: String, stopped: String) {
    switch mediaType {
    case "book":
        return ("Currently Reading", "Finished Reading", "Stopped Reading")
    case "music":
        return ("Listen", "Listened", "Dropped")
    default:
        return ("Currently Playing", "Finished Playing", "Stopped Playing")
    }
}

private struct PosterMenuSheet: View {
    let posterLabel: String
    let showsSeasonOption: Bool
    let showsTVShowOption: Bool
    let showsPosterOption: Bool
    let showsBackdropOption: Bool
    let showsLogoOption: Bool
    let onViewSeason: () -> Void
    let onViewTVShow: () -> Void
    let onAddToList: () -> Void
    let onCustomizePoster: () -> Void
    let onCustomizeBackdrop: () -> Void
    let onCustomizeLogo: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if showsSeasonOption {
                Button(action: onViewSeason) {
                    Label("View Season", systemImage: "rectangle.stack")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .frame(height: 54)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }

            if showsTVShowOption {
                Button(action: onViewTVShow) {
                    Label("View TV Show", systemImage: "tv")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .frame(height: 54)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }

            Button(action: onAddToList) {
                Label("Add to List", systemImage: "list.bullet.rectangle")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .frame(height: 54)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)

            if showsPosterOption {
                Button(action: onCustomizePoster) {
                    Label(posterLabel, systemImage: "photo.on.rectangle.angled")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .frame(height: 54)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }

            if showsBackdropOption {
                Button(action: onCustomizeBackdrop) {
                    Label("Customize Backdrop", systemImage: "photo.on.rectangle")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .frame(height: 54)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }

            if showsLogoOption {
                Button(action: onCustomizeLogo) {
                    Label("Customize Logo", systemImage: "textformat")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .frame(height: 54)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
        }
        .presentationBackground(.regularMaterial)
    }
}

private struct BookGameActionSheet: View {
    let mediaType: String
    let status: String?
    let isSaving: Bool
    let errorMessage: String?
    let onAction: (MediaDetailQuickAction) async -> Void
    let onUpdateProgress: () -> Void
    let onLog: () -> Void

    private var isInProgress: Bool {
        status == "In progress"
    }

    var body: some View {
        let copy = bookGameCopy(for: mediaType)

        VStack(spacing: 16) {
            HStack(spacing: 12) {
                if mediaType == "music" && isInProgress {
                    actionButton(title: "Pause", systemName: "pause.fill", action: .paused)
                } else if isInProgress {
                    progressButton
                } else {
                    actionButton(
                        title: mediaType == "music" && (status == "Paused" || status == "Dropped") ? "Resume" : copy.currently,
                        systemName: "play.fill",
                        action: .currently
                    )
                }
                actionButton(title: copy.finished, systemName: "checkmark", action: .finished)
                actionButton(title: copy.stopped, systemName: "xmark", action: .stopped)
                logButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 36)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
        }
        .presentationBackground(.regularMaterial)
    }

    private func actionButton(title: String, systemName: String, action: MediaDetailQuickAction) -> some View {
        Button {
            Task {
                await onAction(action)
            }
        } label: {
            actionLabel(title: title, systemName: systemName)
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    private var progressButton: some View {
        Button(action: onUpdateProgress) {
            actionLabel(title: "Update Progress", systemName: "slider.horizontal.3")
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    private var logButton: some View {
        Button(action: onLog) {
            actionLabel(title: "Log", systemName: "square.and.pencil")
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    private func actionLabel(title: String, systemName: String) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.055))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.13), lineWidth: 1.25)
                    }
                Group {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: systemName)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.94))
                    }
                }
                .spineContentTransition(value: isSaving)
            }
            .frame(height: 86)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 6)

            Text(title)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .frame(height: 36, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }
}

@MainActor
@Observable
private final class AddToListViewModel {
    var lists: [CustomListSummary] = []
    var ref: MediaRef
    var isLoading = false
    var loadingListID: Int?
    var errorMessage: String?

    private let listRepository: ListRepository
    private let onUnauthorized: () -> Void

    init(ref: MediaRef, listRepository: ListRepository, onUnauthorized: @escaping () -> Void) {
        self.ref = ref
        self.listRepository = listRepository
        self.onUnauthorized = onUnauthorized
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            lists = try await listRepository.list(membershipFor: ref)
        } catch {
            handle(error)
        }
    }

    func toggle(_ list: CustomListSummary) async {
        guard loadingListID == nil else { return }
        loadingListID = list.id
        errorMessage = nil
        defer { loadingListID = nil }

        do {
            if list.hasItem == true {
                guard let itemId = ref.itemId else {
                    await load()
                    return
                }
                try await listRepository.removeItem(listId: list.id, itemId: itemId)
            } else {
                let item = try await listRepository.addItem(listId: list.id, ref: ref)
                ref = item.ref
            }
            await load()
        } catch {
            handle(error)
        }
    }

    func createAndAdd(name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        loadingListID = -1
        errorMessage = nil
        defer { loadingListID = nil }

        do {
            let list = try await listRepository.create(CustomListWriteRequest(
                name: trimmed,
                description: "",
                visibility: "private",
                isRanked: false
            ))
            let item = try await listRepository.addItem(listId: list.id, ref: ref)
            ref = item.ref
            await load()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    private func handle(_ error: Error) {
        errorMessage = error.localizedDescription
        if case APIError.unauthorized = error {
            onUnauthorized()
        }
    }
}

private struct AddToListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: AddToListViewModel
    @State private var searchText = ""
    @State private var newListName = ""
    @State private var isCreating = false

    init(ref: MediaRef, listRepository: ListRepository, onUnauthorized: @escaping () -> Void) {
        _viewModel = State(initialValue: AddToListViewModel(
            ref: ref,
            listRepository: listRepository,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if viewModel.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    } else if filteredLists.isEmpty {
                        ContentUnavailableView("No Lists", systemImage: "list.bullet.rectangle")
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(filteredLists) { list in
                            Button {
                                Task {
                                    await viewModel.toggle(list)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(list.name)
                                            .font(.system(size: 16, weight: .semibold))
                                        Text("\(list.itemsCount.formatted()) items")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Group {
                                        if viewModel.loadingListID == list.id {
                                            ProgressView()
                                        } else if list.hasItem == true {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    .frame(width: 20, height: 20)
                                    .spineContentTransition(value: listIndicatorPhase(for: list))
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.loadingListID != nil)
                        }
                    }
                }
                .spineContentTransition(value: contentPhase)

                Section {
                    if isCreating {
                        HStack {
                            TextField("New list name", text: $newListName)
                            Button("Create") {
                                Task {
                                    if await viewModel.createAndAdd(name: newListName) {
                                        newListName = ""
                                        isCreating = false
                                    }
                                }
                            }
                            .disabled(newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.loadingListID != nil)
                        }
                    } else {
                        Button {
                            isCreating = true
                        } label: {
                            Label("Create new list...", systemImage: "plus")
                        }
                    }
                }
                .spineContentTransition(value: isCreating)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Add to List")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search lists")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                if viewModel.lists.isEmpty {
                    await viewModel.load()
                }
            }
        }
    }

    private var contentPhase: SpineContentPhase {
        .resolve(
            isLoading: viewModel.isLoading,
            hasContent: !filteredLists.isEmpty,
            hasError: viewModel.errorMessage != nil
        )
    }

    private func listIndicatorPhase(for list: CustomListSummary) -> String {
        if viewModel.loadingListID == list.id { return "loading" }
        return list.hasItem == true ? "selected" : "empty"
    }

    private var filteredLists: [CustomListSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.lists }
        return viewModel.lists.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

private struct EpisodeDetailLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 0)
                .fill(.white.opacity(0.08))
                .frame(height: 330)

            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 74, height: 12)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .frame(width: 210, height: 16)
                HStack(spacing: 10) {
                    Capsule().fill(.white.opacity(0.1)).frame(width: 112, height: 38)
                    Spacer()
                    ForEach(0 ..< 3, id: \.self) { _ in
                        Circle().fill(.white.opacity(0.1)).frame(width: 42, height: 42)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading episode details")
        .frame(maxWidth: .infinity, minHeight: 520, alignment: .top)
    }
}

private struct EpisodeHeroArtwork: View {
    let urlString: String?
    let title: String

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                placeholder

                if let urlString, let url = URL(string: urlString) {
                    SpineAsyncImage(url: url) { phase in
                        if case let .success(image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                        }
                    }
                }

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.5), location: 0),
                        .init(color: .black.opacity(0.12), location: 0.3),
                        .init(color: .clear, location: 0.48),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.25),
                        .init(color: .black.opacity(0.2), location: 0.5),
                        .init(color: SpinePalette.pageBackground.opacity(0.72), location: 0.72),
                        .init(color: SpinePalette.pageBackground, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    colors: [.black.opacity(0.28), .clear, .black.opacity(0.08)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Episode still for \(title)")
    }

    private var placeholder: some View {
        let theme = MediaTypeTheme.theme(for: "episode")
        return LinearGradient(
            colors: theme.gradientColors.map { $0.opacity(0.52) } + [SpinePalette.pageBackground],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct IMDbExternalLinkPill: View {
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 6) {
                Image("RatingIMDb")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                Text("IMDb")
                    .font(.caption.weight(.heavy))
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, MediaDetailLayout.ratingPillVerticalPadding)
            .background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View this episode on IMDb")
    }
}

struct HeroArtwork: View {
    let detail: MediaDetail

    var body: some View {
        ZStack {
            SpinePalette.pageBackground

            GeometryReader { proxy in
                SpineAsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    default:
                        accentColor
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .blur(radius: blurRadius, opaque: true)
                .scaleEffect(scale)
                .brightness(0.02)
                .saturation(usesPosterFallback ? 1.18 : 1.34)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }

            accentColor
                .opacity(0.07)
                .blendMode(.softLight)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.22), location: 0),
                    .init(color: .black.opacity(0.08), location: 0.14),
                    .init(color: .clear, location: 0.38),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.48),
                    .init(color: SpinePalette.pageBackground.opacity(0.12), location: 0.62),
                    .init(color: SpinePalette.pageBackground.opacity(0.45), location: 0.78),
                    .init(color: SpinePalette.pageBackground.opacity(0.82), location: 0.9),
                    .init(color: SpinePalette.pageBackground, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [.clear, .black.opacity(0.1)],
                center: .center,
                startRadius: 60,
                endRadius: 360
            )
            .blendMode(.multiply)
        }
        .clipped()
    }

    private var artworkURL: URL? {
        return URL(string: detail.displayBackdropURL ?? detail.displayPosterURL ?? "")
    }

    private var usesPosterFallback: Bool {
        detail.displayBackdropURL == nil && detail.displayPosterURL != nil
    }

    private var blurRadius: CGFloat {
        usesPosterFallback ? 30 : 22
    }

    private var scale: CGFloat {
        usesPosterFallback ? 1.28 : 1.2
    }

    private var accentColor: Color {
        Color(hex: detail.posterAccentColor) ?? SpinePalette.pageBackground
    }
}

struct BackdropArtwork: View {
    let urlString: String

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                SpineAsyncImage(url: URL(string: urlString)) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    default:
                        Color.clear
                    }
                }

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.42), location: 0),
                        .init(color: .black.opacity(0.18), location: 0.36),
                        .init(color: .clear, location: 0.72),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.52),
                        .init(color: .white.opacity(0.35), location: 0.78),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .clipped()
    }
}

private struct ActionRail: View {
    private static let buttonSize: CGFloat = 42
    private static let buttonSpacing: CGFloat = 9

    let isTracked: Bool
    let isLiked: Bool
    let isHorizontal: Bool
    var trackLabel: String?
    var eyeLabel: String?
    var isEyeSelected = false
    var isEyeDisabled = false
    var isEyeLoading = false
    var isLikeLoading = false
    let onTrack: () -> Void
    let onLike: () -> Void
    var onEye: () -> Void = {}

    var body: some View {
        GlassEffectContainer(spacing: Self.buttonSpacing) {
            if isHorizontal {
                HStack(spacing: Self.buttonSpacing) {
                    railButton(
                        systemName: "plus",
                        label: trackLabel ?? (isTracked ? "Edit tracking" : "Log"),
                        usesLargePlus: true,
                        action: onTrack
                    )
                    railButton(
                        systemName: isLiked ? "heart.fill" : "heart",
                        label: isLiked ? "Unlike" : "Like",
                        usesLargePlus: false,
                        isLoading: isLikeLoading,
                        action: onLike
                    )
                    railButton(
                        systemName: isEyeSelected ? "eye.fill" : "eye",
                        label: eyeLabel ?? "Mark as watched",
                        usesLargePlus: false,
                        isLoading: isEyeLoading,
                        isDisabled: isEyeDisabled,
                        action: onEye
                    )
                }
            } else {
                VStack(spacing: Self.buttonSpacing) {
                    railButton(
                        systemName: isLiked ? "heart.fill" : "heart",
                        label: isLiked ? "Unlike" : "Like",
                        usesLargePlus: false,
                        isLoading: isLikeLoading,
                        action: onLike
                    )
                    railButton(
                        systemName: isEyeSelected ? "eye.fill" : "eye",
                        label: eyeLabel ?? "Mark as watched",
                        usesLargePlus: false,
                        isLoading: isEyeLoading,
                        isDisabled: isEyeDisabled,
                        action: onEye
                    )
                    railButton(
                        systemName: "plus",
                        label: trackLabel ?? (isTracked ? "Edit tracking" : "Log"),
                        usesLargePlus: false,
                        action: onTrack
                    )
                }
            }
        }
    }

    private func railButton(
        systemName: String,
        label: String,
        usesLargePlus: Bool,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Group {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: systemName)
                            .font(.system(size: usesLargePlus ? 22 : 16, weight: .semibold))
                            .foregroundStyle(railIconColor(systemName: systemName))
                    }
                }
                .spineContentTransition(value: isLoading)
            }
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            .background(.white.opacity(0.08), in: Circle())
            .glassEffect(.regular.tint(.white.opacity(0.1)).interactive(), in: Circle())
            .overlay {
                Circle().stroke(.white.opacity(0.16), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(isLoading || isDisabled)
        .opacity(isDisabled ? 0.62 : 1)
        .accessibilityLabel(label)
    }

    private func railIconColor(systemName: String) -> Color {
        if systemName == "heart.fill" { return .pink }
        return .white.opacity(0.84)
    }
}

private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white.opacity(0.48))
            .tracking(0)
    }
}

private struct RatingChip: Hashable {
    let source: String
    let value: String
    let assetName: String?
    let providerName: String
    let destination: URL?
    let voteCount: Int?
    let voteCountLabel: String?

    init(
        source: String,
        value: String,
        assetName: String?,
        providerName: String? = nil,
        destination: URL? = nil,
        voteCount: Int? = nil,
        voteCountLabel: String? = nil
    ) {
        self.source = source
        self.value = value
        self.assetName = assetName
        self.providerName = providerName ?? source
        self.destination = destination
        self.voteCount = voteCount
        self.voteCountLabel = voteCountLabel
    }

    var accessibilityLabel: String {
        var components = ["\(providerName) rating \(value)"]
        if let voteCount, voteCount > 0 {
            components.append("\(voteCount.formatted()) \(voteCountLabel ?? "votes")")
        }
        return components.joined(separator: ", ")
    }
}

private struct RatingChipRow: View {
    let chips: [RatingChip]
    let stacked: Bool

    var body: some View {
        if !chips.isEmpty {
            if stacked {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        ratingChip(chip)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.self) { chip in
                            ratingChip(chip)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func ratingChip(_ chip: RatingChip) -> some View {
        if let destination = chip.destination {
            Link(destination: destination) {
                ratingChipContent(chip)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(chip.accessibilityLabel)
            .accessibilityHint("Opens the \(chip.providerName) media page")
        } else {
            ratingChipContent(chip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(chip.accessibilityLabel)
        }
    }

    private func ratingChipContent(_ chip: RatingChip) -> some View {
        HStack(spacing: 6) {
            RatingSourceBadge(chip: chip)
            VStack(alignment: .leading, spacing: 1) {
                Text(chip.value)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white)
                if let voteCount = chip.voteCount, voteCount > 0 {
                    Text("\(voteCount.formatted(.number.notation(.compactName))) \(chip.voteCountLabel ?? "votes")")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, MediaDetailLayout.ratingPillVerticalPadding)
        .background(.white.opacity(0.12), in: Capsule())
    }
}

private struct RatingSourceBadge: View {
    let chip: RatingChip

    var body: some View {
        Group {
            if let assetName = chip.assetName {
                ratingLogo(assetName: assetName)
            } else {
                Text(chip.source)
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.black)
            }
        }
        .frame(width: MediaDetailLayout.ratingBadgeSize, height: MediaDetailLayout.ratingBadgeSize)
        .background(["RatingMAL", "RatingMetacritic"].contains(chip.assetName) ? .clear : .white, in: Circle())
        .clipShape(Circle())
    }

    @ViewBuilder
    private func ratingLogo(assetName: String) -> some View {
        switch assetName {
        case "RatingIMDb":
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .scaleEffect(1.15)
                .frame(width: 24, height: 24)
                .clipped()
        case "RatingLetterboxd":
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .scaleEffect(1.1)
                .frame(width: 24, height: 24)
                .clipped()
        case "RatingMAL":
            Image(assetName)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .clipped()
        case "RatingMetacritic":
            Image(assetName)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .clipped()
        case "RatingRottenTomatoesCertifiedFresh":
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .scaleEffect(1.045)
                .frame(width: 24, height: 24)
                .clipped()
        case "RatingHardcover":
            Image(assetName)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .offset(y: 3)
                .clipped()
        case "RatingIGDB":
            Image(assetName)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .scaleEffect(1.55)
                .frame(width: 24, height: 24)
                .clipped()
        default:
            Image(assetName)
                .resizable()
                .scaledToFit()
                .padding(3)
        }
    }
}

private struct TrackingSummarySection: View {
    let detail: MediaDetail
    let tracking: TrackingState?
    let userState: UserMediaState?
    let onOpenDiaryEntry: () -> Void
    let onUpdateProgress: () -> Void

    var body: some View {
        if hasState {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(title: "Your Tracking")
                HStack(alignment: .top, spacing: 10) {
                    if detail.ref.mediaType != "episode" {
                        MediaArtwork(
                            url: detail.displayPosterURL,
                            title: detail.title,
                            slot: .libraryRow,
                            mediaType: detail.ref.mediaType,
                            orientation: detail.posterOrientation
                        )
                        .onTapGesture(perform: onOpenDiaryEntry)
                        .accessibilityLabel("View diary log for \(detail.title)")
                        .accessibilityAddTraits(.isButton)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if let status {
                            Text(detail.ref.trackingStatusLabel(status))
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundStyle(.white)
                                .onTapGesture {
                                    if hasMultipleLogs {
                                        onOpenDiaryEntry()
                                    }
                                }
                                .accessibilityAddTraits(hasMultipleLogs ? .isButton : [])
                            if showsUpdateProgressButton {
                                Button(action: onUpdateProgress) {
                                    Text("Update Progress")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.82))
                                        .padding(.horizontal, 11)
                                        .frame(height: 24)
                                        .background(.white.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 3)
                            }
                        }
                        ForEach(lines, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.76))
                                .onTapGesture {
                                    if line == logLine {
                                        onOpenDiaryEntry()
                                    }
                                }
                                .accessibilityAddTraits(line == logLine ? .isButton : [])
                        }
                    }

                    Spacer()
                }
            }
        }
    }

    private var status: String? {
        tracking?.status
            ?? userState?.status
            ?? (detail.ref.isEpisode && userState?.isTracked == true ? "Watched" : nil)
    }
    private var hasState: Bool { status != nil || !lines.isEmpty }
    private var showsUpdateProgressButton: Bool {
        status == "In progress" && ["book", "game"].contains(detail.ref.mediaType)
    }
    private var hasMultipleLogs: Bool {
        (userState?.diaryCount ?? 0) > 1
    }
    private var logLine: String? {
        guard hasMultipleLogs, let diaryCount = userState?.diaryCount else { return nil }
        return "\(diaryCount) logs"
    }

    private var lines: [String] {
        var values: [String] = []
        if status == "In progress",
           detail.ref.mediaType != "movie",
            let progressText = (tracking?.progress ?? userState?.progress)?.detailDisplayText(preferredMode: ProgressDisplayPreferences.mode(for: detail.ref)) {
            values.append(progressText)
        }
        if let logLine {
            values.append(logLine)
        }
        if let rating = userState?.diaryRating ?? tracking?.rating ?? userState?.rating {
            values.append("Rated \(rating.starRatingLabel)")
        }
        if !hasMultipleLogs, let consumedAt = userState?.diaryConsumedAt {
            values.append("Logged \(consumedAt.shortDateLabel)")
        }
        if detail.ref.mediaType != "movie" {
            if let startDate = tracking?.startDate {
                values.append("Started \(startDate.longDateLabel)")
            }
        }
        return values
    }

}

private struct SynopsisText: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) {
                isExpanded.toggle()
            }
        } label: {
            synopsisCopy
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse synopsis" : "Expand synopsis")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .animation(.smooth(duration: 0.3), value: isExpanded)
    }

    private var synopsisCopy: some View {
        Text(text)
            .font(synopsisFont)
            .foregroundStyle(.white.opacity(0.88))
            .lineSpacing(3)
            .lineLimit(isExpanded ? nil : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var synopsisFont: Font {
        .system(size: 15, weight: .medium)
    }
}

private struct DetailFactRow: Identifiable {
    let label: String
    var value: String?
    var people: [MediaPersonCredit]
    var companies: [MediaCompanyCredit]

    var id: String { label }
    var isEmpty: Bool { label.isEmpty || (value?.isEmpty != false && people.isEmpty && companies.isEmpty) }

    init(label: String, value: String?) {
        self.label = label
        self.value = value
        people = []
        companies = []
    }

    init(label: String, people: [MediaPersonCredit]) {
        self.label = label
        value = nil
        self.people = people
        companies = []
    }

    init(label: String, companies: [MediaCompanyCredit]) {
        self.label = label
        value = nil
        people = []
        self.companies = companies
    }
}

private struct MediaFactsSection: View {
    let rows: [DetailFactRow]
    let onPersonSelected: (PersonRef) -> Void
    let onCompanySelected: (CompanyRef) -> Void

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                SectionLabel(title: "Details")

                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        DetailFactRowView(
                            row: row,
                            onPersonSelected: onPersonSelected,
                            onCompanySelected: onCompanySelected
                        )

                        if row.id != rows.last?.id {
                            Divider().overlay(.white.opacity(0.045))
                        }
                    }
                }
                .mediaDetailSurface(cornerRadius: 14)
            }
        }
    }
}

private struct DetailFactRowView: View {
    let row: DetailFactRow
    let onPersonSelected: (PersonRef) -> Void
    let onCompanySelected: (CompanyRef) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(row.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.44))
                .lineLimit(1)
                .frame(width: 98, alignment: .leading)

            if row.people.isEmpty && row.companies.isEmpty {
                Text(row.value ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !row.people.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(row.people, id: \.self) { person in
                        if let personRef = person.personRef {
                            Button {
                                onPersonSelected(personRef)
                            } label: {
                                personName(person.name)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("View \(person.name)")
                        } else {
                            personName(person.name)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(row.companies) { company in
                        Button {
                            onCompanySelected(company.ref)
                        } label: {
                            detailText(company.name)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View \(company.name)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func personName(_ name: String) -> some View {
        detailText(name)
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.84))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func mediaDetailSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return self
            .background(Color.white.opacity(0.028), in: shape)
            .overlay { shape.stroke(.white.opacity(0.045), lineWidth: 1) }
    }
}

private struct SpineRatingDistributionSection: View {
    let community: CommunityStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let average = community?.averageRating {
                    Label(average.starRatingLabel, systemImage: "star.fill")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text("\((community?.ratingCount ?? 0).formatted()) ratings")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.52))
            }

            if buckets.isEmpty {
                Text("No ratings yet.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(buckets, id: \.rating) { bucket in
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.white.opacity(0.82))
                                .frame(width: 18, height: max(4, CGFloat(bucket.count) / CGFloat(maxCount) * 70))
                            Text(bucket.rating)
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 96, alignment: .bottom)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
    }

    private var buckets: [RatingDistributionBucket] {
        let rawBuckets = community?.ratingDistribution ?? []
        guard !rawBuckets.isEmpty else { return [] }
        let counts = Dictionary(grouping: rawBuckets, by: { $0.rating.starRatingStep })
            .mapValues { $0.reduce(0) { $0 + $1.count } }
        return (1...10).map { step in
            RatingDistributionBucket(rating: String.starRatingLabel(forStep: step), count: counts[step, default: 0])
        }
    }

    private var maxCount: Int {
        max(buckets.map(\.count).max() ?? 1, 1)
    }
}

private struct CreditDisplay: Identifiable {
    let name: String
    let subtitle: String?
    let imageUrl: String?
    let personRef: PersonRef?

    var id: String { "\(name):\(subtitle ?? ""):\(personRef?.id ?? "")" }
}

private struct CreditSection: View {
    let title: String
    let cast: [CreditDisplay]
    let crew: [CreditDisplay]
    let onSelect: (PersonRef) -> Void
    @State private var selectedTab = CreditTab.cast

    private var visiblePeople: [CreditDisplay] {
        switch selectedTab {
        case .cast:
            cast.isEmpty ? crew : cast
        case .crew:
            crew.isEmpty ? cast : crew
        }
    }

    var body: some View {
        if !visiblePeople.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    SectionLabel(title: title)
                    Spacer()
                    if !cast.isEmpty && !crew.isEmpty {
                        creditTabs
                    }
                }

                LazyVStack(spacing: 7) {
                    ForEach(visiblePeople) { person in
                        creditRow(person)
                    }
                }
            }
        }
    }

    private var creditTabs: some View {
        HStack(spacing: 4) {
            creditTab(.cast)
            creditTab(.crew)
        }
        .padding(3)
        .background(.white.opacity(0.055), in: Capsule())
    }

    private func creditTab(_ tab: CreditTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Text(tab.title)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(selectedTab == tab ? .white.opacity(0.9) : .white.opacity(0.52))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(selectedTab == tab ? .white.opacity(0.13) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func creditRow(_ person: CreditDisplay) -> some View {
        Group {
            if let personRef = person.personRef {
                Button {
                    onSelect(personRef)
                } label: {
                    creditRowContent(person, showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: person))
                .accessibilityHint("Opens person details")
            } else {
                creditRowContent(person, showsChevron: false)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    private func creditRowContent(_ person: CreditDisplay, showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            SpineAsyncImage(url: URL(string: person.imageUrl ?? "")) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    Circle()
                        .fill(.white.opacity(0.12))
                        .overlay {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(person.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)

                if let subtitle = person.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.38))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.12), in: Capsule())
        .contentShape(Capsule())
    }

    private func accessibilityLabel(for person: CreditDisplay) -> String {
        guard let subtitle = person.subtitle, !subtitle.isEmpty else {
            return "View \(person.name)"
        }
        return "View \(person.name), \(subtitle)"
    }
}

private enum CreditTab {
    case cast
    case crew

    var title: String {
        switch self {
        case .cast: "Cast"
        case .crew: "Crew"
        }
    }
}

private struct SeasonsSection: View {
    let seasons: [SeasonSummary]
    let onSelect: (SeasonSummary) -> Void

    var body: some View {
        if !seasons.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(title: "Seasons")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(seasons) { season in
                            Button {
                                onSelect(season)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    MediaArtwork(
                                        url: season.imageUrl,
                                        title: season.title,
                                        slot: .seasonCard,
                                        mediaType: "season"
                                    )
                                    Text(season.title)
                                        .font(.system(size: 12, weight: .heavy))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                    if let count = season.episodeCount {
                                        Text("\(count) episodes")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.55))
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: MediaDetailLayout.seasonPosterSize.width, alignment: .topLeading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(season.title)")
                        }
                    }
                }
            }
        }
    }
}

private struct EpisodesSection: View {
    let episodes: [EpisodeSummary]
    let onSelect: (EpisodeSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(title: "Episodes")
            if episodes.isEmpty {
                ContentUnavailableView(
                    "No episodes available",
                    systemImage: "play.rectangle",
                    description: Text("Episode information has not been released yet.")
                )
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 130)
                .mediaDetailSurface(cornerRadius: 18)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(episodes) { episode in
                        EpisodeCard(episode: episode) {
                            onSelect(episode)
                        }
                    }
                }
            }
        }
    }
}

private struct EpisodeCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let episode: EpisodeSummary
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    accessibilityLayout
                } else {
                    compactLayout
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Opens episode details")
        .accessibilityAddTraits(.isButton)
    }

    private var compactLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            EpisodeCardStill(episode: episode, fillsWidth: false)

            episodeCopy

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.32))
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            EpisodeCardStill(episode: episode, fillsWidth: true)
            episodeCopy
        }
    }

    private var episodeCopy: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(episode.title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !metadata.isEmpty {
                Text(metadata)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }

            if let overview = episode.overview?.nilIfEmpty {
                Text(overview)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                    .padding(.top, 1)
            }
        }
    }

    private var metadata: String {
        [episode.airDate?.longDateLabel, episode.runtime]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " · ")
    }

    private var accessibilityDescription: String {
        var components = ["Episode \(episode.episodeNumber), \(episode.title)"]
        if let airDate = episode.airDate?.longDateLabel.nilIfEmpty {
            components.append("Aired \(airDate)")
        }
        if let runtime = episode.runtime?.nilIfEmpty {
            components.append(runtime)
        }
        if let overview = episode.overview?.nilIfEmpty {
            components.append(overview)
        }
        return components.joined(separator: ". ")
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return shape
            .fill(.white.opacity(0.045))
            .overlay { shape.stroke(.white.opacity(0.065), lineWidth: 1) }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
    }
}

private struct EpisodeCardStill: View {
    let episode: EpisodeSummary
    let fillsWidth: Bool

    var body: some View {
        artwork
            .aspectRatio(16 / 9, contentMode: .fill)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(width: fillsWidth ? nil : 116, height: fillsWidth ? nil : 66)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Text("E\(episode.episodeNumber)")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(7)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 0.75)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artwork: some View {
        SpineAsyncImage(url: episode.imageUrl.flatMap(URL.init(string:))) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        let theme = MediaTypeTheme.theme(for: "episode")
        return ZStack {
            LinearGradient(
                colors: theme.gradientColors.map { $0.opacity(0.78) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "play.rectangle.fill")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.56))
        }
    }
}

private struct ReviewsSection: View {
    let reviews: [MediaReview]
    let isLoading: Bool
    let error: String?

    var body: some View {
        Group {
            if isLoading || !reviews.isEmpty || error != nil {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(title: "Reviews")
                    if !reviews.isEmpty {
                        ForEach(reviews.prefix(3)) { review in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(review.user.displayName)
                                        .font(.system(size: 13, weight: .heavy))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    if let rating = review.rating {
                                        Label(rating.starRatingLabel, systemImage: "star.fill")
                                            .font(.system(size: 11, weight: .heavy))
                                            .foregroundStyle(.white.opacity(0.85))
                                    }
                                }
                                if let title = review.reviewTitle, !title.isEmpty {
                                    Text(title)
                                        .font(.system(size: 14, weight: .heavy))
                                        .foregroundStyle(.white)
                                }
                                Text(review.containsSpoilers ? "Spoiler review" : review.review)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.68))
                                    .lineLimit(4)
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                        }
                    } else if isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    if let error {
                        Text(error)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }
            }
        }
        .spineContentTransition(value: contentPhase)
    }

    private var contentPhase: SpineContentPhase {
        .resolve(
            isLoading: isLoading,
            hasContent: !reviews.isEmpty,
            hasError: error != nil
        )
    }
}

private struct RecommendationsSection: View {
    let sections: [RelatedMediaSection]
    let onSelect: (MediaSummary) -> Void

    var body: some View {
        ForEach(sections.filter { !$0.items.isEmpty }) { section in
            VStack(alignment: .leading, spacing: 18) {
                SectionLabel(title: section.title)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(section.items) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    MediaArtwork(
                                        url: item.displayPosterURL,
                                        title: item.title,
                                        slot: .carousel,
                                        mediaType: item.ref.mediaType,
                                        orientation: item.posterOrientation
                                    )
                                    Text(item.title)
                                        .font(.system(size: 12, weight: .heavy))
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                        .frame(height: 32, alignment: .topLeading)
                                }
                                .frame(width: MediaDetailLayout.recommendationPosterSize.width, height: MediaDetailLayout.recommendationCardHeight, alignment: .topLeading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(item.title)")
                        }
                    }
                }
            }
        }
    }
}

private struct MediaDetailBottomBar: View {
    let selectedTab: AppTab
    let onSelectTab: (AppTab) -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                BottomBarItem(title: "Home", systemName: "house.fill", isSelected: selectedTab == .home) {
                    onSelectTab(.home)
                }
                BottomBarItem(title: "Library", systemName: "books.vertical.fill", isSelected: selectedTab == .library) {
                    onSelectTab(.library)
                }
                BottomBarItem(title: "Profile", systemName: "person.fill", isSelected: selectedTab == .profile) {
                    onSelectTab(.profile)
                }
            }
            .padding(5)
            .background(.black.opacity(0.74), in: Capsule())
            .overlay {
                Capsule().stroke(.white.opacity(0.06))
            }

            Button {
                onSelectTab(.search)
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(.black.opacity(0.82), in: Circle())
                    .overlay {
                        Circle().stroke(.white.opacity(0.06))
                    }
                }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
        }
    }
}

private struct BottomBarItem: View {
    let title: String
    let systemName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 21, weight: .bold))
                Text(title)
                    .font(.system(size: 9, weight: .heavy))
            }
            .foregroundStyle(.white)
            .frame(width: isSelected ? 88 : 76, height: 48)
            .background(isSelected ? Color.white.opacity(0.16) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private extension JSONValue {
    var displayString: String? {
        switch self {
        case let .string(value):
            value
        case let .number(value):
            value.rounded() == value ? String(Int(value)) : String(value)
        case let .bool(value):
            value ? "Yes" : "No"
        case let .object(value):
            value["name"]?.displayString ?? value["provider_name"]?.displayString
        case .array, .null:
            nil
        }
    }

    var displayStrings: [String] {
        switch self {
        case let .array(values):
            values.flatMap(\.displayStrings)
        case let .object(value):
            if let string = displayString {
                [string]
            } else {
                value.values.flatMap(\.displayStrings)
            }
        default:
            displayString.map { [$0] } ?? []
        }
    }

    var numberValue: Double? {
        switch self {
        case let .number(value):
            value
        case let .string(value):
            Double(value)
        default:
            nil
        }
    }

    var intValue: Int? {
        numberValue.map(Int.init)
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }
}

private extension Color {
    init?(hex: String?) {
        guard let hex else { return nil }
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let int = Int(value, radix: 16) else { return nil }
        self.init(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
    }
}

func supportsTitleLogo(_ detail: MediaDetail) -> Bool {
    detail.displayLogoURL != nil && (
        detail.ref.source == "tmdb" && ["movie", "tv"].contains(detail.ref.mediaType)
            || detail.ref.source == "igdb" && detail.ref.mediaType == "game"
    )
}

private struct MediaTitleDisplay: View {
    let detail: MediaDetail
    let title: String
    @Binding var showsLogo: Bool
    let font: Font
    let lineLimit: Int?
    let minimumScaleFactor: CGFloat
    let maxLogoHeight: CGFloat
    let onTap: (() -> Void)?
    let onLongPress: (() -> Void)?

    private var canToggle: Bool {
        supportsTitleLogo(detail)
    }

    private var isInteractive: Bool {
        onTap != nil || canToggle
    }

    var body: some View {
        Group {
            if canToggle, showsLogo, let logoUrl = detail.displayLogoURL, let url = URL(string: logoUrl) {
                SpineAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        TitleLogoLayout(maxLogoHeight: maxLogoHeight, aspectRatio: aspectRatio) {
                            image
                                .resizable()
                                .scaledToFit()
                        }
                    case .failure:
                        titleText
                    default:
                        Color.clear
                            .frame(height: maxLogoHeight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                titleText
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let onTap {
                onTap()
                return
            }
            guard canToggle else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                showsLogo.toggle()
            }
        }
        .onLongPressGesture {
            guard canToggle, showsLogo else { return }
            onLongPress?()
        }
        .accessibilityLabel(title)
        .accessibilityHint(onTap != nil ? "Open TV show" : canToggle ? "Double tap to switch between logo and text title" : "")
        .accessibilityAddTraits(isInteractive ? .isButton : [])
    }

    private var titleText: some View {
        Text(title)
            .font(font)
            .foregroundStyle(.white)
            .lineLimit(lineLimit)
            .minimumScaleFactor(minimumScaleFactor)
    }

    private var aspectRatio: CGFloat? {
        if let ratio = detail.logoAspectRatio, ratio > 0 {
            return CGFloat(ratio)
        }
        if let width = detail.logoWidth, let height = detail.logoHeight, height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        return nil
    }
}

private struct TitleLogoLayout: Layout {
    let maxLogoHeight: CGFloat
    let aspectRatio: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        return CGSize(width: width, height: logoSize(for: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let size = logoSize(for: bounds.width)
        let origin = CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.minY
        )
        subview.place(
            at: origin,
            proposal: ProposedViewSize(size)
        )
    }

    private func logoSize(for availableWidth: CGFloat) -> CGSize {
        titleLogoSize(
            availableWidth: availableWidth,
            maxLogoHeight: maxLogoHeight,
            aspectRatio: aspectRatio
        )
    }
}

func titleLogoSize(
    availableWidth: CGFloat,
    maxLogoHeight: CGFloat,
    aspectRatio: CGFloat?
) -> CGSize {
    guard availableWidth > 0, let aspectRatio, aspectRatio > 0 else {
        return CGSize(width: availableWidth, height: maxLogoHeight)
    }

    let targetWidth = availableWidth * 0.82
    let preferredHeight = min(
        max(targetWidth / aspectRatio, maxLogoHeight),
        maxLogoHeight * 1.45
    )
    let width = min(availableWidth, preferredHeight * aspectRatio)
    return CGSize(width: width, height: width / aspectRatio)
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var yearPrefix: String? {
        count >= 4 ? String(prefix(4)) : nil
    }

    var starRatingLabel: String {
        guard let raw = Double(self) else { return self }
        let stars = raw / 2
        return "\(Self.cleanRating(stars))/5"
    }

    var starRatingValue: String {
        guard let raw = Double(self) else { return self }
        return String(format: "%.1f", raw / 2)
    }

    var starRatingStep: Int {
        guard let raw = Double(self) else { return 0 }
        return min(max(Int(round(raw)), 1), 10)
    }

    var shortDateLabel: String {
        let trimmed = String(prefix(10))
        let input = DateFormatter()
        input.calendar = Calendar(identifier: .gregorian)
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd"
        guard let date = input.date(from: trimmed) else { return trimmed }

        let output = DateFormatter()
        output.calendar = Calendar(identifier: .gregorian)
        output.locale = Locale.current
        output.dateFormat = "MMM d, yyyy"
        return output.string(from: date)
    }

    var longDateLabel: String {
        LongDateFormatter().string(from: self) ?? self
    }

    var oneDecimalLabel: String {
        guard let value = Double(self) else { return self }
        return String(format: "%.1f", value)
    }

    static func starRatingLabel(forStep step: Int) -> String {
        cleanRating(Double(step) / 2)
    }

    private static func cleanRating(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

private extension ExternalRating {
    var displayValue: String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["rotten tomatoes", "rottentomatoes"].contains(source.lowercased()) {
            return trimmedValue.hasSuffix("%") ? trimmedValue : "\(trimmedValue)%"
        }
        if source.lowercased() == "hardcover" {
            let displayRating = Double(trimmedValue).map { rawValue in
                let value = rawValue > 5 ? rawValue / 2 : rawValue
                return value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
            } ?? trimmedValue
            return "\(displayRating)/5"
        }
        if trimmedValue.contains("/") || trimmedValue.hasSuffix("%") {
            return trimmedValue
        }
        if let denominator = ratingDenominator ?? maxValue?.nilIfEmpty {
            return "\(trimmedValue)/\(denominator)"
        }
        return trimmedValue
    }

    private var ratingDenominator: String? {
        switch source.lowercased() {
        case "spine", "letterboxd", "hardcover":
            "5"
        case "imdb":
            "10"
        default:
            nil
        }
    }

    var ratingAssetName: String? {
        switch source.lowercased() {
        case "imdb":
            "RatingIMDb"
        case "tmdb":
            "RatingTMDB"
        case "letterboxd":
            "RatingLetterboxd"
        case "rotten tomatoes":
            rottenTomatoesAssetName
        case "mal", "myanimelist":
            "RatingMAL"
        case "hardcover":
            "RatingHardcover"
        case "metacritic":
            "RatingMetacritic"
        case "igdb":
            "RatingIGDB"
        default:
            nil
        }
    }

    private var rottenTomatoesAssetName: String {
        // ponytail: API only sends RT score; use percent thresholds until it sends certification.
        guard let score = value.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.flatMap({ Double($0) }) else {
            return "RatingRottenTomatoes"
        }
        if score <= 59 {
            return "RatingRottenTomatoesRotten"
        }
        if score >= 75 {
            return "RatingRottenTomatoesCertifiedFresh"
        }
        return "RatingRottenTomatoes"
    }
}

private extension String {

    var ratingCountLabel: String {
        switch lowercased() {
        case "letterboxd":
            "ratings"
        case "rotten tomatoes", "rottentomatoes":
            "reviews"
        default:
            "votes"
        }
    }

    var ratingAbbreviation: String {
        switch lowercased() {
        case "imdb":
            "IM"
        case "letterboxd":
            "LB"
        case "rotten tomatoes":
            "RT"
        case "tmdb":
            "TM"
        case "hardcover":
            "HC"
        case "igdb":
            "IG"
        case "metacritic":
            "MC"
        case "mal":
            "MA"
        case "mangaupdates":
            "MU"
        case "openlibrary":
            "OL"
        default:
            String(prefix(2)).uppercased()
        }
    }
}

private extension Array where Element == String {
    var joinedOrNil: String? {
        let value = joined(separator: ", ")
        return value.isEmpty ? nil : value
    }
}

private struct LongDateFormatter {
    private let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale.current
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    func string(from raw: String) -> String? {
        let trimmed = String(raw.prefix(10))
        guard let date = isoFormatter.date(from: trimmed) else { return nil }
        return displayFormatter.string(from: date)
    }
}
