import Foundation
import PutioSDK

protocol HistoryRepositoryProtocol: Sendable {
    func events() async throws -> [PutioHistoryEvent]
    func clear() async throws
}

struct HistoryRepository: HistoryRepositoryProtocol {
    let api: PutioSDK

    func events() async throws -> [PutioHistoryEvent] {
        try await api.getHistoryEvents().events
    }

    func clear() async throws {
        _ = try await api.clearHistoryEvents()
    }
}

/// Wraps an event with the derived presentation it needs in the TV history
/// list. Mirrors the React Native `getFilteredEventsForTV` + `groupEventsByDate`
/// helpers — `tv-native` only surfaces `file_shared` and `transfer_completed`.
struct HistoryEventViewItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case completedTransfer
        case sharedFile
    }

    let id: Int
    let title: String
    let subtitle: String?
    let date: Date
    let fileID: Int?
    let kind: Kind
}

struct HistoryGroup: Identifiable, Hashable {
    enum Bucket: String, Hashable {
        case today = "Today"
        case yesterday = "Yesterday"
        case lastWeek = "Last week"
        case earlier = "Earlier"
    }

    let bucket: Bucket
    let items: [HistoryEventViewItem]
    var id: Bucket { bucket }
}

enum HistoryGrouping {
    /// Drops non-file activity (RSS errors, vouchers, callback errors) the same
    /// way the React Native `getFilteredEventsForTV` helper does.
    static func tvFiltered(_ events: [PutioHistoryEvent]) -> [HistoryEventViewItem] {
        events.compactMap(viewItem(for:))
    }

    static func grouped(_ items: [HistoryEventViewItem], now: Date = .now) -> [HistoryGroup] {
        let calendar = Calendar.current
        var buckets: [HistoryGroup.Bucket: [HistoryEventViewItem]] = [:]

        for item in items.sorted(by: { $0.date > $1.date }) {
            let bucket = bucketFor(item.date, now: now, calendar: calendar)
            buckets[bucket, default: []].append(item)
        }

        return [HistoryGroup.Bucket.today, .yesterday, .lastWeek, .earlier]
            .compactMap { bucket in
                guard let entries = buckets[bucket], !entries.isEmpty else { return nil }
                return HistoryGroup(bucket: bucket, items: entries)
            }
    }

    private static func bucketFor(_ date: Date, now: Date, calendar: Calendar) -> HistoryGroup.Bucket {
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        return days <= 7 ? .lastWeek : .earlier
    }

    private static func viewItem(for event: PutioHistoryEvent) -> HistoryEventViewItem? {
        switch event {
        case let event as PutioTransferCompletedEvent:
            return HistoryEventViewItem(
                id: event.id,
                title: event.transferName.isEmpty ? "Transfer completed" : event.transferName,
                subtitle: subtitleForBytes(event.transferSize, source: event.source),
                date: event.createdAt,
                fileID: event.fileID > 0 ? event.fileID : nil,
                kind: .completedTransfer
            )
        case let event as PutioFileSharedEvent:
            return HistoryEventViewItem(
                id: event.id,
                title: event.fileName.isEmpty ? "Shared file" : event.fileName,
                subtitle: sharedSubtitle(event),
                date: event.createdAt,
                fileID: event.fileID > 0 ? event.fileID : nil,
                kind: .sharedFile
            )
        default:
            return nil
        }
    }

    private static func sharedSubtitle(_ event: PutioFileSharedEvent) -> String? {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: event.createdAt, relativeTo: .now)
        if event.sharingUserName.isEmpty { return relative }
        return "\(relative) · Shared by \(event.sharingUserName)"
    }

    private static func subtitleForBytes(_ bytes: Int64, source: String?) -> String? {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        let size = bytes > 0 ? formatter.string(fromByteCount: bytes) : nil
        switch (size, source?.isEmpty == false ? source : nil) {
        case let (size?, source?): return "\(size) · \(source)"
        case let (size?, nil): return size
        case let (nil, source?): return source
        default: return nil
        }
    }
}
