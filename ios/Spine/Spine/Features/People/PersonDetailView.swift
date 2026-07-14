import Foundation
import SwiftUI

@MainActor
@Observable
final class PersonDetailViewModel {
    var detail: PersonDetail?
    var filmography: [MediaSummary] = []
    var filter = MediaFilterState()
    var filterOptions: MediaFilterOptionsResponse = .empty
    var isLoading = true
    var errorMessage: String?

    private let ref: PersonRef
    private let peopleRepository: PeopleRepository
    private let onUnauthorized: () -> Void
    private var requestGeneration = 0
    private var presentedFilter: MediaFilterState?

    init(
        ref: PersonRef,
        peopleRepository: PeopleRepository,
        onUnauthorized: @escaping () -> Void
    ) {
        self.ref = ref
        self.peopleRepository = peopleRepository
        self.onUnauthorized = onUnauthorized
    }

    func load() async {
        requestGeneration += 1
        let generation = requestGeneration
        let requestFilter = filter
        if presentedFilter != requestFilter {
            detail = nil
            filmography = []
        }
        presentedFilter = requestFilter
        isLoading = true
        errorMessage = nil
        defer {
            if generation == requestGeneration, requestFilter == filter {
                isLoading = false
            }
        }

        do {
            let loaded = try await peopleRepository.detail(ref: ref, filter: requestFilter)
            guard generation == requestGeneration, requestFilter == filter else { return }
            let loadedFilmography = Self.uniqueFilmography(from: loaded.filmography)
            detail = loaded
            filmography = loadedFilmography
            if !filter.isActive || filterOptions == .empty {
                filterOptions = Self.options(from: loadedFilmography)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration, requestFilter == filter else { return }
            errorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }

    static func uniqueFilmography(from media: [MediaSummary]) -> [MediaSummary] {
        var seen = Set<String>()
        return media.filter { seen.insert($0.id).inserted }
    }

    static func options(from media: [MediaSummary]) -> MediaFilterOptionsResponse {
        let years = Set(media.compactMap { item -> Int? in
            guard let releaseDate = item.releaseDate, releaseDate.count >= 4 else { return nil }
            return Int(releaseDate.prefix(4))
        })
        let genres = Set(media.flatMap(\.genres)).sorted()
        let languages = Set(media.flatMap(\.languages)).sorted()
        return MediaFilterOptionsResponse(
            sorts: [],
            genres: genres.map { FilterChoice(value: $0, label: $0) },
            languages: languages.map { FilterChoice(value: $0, label: $0) },
            years: years.sorted(by: >)
        )
    }
}

struct PersonDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PersonDetailViewModel
    @State private var selectedMedia: MediaBrowsingSelection?
    @State private var selectedFilmographyType: FilmographyType = .movie
    @State private var expandedCreditRoles = Set<String>()
    @State private var edgeDragOffset: CGFloat = 0

    private let peopleRepository: PeopleRepository
    private let mediaRepository: MediaRepository
    private let trackingRepository: TrackingRepository
    private let diaryRepository: DiaryRepository
    private let listRepository: ListRepository
    private let currentUserId: Int?
    private let selectedTab: AppTab
    private let onSelectTab: (AppTab) -> Void
    private let onUnauthorized: () -> Void

    init(
        ref: PersonRef,
        peopleRepository: PeopleRepository,
        mediaRepository: MediaRepository,
        trackingRepository: TrackingRepository,
        diaryRepository: DiaryRepository,
        listRepository: ListRepository = AppRepositories.current().lists,
        currentUserId: Int? = nil,
        selectedTab: AppTab = .home,
        onSelectTab: @escaping (AppTab) -> Void = { _ in },
        onUnauthorized: @escaping () -> Void = {}
    ) {
        self.peopleRepository = peopleRepository
        self.mediaRepository = mediaRepository
        self.trackingRepository = trackingRepository
        self.diaryRepository = diaryRepository
        self.listRepository = listRepository
        self.currentUserId = currentUserId
        self.selectedTab = selectedTab
        self.onSelectTab = onSelectTab
        self.onUnauthorized = onUnauthorized
        _viewModel = State(initialValue: PersonDetailViewModel(
            ref: ref,
            peopleRepository: peopleRepository,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpinePageBackground()

            content
                .spineContentTransition(value: contentPhase)

            PersonBackButton {
                dismiss()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden()
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
        .task {
            if viewModel.detail == nil {
                await viewModel.load()
                syncSelectedFilmographyType()
                expandPrimaryCreditRole()
            }
        }
        .onChange(of: selectedFilmographyType) { _, _ in
            expandPrimaryCreditRole()
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

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, viewModel.detail == nil {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail = viewModel.detail {
            ScrollView(showsIndicators: false) {
                ZStack(alignment: .top) {
                    PersonHeroArtwork(urlString: detail.profileUrl)
                        .frame(height: 390)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)

                    VStack(alignment: .leading, spacing: 26) {
                        hero(detail)
                        biographySection(detail)
                        filmographySection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 44)
                    .padding(.bottom, 36)
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable {
                await viewModel.load()
                syncSelectedFilmographyType()
            }
        } else if let error = viewModel.errorMessage, viewModel.detail == nil {
            ContentUnavailableView(
                "Could not load person",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .foregroundStyle(.white)
            .padding()
        }
    }

    private var contentPhase: SpineContentPhase {
        .resolve(
            isLoading: viewModel.isLoading,
            hasContent: viewModel.detail != nil,
            hasError: viewModel.errorMessage != nil
        )
    }

    private func hero(_ detail: PersonDetail) -> some View {
        VStack(spacing: 16) {
            PersonProfileImage(urlString: detail.profileUrl, name: detail.name)
                .frame(width: 156, height: 156)
                .shadow(color: .black.opacity(0.42), radius: 24, y: 14)

            VStack(spacing: 10) {
                Text(detail.name)
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity)

                personChips(detail)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func personChips(_ detail: PersonDetail) -> some View {
        let chips = metadataChips(detail)
        if !chips.isEmpty {
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                                .padding(.horizontal, 11)
                                .frame(height: 31)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                    }
                    .frame(minWidth: proxy.size.width)
                }
                .mask(alignment: .trailing) {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.9),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }
            .frame(height: 31)
        }
    }

    @ViewBuilder
    private func biographySection(_ detail: PersonDetail) -> some View {
        if let biography = clean(detail.biography) {
            VStack(alignment: .leading, spacing: 12) {
                PersonSectionLabel(title: "Biography")
                PersonBiographyCard(text: biography)
            }
        }
    }

    private var filmographySection: some View {
        let types = FilmographyType.available(in: viewModel.filmography)
        let selectedType = types.contains(selectedFilmographyType) ? selectedFilmographyType : types.first ?? selectedFilmographyType
        let filmography = viewModel.filmography.filter { $0.ref.mediaType == selectedType.rawValue }
        let groups = FilmographyCreditGroup.groups(
            from: filmography,
            knownForDepartment: viewModel.detail?.knownForDepartment
        )

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                PersonSectionLabel(title: selectedType.sectionTitle)

                Spacer()

                MediaFilterButton(
                    filter: $viewModel.filter,
                    scope: .person(ref: viewModel.detail?.ref ?? PersonRef(source: "", id: "")),
                    options: viewModel.filterOptions,
                    mediaTypes: types.map(\.rawValue)
                ) {
                    Task {
                        await viewModel.load()
                        if let mediaType = viewModel.filter.mediaType, let selectedType = FilmographyType(rawValue: mediaType) {
                            selectedFilmographyType = selectedType
                        }
                        syncSelectedFilmographyType()
                        expandPrimaryCreditRole()
                    }
                }

                if types.count > 1 {
                    Picker("Credit type", selection: $selectedFilmographyType) {
                        ForEach(types) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: max(75, CGFloat(types.count) * 75))
                }
            }

            Group {
                if filmography.isEmpty {
                    ContentUnavailableView(
                        "No \(selectedType.title.lowercased())",
                        systemImage: "square.grid.2x2",
                        description: Text("Credits will appear here when available.")
                    )
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            roleDisclosureRow(group, type: selectedType)
                        }
                    }
                }
            }
            .spineContentTransition(value: selectedType)
        }
    }

    private func roleDisclosureRow(_ group: FilmographyCreditGroup, type: FilmographyType) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if expandedCreditRoles.contains(group.id) {
                        expandedCreditRoles.remove(group.id)
                    } else {
                        expandedCreditRoles.insert(group.id)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(group.compactTitle(for: type))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.74))

                    Spacer()

                    Image(systemName: expandedCreditRoles.contains(group.id) ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.44))
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if expandedCreditRoles.contains(group.id) {
                filmographyGrid(group.media)
            }
        }
    }

    private func filmographyGrid(_ media: [MediaSummary]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
            ForEach(media) { item in
                Button {
                    selectedMedia = MediaBrowsingSelection(
                        ref: item.ref,
                        within: media.map(\.ref)
                    )
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
    }

    private func metadataChips(_ detail: PersonDetail) -> [String] {
        var chips: [String] = []
        if let department = clean(detail.knownForDepartment) {
            chips.append(department)
        }
        if let birthDate = clean(detail.birthDate) {
            chips.append("Born \(yearOrDate(birthDate))")
        }
        if let deathDate = clean(detail.deathDate) {
            chips.append("Died \(yearOrDate(deathDate))")
        }
        if let place = clean(detail.placeOfBirth) {
            chips.append(place)
        }
        return chips
    }

    private func syncSelectedFilmographyType() {
        let types = FilmographyType.available(in: viewModel.filmography)
        if let first = types.first, !types.contains(selectedFilmographyType) {
            selectedFilmographyType = first
        }
    }

    private func expandPrimaryCreditRole() {
        let types = FilmographyType.available(in: viewModel.filmography)
        let selectedType = types.contains(selectedFilmographyType) ? selectedFilmographyType : types.first ?? selectedFilmographyType
        let filmography = viewModel.filmography.filter { $0.ref.mediaType == selectedType.rawValue }
        if let primaryGroup = FilmographyCreditGroup.groups(
            from: filmography,
            knownForDepartment: viewModel.detail?.knownForDepartment
        ).first {
            expandedCreditRoles = [primaryGroup.id]
        } else {
            expandedCreditRoles = []
        }
    }

    private func clean(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private func yearOrDate(_ value: String) -> String {
        value.count >= 4 ? String(value.prefix(4)) : value
    }
}

private enum FilmographyType: String, CaseIterable, Identifiable {
    case movie
    case tv
    case book

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movie:
            "Film"
        case .tv:
            "TV"
        case .book:
            "Books"
        }
    }

    var sectionTitle: String {
        switch self {
        case .book:
            "Books"
        case .movie, .tv:
            "Filmography"
        }
    }

    static func available(in media: [MediaSummary]) -> [FilmographyType] {
        allCases.filter { type in
            media.contains { $0.ref.mediaType == type.rawValue }
        }
    }
}

