import Foundation
import UIKit
import RealmSwift
import PutioSDK

class DeeplinkManager {
    static let sharedInstance = DeeplinkManager()

    var tabBarController: MainTabBarController?
    var isReadyToHandleURL: Bool = false
    var diagnosticsCheck: () -> Bool = { SentryTelemetry.captureDiagnosticsCheck() }

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
        guard let linkAccountVC = storyboard.instantiateViewController(withIdentifier: "LinkAccount", as: LinkAccountViewController.self) else {
            return InternalFailurePresenter.log("Unable to instantiate LinkAccountViewController")
        }

        guard let settingsNC = tabBarController?.selectedViewController as? UINavigationController else {
            return InternalFailurePresenter.log("Unable to access settings navigation controller for deeplink")
        }
        settingsNC.pushViewController(linkAccountVC, animated: true)
    }

    private func openFilePage(file: PutioFile) {
        guard let filesNC = tabBarController?.selectedViewController as? UINavigationController else {
            return InternalFailurePresenter.log("Open File Page: unable to access files navigation controller")
        }

        if let presentedFileVC = filesNC.presentedViewController {
            return presentedFileVC.dismiss(animated: true, completion: {
                self.openFilePage(file: file)
            })
        }

        guard let visibleFileVC = filesNC.visibleViewController as? FilesViewController else {
            return InternalFailurePresenter.log("Open File Page: visible controller is not FilesViewController")
        }

        return visibleFileVC.presentFile(file)
    }

    private func openDownloadedFile(fileID: Int) {
        guard let realm = PutioRealm.open(context: "DeeplinkManager.openDownloadedFile"),
              let download = realm.object(ofType: Download.self, forPrimaryKey: fileID),
            let downloadsNC = tabBarController?.selectedViewController as? UINavigationController else { return }

        if let presentedDownloadVC = downloadsNC.presentedViewController {
            return presentedDownloadVC.dismiss(animated: true, completion: {
                self.openDownloadedFile(fileID: fileID)
            })
        }

        guard let visibleDownloadVC = downloadsNC.visibleViewController as? DownloadsViewController else {
            return InternalFailurePresenter.log("Open Downloaded File: visible controller is not DownloadsViewController")
        }

        visibleDownloadVC.presentDownloadedFile(download)
    }

    func handleURL(url: URL) -> Bool {
        guard isReadyToHandleURL else { return false }

        let path = Self.routePath(of: url)

        if path.starts(with: "/files") {
            return handleFileURL(path: path)
        }

        if path.starts(with: "/downloads") {
            return handleDownloadURL(path: path)
        }

        return handleStaticURL(path: path)
    }

    // putio://files/1 parses "files" as the host, so the custom scheme reads
    // host and path together. putio:///files/1, putio://put.io/files/1 and
    // https://put.io/files/1 have the route in the path alone.
    static func routePath(of url: URL) -> String {
        guard url.scheme?.lowercased() == "putio", let host = url.host?.lowercased(), !host.isEmpty,
              host != "put.io", !host.hasSuffix(".put.io") else { return url.path }
        return "/" + host + url.path
    }

    private func handleFileURL(path: String) -> Bool {
        tabBarController?.setSelectedTab(.files)
        guard let id = extractIDFromPath(pattern: "/files/(.*)", path: path) else { return false }

        api.getFile(fileID: id) { result in
            guard case .success(let file) = result else { return }
            self.openFilePage(file: file)
        }

        return true
    }

    private func handleDownloadURL(path: String) -> Bool {
        tabBarController?.setSelectedTab(.downloads)
        guard let id = extractIDFromPath(pattern: "/downloads/(.*)", path: path) else { return false }

        openDownloadedFile(fileID: id)
        return true
    }

    private func handleStaticURL(path: String) -> Bool {
        switch path {
        case "/history":
            tabBarController?.setSelectedTab(.history)
            return true
        case "/settings", "/account":
            tabBarController?.setSelectedTab(.account)
            return true
        case "/link":
            tabBarController?.setSelectedTab(.account)
            openLinkPage()
            return true
        case "/diagnostics-check":
            return diagnosticsCheck()
        default:
            return false
        }
    }
}
