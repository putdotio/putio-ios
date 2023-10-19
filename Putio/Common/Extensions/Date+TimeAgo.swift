import Foundation

extension Date {
    func timeAgoSinceDate() -> String {
        let date = self
        let calendar = NSCalendar.current
        let unitFlags: Set<Calendar.Component> = [.minute, .hour, .day, .weekOfYear, .month, .year, .second]

        let now = Date()
        let earliest = now < date ? now : date
        let latest = (earliest == now) ? date : now

        let components = calendar.dateComponents(unitFlags, from: earliest, to: latest)

        if let year = components.year {
            if year >= 2 {
                return "\(year) years ago"
            }

            if year >= 1 {
                return "last year"
            }
        }

        if let month = components.month {
            if month >= 2 {
                return "\(month) months ago"
            }

            if month >= 1 {
                return "last month"
            }
        }

        if let weekOfYear = components.weekOfYear {
            if weekOfYear >= 2 {
                return "\(weekOfYear) weeks ago"
            }

            if weekOfYear >= 1 {
                return "last week"
            }
        }

        if let day = components.day {
            if day >= 2 {
                return "\(day) days ago"
            }

            if day >= 1 {
                return "yesterday"
            }
        }

        if let hour = components.hour {
            if hour >= 2 {
                return "\(hour) hours ago"
            }

            if hour >= 1 {
                return "an hour ago"
            }
        }

        if let minute = components.minute {
            if minute >= 2 {
                return "\(minute) minutes ago"
            }

            if minute >= 1 {
                return "a minute ago"
            }
        }

        if let second = components.second {
            if second >= 10 {
                return "\(second) seconds ago"
            }

        }

        return "just now"
    }
}
