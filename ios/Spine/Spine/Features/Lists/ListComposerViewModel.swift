import Foundation
import Observation

enum ListComposerMode: Identifiable {
    case create(CustomListType)
    case edit(CustomListDetail)

    var id: String {
        switch self {
        case let .create(type):
            "create-\(type.rawValue)"
        case let .edit(list):
            "edit-\(list.id)"
        }
    }

    var title: String {
        switch self {
        case let .create(type): type == .people ? "New People List" : "New Media List"
        case .edit: "Edit List"
        }
    }

    var listType: CustomListType {
        switch self {
        case let .create(type): type
        case let .edit(list): list.listType
        }
    }
}

struct ListComposerDraft: Equatable {
    var listType: CustomListType
    var name: String
    var description: String
    var visibility: String
    var isRanked: Bool
    var items: [MediaSummary]
    var people: [PersonListEntry]

    static func empty(type: CustomListType) -> ListComposerDraft {
        ListComposerDraft(
            listType: type,
            name: "",
            description: "",
            visibility: "private",
            isRanked: false,
            items: [],
            people: []
        )
    }
}

enum ListComposerSavePhase: Equatable {
    case idle
    case reconciling
    case savingDetails
    case adding(current: Int, total: Int)
    case removing(current: Int, total: Int)
    case savingOrder
    case reloading
    case failed

    var label: String {
        switch self {
        case .idle:
            ""
        case .reconciling:
            "Checking saved changes…"
        case .savingDetails:
            "Saving list details…"
        case let .adding(current, total):
            "Adding \(current) of \(total)…"
        case let .removing(current, total):
            "Removing \(current) of \(total)…"
        case .savingOrder:
            "Saving item order…"
        case .reloading:
            "Finishing up…"
        case .failed:
            "Retry Save"
        }
    }
}

struct RemovedListComposerItem: Identifiable {
    let id = UUID()
    let item: MediaSummary
    let index: Int
}

struct RemovedListComposerPerson: Identifiable {
    let id = UUID()
    let person: PersonListEntry
    let index: Int
}

@MainActor
@Observable
final class ListComposerViewModel {
    var draft: ListComposerDraft
    var phase: ListComposerSavePhase = .idle
    var errorMessage: String?
    var failedItemTitles: [String] = []
    var removedItem: RemovedListComposerItem?
    var removedPerson: RemovedListComposerPerson?

    let mode: ListComposerMode

    private let initialDraft: ListComposerDraft
    private let listRepository: ListRepository
    private let onUnauthorized: () -> Void
    private var serverListID: Int?
    private var serverItemsByRefID: [String: MediaSummary]
    private var serverPeopleByEntryID: [Int: PersonListEntry]
    private var needsReconciliation = false
    private var nextTemporaryPersonEntryID = -1

    init(
        mode: ListComposerMode,
        initialItems: [MediaSummary] = [],
        listRepository: ListRepository,
        onUnauthorized: @escaping () -> Void
    ) {
        self.mode = mode
        self.listRepository = listRepository
        self.onUnauthorized = onUnauthorized

        switch mode {
        case let .create(type):
            var draft = ListComposerDraft.empty(type: type)
            if type == .media {
                draft.items = initialItems
            }
            self.draft = draft
            initialDraft = draft
            serverListID = nil
            serverItemsByRefID = [:]
            serverPeopleByEntryID = [:]
        case let .edit(list):
            let draft = ListComposerDraft(
                listType: list.listType,
                name: list.name,
                description: list.description,
                visibility: list.visibility == "public" ? "public" : "private",
                isRanked: list.isRanked,
                items: list.items,
                people: list.people
            )
            self.draft = draft
            initialDraft = draft
            serverListID = list.id
            serverItemsByRefID = Dictionary(uniqueKeysWithValues: list.items.map { ($0.ref.id, $0) })
            serverPeopleByEntryID = Dictionary(uniqueKeysWithValues: list.people.map { ($0.entryId, $0) })
        }
    }

    var isSaving: Bool {
        phase != .idle && phase != .failed
    }

    var isDirty: Bool {
        draft != initialDraft
    }

    var requiresDiscardConfirmation: Bool {
        isDirty || phase == .failed || needsReconciliation
    }

