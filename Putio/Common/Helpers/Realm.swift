import Foundation
import RealmSwift

class PutioRealm {
    static func setup() {
        let latestSchemaVersion: UInt64 = 10

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

                if oldSchemaVersion < 5 {
                    migration.enumerateObjects(ofType: User.className(), { (_, newAppUser) in
                        migration.enumerateObjects(ofType: UserFeatures.className(), { (_, newAppUserFeatures) in
                            newAppUserFeatures!["debugChromecast"] = false
                            newAppUser!["features"] = newAppUserFeatures
                        })
                    })
                }

                if oldSchemaVersion < 6 {
                    migration.enumerateObjects(ofType: User.className(), { (_, newAppUser) in
                        migration.enumerateObjects(ofType: UserFeatures.className(), { (_, newAppUserFeatures) in
                            newAppUserFeatures!["downloadVideosAsMp4"] = false
                            newAppUser!["features"] = newAppUserFeatures
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

                if oldSchemaVersion < 8 {
                    migration.enumerateObjects(ofType: User.className(), { (_, newAppUser) in
                        migration.enumerateObjects(ofType: UserFeatures.className(), { (_, newAppUserFeatures) in
                            newAppUserFeatures!["playHLSOnChromecast"] = false
                            newAppUser!["features"] = newAppUserFeatures
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
            }
        )

        Realm.Configuration.defaultConfiguration = config

        // log.debug("Realm \(Realm.Configuration.defaultConfiguration.fileURL?.path)", context: nil)
    }
}
