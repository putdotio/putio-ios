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
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let matches = regex.matches(in: path, options: [], range: NSRange(location: 0, length: path.utf16.count))
        guard let match = matches.first,
              let swiftRange = Range(match.range(at: 1), in: path) else { return nil }
        return Int(path[swiftRange])
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
            return handleFileURL(path: url.path)
        }

        if url.path.starts(with: "/downloads") {
            return handleDownloadURL(path: url.path)
        }

        return handleStaticURL(path: url.path)
    }

    private func handleFileURL(path: String) -> Bool {
        tabBarController?.setSelectedTab(title: .files)
        guard let id = extractIDFromPath(pattern: "/files/(.*)", path: path) else { return false }

        api.getFile(fileID: id) { result in
            guard case .success(let file) = result else { return }
            self.openFilePage(file: file)
        }

        return true
    }

    private func handleDownloadURL(path: String) -> Bool {
        tabBarController?.setSelectedTab(title: .downloads)
        guard let id = extractIDFromPath(pattern: "/downloads/(.*)", path: path) else { return false }

        openDownloadedFile(fileID: id)
        return true
    }

    private func handleStaticURL(path: String) -> Bool {
        switch path {
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
