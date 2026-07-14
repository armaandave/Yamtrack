import Foundation
import SwiftUI

@MainActor
@Observable
final class CompanyDetailViewModel {
    var detail: CompanyDetail?
    var gamesByRole: [CompanyCatalogRole: [MediaSummary]] = [:]
    var nextPageByRole: [CompanyCatalogRole: String] = [:]
    var filter = MediaFilterState()
    var filterOptions: MediaFilterOptionsResponse = .companyFallback
    var isLoading = true
    var errorMessage: String?

    private let ref: CompanyRef
    private let companyRepository: CompanyRepository
    private let onUnauthorized: () -> Void
    private var filterRevision = 0
    private var loadingRevisionByRole: [CompanyCatalogRole: Int] = [:]
    private var loadingMoreRevisionByRole: [CompanyCatalogRole: Int] = [:]

    init(ref: CompanyRef, companyRepository: CompanyRepository, onUnauthorized: @escaping () -> Void) {
        self.ref = ref
        self.companyRepository = companyRepository
        self.onUnauthorized = onUnauthorized
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await companyRepository.detail(ref: ref)
            detail = loaded
            let role = preferredRole(for: loaded)
            filterRevision += 1
            await loadGames(for: role, reset: true)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            handleUnauthorized(error)
        }
    }

    func loadFilterOptions() async {
        do {
            filterOptions = try await companyRepository.gameFilterOptions(ref: ref)
        } catch is CancellationError {
            return
        } catch {
            handleUnauthorized(error)
        }
    }

    func loadGames(for role: CompanyCatalogRole, reset: Bool = false) async {
        guard detail != nil, reset || gamesByRole[role] == nil else { return }
        let requestRevision = filterRevision
        let requestFilter = filter
        loadingRevisionByRole[role] = requestRevision
        defer {
            if loadingRevisionByRole[role] == requestRevision {
                loadingRevisionByRole[role] = nil
            }
        }

        do {
            let response = try await companyRepository.games(
                ref: ref,
                role: role,
                page: nil,
                filter: requestFilter
            )
            guard requestRevision == filterRevision, requestFilter == filter else { return }
            gamesByRole[role] = response.results
            nextPageByRole[role] = APIPageCursor.nextPage(from: response.next)
        } catch is CancellationError {
            return
        } catch {
            guard requestRevision == filterRevision else { return }
            errorMessage = error.localizedDescription
            handleUnauthorized(error)
        }
    }

    func loadMore(for role: CompanyCatalogRole) async {
        guard loadingMoreRevisionByRole[role] == nil, let page = nextPageByRole[role] else { return }
        let requestRevision = filterRevision
        let requestFilter = filter
        loadingMoreRevisionByRole[role] = requestRevision
        defer {
            if loadingMoreRevisionByRole[role] == requestRevision {
                loadingMoreRevisionByRole[role] = nil
            }
        }

        do {
            let response = try await companyRepository.games(
                ref: ref,
                role: role,
                page: page,
                filter: requestFilter
            )
            guard requestRevision == filterRevision, requestFilter == filter else { return }
            var games = gamesByRole[role] ?? []
            var seen = Set(games.map(\.id))
            games += response.results.filter { seen.insert($0.id).inserted }
            gamesByRole[role] = games
            nextPageByRole[role] = APIPageCursor.nextPage(from: response.next)
        } catch is CancellationError {
            return
        } catch {
            guard requestRevision == filterRevision else { return }
            errorMessage = error.localizedDescription
            handleUnauthorized(error)
        }
    }

    func applyFilter(to roles: Set<CompanyCatalogRole>) async {
        filterRevision += 1
        let applyRevision = filterRevision
        errorMessage = nil
        gamesByRole = [:]
        nextPageByRole = [:]
        for role in CompanyCatalogRole.allCases where roles.contains(role) {
            guard applyRevision == filterRevision else { return }
            await loadGames(for: role, reset: true)
        }
    }

    func isLoadingGames(for role: CompanyCatalogRole) -> Bool {
        loadingRevisionByRole[role] == filterRevision
    }

    func isLoadingMore(for role: CompanyCatalogRole) -> Bool {
        loadingMoreRevisionByRole[role] == filterRevision
    }

    private func preferredRole(for detail: CompanyDetail) -> CompanyCatalogRole {
        detail.catalogs.developed.count > 0 ? .developed : .published
    }

    private func handleUnauthorized(_ error: Error) {
        if case APIError.unauthorized = error {
            onUnauthorized()
        }
    }
}

