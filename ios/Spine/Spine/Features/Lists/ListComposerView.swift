import SwiftUI

struct ListComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ListComposerViewModel
    @State private var presentedSheet: ListComposerSheet?
    @State private var showsDiscardConfirmation = false
    @FocusState private var focusedField: Field?

    private let mediaRepository: MediaRepository
    private let peopleRepository: PeopleRepository
    private let onUnauthorized: () -> Void
    private let onSaved: (Int, ListComposerDraft) -> Void

    private enum Field: Hashable {
        case name
        case description
    }

    init(
        mode: ListComposerMode,
        initialItems: [MediaSummary] = [],
        listRepository: ListRepository,
        mediaRepository: MediaRepository,
        peopleRepository: PeopleRepository,
        onUnauthorized: @escaping () -> Void,
        onSaved: @escaping (Int, ListComposerDraft) -> Void
    ) {
        _viewModel = State(initialValue: ListComposerViewModel(
            mode: mode,
            initialItems: initialItems,
            listRepository: listRepository,
            onUnauthorized: onUnauthorized
        ))
        self.mediaRepository = mediaRepository
        self.peopleRepository = peopleRepository
        self.onUnauthorized = onUnauthorized
        self.onSaved = onSaved
    }

    var body: some View {
        ZStack(alignment: .top) {
            SpinePageBackground()

            VStack(spacing: 0) {
                topBar

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        detailsSection
                        settingsSection
                        itemsSection
                        errorSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
                .disabled(viewModel.isSaving)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if focusedField == nil {
                actionFooter
            }
        }
        .overlay(alignment: .bottom) {
            if let removedItem = viewModel.removedItem {
                undoBanner(removedItem)
                    .padding(.horizontal, 16)
                    .padding(.bottom, focusedField == nil ? 92 : 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let removedPerson = viewModel.removedPerson {
                undoBanner(removedPerson)
                    .padding(.horizontal, 16)
                    .padding(.bottom, focusedField == nil ? 92 : 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: removedEntryID)
        .fullScreenCover(item: $presentedSheet) { sheet in
            switch sheet {
            case .mediaPicker:
                ListMediaPickerView(
                    viewModel: viewModel,
                    mediaRepository: mediaRepository,
                    onUnauthorized: onUnauthorized
                )
            case .peoplePicker:
                ListPeoplePickerView(
                    viewModel: viewModel,
                    peopleRepository: peopleRepository,
                    onUnauthorized: onUnauthorized
                )
            }
        }
        .interactiveDismissDisabled(viewModel.requiresDiscardConfirmation || viewModel.isSaving)
        .alert("Discard Changes?", isPresented: $showsDiscardConfirmation) {
            Button("Discard Changes", role: .destructive) {
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(viewModel.discardConfirmationMessage)
        }
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button(action: requestClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.34), in: Circle())
                    .overlay { Circle().stroke(.white.opacity(0.08)) }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSaving)
            .accessibilityLabel("Close list editor")

            Text(viewModel.mode.title)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var detailsSection: some View {
        composerSurface {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name", text: $viewModel.draft.name)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .description }

                Divider().overlay(.white.opacity(0.1))

                TextField("Description", text: $viewModel.draft.description, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .description)
                    .lineLimit(3...6)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }

    private var settingsSection: some View {
        composerSurface {
            HStack(spacing: 12) {
                Text("Visibility")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))

                Spacer(minLength: 8)

                Picker("Visibility", selection: $viewModel.draft.visibility) {
                    Text("Public").tag("public")
                    Text("Private").tag("private")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.white)
            }

            Divider().overlay(.white.opacity(0.1))

            Toggle("Ranked", isOn: $viewModel.draft.isRanked)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .tint(.white)
        }
    }

    @ViewBuilder
    private var itemsSection: some View {
        if viewModel.draft.listType == .people {
            peopleSection
        } else {
            mediaItemsSection
        }
    }

    private var mediaItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Items")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(viewModel.draft.items.count) selected")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.46))
                }

                Spacer()

                Button(action: presentMediaPicker) {
                    Label("Add Media", systemImage: "plus")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)

            if viewModel.draft.items.isEmpty {
                emptyItemsState
            } else {
                ListComposerReorderRows(viewModel: viewModel)
            }
        }
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your People")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(viewModel.draft.people.count) selected")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.46))
                }

                Spacer()

                Button(action: presentPeoplePicker) {
                    Label("Add People", systemImage: "plus")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)

            if viewModel.draft.people.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.54))
                    Text("No people added yet")
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Search for people or add them from any person page.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 30)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.07))
                }
            } else {
                ListComposerPeopleReorderRows(viewModel: viewModel)
            }
        }
    }

    private var emptyItemsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.54))
            Text("No media added yet")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 30)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.07))
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = viewModel.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label("Could not finish saving", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                Text(error)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                if !viewModel.failedItemTitles.isEmpty {
                    Text(viewModel.failedItemTitles.joined(separator: ", "))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.64))
                }
            }
            .foregroundStyle(.red.opacity(0.94))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var actionFooter: some View {
        VStack(spacing: 7) {
            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 10) {
                    if viewModel.isSaving {
                        ProgressView().tint(.black)
                    }
                    Text(viewModel.isSaving ? viewModel.phaseLabel : viewModel.primaryActionTitle)
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                }
                .spineContentTransition(value: viewModel.isSaving)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(viewModel.canSave ? .white : .white.opacity(0.28), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSave)

            if viewModel.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Add a list name to continue")
            } else if viewModel.draft.listType == .media, viewModel.draft.items.isEmpty {
                Text("Add at least one media item to continue")
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.48))
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private func undoBanner(_ removedItem: RemovedListComposerItem) -> some View {
        HStack(spacing: 12) {
            Text("Removed \(removedItem.item.title)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo") {
                viewModel.undoRemoval()
            }
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 15)
        .frame(height: 48)
        .background(.black.opacity(0.94), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.14)) }
        .task(id: removedItem.id) {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            viewModel.clearUndo()
        }
    }

    private func undoBanner(_ removedPerson: RemovedListComposerPerson) -> some View {
        HStack(spacing: 12) {
            Text("Removed \(removedPerson.person.name)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo") {
                viewModel.undoPersonRemoval()
            }
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 15)
        .frame(height: 48)
        .background(.black.opacity(0.94), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.14)) }
        .task(id: removedPerson.id) {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            viewModel.clearUndo()
        }
    }

    private var removedEntryID: UUID? {
        viewModel.removedItem?.id ?? viewModel.removedPerson?.id
    }

    private func composerSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.09))
            }
    }

    private func requestClose() {
        guard !viewModel.isSaving else { return }
        if viewModel.requiresDiscardConfirmation {
            showsDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func save() async {
        if let listID = await viewModel.save() {
            onSaved(listID, viewModel.draft)
            dismiss()
        }
    }

    private func presentMediaPicker() {
        focusedField = nil
        presentedSheet = .mediaPicker
    }

    private func presentPeoplePicker() {
        focusedField = nil
        presentedSheet = .peoplePicker
    }
}

private enum ListComposerSheet: Identifiable {
    case mediaPicker
    case peoplePicker

    var id: String {
        switch self {
        case .mediaPicker: "media-picker"
        case .peoplePicker: "people-picker"
        }
    }
}

private struct ListComposerReorderRows: View {
    let viewModel: ListComposerViewModel

    @State private var draggedItemID: String?
    @State private var sourceIndex: Int?
    @State private var dragTranslation = 0.0
    @State private var targetIndex: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(viewModel.draft.items.enumerated()), id: \.element.id) { index, item in
                ListComposerItemRow(
                    item: item,
                    rank: viewModel.draft.isRanked ? index + 1 : nil,
                    canMoveUp: index > 0,
                    canMoveDown: index < viewModel.draft.items.count - 1,
                    onRemove: { viewModel.removeItem(id: item.id) },
                    onMoveUp: { viewModel.moveItem(from: index, to: index - 1) },
                    onMoveDown: { viewModel.moveItem(from: index, to: index + 2) },
                    onReorderChanged: { value in handleChanged(value, item: item, at: index) },
                    onReorderEnded: { value in handleEnded(value) }
                )
                .frame(height: ListComposerReorderMath.rowHeight)
                .offset(
                    y: Double(index) * ListComposerReorderMath.rowHeight
                        + ListComposerReorderMath.rowOffset(
                            for: index,
                            sourceIndex: sourceIndex,
                            targetIndex: targetIndex,
                            activeTranslation: dragTranslation
                        )
                )
                .zIndex(draggedItemID == item.id ? 10 : 0)
                .shadow(color: draggedItemID == item.id ? .black.opacity(0.34) : .clear, radius: 12, y: 6)
                .animation(draggedItemID == item.id ? nil : .snappy(duration: 0.14), value: targetIndex)
            }
        }
        .frame(
            height: Double(viewModel.draft.items.count) * ListComposerReorderMath.rowHeight,
            alignment: .topLeading
        )
        .disabled(viewModel.isSaving)
    }

    private func handleChanged(_ value: DragGesture.Value, item: MediaSummary, at index: Int) {
        if draggedItemID == nil {
            draggedItemID = item.id
            sourceIndex = index
            targetIndex = index
            UIImpactFeedbackGenerator(style: .light).prepare()
        }
        guard let sourceIndex else { return }
        dragTranslation = ListComposerReorderMath.clampedTranslation(
            Double(value.translation.height),
            sourceIndex: sourceIndex,
            count: viewModel.draft.items.count
        )
        let nextTarget = ListComposerReorderMath.targetIndex(
            from: sourceIndex,
            translation: dragTranslation,
            count: viewModel.draft.items.count
        )
        if nextTarget != targetIndex {
            targetIndex = nextTarget
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func handleEnded(_ value: DragGesture.Value) {
        guard let sourceIndex else { reset(); return }
        let destination = ListComposerReorderMath.destination(
            from: sourceIndex,
            translation: Double(value.translation.height),
            count: viewModel.draft.items.count
        )
        reset()
        guard destination != sourceIndex else { return }
        viewModel.moveItem(from: sourceIndex, to: destination)
    }

    private func reset() {
        draggedItemID = nil
        sourceIndex = nil
        dragTranslation = 0
        targetIndex = nil
    }
}

private struct ListComposerPeopleReorderRows: View {
    let viewModel: ListComposerViewModel

    @State private var draggedEntryID: Int?
    @State private var sourceIndex: Int?
    @State private var dragTranslation = 0.0
    @State private var targetIndex: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(viewModel.draft.people.enumerated()), id: \.element.entryId) { index, person in
                ListComposerPersonRow(
                    person: person,
                    rank: viewModel.draft.isRanked ? index + 1 : nil,
                    canMoveUp: index > 0,
                    canMoveDown: index < viewModel.draft.people.count - 1,
                    onRemove: { viewModel.removePerson(entryId: person.entryId) },
                    onMoveUp: { viewModel.movePerson(from: index, to: index - 1) },
                    onMoveDown: { viewModel.movePerson(from: index, to: index + 2) },
                    onReorderChanged: { value in handleChanged(value, person: person, at: index) },
                    onReorderEnded: { value in handleEnded(value) }
                )
                .frame(height: ListComposerReorderMath.rowHeight)
                .offset(
                    y: Double(index) * ListComposerReorderMath.rowHeight
                        + ListComposerReorderMath.rowOffset(
                            for: index,
                            sourceIndex: sourceIndex,
                            targetIndex: targetIndex,
                            activeTranslation: dragTranslation
                        )
                )
                .zIndex(draggedEntryID == person.entryId ? 10 : 0)
                .shadow(color: draggedEntryID == person.entryId ? .black.opacity(0.34) : .clear, radius: 12, y: 6)
                .animation(draggedEntryID == person.entryId ? nil : .snappy(duration: 0.14), value: targetIndex)
            }
        }
        .frame(
            height: Double(viewModel.draft.people.count) * ListComposerReorderMath.rowHeight,
            alignment: .topLeading
        )
        .disabled(viewModel.isSaving)
    }

    private func handleChanged(_ value: DragGesture.Value, person: PersonListEntry, at index: Int) {
        if draggedEntryID == nil {
            draggedEntryID = person.entryId
            sourceIndex = index
            targetIndex = index
            UIImpactFeedbackGenerator(style: .light).prepare()
        }
        guard let sourceIndex else { return }
        dragTranslation = ListComposerReorderMath.clampedTranslation(
            Double(value.translation.height),
            sourceIndex: sourceIndex,
            count: viewModel.draft.people.count
        )
        let nextTarget = ListComposerReorderMath.targetIndex(
            from: sourceIndex,
            translation: dragTranslation,
            count: viewModel.draft.people.count
        )
        if nextTarget != targetIndex {
            targetIndex = nextTarget
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func handleEnded(_ value: DragGesture.Value) {
        guard let sourceIndex else { reset(); return }
        let destination = ListComposerReorderMath.destination(
            from: sourceIndex,
            translation: Double(value.translation.height),
            count: viewModel.draft.people.count
        )
        reset()
        guard destination != sourceIndex else { return }
        viewModel.movePerson(from: sourceIndex, to: destination)
    }

    private func reset() {
        draggedEntryID = nil
        sourceIndex = nil
        dragTranslation = 0
        targetIndex = nil
    }
}

private struct ListComposerPersonRow: View {
    let person: PersonListEntry
    let rank: Int?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onRemove: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onReorderChanged: (DragGesture.Value) -> Void
    let onReorderEnded: (DragGesture.Value) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let rank {
                Text("#\(rank)")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.56))
                    .frame(width: 30)
            }

            PersonArtwork(urlString: person.profileUrl, name: person.name, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(person.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(2)
                if let department = person.knownForDepartment {
                    Text(department)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.82))
                    .frame(width: 38, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(person.name)")

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.52))
                .frame(width: 42, height: 44)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged(onReorderChanged)
                        .onEnded(onReorderEnded)
                )
                .accessibilityLabel("Reorder \(person.name)")
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.075))
        }
        .accessibilityAction(named: "Move Up") {
            if canMoveUp { onMoveUp() }
        }
        .accessibilityAction(named: "Move Down") {
            if canMoveDown { onMoveDown() }
        }
    }
}

