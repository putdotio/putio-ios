import Foundation
import RealmSwift

class PutioRealm {
    private static let needsDownloadRecoveryKey = "PutioRealm.needsDownloadRecovery"

    static var needsDownloadRecovery: Bool {
        return UserDefaults.standard.bool(forKey: needsDownloadRecoveryKey)
    }

    static func setup() {
        let latestSchemaVersion: UInt64 = 12

        let config = Realm.Configuration(
            schemaVersion: latestSchemaVersion,
            migrationBlock: { (migration, oldSchemaVersion) in
                if oldSchemaVersion < 1 {
                    migration.enumerateObjects(ofType: Download.className(), { (_, newDownload) in
                        newDownload!["fileType"] = 1
                    })
                }

                if oldSchemaVersion < 2 {
                    migration.enumerateObjects(ofType: User.className(), { (_, newAppUser) in
                        migration.enumerateObjects(ofType: UserSettings.className(), { (_, newAppUserSettings) in
                            newAppUserSettings!["historyEnabled"] = true
                            newAppUserSettings!["trashEnabled"] = true
                            newAppUser!["settings"] = newAppUserSettings
                        })
                    })
                }

                if oldSchemaVersion < 3 {
                    migration.enumerateObjects(ofType: Download.className(), { (_, newDownload) in
                        newDownload!["startFrom"] = 0
                    })
                }

                if oldSchemaVersion < 4 {
                    migration.enumerateObjects(ofType: User.className(), { (_, newAppUser) in
                        migration.enumerateObjects(ofType: UserSettings.className(), { (_, newAppUserSettings) in
                            newAppUserSettings!["sortBy"] = "DATE_DESC"
                            newAppUser!["settings"] = newAppUserSettings
                        })
                    })
                }

                if oldSchemaVersion < 7 {
                    migration.enumerateObjects(ofType: User.className(), { (_, newAppUser) in
                        migration.enumerateObjects(ofType: UserSettings.className(), { (_, newAppUserSettings) in
                            newAppUserSettings!["showOptimisticUsage"] = false
                            newAppUser!["settings"] = newAppUserSettings
                        })

                        migration.enumerateObjects(ofType: UserDisk.className(), { (_, newAppUserDisk) in
                            newAppUserDisk!["used"] = 0
                            newAppUser!["disk"] = newAppUserDisk
                        })
                    })
                }

                if oldSchemaVersion < 9 {
                    migration.enumerateObjects(ofType: User.className(), { (_, newAppUser) in
                        newAppUser!["trashSize"] = 0
                    })
                }

                if oldSchemaVersion < 10 {
                    migration.enumerateObjects(ofType: User.className(), { (_, newAppUser) in
                        migration.enumerateObjects(ofType: UserSettings.className(), { (_, newAppUserSettings) in
                            newAppUserSettings!["twoFactorEnabled"] = false
                            newAppUser!["settings"] = newAppUserSettings
                        })
                    })
                }

                if oldSchemaVersion < 11 {
                    migration.enumerateObjects(ofType: User.className(), { (_, newAppUser) in
                        migration.enumerateObjects(ofType: UserSettings.className(), { (_, newAppUserSettings) in
                            newAppUserSettings!["hideSubtitles"] = false
                            newAppUserSettings!["dontAutoSelectSubtitles"] = false
                            newAppUser!["settings"] = newAppUserSettings
                        })
                    })
                }

                // Schema 12: Download columns renamed from state/fileType to
                // stateRaw/fileTypeRaw. No migration needed — old format v9
                // databases are deleted before this runs, and fresh databases
                // get the new column names automatically.
            }
        )

        Realm.Configuration.defaultConfiguration = config

        // Realm 10.x cannot upgrade from file format version 9 (Realm 3.x).
        // Delete the old database and flag for download recovery.
        // Download file references survive in UserDefaults.
        do {
            _ = try Realm()
        } catch {
            let nsError = error as NSError
            if nsError.domain == "io.realm" && nsError.code == 16 {
                print("[PutioRealm] Incompatible Realm file format — deleting old database")
                if let realmURL = config.fileURL {
                    let realmURLs = [
                        realmURL,
                        realmURL.appendingPathExtension("lock"),
                        realmURL.appendingPathExtension("note"),
                        realmURL.appendingPathExtension("management")
                    ]
                    for url in realmURLs {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                UserDefaults.standard.set(true, forKey: needsDownloadRecoveryKey)
            }
        }
    }

    private static let hlsExtensions: Set<String> = ["movpkg"]
    private static let mediaExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "wmv", "webm"]

    /// Rebuild Download records from file references left in UserDefaults.
    /// Video downloads are stored as bookmark Data, audio as relative path Strings.
    /// Also scans the Documents directory for audio files whose UserDefaults entries were lost.
    /// Fetches real file names from the put.io API.
    static func recoverDownloadsIfNeeded() {
        guard UserDefaults.standard.bool(forKey: needsDownloadRecoveryKey) else { return }

        guard let realm = try? Realm() else { return }

        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys

        var recovered = 0
        var recoveredFileIds = Set<Int>()

        for key in allKeys {
            guard let fileId = Int(key), fileId > 0 else { continue }

            var isVideo = false
            var fileExists = false

            // Video: bookmark Data - validate it resolves to an HLS .movpkg or known media file
            if let bookmarkData = defaults.value(forKey: key) as? Data {
                var isStale = false
                if let url = (try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)) ?? nil,
                   !isStale, FileManager.default.fileExists(atPath: url.path) {
                    let ext = url.pathExtension.lowercased()
                    if hlsExtensions.contains(ext) || mediaExtensions.contains(ext) {
                        isVideo = true
                        fileExists = true
                    }
                }
            }

            // Audio: relative path String in Documents directory
            if !fileExists,
               let relativePath = defaults.value(forKey: key) as? String,
               relativePath.hasPrefix("putio_adm_") {
                let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let fileURL = docsURL.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    isVideo = false
                    fileExists = true
                }
            }

            guard fileExists else { continue }

            let download = Download()
            download.id = fileId
            download.name = "Recovering..."
            download.stateRaw = Download.State.completed.rawValue
            download.fileTypeRaw = isVideo ? Download.FileType.video.rawValue : Download.FileType.audio.rawValue
            download.completedAt = Date()
            download.createdAt = Date()

            try? realm.write {
                realm.add(download, update: .all)
            }
            recovered += 1
            recoveredFileIds.insert(fileId)
        }