struct FilmographyCreditGroup: Identifiable {
    let role: String
    let media: [MediaSummary]

    var id: String { role }

    static func groups(
        from media: [MediaSummary],
        knownForDepartment: String? = nil
    ) -> [FilmographyCreditGroup] {
        var grouped: [String: [MediaSummary]] = [:]

        for item in media {
            let roles = cleanRoles(item.creditRoles)
            for role in roles.isEmpty ? ["Credits"] : roles {
                grouped[role, default: []].append(item)
            }
        }

        let primaryRoles = primaryRoles(for: knownForDepartment)

        return grouped
            .map { FilmographyCreditGroup(role: $0.key, media: $0.value) }
            .sorted {
                let firstIsPrimary = primaryRoles.contains($0.role.lowercased())
                let secondIsPrimary = primaryRoles.contains($1.role.lowercased())
                if firstIsPrimary != secondIsPrimary {
                    return firstIsPrimary
                }
                if $0.media.count != $1.media.count {
                    return $0.media.count > $1.media.count
                }
                return $0.role < $1.role
            }
    }

    fileprivate func title(for type: FilmographyType) -> String {
        if role == "Credits" {
            return compactTitle(for: type)
        }
        return "\(role) \(connector) \(media.count) \(type.creditNoun(count: media.count))"
    }

