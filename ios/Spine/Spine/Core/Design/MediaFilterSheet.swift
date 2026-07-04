import SwiftUI

struct MediaFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: MediaFilterState
    let scope: MediaFilterScope
    let options: MediaFilterOptionsResponse
    let mediaTypes: [String]
    let showsTagFilter: Bool
    let onApply: () -> Void

    @State private var draft: MediaFilterState
    @State private var isGenreExpanded = false
    @State private var isLanguageExpanded = false

    init(
        filter: Binding<MediaFilterState>,
        scope: MediaFilterScope,
        options: MediaFilterOptionsResponse,
        mediaTypes: [String],
        showsTagFilter: Bool = true,
        onApply: @escaping () -> Void
    ) {
        _filter = filter
        self.scope = scope
        self.options = options
        self.mediaTypes = mediaTypes
        self.showsTagFilter = showsTagFilter
        self.onApply = onApply
        _draft = State(initialValue: filter.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                sortSection
                contextSection
                yearSection
                releaseSection
                choiceSection("Genre", choices: options.genres, include: \.genres, exclude: \.excludedGenres)
                choiceSection("Language", choices: options.languages, include: \.languages, exclude: \.excludedLanguages)
                ratingSection
                diarySection
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        filter = draft
                        onApply()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset", role: .destructive) {
                        draft = resetFilter
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    private var sortSection: some View {
        Section("Sort") {
            Picker("Direction", selection: directionBinding) {
                ForEach(MediaFilterDirection.allCases) { direction in
                    Text(direction.label).tag(direction)
                }
            }
            .pickerStyle(.segmented)
            .disabled(draft.sort == nil)

            Picker("Sort by", selection: sortBinding) {
                Text("Default").tag(String?.none)
                ForEach(sortChoices) { choice in
                    Text(choice.label).tag(Optional(choice.value))
                }
            }
        }
    }

    @ViewBuilder
    private var contextSection: some View {
        if showsMediaType || showsStatus {
            Section("Context") {
                if showsMediaType {
                    Picker("Media Type", selection: mediaTypeBinding) {
                        Text("All").tag(String?.none)
                        ForEach(mediaTypes, id: \.self) { type in
                            Text(MediaTypeTheme.theme(for: type).displayName).tag(Optional(type))
                        }
                    }
                }

                if showsStatus {
                    Picker("Status", selection: statusBinding) {
                        Text("All").tag(String?.none)
                        ForEach(APIConstants.statusChoices, id: \.self) { status in
                            Text(status).tag(Optional(status))
                        }
                    }
                }
            }
        }
    }

    private var yearSection: some View {
        Section("Year") {
            Picker("Exact Year", selection: yearBinding) {
                Text("Any").tag(Int?.none)
                ForEach(options.years, id: \.self) { year in
                    Text(String(year)).tag(Optional(year))
                }
            }
            .disabled(options.years.isEmpty)
        }
    }

    private var releaseSection: some View {
        Section("Release") {
            Picker("Status", selection: releaseStatusBinding) {
                Text("Any").tag(String?.none)
                Text("Released").tag(Optional("released"))
                Text("Unreleased").tag(Optional("unreleased"))
            }

            Picker("Length", selection: lengthBinding) {
                Text("Any").tag(String?.none)
                Text("Feature Length").tag(Optional("feature"))
                Text("Short Film").tag(Optional("short"))
            }
        }
    }

    private func choiceSection(
        _ title: String,
        choices: [FilterChoice],
        include includeKeyPath: WritableKeyPath<MediaFilterState, [String]>,
        exclude excludeKeyPath: WritableKeyPath<MediaFilterState, [String]>
    ) -> some View {
        Section(title) {
            DisclosureGroup(isExpanded: expandedBinding(for: title)) {
                if choices.isEmpty {
                    Text("No options")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(choices) { choice in
                        Button {
                            draft.cycleFacet(choice.value, include: includeKeyPath, exclude: excludeKeyPath)
                        } label: {
                            HStack {
                                Text(choice.label)
                                Spacer()
                                if draft[keyPath: includeKeyPath].contains(choice.value) {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                } else if draft[keyPath: excludeKeyPath].contains(choice.value) {
                                    Image(systemName: "nosign")
                                        .font(.body.weight(.semibold))
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            } label: {
                Text(compactTitle(
                    title,
                    includeCount: draft[keyPath: includeKeyPath].count,
                    excludeCount: draft[keyPath: excludeKeyPath].count
                ))
            }
        }
    }

    private var ratingSection: some View {
        Section("Rating") {
            TextField("Minimum", text: decimalText(\.ratingMin))
                .keyboardType(.decimalPad)
            TextField("Maximum", text: decimalText(\.ratingMax))
                .keyboardType(.decimalPad)
        }
    }

    @ViewBuilder
    private var diarySection: some View {
        if showsDiaryFilters {
            Section("Diary") {
                if showsTagFilter {
                    TextField("Tag", text: tagBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle("Has Review", isOn: $draft.hasReview)
                Toggle("Liked", isOn: $draft.liked)
                OptionalDatePicker("Watched From", date: $draft.watchedFrom)
                OptionalDatePicker("Watched To", date: $draft.watchedTo)
            }
        }
    }

    private var sortChoices: [FilterChoice] {
        let choices = options.sorts.isEmpty ? defaultSortChoices : options.sorts
        return choices.filter { choice in
            guard MediaFilterSort(rawValue: choice.value) != nil else { return false }
            switch scope {
            case .tracking:
                return choice.value != MediaFilterSort.consumedAt.rawValue && choice.value != MediaFilterSort.dateAdded.rawValue
            case .diary:
                return choice.value != MediaFilterSort.dateAdded.rawValue
            case .list:
                return choice.value != MediaFilterSort.consumedAt.rawValue
            case .person:
                return choice.value != MediaFilterSort.yourRating.rawValue && choice.value != MediaFilterSort.averageRating.rawValue
            }
        }
    }

    private var defaultSortChoices: [FilterChoice] {
        MediaFilterSort.allCases.map { FilterChoice(value: $0.rawValue, label: $0.label) }
    }

    private var resetFilter: MediaFilterState {
        switch scope {
        case .tracking:
            return MediaFilterState()
        case .diary:
            return MediaFilterState()
        case .list:
            return MediaFilterState()
        case .person:
            return MediaFilterState()
        }
    }

    private var showsMediaType: Bool {
        switch scope {
        case .tracking:
            false
        case .diary, .list, .person:
            true
        }
    }

    private var showsStatus: Bool {
        switch scope {
        case .tracking, .list:
            true
        case .diary, .person:
            false
        }
    }

    private var showsDiaryFilters: Bool {
        if case .diary = scope {
            return true
        }
        return false
    }

    private var sortBinding: Binding<String?> {
        Binding(
            get: { draft.sort?.rawValue },
            set: { value in
                draft.sort = value.flatMap(MediaFilterSort.init(rawValue:))
                if draft.sort != nil, draft.direction == nil {
                    draft.direction = .desc
                }
            }
        )
    }

    private var directionBinding: Binding<MediaFilterDirection> {
        Binding(
            get: { draft.direction ?? .desc },
            set: { draft.direction = $0 }
        )
    }

    private var mediaTypeBinding: Binding<String?> {
        Binding(get: { draft.mediaType }, set: { draft.mediaType = $0 })
    }

    private var statusBinding: Binding<String?> {
        Binding(get: { draft.status }, set: { draft.status = $0 })
    }

    private var yearBinding: Binding<Int?> {
        Binding(get: { draft.year }, set: { draft.year = $0 })
    }

    private var releaseStatusBinding: Binding<String?> {
        Binding(get: { draft.releaseStatus }, set: { draft.releaseStatus = $0 })
    }

    private var lengthBinding: Binding<String?> {
        Binding(get: { draft.length }, set: { draft.length = $0 })
    }

    private var tagBinding: Binding<String> {
        Binding(
            get: { draft.tag ?? "" },
            set: { draft.tag = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    private func decimalText(_ keyPath: WritableKeyPath<MediaFilterState, Decimal?>) -> Binding<String> {
        Binding(
            get: {
                draft[keyPath: keyPath].map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
            },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                draft[keyPath: keyPath] = trimmed.isEmpty ? nil : Decimal(string: trimmed)
            }
        )
    }

    private func expandedBinding(for title: String) -> Binding<Bool> {
        title == "Genre" ? $isGenreExpanded : $isLanguageExpanded
    }

    private func compactTitle(_ title: String, includeCount: Int, excludeCount: Int) -> String {
        let count = includeCount + excludeCount
        guard count > 0 else { return title }
        return excludeCount > 0 ? "\(title) (-\(excludeCount))" : "\(title) (\(count))"
    }
}

private struct OptionalDatePicker: View {
    let title: String
    @Binding var date: Date?

    init(_ title: String, date: Binding<Date?>) {
        self.title = title
        _date = date
    }

    var body: some View {
        Toggle(isOn: isEnabled) {
            Text(title)
        }
        if date != nil {
            DatePicker(title, selection: selectedDate, displayedComponents: .date)
                .labelsHidden()
        }
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { date != nil },
            set: { enabled in
                date = enabled ? Date() : nil
            }
        )
    }

    private var selectedDate: Binding<Date> {
        Binding(
            get: { date ?? Date() },
            set: { date = $0 }
        )
    }
}
