import Foundation
import SwiftUI

@MainActor
@Observable
final class SongDetailViewModel {
    var detail: MusicRecordingDetail?
    var isLoading = true
    var errorMessage: String?

    private let selection: MusicSongSelection
    private let musicRepository: MusicRepository
    private let onUnauthorized: () -> Void

    init(
        selection: MusicSongSelection,
        musicRepository: MusicRepository,
        onUnauthorized: @escaping () -> Void
    ) {
        self.selection = selection
        self.musicRepository = musicRepository
        self.onUnauthorized = onUnauthorized
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            detail = try await musicRepository.recordingDetail(
                album: selection.album,
                recordingMbid: selection.recordingMbid
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }
}

enum MusicSongPresentation {
    static func musicBrainzURL(_ detail: MusicRecordingDetail) -> URL {
        for value in [detail.externalLinks["MusicBrainz"], detail.sourceUrl].compactMap({ $0 }) {
            guard
                let url = URL(string: value),
                ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                let host = url.host?.lowercased(),
                host == "musicbrainz.org" || host.hasSuffix(".musicbrainz.org")
            else { continue }
            return url
        }
        return URL(string: "https://musicbrainz.org")!
            .appending(path: "recording")
            .appending(path: detail.recordingMbid)
    }

    static func rating(_ rating: MusicRecordingRating?) -> String? {
        guard let value = rating?.value else { return nil }
        return String(format: "%.1f / %d", value, rating?.maxValue ?? 5)
    }

    static func credit(_ credit: MusicRecordingCredit) -> String? {
        let roles = credit.roles.compactMap { role -> String? in
            switch role.lowercased() {
            case "writer": "Songwriter"
            case "composer": "Composer"
            case "lyricist": "Lyricist"
            default: nil
            }
        }
        guard !roles.isEmpty else { return nil }
        return "\(credit.name) · \(roles.joined(separator: ", "))"
    }
}

struct SongDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SongDetailViewModel
    @State private var selectedAlbum: MediaRef?

    private let selection: MusicSongSelection
    private let musicRepository: MusicRepository
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

