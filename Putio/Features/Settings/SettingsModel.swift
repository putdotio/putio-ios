import Foundation

class SettingsModel {
    struct SortByKey {
        let key: String
        let label: String
    }

    struct SortByDirection {
        let key: String
        let label: String

        init(key: String) {
            self.key = key
            self.label = key == "ASC" ? "↑" : "↓"
        }
    }

    static let sortByKeys = [
        SortByKey(key: "NAME", label: "Name"),
        SortByKey(key: "SIZE", label: "Size"),
        SortByKey(key: "DATE", label: "Date Added"),
        SortByKey(key: "MODIFIED", label: "Date Modified"),
        SortByKey(key: "TYPE", label: "Type"),
        SortByKey(key: "WATCH", label: "Watch Status")
    ]

    enum SectionItemType: Int {
        case toggle, link, button, text
    }

    struct SectionItem {
        let title: String
        let type: SectionItemType
        let icon: String
        let value: Any
        let action: (() -> Void)?
        let visible: Bool
    }

    struct Section {
        let title: String
        let items: [SectionItem]
    }
}
