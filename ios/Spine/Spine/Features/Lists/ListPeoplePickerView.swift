import Observation
import SwiftUI

@MainActor
@Observable
final class PeopleSearchViewModel {
    var results: [PersonSearchResult] = []
    var unavailableSources: [String] = []
    var isLoading = false
    var errorMessage: String?

    private let peopleRepository: PeopleRepository
    private let onUnauthorized: () -> Void
    private var searchID = 0

    init(
        peopleRepository: PeopleRepository,
        onUnauthorized: @escaping () -> Void
    ) {
        self.peopleRepository = peopleRepository
        self.onUnauthorized = onUnauthorized
    }

    func clear() {
        searchID += 1
        results = []
        unavailableSources = []
        errorMessage = nil
        isLoading = false
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchID += 1
        let currentSearchID = searchID

        guard !trimmed.isEmpty else {
            clear()
            return
        }

        isLoading = true
        errorMessage = nil
        unavailableSources = []
        defer {
            if currentSearchID == searchID {
                isLoading = false
            }
        }

        do {
            let response = try await peopleRepository.search(query: trimmed)
            guard currentSearchID == searchID else { return }
            var seen = Set<PersonRef>()
            results = response.results.filter { seen.insert($0.ref).inserted }
            unavailableSources = response.unavailableSources
        } catch is CancellationError {
            return
        } catch {
            guard currentSearchID == searchID else { return }
            errorMessage = error.localizedDescription
            if case APIError.unauthorized = error {
                onUnauthorized()
            }
        }
    }
}

struct ListPeoplePickerView: View {
    @Environment(\.dismiss) private var dismiss

    private let viewModel: ListComposerViewModel
    @State private var searchViewModel: PeopleSearchViewModel
    @State private var searchText = ""

    init(
        viewModel: ListComposerViewModel,
        peopleRepository: PeopleRepository,
        onUnauthorized: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        _searchViewModel = State(initialValue: PeopleSearchViewModel(
            peopleRepository: peopleRepository,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SpinePageBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        if !searchViewModel.unavailableSources.isEmpty {
                            unavailableSourcesWarning
                        }

                        resultsContent
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, minHeight: 440, alignment: .top)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Add People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done · \(viewModel.draft.people.count)") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .accessibilityLabel(
                        "Done adding people, \(viewModel.draft.people.count) selected"
                    )
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search people"
            )
            .task(id: searchText) {
                await searchAfterDebounce()
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var resultsContent: some View {
        if let error = searchViewModel.errorMessage {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "Search failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                Button("Retry") {
                    Task { await searchViewModel.search(searchText) }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: 420)
        } else if searchViewModel.isLoading, searchViewModel.results.isEmpty {
            ProgressView("Searching…")
                .tint(.white)
                .frame(maxWidth: .infinity, minHeight: 420)
        } else if !searchViewModel.results.isEmpty {
            peopleRows
        } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Search People",
                systemImage: "person.crop.circle.badge.plus",
                description: Text("Enter a name to add people to this list.")
            )
            .frame(minHeight: 420)
        } else {
            ContentUnavailableView(
                "No people found",
                systemImage: "magnifyingglass",
                description: Text("Try another name.")
            )
            .frame(minHeight: 420)
        }
    }

    private var peopleRows: some View {
        LazyVStack(spacing: 0) {
            if searchViewModel.isLoading {
                ProgressView()
                    .tint(.white)
                    .padding(.vertical, 12)
                    .accessibilityLabel("Updating search results")
            }

            ForEach(searchViewModel.results) { person in
                Button {
                    viewModel.toggleSelection(person)
                } label: {
                    HStack(spacing: 13) {
                        PersonArtwork(
                            urlString: person.profileUrl,
                            name: person.name,
                            size: 52
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(person.name)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            Text(
                                [person.knownForDepartment, person.ref.sourceDisplayName]
                                    .compactMap { $0 }
                                    .joined(separator: " · ")
                            )
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Image(
                            systemName: viewModel.contains(person)
                                ? "checkmark.circle.fill"
                                : "plus.circle"
                        )
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(
                            viewModel.contains(person) ? .green : .white.opacity(0.72)
                        )
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(viewModel.contains(person) ? "Remove" : "Add") \(person.name) from \(person.ref.sourceDisplayName)"
                )

                if person.id != searchViewModel.results.last?.id {
                    Divider()
                        .overlay(.white.opacity(0.08))
                        .padding(.leading, 76)
                }
            }
        }
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08))
        }
    }

    private var unavailableSourcesWarning: some View {
        Label(
            "Some sources could not be searched: \(searchViewModel.unavailableSources.joined(separator: ", ")).",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.yellow.opacity(0.9))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("list-people-picker.partial-warning")
    }

    private func searchAfterDebounce() async {
        do {
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
        } catch {
            return
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchViewModel.clear()
            return
        }
        await searchViewModel.search(trimmed)
    }
}
