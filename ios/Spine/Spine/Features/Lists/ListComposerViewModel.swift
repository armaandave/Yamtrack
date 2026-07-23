import Foundation
import Observation

enum ListComposerMode: Identifiable {
    case create
    case edit(CustomListDetail)

    var id: String {
        switch self {
        case .create:
            "create"
        case let .edit(list):
            "edit-\(list.id)"
        }
    }

    var title: String {
        switch self {
        case .create: "New List"
        case .edit: "Edit List"
        }
    }
}

struct ListComposerDraft: Equatable {
    var name: String
    var description: String
    var visibility: String
    var isRanked: Bool
    var items: [MediaSummary]

    static let empty = ListComposerDraft(
        name: "",
        description: "",
        visibility: "private",
        isRanked: false,
        items: []
    )
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

@MainActor
@Observable
final class ListComposerViewModel {
    var draft: ListComposerDraft
    var phase: ListComposerSavePhase = .idle
    var errorMessage: String?
    var failedItemTitles: [String] = []
    var removedItem: RemovedListComposerItem?

    let mode: ListComposerMode

    private let initialDraft: ListComposerDraft
    private let listRepository: ListRepository
    private let onUnauthorized: () -> Void
    private var serverListID: Int?
    private var serverItemsByRefID: [String: MediaSummary]
    private var needsReconciliation = false

    init(
        mode: ListComposerMode,
        listRepository: ListRepository,
        onUnauthorized: @escaping () -> Void
    ) {
        self.mode = mode
        self.listRepository = listRepository
        self.onUnauthorized = onUnauthorized

        switch mode {
        case .create:
            let draft = ListComposerDraft.empty
            self.draft = draft
            initialDraft = draft
            serverListID = nil
            serverItemsByRefID = [:]
        case let .edit(list):
            let draft = ListComposerDraft(
                name: list.name,
                description: list.description,
                visibility: list.visibility == "public" ? "public" : "private",
                isRanked: list.isRanked,
                items: list.items
            )
            self.draft = draft
            initialDraft = draft
            serverListID = list.id
            serverItemsByRefID = Dictionary(uniqueKeysWithValues: list.items.map { ($0.ref.id, $0) })
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
            && !draft.items.isEmpty
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
        clearFailure()
    }

    func removeItem(id: String) {
        guard let index = draft.items.firstIndex(where: { $0.id == id }) else { return }
        let item = draft.items.remove(at: index)
        removedItem = RemovedListComposerItem(item: item, index: index)
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
    }

    /// Uses SwiftUI's move destination semantics: downward destinations refer to the pre-removal array.
    func moveItem(from source: Int, to destination: Int) {
        guard draft.items.indices.contains(source), destination >= 0, destination <= draft.items.count else { return }
        let item = draft.items.remove(at: source)
        let insertionIndex = destination > source ? destination - 1 : destination
        draft.items.insert(item, at: min(max(insertionIndex, 0), draft.items.endIndex))
        removedItem = nil
        clearFailure()
    }

    func save() async -> Int? {
        guard canSave else { return nil }
        errorMessage = nil
        failedItemTitles = []
        removedItem = nil

        do {
            if needsReconciliation, let listID = serverListID {
                phase = .reconciling
                try await reconcileServerItems(listID: listID)
                needsReconciliation = false
            }

            phase = .savingDetails
            let listID = try await saveDetails()

            let desiredRefIDs = Set(draft.items.map(\.ref.id))
            let additions = draft.items.filter { serverItemsByRefID[$0.ref.id] == nil }
            var addFailures: [String] = []
            for (offset, item) in additions.enumerated() {
                phase = .adding(current: offset + 1, total: additions.count)
                do {
                    let savedItem = try await listRepository.addItem(listId: listID, ref: item.ref)
                    serverItemsByRefID[savedItem.ref.id] = savedItem
                    replaceDraftItem(savedItem)
                } catch {
                    addFailures.append(item.title)
                    handleUnauthorized(error)
                }
            }
            if !addFailures.isEmpty {
                return fail(
                    message: "Some media could not be added. Your list was kept so you can retry.",
                    itemTitles: addFailures
                )
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
                } catch {
                    removeFailures.append(item.title)
                    handleUnauthorized(error)
                }
            }
            if !removeFailures.isEmpty {
                return fail(
                    message: "Some media could not be removed. Retry to finish saving this list.",
                    itemTitles: removeFailures
                )
            }

            let orderedItemIDs = draft.items.compactMap { serverItemsByRefID[$0.ref.id]?.ref.itemId }
            guard orderedItemIDs.count == draft.items.count else {
                return fail(message: "Spine could not determine the saved order. Retry to reconcile the list.")
            }

            phase = .savingOrder
            _ = try await listRepository.reorderItems(listId: listID, itemIds: orderedItemIDs)

            phase = .reloading
            try await reconcileServerItems(listID: listID)
            phase = .idle
            return listID
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
            isRanked: draft.isRanked
        )

        if let serverListID {
            _ = try await listRepository.update(id: serverListID, request)
            return serverListID
        }

        let list = try await listRepository.create(request)
        serverListID = list.id
        needsReconciliation = true
        return list.id
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

    private func replaceDraftItem(_ savedItem: MediaSummary) {
        guard let index = draft.items.firstIndex(where: { $0.ref.id == savedItem.ref.id }) else { return }
        draft.items[index] = savedItem
    }

    private func fail(message: String, itemTitles: [String] = []) -> Int? {
        errorMessage = message
        failedItemTitles = itemTitles
        phase = .failed
        needsReconciliation = serverListID != nil
        return nil
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