    var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (draft.listType == .people || !draft.items.isEmpty)
            && !isSaving
    }

    var primaryActionTitle: String {
        if phase == .failed {
            return "Retry Save"
        }
        switch mode {
        case .create: return "Create List"
        case .edit: return "Save Changes"
        }
    }

    var phaseLabel: String {
        if phase == .savingOrder, draft.listType == .people {
            return "Saving people order…"
        }
        return phase.label
    }

    var discardConfirmationMessage: String {
        draft.listType == .people
            ? "Your list details, people changes, and order have not been saved."
            : "Your list details, media selections, and order have not been saved."
    }

    func contains(_ item: MediaSummary) -> Bool {
        draft.items.contains { $0.ref.id == item.ref.id }
    }

    func toggleSelection(_ item: MediaSummary) {
        if let index = draft.items.firstIndex(where: { $0.ref.id == item.ref.id }) {
            draft.items.remove(at: index)
        } else {
            draft.items.append(item)
        }
        removedItem = nil
        removedPerson = nil
        clearFailure()
    }

    func removeItem(id: String) {
        guard let index = draft.items.firstIndex(where: { $0.id == id }) else { return }
        let item = draft.items.remove(at: index)
        removedItem = RemovedListComposerItem(item: item, index: index)
        removedPerson = nil
        clearFailure()
    }

    func undoRemoval() {
        guard let removedItem else { return }
        let index = min(removedItem.index, draft.items.endIndex)
        guard !contains(removedItem.item) else {
            self.removedItem = nil
            return
        }
        draft.items.insert(removedItem.item, at: index)
        self.removedItem = nil
    }

    func clearUndo() {
        removedItem = nil
        removedPerson = nil
    }

    /// Uses SwiftUI's move destination semantics: downward destinations refer to the pre-removal array.
    func moveItem(from source: Int, to destination: Int) {
        guard draft.items.indices.contains(source), destination >= 0, destination <= draft.items.count else { return }
        let item = draft.items.remove(at: source)
        let insertionIndex = destination > source ? destination - 1 : destination
        draft.items.insert(item, at: min(max(insertionIndex, 0), draft.items.endIndex))
        removedItem = nil
        removedPerson = nil
        clearFailure()
    }

    func removePerson(entryId: Int) {
        guard let index = draft.people.firstIndex(where: { $0.entryId == entryId }) else { return }
        let person = draft.people.remove(at: index)
        removedPerson = RemovedListComposerPerson(person: person, index: index)
        removedItem = nil
        clearFailure()
    }

    func contains(_ person: PersonSearchResult) -> Bool {
        draft.people.contains { $0.ref == person.ref }
    }

    func toggleSelection(_ person: PersonSearchResult) {
        if let index = draft.people.firstIndex(where: { $0.ref == person.ref }) {
            draft.people.remove(at: index)
        } else {
            draft.people.append(
                PersonListEntry(
                    entryId: nextTemporaryPersonEntryID,
                    personId: person.ref.id,
                    source: person.ref.source,
                    name: person.name,
                    profileUrl: person.profileUrl,
                    knownForDepartment: person.knownForDepartment,
                    position: nil,
                    dateAdded: ""
                )
            )
            nextTemporaryPersonEntryID -= 1
        }
        removedItem = nil
        removedPerson = nil
        clearFailure()
    }

    func undoPersonRemoval() {
        guard let removedPerson else { return }
        let index = min(removedPerson.index, draft.people.endIndex)
        guard !draft.people.contains(where: { $0.ref == removedPerson.person.ref }) else {
            self.removedPerson = nil
            return
        }
        draft.people.insert(removedPerson.person, at: index)
        self.removedPerson = nil
    }

    func movePerson(from source: Int, to destination: Int) {
        guard draft.people.indices.contains(source), destination >= 0, destination <= draft.people.count else { return }
        let person = draft.people.remove(at: source)
        let insertionIndex = destination > source ? destination - 1 : destination
        draft.people.insert(person, at: min(max(insertionIndex, 0), draft.people.endIndex))
        removedItem = nil
        removedPerson = nil
        clearFailure()
    }

    func save() async -> Int? {
        guard canSave else { return nil }
        errorMessage = nil
        failedItemTitles = []
        removedItem = nil
        removedPerson = nil

        do {
            if needsReconciliation, let listID = serverListID {
                phase = .reconciling
                try await reconcileServerEntries(listID: listID)
                needsReconciliation = false
            }

            phase = .savingDetails
            let listID = try await saveDetails()
            let saved: Bool
            switch draft.listType {
            case .media:
                saved = await saveMediaEntries(listID: listID)
            case .people:
                saved = await savePeopleEntries(listID: listID)
            }
            guard saved else { return nil }

            phase = .reloading
            try await reconcileServerEntries(listID: listID)
            needsReconciliation = false
            phase = .idle
            CustomListChange.post(listId: listID, listType: draft.listType)
            return listID
        } catch is CancellationError {
            phase = .idle
            return nil
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
            needsReconciliation = serverListID != nil
            handleUnauthorized(error)
            return nil
        }
    }

    private func saveDetails() async throws -> Int {
        let request = CustomListWriteRequest(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
            visibility: draft.visibility,
            isRanked: draft.isRanked,
            listType: serverListID == nil && draft.listType == .people ? .people : nil
        )

        if let serverListID {
            _ = try await listRepository.update(id: serverListID, request)
            CustomListChange.post(listId: serverListID, listType: draft.listType)
            return serverListID
        }

        let list = try await listRepository.create(request)
        serverListID = list.id
        needsReconciliation = true
        CustomListChange.post(listId: list.id, listType: draft.listType)
        return list.id
    }

    private func saveMediaEntries(listID: Int) async -> Bool {
        let desiredRefIDs = Set(draft.items.map(\.ref.id))
        let additions = draft.items.filter { serverItemsByRefID[$0.ref.id] == nil }
        var addFailures: [String] = []
        for (offset, item) in additions.enumerated() {
            phase = .adding(current: offset + 1, total: additions.count)
            do {
                let savedItem = try await listRepository.addItem(listId: listID, ref: item.ref)
                serverItemsByRefID[savedItem.ref.id] = savedItem
                replaceDraftItem(savedItem)
                CustomListChange.post(listId: listID, listType: .media)
            } catch {
                addFailures.append(item.title)
                handleUnauthorized(error)
            }
        }
        if !addFailures.isEmpty {
            fail(
                message: "Some media could not be added. Your list was kept so you can retry.",
                itemTitles: addFailures
            )
            return false
        }

        let removals = serverItemsByRefID.values.filter { !desiredRefIDs.contains($0.ref.id) }
        var removeFailures: [String] = []
        for (offset, item) in removals.enumerated() {
            phase = .removing(current: offset + 1, total: removals.count)
            guard let itemID = item.ref.itemId else {
                removeFailures.append(item.title)
                continue
            }
            do {
                try await listRepository.removeItem(listId: listID, itemId: itemID)
                serverItemsByRefID[item.ref.id] = nil
                CustomListChange.post(listId: listID, listType: .media)
            } catch {
                removeFailures.append(item.title)
                handleUnauthorized(error)
            }
        }
        if !removeFailures.isEmpty {
            fail(
                message: "Some media could not be removed. Retry to finish saving this list.",
                itemTitles: removeFailures
            )
            return false
        }

        let orderedItemIDs = draft.items.compactMap { serverItemsByRefID[$0.ref.id]?.ref.itemId }
        guard orderedItemIDs.count == draft.items.count else {
            fail(message: "Spine could not determine the saved order. Retry to reconcile the list.")
            return false
        }

        phase = .savingOrder
        do {
            _ = try await listRepository.reorderItems(listId: listID, itemIds: orderedItemIDs)
            CustomListChange.post(listId: listID, listType: .media)
            return true
        } catch {
            fail(message: error.localizedDescription)
            handleUnauthorized(error)
            return false
        }
    }

    private func savePeopleEntries(listID: Int) async -> Bool {
        let savedPeopleByRef = peopleByRef(serverPeopleByEntryID.values)
        let additions = draft.people.filter { savedPeopleByRef[$0.ref] == nil }
        var addFailures: [String] = []
        for (offset, person) in additions.enumerated() {
            phase = .adding(current: offset + 1, total: additions.count)
            do {
                let savedPerson = try await listRepository.addPerson(listId: listID, ref: person.ref)
                serverPeopleByEntryID[savedPerson.entryId] = savedPerson
                replaceDraftPerson(selectedRef: person.ref, with: savedPerson)
                CustomListChange.post(listId: listID, listType: .people)
            } catch {
                addFailures.append(person.name)
                handleUnauthorized(error)
            }
        }
        if !addFailures.isEmpty {
            fail(
                message: "Some people could not be added. Your list was kept so you can retry.",
                itemTitles: addFailures
            )
            return false
        }

        let desiredRefs = Set(draft.people.map(\.ref))
        let removals = serverPeopleByEntryID.values.filter { !desiredRefs.contains($0.ref) }
        var removeFailures: [String] = []
        for (offset, person) in removals.enumerated() {
            phase = .removing(current: offset + 1, total: removals.count)
            do {
                try await listRepository.removePerson(listId: listID, entryId: person.entryId)
                serverPeopleByEntryID[person.entryId] = nil
                CustomListChange.post(listId: listID, listType: .people)
            } catch {
                removeFailures.append(person.name)
                handleUnauthorized(error)
            }
        }
        if !removeFailures.isEmpty {
            fail(
                message: "Some people could not be removed. Retry to finish saving this list.",
                itemTitles: removeFailures
            )
            return false
        }

        let currentPeopleByRef = peopleByRef(serverPeopleByEntryID.values)
        let entryIDs = draft.people.compactMap { currentPeopleByRef[$0.ref]?.entryId }
        guard entryIDs.count == draft.people.count else {
            fail(message: "Spine could not determine the saved people order. Retry to reconcile the list.")
            return false
        }
        phase = .savingOrder
        do {
            _ = try await listRepository.reorderPeople(listId: listID, entryIds: entryIDs)
            CustomListChange.post(listId: listID, listType: .people)
            return true
        } catch {
            fail(message: error.localizedDescription)
            handleUnauthorized(error)
            return false
        }
    }

    private func reconcileServerEntries(listID: Int) async throws {
        switch draft.listType {
        case .media:
            try await reconcileServerItems(listID: listID)
        case .people:
            try await reconcileServerPeople(listID: listID)
        }
    }

    private func reconcileServerItems(listID: Int) async throws {
        _ = try await listRepository.detail(id: listID)
        var items: [MediaSummary] = []
        var page: String?
        repeat {
            let response = try await listRepository.items(
                listId: listID,
                page: page,
                filter: MediaFilterState()
            )
            let existingIDs = Set(items.map(\.ref.id))
            items += response.results.filter { !existingIDs.contains($0.ref.id) }
            page = APIPageCursor.nextPage(from: response.next)
        } while page != nil

        serverItemsByRefID = Dictionary(uniqueKeysWithValues: items.map { ($0.ref.id, $0) })
        draft.items = draft.items.map { serverItemsByRefID[$0.ref.id] ?? $0 }
    }

    private func reconcileServerPeople(listID: Int) async throws {
        _ = try await listRepository.detail(id: listID)
        var people: [PersonListEntry] = []
        var page: String?
        repeat {
            let response = try await listRepository.people(listId: listID, page: page)
            let existingIDs = Set(people.map(\.entryId))
            people += response.results.filter { !existingIDs.contains($0.entryId) }
            page = APIPageCursor.nextPage(from: response.next)
        } while page != nil

        serverPeopleByEntryID = Dictionary(uniqueKeysWithValues: people.map { ($0.entryId, $0) })
        let serverPeopleByRef = peopleByRef(people)
        draft.people = draft.people.map { serverPeopleByRef[$0.ref] ?? $0 }
    }

    private func replaceDraftItem(_ savedItem: MediaSummary) {
        guard let index = draft.items.firstIndex(where: { $0.ref.id == savedItem.ref.id }) else { return }
        draft.items[index] = savedItem
    }

    private func replaceDraftPerson(
        selectedRef: PersonRef,
        with savedPerson: PersonListEntry
    ) {
        guard let index = draft.people.firstIndex(where: { $0.ref == selectedRef }) else { return }
        if draft.people.indices.contains(where: {
            $0 != index && draft.people[$0].ref == savedPerson.ref
        }) {
            draft.people.remove(at: index)
        } else {
            draft.people[index] = savedPerson
        }
    }

    private func peopleByRef<S: Sequence>(_ people: S) -> [PersonRef: PersonListEntry]
    where S.Element == PersonListEntry {
        Dictionary(people.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func fail(message: String, itemTitles: [String] = []) {
        errorMessage = message
        failedItemTitles = itemTitles
        phase = .failed
        needsReconciliation = serverListID != nil
    }

    private func clearFailure() {
        guard phase == .failed else { return }
        phase = .idle
        errorMessage = nil
        failedItemTitles = []
    }

    private func handleUnauthorized(_ error: Error) {
        if case APIError.unauthorized = error {
            onUnauthorized()
        }
    }
}