        // Fallback: scan Documents directory for audio files whose UserDefaults entries were lost
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: docsURL.path) {
            for filename in contents where filename.hasPrefix("putio_adm_") {
                // Extract file ID from "putio_adm_{id}.ext" or "putio_adm_{id}"
                let stripped = filename
                    .replacingOccurrences(of: "putio_adm_", with: "")
                    .components(separatedBy: ".").first ?? ""
                guard let fileId = Int(stripped), fileId > 0, !recoveredFileIds.contains(fileId) else { continue }

                let fileURL = docsURL.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

                let download = Download()
                download.id = fileId
                download.name = "Recovering..."
                download.stateRaw = Download.State.completed.rawValue
                download.fileTypeRaw = Download.FileType.audio.rawValue
                download.completedAt = Date()
                download.createdAt = Date()

                try? realm.write {
                    realm.add(download, update: .all)
                }
                recovered += 1
                recoveredFileIds.insert(fileId)
            }
        }

        // Clear recovery flag after all records are created.
        // API enrichment below is fire-and-forget - don't block flag clearing on it.
        UserDefaults.standard.removeObject(forKey: needsDownloadRecoveryKey)

        print("[PutioRealm] Recovered \(recovered) download record(s)")

        // Enrich all recovered downloads with real names from the API
        enrichPlaceholderDownloads(in: realm)
    }

    /// Re-attempt API enrichment for downloads that still have placeholder names.
    /// Safe to call on every launch - just a query + API calls, no full recovery re-run.
    static func enrichPlaceholderDownloads(in realm: Realm? = nil) {
        guard let realm = realm ?? (try? Realm()) else { return }

        let placeholders = realm.objects(Download.self).filter(
            "name == 'Recovering...' OR name BEGINSWITH 'Video ' OR name BEGINSWITH 'Audio '"
        )
        guard !placeholders.isEmpty else { return }

        print("[PutioRealm] Enriching \(placeholders.count) download(s) with placeholder names")

        for download in placeholders {
            let fileId = download.id
            let isVideo = download.fileTypeRaw == Download.FileType.video.rawValue
            api.getFile(fileID: fileId) { result in
                guard let download = realm.object(ofType: Download.self, forPrimaryKey: fileId) else { return }
                switch result {
                case .success(let file):
                    try? realm.write {
                        download.name = file.name
                        download.size = file.size
                    }
                    print("[PutioRealm] Enriched download \(fileId): \(file.name)")
                case .failure:
                    // Only replace "Recovering..." with a fallback - keep existing "Video/Audio X" as-is
                    if download.name == "Recovering..." {
                        let fallbackName = isVideo ? "Video \(fileId)" : "Audio \(fileId)"
                        try? realm.write {
                            download.name = fallbackName
                        }
                    }
                    print("[PutioRealm] Could not fetch file info for \(fileId)")
                }
            }
        }
    }
}
