import SwiftUI

@MainActor
@Observable
final class SeriesDetailViewModel {
    var detail: SeriesDetail?
    var isLoading = true
    var errorMessage: String?

    private let ref: SeriesRef
    private let mediaRepository: MediaRepository
    private let onUnauthorized: () -> Void

    init(
        ref: SeriesRef,
        mediaRepository: MediaRepository,
        onUnauthorized: @escaping () -> Void
    ) {
        self.ref = ref
        self.mediaRepository = mediaRepository
        self.onUnauthorized = onUnauthorized
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            detail = try await mediaRepository.series(ref: ref)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }

    func selection(for item: MediaSummary) -> MediaBrowsingSelection {
        MediaBrowsingSelection(
            ref: item.ref,
            within: detail?.items.map(\.ref) ?? [item.ref]
        )
    }
}

struct SeriesDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SeriesDetailViewModel
    @State private var selectedMedia: MediaBrowsingSelection?
    @State private var edgeDragOffset: CGFloat = 0

    private let mediaRepository: MediaRepository
    private let trackingRepository: TrackingRepository
    private let diaryRepository: DiaryRepository
    private let listRepository: ListRepository
    private let peopleRepository: PeopleRepository
    private let currentUserId: Int?
    private let selectedTab: AppTab
    private let onSelectTab: (AppTab) -> Void
    private let onUnauthorized: () -> Void

    init(
        ref: SeriesRef,
        mediaRepository: MediaRepository,
        trackingRepository: TrackingRepository,
        diaryRepository: DiaryRepository,
        listRepository: ListRepository = AppRepositories.current().lists,
        peopleRepository: PeopleRepository = AppRepositories.current().people,
        currentUserId: Int? = nil,
        selectedTab: AppTab = .home,
        onSelectTab: @escaping (AppTab) -> Void = { _ in },
        onUnauthorized: @escaping () -> Void = {}
    ) {
        self.mediaRepository = mediaRepository
        self.trackingRepository = trackingRepository
        self.diaryRepository = diaryRepository
        self.listRepository = listRepository
        self.peopleRepository = peopleRepository
        self.currentUserId = currentUserId
        self.selectedTab = selectedTab
        self.onSelectTab = onSelectTab
        self.onUnauthorized = onUnauthorized
        _viewModel = State(initialValue: SeriesDetailViewModel(
            ref: ref,
            mediaRepository: mediaRepository,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
                    .spineContentTransition(value: contentPhase)
            }
            .navigationTitle(viewModel.detail?.name ?? "Series")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    MediaDiscoverBackButton {
                        dismiss()
                    }
                }
            }
            .task {
                if viewModel.detail == nil {
                    await viewModel.load()
                }
            }
        }
        .background(Color.black)
        .offset(x: edgeDragOffset)
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 28)
                .contentShape(Rectangle())
                .gesture(edgeSwipeBackGesture)
        }
        .fullScreenCover(item: $selectedMedia, onDismiss: { selectedMedia = nil }) { selection in
            MediaDetailView(
                ref: selection.ref,
                browsingContext: selection.context,
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
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, viewModel.detail == nil {
            ProgressView()
                .tint(.white)
        } else if let error = viewModel.errorMessage, viewModel.detail == nil {
            ContentUnavailableView(
                "Could not load series",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if let detail = viewModel.detail, detail.items.isEmpty {
            ContentUnavailableView(
                detail.mediaType == "movie" ? "No movies" : detail.mediaType == "game" ? "No games" : "No books",
                systemImage: detail.mediaType == "movie" ? "film" : detail.mediaType == "game" ? "gamecontroller" : "books.vertical"
            )
        } else if let detail = viewModel.detail {
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                    spacing: 10
                ) {
                    ForEach(detail.items) { item in
                        Button {
                            selectedMedia = viewModel.selection(for: item)
                        } label: {
                            MediaArtwork(
                                url: item.displayPosterURL,
                                title: item.title,
                                slot: .tagGrid,
                                mediaType: item.ref.mediaType,
                                orientation: item.posterOrientation
                            )
                            .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View \(item.title)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }
        }
    }

    private var contentPhase: SpineContentPhase {
        .resolve(
            isLoading: viewModel.isLoading,
            hasContent: viewModel.detail != nil,
            hasError: viewModel.errorMessage != nil
        )
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
}
