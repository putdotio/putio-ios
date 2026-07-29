#if DEBUG
import Foundation
import RealmSwift

// Downloads are local Realm state, not an API resource, so they are the one
// screen PutioE2EMockURLProtocol cannot reach. Without a seed the Downloads tab
// renders its empty state on every mocked run: no coverage for the cell, the
// state button, or the size and age formatting, and an empty screen in the App
// Store set. Seed the table directly instead.
//
// DEBUG-only and installed only after PUTIO_E2E_RESET_STATE has cleared the
// realm, so this can never touch a real user's downloads.
enum PutioE2EDownloadFixtures {
    private struct Seed {
        let id: Int
        let name: String
        let size: Int64
        let fileType: Download.FileType
        let state: Download.State
        // Hours back from launch. Two hours or more renders a stable "N hours
        // ago" in every calendar; smaller offsets cross the minute boundary
        // mid-run and day-scale ones can straddle a month bucket.
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

    // Ordered oldest first, matching the table's createdAt sort, so the list
    // reads the way a real one does: finished items settled at the top and the
    // active transfer newest at the bottom. Names come from the same Blender
    // open-content set the API fixtures use.
    //
    // Eight rows rather than a token two or three: the pinned capture device is
    // 2868pt tall and a short list leaves most of the screen black, which is
    // both a weak App Store slot and no proof the table scrolls or that long
    // names truncate.
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
        let now = Date()

        _ = PutioRealm.write(realm, context: "PutioE2EDownloadFixtures.install") {
            for (index, seed) in seeds.enumerated() {
                let download = Download()
                download.id = seed.id
                download.name = seed.name
                download.size = seed.size
                download.fileType = seed.fileType
                download.state = seed.state
                download.progress = seed.progress
                // Spaced a minute apart purely to fix the sort order, and kept
                // in the past: nothing shows createdAt today, but a future date
                // is a trap for anything that later formats or prunes on it.
                download.createdAt = now.addingTimeInterval(TimeInterval((index - seeds.count) * 60))
                download.completedAt = seed.completedHoursAgo.map {
                    now.addingTimeInterval(TimeInterval(-3600 * $0))
                }
                realm.add(download, update: .modified)
            }
        }
    }
}
#endif
