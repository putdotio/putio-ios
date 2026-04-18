import Foundation
import UIKit
import RealmSwift
import PutioSDK

class DeeplinkManager {
    static let sharedInstance = DeeplinkManager()

    let realm = try! Realm()
    var tabBarController: MainTabBarController?
    var isReadyToHandleURL: Bool = false

    func setup(with tabBarController: MainTabBarController) {
        self.tabBarController = tabBarController
        self.isReadyToHandleURL = true
    }

    private func extractIDFromPath(pattern: String, path: String) -> Int? {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let matches = regex.matches(in: path, options: [], range: NSRange(location: 0, length: path.utf16.count))
            if let match = matches.first {
                let range = match.range(at: 1)
                if let swiftRange = Range(range, in: path) {
                    let id = path[swiftRange]
                    return Int(id)
                }
                return nil
            }
            return nil
        } catch {
            return nil
        }
    }

    private func openLinkPage() {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        let linkAccountVC = storyboard.instantiateViewController(withIdentifier: "LinkAccount") as! LinkAccountViewController
        let settingsNC = tabBarController?.selectedViewController as! UINavigationController
        settingsNC.pushViewController(linkAccountVC, animated: true)
    }

    private func openFilePage(file: PutioFile) {
        guard let filesNC = tabBarController?.selectedViewController as? UINavigationController else {
            return print("DeeplinkManager - Open File Page -> Unable to cast filesNC")
        }

        if let presentedFileVC = filesNC.presentedViewController {
            return presentedFileVC.dismiss(animated: true, completion: {
                self.openFilePage(file: file)
            })
        }

        guard let visibleFileVC = filesNC.visibleViewController as? FilesViewController else {
            return print("DeeplinkManager - Open File Page -> Unable to cast visibleFileVC")
        }

        return visibleFileVC.presentFile(file)
    }

    private func openDownloadedFile(fileID: Int) {
        guard let download = realm.object(ofType: Download.self, forPrimaryKey: fileID),
            let downloadsNC = tabBarController?.selectedViewController as? UINavigationController else { return }

        if let presentedDownloadVC = downloadsNC.presentedViewController {
            return presentedDownloadVC.dismiss(animated: true, completion: {
                self.openDownloadedFile(fileID: fileID)
            })
        }

        guard let visibleDownloadVC = downloadsNC.visibleViewController as? DownloadsViewController else {
            return print("DeeplinkManager - Open Downloaded File -> Unable to cast visibleDownloadVC")
        }

        visibleDownloadVC.presentDownloadedFile(download)
    }

    func handleURL(url: URL) -> Bool {
        guard isReadyToHandleURL else { return false }

        if url.path.starts(with: "/files") {
            tabBarController?.setSelectedTab(title: .files)

            guard let id = extractIDFromPath(pattern: "/files/(.*)", path: url.path) else {
                return false
            }

            api.getFile(fileID: id) { result in
                switch result {
                case .success(let file):
                    self.openFilePage(file: file)

                case .failure:
                    break
                }
            }

            return true
        }

        if url.path.starts(with: "/downloads") {
            tabBarController?.setSelectedTab(title: .downloads)

            guard let id = extractIDFromPath(pattern: "/downloads/(.*)", path: url.path) else {
                return false
            }

            openDownloadedFile(fileID: id)
            return true
        }

        switch url.path {
        case "/history":
            tabBarController?.setSelectedTab(title: .history)
            return true

        case "/settings", "/account":
            tabBarController?.setSelectedTab(title: .account)
            return true

        case "/link":
            tabBarController?.setSelectedTab(title: .account)
            openLinkPage()
            return true

        default:
            return false
        }
    }
}
