import Foundation
import RealmSwift

class PutioRealm {
    private static let needsDownloadRecoveryKey = "PutioRealm.needsDownloadRecovery"
    static let latestSchemaVersion: UInt64 = 12

    static var needsDownloadRecovery: Bool {
        return needsDownloadRecovery(defaults: .standard)
    }

    static func needsDownloadRecovery(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: needsDownloadRecoveryKey)
    }

    static func setNeedsDownloadRecovery(_ value: Bool, defaults: UserDefaults = .standard) {
        if value {
            defaults.set(true, forKey: needsDownloadRecoveryKey)
        } else {
            defaults.removeObject(forKey: needsDownloadRecoveryKey)
        }
    }

    static func logFailure(_ context: String, error: Error) {
        log.error("[PutioRealm] \(context): \(error.localizedDescription)")
    }

    static func configuration(fileURL: URL? = nil) -> Realm.Configuration {
        var configuration = Realm.Configuration(
            schemaVersion: latestSchemaVersion,
            migrationBlock: migrate
        )

        if let fileURL {
            configuration.fileURL = fileURL
        }

        return configuration
    }

    static func open(context: String, configuration: Realm.Configuration? = nil) -> Realm? {
        let resolvedConfiguration = configuration ?? Realm.Configuration.defaultConfiguration

        do {
            return try Realm(configuration: resolvedConfiguration)
        } catch {
            logFailure(context, error: error)
            return nil
        }
    }

    @discardableResult
    static func write(_ realm: Realm, context: String, updates: () -> Void) -> Bool {
        do {
            try realm.write(updates)
            return true
        } catch {
            logFailure(context, error: error)
            return false
        }
    }

    @discardableResult
    static func replaceUserSession(_ realm: Realm, user: User, config: UserConfig, context: String) -> Bool {
        write(realm, context: context) {
            realm.delete(realm.objects(User.self))
            realm.delete(realm.objects(UserConfig.self))
            realm.add(user, update: .all)
            realm.add(config)
        }
    }

    static func setup() {
        let config = configuration()

        Realm.Configuration.defaultConfiguration = config

        // Realm 10.x cannot upgrade from file format version 9 (Realm 3.x).
        // Delete the old database and flag for download recovery.
        // Download file references survive in UserDefaults.
        do {
            _ = try Realm()
        } catch {
            let nsError = error as NSError
            if nsError.domain == "io.realm" && nsError.code == 16 {
                log.warning("[PutioRealm] Incompatible Realm file format, deleting old database")
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
                setNeedsDownloadRecovery(true)
            }
        }
    }

    private static let hlsExtensions: Set<String> = ["movpkg"]
    private static let mediaExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "wmv", "webm"]

    private static func migrate(_ migration: Migration, _ oldSchemaVersion: UInt64) {
        if oldSchemaVersion < 1 {
            migration.enumerateObjects(ofType: Download.className()) { _, newDownload in
                newDownload!["fileTypeRaw"] = Download.FileType.audio.rawValue
            }
        }

        if oldSchemaVersion < 2 {
            updateUserSettings(migration) { newAppUserSettings in
                newAppUserSettings!["historyEnabled"] = true
                newAppUserSettings!["trashEnabled"] = true
            }
        }

        if oldSchemaVersion < 3 {
            migration.enumerateObjects(ofType: Download.className()) { _, newDownload in
                newDownload!["startFrom"] = 0
            }
        }

        if oldSchemaVersion < 4 {
            updateUserSettings(migration) { newAppUserSettings in
                newAppUserSettings!["sortBy"] = "DATE_DESC"
            }
        }

        if oldSchemaVersion < 7 {
            updateUserSettings(migration) { newAppUserSettings in
                newAppUserSettings!["showOptimisticUsage"] = false
            }

            migration.enumerateObjects(ofType: User.className()) { _, newAppUser in
                migration.enumerateObjects(ofType: UserDisk.className()) { _, newAppUserDisk in
                    newAppUserDisk!["used"] = 0
                    newAppUser!["disk"] = newAppUserDisk
                }
            }
        }

        if oldSchemaVersion < 9 {
            migration.enumerateObjects(ofType: User.className()) { _, newAppUser in
                newAppUser!["trashSize"] = 0
            }
        }

        if oldSchemaVersion < 10 {
            updateUserSettings(migration) { newAppUserSettings in
                newAppUserSettings!["twoFactorEnabled"] = false
            }
        }

        if oldSchemaVersion < 11 {
            updateUserSettings(migration) { newAppUserSettings in
                newAppUserSettings!["hideSubtitles"] = false
                newAppUserSettings!["dontAutoSelectSubtitles"] = false
            }
        }

        if oldSchemaVersion < 12 {
            migrateDownloadRawColumns(migration)
        }
    }

    private static func migrateDownloadRawColumns(_ migration: Migration) {
        let hasLegacyState = migration.oldSchema[Download.className()]?["state"] != nil
        let hasLegacyFileType = migration.oldSchema[Download.className()]?["fileType"] != nil

        migration.enumerateObjects(ofType: Download.className()) { oldDownload, newDownload in
            let rawValues = legacyDownloadRawValues(
                state: hasLegacyState ? oldDownload?["state"] : nil,
                fileType: hasLegacyFileType ? oldDownload?["fileType"] : nil
            )

            if let stateRaw = rawValues.stateRaw {
                newDownload!["stateRaw"] = stateRaw
            }

            if let fileTypeRaw = rawValues.fileTypeRaw {
                newDownload!["fileTypeRaw"] = fileTypeRaw
            }
        }
    }

    static func legacyDownloadRawValues(state: Any?, fileType: Any?) -> (stateRaw: Int?, fileTypeRaw: Int?) {
        return (legacyIntValue(state), legacyIntValue(fileType))
    }

    private static func legacyIntValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func updateUserSettings(_ migration: Migration, updates: @escaping (MigrationObject?) -> Void) {
        migration.enumerateObjects(ofType: User.className()) { _, newAppUser in
            migration.enumerateObjects(ofType: UserSettings.className()) { _, newAppUserSettings in
                updates(newAppUserSettings)
                newAppUser!["settings"] = newAppUserSettings
            }
        }
    }

    /// Rebuild Download records from file references left in UserDefaults.
    /// Video downloads are stored as bookmark Data, audio as relative path Strings.
    /// Also scans the Documents directory for audio files whose UserDefaults entries were lost.
    /// Fetches real file names from the put.io API.
    static func recoverDownloadsIfNeeded(
        defaults: UserDefaults = .standard,
        documentsURL: URL = documentsURL,
        realm: Realm? = nil,
        shouldEnrichPlaceholders: Bool = true
    ) {
        guard needsDownloadRecovery(defaults: defaults) else { return }

        guard let realm = realm ?? open(context: "recoverDownloadsIfNeeded") else { return }

        let allKeys = defaults.dictionaryRepresentation().keys

        var recovered = 0
        var recoveredFileIds = Set<Int>()

        for key in allKeys {
            guard let fileId = Int(key), fileId > 0 else { continue }

            guard let download = buildRecoveredDownload(
                fileId: fileId,
                defaults: defaults,
                documentsURL: documentsURL
            ) else { continue }

            addRecoveredDownload(download, to: realm)
            recovered += 1
            recoveredFileIds.insert(fileId)
        }

        // Fallback: scan Documents directory for audio files whose UserDefaults entries were lost
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: documentsURL.path) {
            for filename in contents where filename.hasPrefix("putio_adm_") {
                guard let fileId = recoveredAudioFileId(from: filename),
                      fileId > 0,
                      !recoveredFileIds.contains(fileId) else { continue }

                let fileURL = documentsURL.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

                addRecoveredDownload(buildRecoveredDownload(fileId: fileId, isVideo: false), to: realm)
                defaults.set(filename, forKey: String(fileId))
                recovered += 1
                recoveredFileIds.insert(fileId)
            }
        }

        // Clear recovery flag after all records are created.
        // API enrichment below is fire-and-forget - don't block flag clearing on it.
        setNeedsDownloadRecovery(false, defaults: defaults)

        log.info("[PutioRealm] Recovered \(recovered) download record(s)")

        // Enrich all recovered downloads with real names from the API
        if shouldEnrichPlaceholders {
            enrichPlaceholderDownloads(in: realm)
        }
    }

    private static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    static func recoveredAudioFileId(from filename: String) -> Int? {
        let prefix = "putio_adm_"
        guard filename.hasPrefix(prefix) else { return nil }

        let filenameWithoutExtension = (filename as NSString).deletingPathExtension
        let idAndSlug = String(filenameWithoutExtension.dropFirst(prefix.count))
        let id = idAndSlug.split(separator: "_", maxSplits: 1).first.map(String.init) ?? idAndSlug
        return Int(id)
    }

    private static func buildRecoveredDownload(fileId: Int, defaults: UserDefaults, documentsURL: URL) -> Download? {
        if hasValidVideoBookmark(fileId: fileId, defaults: defaults) {
            return buildRecoveredDownload(fileId: fileId, isVideo: true)
        }

        if hasValidAudioPath(fileId: fileId, defaults: defaults, documentsURL: documentsURL) {
            return buildRecoveredDownload(fileId: fileId, isVideo: false)
        }

        return nil
    }

    private static func buildRecoveredDownload(fileId: Int, isVideo: Bool) -> Download {
        let download = Download()
        download.id = fileId
        download.name = localizedRecoveringPlaceholder
        download.stateRaw = Download.State.completed.rawValue
        download.fileTypeRaw = isVideo ? Download.FileType.video.rawValue : Download.FileType.audio.rawValue
        download.completedAt = Date()
        download.createdAt = Date()
        return download
    }

    private static func addRecoveredDownload(_ download: Download, to realm: Realm) {
        try? realm.write {
            realm.add(download, update: .all)
        }
    }

    private static func hasValidVideoBookmark(fileId: Int, defaults: UserDefaults) -> Bool {
        guard let bookmarkData = defaults.value(forKey: "\(fileId)") as? Data else { return false }

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale),
              !isStale,
              FileManager.default.fileExists(atPath: url.path) else { return false }

        let ext = url.pathExtension.lowercased()
        return hlsExtensions.contains(ext) || mediaExtensions.contains(ext)
    }

    private static func hasValidAudioPath(fileId: Int, defaults: UserDefaults, documentsURL: URL) -> Bool {
        guard let relativePath = defaults.value(forKey: "\(fileId)") as? String,
              relativePath.hasPrefix("putio_adm_") else { return false }

        let fileURL = documentsURL.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Re-attempt API enrichment for downloads that still have placeholder names.
    /// Safe to call on every launch - just a query + API calls, no full recovery re-run.
    static func enrichPlaceholderDownloads(in realm: Realm? = nil) {
        guard let realm = realm ?? (try? Realm()) else { return }

        let placeholders = realm.objects(Download.self).filter(
            NSPredicate(
                format: "name == %@ OR name BEGINSWITH %@ OR name BEGINSWITH %@",
                localizedRecoveringPlaceholder,
                localizedVideoPlaceholderPrefix,
                localizedAudioPlaceholderPrefix
            )
        )
        guard !placeholders.isEmpty else { return }

        log.info("[PutioRealm] Enriching \(placeholders.count) download(s) with placeholder names")

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
                    log.info("[PutioRealm] Enriched download \(fileId): \(file.name)")
                case .failure:
                    // Only replace "Recovering..." with a fallback - keep existing "Video/Audio X" as-is
                    if download.name == localizedRecoveringPlaceholder {
                        let fallbackName = isVideo
                            ? String(format: localizedVideoPlaceholderFormat, fileId)
                            : String(format: localizedAudioPlaceholderFormat, fileId)
                        try? realm.write {
                            download.name = fallbackName
                        }
                    }
                    log.warning("[PutioRealm] Could not fetch file info for \(fileId)")
                }
            }
        }
    }

    private static var localizedRecoveringPlaceholder: String {
        NSLocalizedString("Recovering...", comment: "")
    }

    private static var localizedVideoPlaceholderFormat: String {
        NSLocalizedString("Video %d", comment: "")
    }

    private static var localizedAudioPlaceholderFormat: String {
        NSLocalizedString("Audio %d", comment: "")
    }

    private static var localizedVideoPlaceholderPrefix: String {
        String(format: localizedVideoPlaceholderFormat, 0).replacingOccurrences(of: "0", with: "")
    }

    private static var localizedAudioPlaceholderPrefix: String {
        String(format: localizedAudioPlaceholderFormat, 0).replacingOccurrences(of: "0", with: "")
    }
}
