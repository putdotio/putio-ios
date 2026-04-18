import Foundation

extension Date {
    private struct TimeAgoDescriptor {
        let value: Int?
        let pluralLabel: String
        let singularLabel: String
    }

    func timeAgoSinceDate() -> String {
        let calendar = NSCalendar.current
        let unitFlags: Set<Calendar.Component> = [.minute, .hour, .day, .weekOfYear, .month, .year, .second]

        let now = Date()
        let earliest = min(now, self)
        let latest = earliest == now ? self : now

        let components = calendar.dateComponents(unitFlags, from: earliest, to: latest)
        let descriptors: [TimeAgoDescriptor] = [
            TimeAgoDescriptor(value: components.year, pluralLabel: "years ago", singularLabel: "last year"),
            TimeAgoDescriptor(value: components.month, pluralLabel: "months ago", singularLabel: "last month"),
            TimeAgoDescriptor(value: components.weekOfYear, pluralLabel: "weeks ago", singularLabel: "last week"),
            TimeAgoDescriptor(value: components.day, pluralLabel: "days ago", singularLabel: "yesterday"),
            TimeAgoDescriptor(value: components.hour, pluralLabel: "hours ago", singularLabel: "an hour ago"),
            TimeAgoDescriptor(value: components.minute, pluralLabel: "minutes ago", singularLabel: "a minute ago")
        ]

        for descriptor in descriptors {
            guard let value = descriptor.value else { continue }
            if value >= 2 {
                return "\(value) \(descriptor.pluralLabel)"
            }

            if value >= 1 {
                return descriptor.singularLabel
            }
        }

        if let second = components.second, second >= 10 {
            return "\(second) seconds ago"
        }

        return "just now"
    }
}