private struct ListComposerItemRow: View {
    let item: MediaSummary
    let rank: Int?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onRemove: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onReorderChanged: (DragGesture.Value) -> Void
    let onReorderEnded: (DragGesture.Value) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let rank {
                Text("#\(rank)")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.56))
                    .frame(width: 30)
            }

            MediaArtwork(
                url: item.displayPosterURL,
                title: item.title,
                slot: .diaryRow,
                mediaType: item.ref.mediaType,
                orientation: item.posterOrientation
            )
            .scaleEffect(0.75)
            .frame(width: 42, height: 63)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(2)
                if let subtitle = item.subtitle ?? item.releaseDate {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.82))
                    .frame(width: 38, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.title)")

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.52))
                .frame(width: 42, height: 44)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged(onReorderChanged)
                        .onEnded(onReorderEnded)
                )
                .accessibilityLabel("Reorder \(item.title)")
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.075))
        }
        .accessibilityAction(named: "Move Up") {
            if canMoveUp { onMoveUp() }
        }
        .accessibilityAction(named: "Move Down") {
            if canMoveDown { onMoveDown() }
        }
    }
}

enum ListComposerReorderMath {
    static let rowHeight = 79.0

    static func clampedTranslation(_ value: Double, sourceIndex: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        return min(
            max(value, -Double(sourceIndex) * rowHeight),
            Double(count - sourceIndex - 1) * rowHeight
        )
    }

    static func targetIndex(from sourceIndex: Int, translation: Double, count: Int) -> Int {
        guard count > 1 else { return sourceIndex }
        let clamped = clampedTranslation(translation, sourceIndex: sourceIndex, count: count)
        return min(max(sourceIndex + Int((clamped / rowHeight).rounded()), 0), count - 1)
    }

    static func destination(from sourceIndex: Int, translation: Double, count: Int) -> Int {
        let target = targetIndex(from: sourceIndex, translation: translation, count: count)
        return target > sourceIndex ? target + 1 : target
    }

    static func rowOffset(
        for index: Int,
        sourceIndex: Int?,
        targetIndex: Int?,
        activeTranslation: Double
    ) -> Double {
        guard let sourceIndex, let targetIndex else { return 0 }
        if index == sourceIndex { return activeTranslation }
        if sourceIndex < targetIndex, index > sourceIndex, index <= targetIndex { return -rowHeight }
        if targetIndex < sourceIndex, index >= targetIndex, index < sourceIndex { return rowHeight }
        return 0
    }
}