struct CompanyDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: CompanyDetailViewModel
    @State private var expandedRoles = Set<CompanyCatalogRole>()
    @State private var selectedMedia: MediaBrowsingSelection?
    @State private var selectedCompany: CompanyRef?
    @State private var edgeDragOffset: CGFloat = 0

    private let companyRepository: CompanyRepository
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
        ref: CompanyRef,
        companyRepository: CompanyRepository = AppRepositories.current().companies,
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
        self.companyRepository = companyRepository
        self.mediaRepository = mediaRepository
        self.trackingRepository = trackingRepository
        self.diaryRepository = diaryRepository
        self.listRepository = listRepository
        self.peopleRepository = peopleRepository
        self.currentUserId = currentUserId
        self.selectedTab = selectedTab
        self.onSelectTab = onSelectTab
        self.onUnauthorized = onUnauthorized
        _viewModel = State(initialValue: CompanyDetailViewModel(
            ref: ref,
            companyRepository: companyRepository,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpinePageBackground()
            content
                .spineContentTransition(value: contentPhase)
            CompanyBackButton { dismiss() }
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
        .fullScreenCover(item: $selectedMedia) { selection in
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
        .fullScreenCover(item: $selectedCompany) { ref in
            CompanyDetailView(
                ref: ref,
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
        .task {
            guard viewModel.detail == nil else { return }
            await viewModel.load()
            expandPrimaryRole()
            await viewModel.loadFilterOptions()
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
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    hero(detail)
                    descriptionSection(detail)
                    studioDetailsSection(detail)
                    gamesSection(detail)
                }
                .padding(.horizontal, 16)
                .padding(.top, 48)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .refreshable {
                await viewModel.load()
                expandPrimaryRole()
            }
        } else if let error = viewModel.errorMessage, viewModel.detail == nil {
            ContentUnavailableView(
                "Could not load studio",
                systemImage: "building.2.crop.circle",
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

    private func hero(_ detail: CompanyDetail) -> some View {
        VStack(spacing: 16) {
            CompanyLogo(urlString: detail.logoUrl, name: detail.name)
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

                CompanyMetadataChips(detail: detail)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func descriptionSection(_ detail: CompanyDetail) -> some View {
        if let description = clean(detail.description) {
            VStack(alignment: .leading, spacing: 12) {
                CompanySectionLabel(title: "About")
                Text(description)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineSpacing(3)
                    .padding(14)
                    .background(.white.opacity(0.028), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func gamesSection(_ detail: CompanyDetail) -> some View {
        let availableRoles = CompanyCatalogRole.allCases.filter { $0.count(in: detail) > 0 }

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                CompanySectionLabel(title: "Games")

                Spacer()

                MediaFilterButton(
                    filter: $viewModel.filter,
                    scope: .company(ref: detail.ref),
                    options: viewModel.filterOptions,
                    mediaTypes: [],
                    showsTagFilter: false
                ) {
                    let roles = expandedRoles
                    Task { await viewModel.applyFilter(to: roles) }
                }
            }

            ForEach(availableRoles) { role in
                roleDisclosureRow(role, detail: detail)
            }
        }
    }

    private func roleDisclosureRow(_ role: CompanyCatalogRole, detail: CompanyDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                let isExpanding = !expandedRoles.contains(role)
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanding {
                        expandedRoles.insert(role)
                    } else {
                        expandedRoles.remove(role)
                    }
                }
                if isExpanding {
                    Task { await viewModel.loadGames(for: role) }
                }
            } label: {
                HStack(spacing: 10) {
                    Text("\(role.creditRole) · \(role.count(in: detail).formatted()) games")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.74))

                    Spacer()

                    Image(systemName: expandedRoles.contains(role) ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.44))
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if expandedRoles.contains(role) {
                roleGames(role)
            }
        }
    }

    @ViewBuilder
    private func roleGames(_ role: CompanyCatalogRole) -> some View {
        let games = viewModel.gamesByRole[role] ?? []

        if viewModel.isLoadingGames(for: role), games.isEmpty, viewModel.errorMessage == nil {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if games.isEmpty {
            ContentUnavailableView(
                "No \(role.title.lowercased()) games",
                systemImage: "square.grid.2x2",
                description: Text("Games will appear here when available.")
            )
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                ForEach(games) { game in
                    Button {
                        selectedMedia = MediaBrowsingSelection(
                            ref: game.ref,
                            within: games.map(\.ref)
                        )
                    } label: {
                        MediaArtwork(
                            url: game.displayPosterURL,
                            title: game.title,
                            slot: .tagGrid,
                            mediaType: game.ref.mediaType,
                            orientation: game.posterOrientation
                        )
                        .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View \(game.title)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.nextPageByRole[role] != nil {
                Button {
                    Task { await viewModel.loadMore(for: role) }
                } label: {
                    Group {
                        if viewModel.isLoadingMore(for: role) {
                            ProgressView().tint(.white)
                        } else {
                            Text("Load More")
                        }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoadingMore(for: role))
            }
        }
    }

    @ViewBuilder
    private func studioDetailsSection(_ detail: CompanyDetail) -> some View {
        let website = detail.websites.first ?? detail.igdbUrl
        if detail.parent != nil || website != nil {
            VStack(alignment: .leading, spacing: 12) {
                CompanySectionLabel(title: "Studio Details")

                VStack(spacing: 0) {
                    if let parent = detail.parent {
                        Button {
                            selectedCompany = CompanyRef(source: detail.source, companyId: parent.id)
                        } label: {
                            detailRow(label: "Parent", value: parent.name, showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View \(parent.name)")
                    }

                    if let website, let url = URL(string: website) {
                        if detail.parent != nil {
                            Divider().overlay(.white.opacity(0.045))
                        }
                        Link(destination: url) {
                            detailRow(label: "Website", value: url.host ?? website, showsChevron: true)
                        }
                    }
                }
                .background(.white.opacity(0.028), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.045), lineWidth: 1)
                }
            }
        }
    }

    private func detailRow(label: String, value: String, showsChevron: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.44))
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.36))
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func expandPrimaryRole() {
        guard let detail = viewModel.detail else {
            expandedRoles = []
            return
        }
        if let primaryRole = CompanyCatalogRole.allCases.first(where: { $0.count(in: detail) > 0 }) {
            expandedRoles = [primaryRole]
        } else {
            expandedRoles = []
        }
    }
}

private struct CompanyLogo: View {
    let urlString: String?
    let name: String

    var body: some View {
        SpineAsyncImage(url: URL(string: urlString ?? "")) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFit()
                    .padding(22)
            default:
                Image(systemName: "building.2.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.black.opacity(0.62))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(white: 0.92), Color(white: 0.62)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.3), lineWidth: 1)
        }
        .accessibilityLabel(name)
    }
}

private struct CompanySectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .heavy))
            .tracking(1.1)
            .foregroundStyle(.white.opacity(0.58))
    }
}

private struct CompanyMetadataChips: View {
    let detail: CompanyDetail

    private var chips: [String] {
        var chips = [
            detail.catalogs.developed.count > 0 ? "\(detail.catalogs.developed.count.formatted()) developed" : nil,
            detail.catalogs.published.count > 0 ? "\(detail.catalogs.published.count.formatted()) published" : nil,
            detail.foundedYear.map { "Founded \($0)" },
            detail.status,
        ].compactMap { $0 }
        if let companySize = detail.companySize, !companySize.isEmpty {
            chips.append(companySize)
        }
        return chips
    }

    var body: some View {
        if !chips.isEmpty {
            CenteredFlowLayout(spacing: 8) {
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
            .frame(maxWidth: .infinity)
        }
    }
}

private struct CenteredFlowLayout: Layout {
    let spacing: CGFloat

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width }
        let rows = rows(for: width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX + max(0, (bounds.width - row.width) / 2)
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, nextWidth > width {
                rows.append(row)
                row = Row()
            }
            row.indices.append(index)
            row.width = row.indices.count == 1 ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty {
            rows.append(row)
        }
        return rows
    }
}

private struct CompanyBackButton: View {
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