    fileprivate func compactTitle(for type: FilmographyType) -> String {
        "\(role) · \(media.count) \(type.creditNoun(count: media.count))"
    }

    private var connector: String {
        switch role.lowercased() {
        case "actor", "actress":
            "in"
        case "author":
            "of"
        default:
            "of"
        }
    }

    private static func cleanRoles(_ roles: [String]) -> [String] {
        var seen = Set<String>()
        return roles.compactMap { role in
            let clean = role.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean).inserted else { return nil }
            return clean
        }
    }

    private static func primaryRoles(for department: String?) -> Set<String> {
        switch department?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "acting":
            ["actor", "actress"]
        case "directing":
            ["director"]
        case "writing":
            ["writer"]
        case "production":
            ["producer"]
        case "author":
            ["author"]
        default:
            []
        }
    }
}

private extension FilmographyType {
    func creditNoun(count: Int) -> String {
        switch self {
        case .movie:
            count == 1 ? "film" : "films"
        case .tv:
            count == 1 ? "show" : "shows"
        case .book:
            count == 1 ? "book" : "books"
        }
    }
}

private struct PersonProfileImage: View {
    let urlString: String?
    let name: String

    var body: some View {
        SpineAsyncImage(url: imageURL) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                Circle()
                    .fill(.white.opacity(0.12))
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 58, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
            }
        }
        .clipShape(Circle())
        .overlay {
            Circle().stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .accessibilityLabel(name)
    }

    private var imageURL: URL? {
        guard let urlString, !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(string: urlString)
    }
}

