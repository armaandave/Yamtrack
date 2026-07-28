import Foundation

extension Notification.Name {
    static let customListsDidChange = Notification.Name("customListsDidChange")
}

enum CustomListChange {
    static let listIdKey = "listId"
    static let listTypeKey = "listType"

    static func post(listId: Int, listType: CustomListType) {
        NotificationCenter.default.post(
            name: .customListsDidChange,
            object: nil,
            userInfo: [
                listIdKey: listId,
                listTypeKey: listType.rawValue,
            ]
        )
    }

    static func listId(from notification: Notification) -> Int? {
        notification.userInfo?[listIdKey] as? Int
    }
}
