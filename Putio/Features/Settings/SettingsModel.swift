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
        SortByKey(key: "NAME", label: NSLocalizedString("Name", comment: "")),
        SortByKey(key: "SIZE", label: NSLocalizedString("Size", comment: "")),
        SortByKey(key: "DATE", label: NSLocalizedString("Date Added", comment: "")),
        SortByKey(key: "MODIFIED", label: NSLocalizedString("Date Modified", comment: "")),
        SortByKey(key: "TYPE", label: NSLocalizedString("Type", comment: "")),
        SortByKey(key: "WATCH", label: NSLocalizedString("Watch Status", comment: ""))
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