private struct PersonHeroArtwork: View {
    let urlString: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                SpineAsyncImage(url: imageURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    default:
                        SpinePalette.pageBackground
                    }
                }
                .blur(radius: 30, opaque: true)
                .scaleEffect(1.28)
                .brightness(-0.04)
                .saturation(1.2)
                .frame(width: proxy.size.width, height: proxy.size.height)

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.4), location: 0),
                        .init(color: .black.opacity(0.14), location: 0.3),
                        .init(color: .clear, location: 0.58),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.32),
                        .init(color: SpinePalette.pageBackground.opacity(0.2), location: 0.54),
                        .init(color: SpinePalette.pageBackground.opacity(0.7), location: 0.78),
                        .init(color: SpinePalette.pageBackground, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
        }
    }

    private var imageURL: URL? {
        guard let urlString, !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(string: urlString)
    }
}

private struct PersonBiographyCard: View {
    let text: String
    @State private var isExpanded = false
    @State private var truncatedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var canExpand: Bool {
        fullHeight > truncatedHeight + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(biographyFont)
                .foregroundStyle(.white.opacity(0.9))
                .lineSpacing(2)
                .lineLimit(isExpanded ? nil : 3)
                .background {
                    measuredText(lineLimit: 3, key: PersonBiographyTruncatedHeightKey.self)
                }
                .background {
                    measuredText(lineLimit: nil, key: PersonBiographyFullHeightKey.self)
                }

            if canExpand {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Label(isExpanded ? "READ LESS" : "READ MORE", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .onPreferenceChange(PersonBiographyTruncatedHeightKey.self) { truncatedHeight = $0 }
        .onPreferenceChange(PersonBiographyFullHeightKey.self) { fullHeight = $0 }
    }

    private func measuredText<Key: PreferenceKey>(lineLimit: Int?, key: Key.Type) -> some View where Key.Value == CGFloat {
        Text(text)
            .font(biographyFont)
            .lineSpacing(2)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: key, value: proxy.size.height)
                }
            }
            .hidden()
    }

    private var biographyFont: Font {
        .system(size: 14, weight: .semibold)
    }
}

private struct PersonBiographyTruncatedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PersonBiographyFullHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PersonBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.34), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }
}

private struct PersonSectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(.white.opacity(0.54))
            .tracking(1.2)
    }
}