    init(
        selection: MusicSongSelection,
        musicRepository: MusicRepository,
        mediaRepository: MediaRepository,
        trackingRepository: TrackingRepository,
        diaryRepository: DiaryRepository,
        listRepository: ListRepository,
        peopleRepository: PeopleRepository,
        companyRepository: CompanyRepository,
        currentUserId: Int? = nil,
        selectedTab: AppTab = .home,
        onSelectTab: @escaping (AppTab) -> Void = { _ in },
        onUnauthorized: @escaping () -> Void = {}
    ) {
        self.selection = selection
        self.musicRepository = musicRepository
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
        _viewModel = State(initialValue: SongDetailViewModel(
            selection: selection,
            musicRepository: musicRepository,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpinePageBackground()
            content
                .spineContentTransition(value: contentPhase)
            backButton
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden()
        .fullScreenCover(item: $selectedAlbum) { ref in
            MediaDetailView(
                ref: ref,
                mediaRepository: mediaRepository,
                musicRepository: musicRepository,
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
        .task {
            if viewModel.detail == nil {
                await viewModel.load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, viewModel.detail == nil {
            ProgressView("Loading song…")
                .tint(.white)
                .foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("song-detail.loading")
        } else if let detail = viewModel.detail {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    hero(detail)
                    facts(detail)
                    works(detail)
                    albums(detail)
                    releases(detail)
                    externalLink(detail)
                }
                .padding(.horizontal, 16)
                .padding(.top, 58)
                .padding(.bottom, 40)
            }
            .scrollContentBackground(.hidden)
        } else {
            VStack(spacing: 18) {
                ContentUnavailableView(
                    "Could not load song",
                    systemImage: "exclamationmark.triangle",
                    description: Text(viewModel.errorMessage ?? "Unknown error")
                )
                .foregroundStyle(.white)
                Button("Try Again") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.16))
                .accessibilityIdentifier("song-detail.retry")
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("song-detail.error")
        }
    }

    private var contentPhase: SpineContentPhase {
        .resolve(
            isLoading: viewModel.isLoading,
            hasContent: viewModel.detail != nil,
            hasError: viewModel.errorMessage != nil
        )
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.48), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to album")
    }

    private func hero(_ detail: MusicRecordingDetail) -> some View {
        VStack(spacing: 16) {
            MediaArtwork(
                url: selection.artworkURL ?? detail.imageUrl,
                title: detail.parentAlbum.title,
                slot: .hero,
                mediaType: "music",
                orientation: .square
            )
            .shadow(color: .black.opacity(0.48), radius: 22, y: 12)

            VStack(spacing: 7) {
                Text(detail.title)
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                if let artist = MusicAlbumPresentation.artistCreditText(detail.artistCredit) {
                    Text(artist)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func facts(_ detail: MusicRecordingDetail) -> some View {
        let rows = factRows(detail)
        if !rows.isEmpty {
            SongSection(title: "Song Details") {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(alignment: .top, spacing: 12) {
                            Text(row.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.44))
                                .frame(width: 92, alignment: .leading)
                            Text(row.value)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.86))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        if row.id != rows.last?.id {
                            Divider().overlay(.white.opacity(0.05))
                        }
                    }
                }
                .songSurface()
            }
        }
    }

    @ViewBuilder
    private func works(_ detail: MusicRecordingDetail) -> some View {
        if !detail.works.isEmpty {
            SongSection(title: "Related Works") {
                VStack(spacing: 10) {
                    ForEach(detail.works, id: \.workMbid) { work in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(work.title)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white.opacity(0.92))
                            let metadata = workMetadata(work)
                            if !metadata.isEmpty {
                                Text(metadata.joined(separator: " · "))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.48))
                            }
                            ForEach(Array(work.credits.enumerated()), id: \.offset) { _, credit in
                                if let value = MusicSongPresentation.credit(credit) {
                                    Text(value)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .songSurface()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func albums(_ detail: MusicRecordingDetail) -> some View {
        if !detail.albums.isEmpty {
            SongSection(title: "Albums") {
                VStack(spacing: 0) {
                    ForEach(detail.albums) { album in
                        Button { openAlbum(album.ref) } label: {
                            HStack(spacing: 12) {
                                MediaArtwork(
                                    url: album.displayPosterURL,
                                    title: album.title,
                                    slot: .libraryRow,
                                    mediaType: "music",
                                    orientation: .square
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(album.title)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.92))
                                    if let subtitle = nonEmpty(album.subtitle) ?? nonEmpty(album.releaseDate) {
                                        Text(subtitle)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            .padding(12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open album \(album.title)")
                        if album.id != detail.albums.last?.id {
                            Divider().overlay(.white.opacity(0.05))
                        }
                    }
                }
                .songSurface()
            }
        }
    }

    @ViewBuilder
    private func releases(_ detail: MusicRecordingDetail) -> some View {
        if !detail.releases.isEmpty {
            SongSection(title: "Release Appearances") {
                VStack(spacing: 0) {
                    ForEach(detail.releases, id: \.releaseMbid) { release in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(release.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                            let metadata = releaseMetadata(release)
                            if !metadata.isEmpty {
                                Text(metadata.joined(separator: " · "))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            if let barcode = nonEmpty(release.barcode) {
                                Text("Barcode \(barcode)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        if release.releaseMbid != detail.releases.last?.releaseMbid {
                            Divider().overlay(.white.opacity(0.05))
                        }
                    }
                }
                .songSurface()
            }
        }
    }

    private func externalLink(_ detail: MusicRecordingDetail) -> some View {
        SongSection(title: "External") {
            Link(destination: MusicSongPresentation.musicBrainzURL(detail)) {
                HStack {
                    Label("View on MusicBrainz", systemImage: "music.note")
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens in the system browser")
            .songSurface()
        }
    }

    private func openAlbum(_ ref: MediaRef) {
        if ref.id == selection.album.id {
            dismiss()
        } else {
            selectedAlbum = ref
        }
    }

    private func factRows(_ detail: MusicRecordingDetail) -> [SongFact] {
        var rows: [SongFact] = []
        if let duration = MusicAlbumPresentation.duration(detail.lengthMs) {
            rows.append(SongFact(label: "Duration", value: duration))
        }
        if let disambiguation = nonEmpty(detail.disambiguation) {
            rows.append(SongFact(label: "Version", value: disambiguation))
        }
        if !detail.isrcs.isEmpty {
            rows.append(SongFact(label: "ISRC", value: detail.isrcs.joined(separator: ", ")))
        }
        if !detail.genres.isEmpty {
            rows.append(SongFact(label: "Genres", value: detail.genres.joined(separator: ", ")))
        }
        if let rating = MusicSongPresentation.rating(detail.rating) {
            let votes = detail.rating?.votesCount.map { " · \($0) votes" } ?? ""
            rows.append(SongFact(label: "Community", value: rating + votes))
        }
        return rows
    }

    private func workMetadata(_ work: MusicWorkRelationship) -> [String] {
        [
            nonEmpty(work.relationshipType)?.capitalized,
            work.iswcs.isEmpty ? nil : work.iswcs.joined(separator: ", "),
            nonEmpty(work.language),
        ].compactMap { $0 }
    }

    private func releaseMetadata(_ release: MusicRecordingAppearance) -> [String] {
        [
            nonEmpty(release.status),
            nonEmpty(release.date),
            MusicAlbumPresentation.countryName(release.country),
        ].compactMap { $0 }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private struct SongFact: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

private struct SongSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white.opacity(0.48))
            content
        }
    }
}

private extension View {
    func songSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return background(Color.white.opacity(0.028), in: shape)
            .overlay { shape.stroke(.white.opacity(0.045), lineWidth: 1) }
    }
}
