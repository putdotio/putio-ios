#if DEBUG
import Foundation
import RealmSwift

// Downloads are local Realm state, not an API resource, so this is the one
// screen PutioE2EMockURLProtocol cannot reach; the rows are seeded directly.
//
// DEBUG-only, and installed only after PUTIO_E2E_RESET_STATE has cleared the
// realm, so it can never touch a real user's downloads.
enum PutioE2EDownloadFixtures {
    private struct Seed {
        let id: Int
        let name: String
        let size: Int64
        let fileType: Download.FileType
        let state: Download.State
        // Hours back from launch. Keep at two or more: smaller offsets cross the
        // minute boundary mid-run, day-scale ones straddle a month bucket.
        let completedHoursAgo: Int?
        let progress: String

        init(
            id: Int,
            name: String,
            size: Int64,
            fileType: Download.FileType = .video,
            state: Download.State = .completed,
            completedHoursAgo: Int? = nil,
            progress: String = "0"
        ) {
            self.id = id
            self.name = name
            self.size = size
            self.fileType = fileType
            self.state = state
            self.completedHoursAgo = completedHoursAgo
            self.progress = progress
        }
    }

    // Oldest first, matching the table's createdAt sort, so the active transfer
    // lands at the bottom. Enough rows to fill the 2868pt capture device and
    // prove the table scrolls; names are the Blender open-content set the API
    // fixtures use, since they reach the App Store listing.
    private static let seeds: [Seed] = [
        Seed(id: 42, name: "Big Buck Bunny.mp4", size: 276_205_568, completedHoursAgo: 9),
        Seed(id: 71, name: "Sintel.mp4", size: 1_503_238_553, completedHoursAgo: 7),
        Seed(id: 73, name: "Elephants Dream.mp4", size: 761_266_995, completedHoursAgo: 6),
        Seed(id: 74, name: "Cosmos Laundromat.mp4", size: 1_181_116_006, completedHoursAgo: 5),
        Seed(id: 75, name: "Caminandes - Llamigos.mp4", size: 432_013_312, completedHoursAgo: 4),
        Seed(id: 76, name: "Spring.mp4", size: 2_469_606_195, completedHoursAgo: 3),
        Seed(id: 43, name: "Sintel Theme.mp3", size: 8_388_608, fileType: .audio, completedHoursAgo: 2),
        Seed(id: 72, name: "Tears of Steel.mp4", size: 2_254_857_830, state: .active, progress: "0.62")
    ]

    static func install(into realm: Realm) {
        if PutioE2ELargeFixture.isEnabled {
            return installLarge(into: realm)
        }

        let now = Date()

        for seed in seeds where seed.state == .completed {
            installLocalFile(for: seed)
        }

        _ = PutioRealm.write(realm, context: "PutioE2EDownloadFixtures.install") {
            for (index, seed) in seeds.enumerated() {
                let download = Download()
                download.id = seed.id
                download.name = seed.name
                download.size = seed.size
                download.fileType = seed.fileType
                download.state = seed.state
                download.progress = seed.progress
                // A minute apart to fix the sort order, and kept in the past so
                // anything that later formats or prunes on createdAt behaves.
                download.createdAt = now.addingTimeInterval(TimeInterval((index - seeds.count) * 60))
                download.completedAt = seed.completedHoursAgo.map {
                    now.addingTimeInterval(TimeInterval(-3600 * $0))
                }
                realm.add(download, update: .modified)
            }
        }
    }

    // 500 rows for the per-cell download lookup to scan: half are root videos
    // and audio, half ids no listing has. Rows only, no local files, since
    // creating 500 at launch would land inside every launch measurement.
    private static func installLarge(into realm: Realm) {
        let now = Date()
        var rows: [(id: Int, fileType: Download.FileType)] = []
        rows += PutioE2ELargeFixture.rootVideoIDs(count: 200).map { (id: $0, fileType: .video) }
        rows += PutioE2ELargeFixture.rootAudioIDs(count: 50).map { (id: $0, fileType: .audio) }
        rows += (1...250).map { (id: 700_000_000 + $0, fileType: $0 % 5 == 0 ? .audio : .video) }
        let states: [Download.State] = [.active, .queued, .failed] + Array(repeating: .completed, count: 7)

        _ = PutioRealm.write(realm, context: "PutioE2EDownloadFixtures.installLarge") {
            for (index, row) in rows.enumerated() {
                let download = Download()
                download.id = row.id
                download.name = "Large fixture download \(index + 1).\(row.fileType == .audio ? "mp3" : "mkv")"
                download.size = 104_857_600 + Int64(index) * 7_340_032
                download.fileType = row.fileType
                download.state = states[index % states.count]
                download.progress = download.state == .active ? "0.4" : "0"
                download.createdAt = now.addingTimeInterval(TimeInterval(-60 * (index + 1)))
                download.completedAt = download.state == .completed ? download.createdAt : nil
                realm.add(download, update: .modified)
            }
        }
    }

    private static func installLocalFile(for seed: Seed) {
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return log.error("[PutioE2EDownloadFixtures] Unable to resolve documents directory")
        }

        let fileExtension = seed.fileType == .audio ? "mp3" : "movpkg"
        let filename = "putio_e2e_\(seed.id).\(fileExtension)"
        let fileURL = documentsURL.appendingPathComponent(filename)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: Data()) else {
            return log.error("[PutioE2EDownloadFixtures] Unable to create \(filename)")
        }

        switch seed.fileType {
        case .audio:
            UserDefaults.standard.set(filename, forKey: String(seed.id))
        case .video:
            do {
                UserDefaults.standard.set(try fileURL.bookmarkData(), forKey: String(seed.id))
            } catch {
                log.error("[PutioE2EDownloadFixtures] Unable to bookmark \(filename): \(error.localizedDescription)")
            }
        }
    }
}
#endif
