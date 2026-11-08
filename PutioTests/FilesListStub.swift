import os
import RealmSwift
import UIKit
import XCTest
@testable import Putio

final class FilesListStub: URLProtocol {
    private static let listedFiles = OSAllocatedUnfairLock(initialState: 0)

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.put.io"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, url.path == "/v2/files/list",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.listing(fileCount: Self.listedFiles.withLock { $0 }))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func listing(fileCount: Int) -> Data {
        let files = (0..<fileCount).map { file(id: 1_000 + $0, name: "File \($0).mp4", type: "VIDEO") }
        let json = """
        {
          "parent": \(file(id: 0, name: "Home", type: "FOLDER")),
          "files": [\(files.joined(separator: ","))],
          "cursor": null,
          "total": \(fileCount)
        }
        """
        return Data(json.utf8)
    }

    private static func file(id: Int, name: String, type: String) -> String {
        """
        {
          "id": \(id),
          "name": "\(name)",
          "icon": "\(type == "FOLDER" ? "folder" : "video")",
          "parent_id": 0,
          "size": 1048576,
          "created_at": "2026-04-24T10:00:00Z",
          "updated_at": "2026-04-24T10:00:00Z",
          "file_type": "\(type)",
          "is_shared": false,
          "sort_by": "NAME_ASC"
        }
        """
    }

    static func answerFilesList(with fileCount: Int, in testCase: XCTestCase) {
        listedFiles.withLock { $0 = fileCount }
        URLProtocol.registerClass(FilesListStub.self)
        testCase.addTeardownBlock { URLProtocol.unregisterClass(FilesListStub.self) }
    }
}

extension XCTestCase {
    func makeFilesNavigation() throws -> UINavigationController {
        let previousRealm = Realm.Configuration.defaultConfiguration
        let configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        Realm.Configuration.defaultConfiguration = configuration
        let realm = try XCTUnwrap(PutioRealm.open(context: "FilesListStub.realm", configuration: configuration))
        let user = Putio.User()
        user.settings = UserSettings()
        XCTAssertTrue(PutioRealm.write(realm, context: "FilesListStub.user") { realm.add(user) })

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let navigationController = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        addTeardownBlock {
            window.isHidden = true
            realm.invalidate()
            Realm.Configuration.defaultConfiguration = previousRealm
        }
        return navigationController
    }

    func pushLoadedFolder(onto navigationController: UINavigationController, listing fileCount: Int) throws -> FilesViewController {
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: FilesViewController.self))
        let folder = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "Files") as? FilesViewController)
        navigationController.pushViewController(folder, animated: false)
        navigationController.view.layoutIfNeeded()
        XCTAssertNotNil(folder.viewIfLoaded?.window)

        let loaded = expectation(for: NSPredicate { [weak folder] _, _ in
            folder?.tableView.numberOfRows(inSection: 0) == fileCount && folder?.viewModel.file != nil
        }, evaluatedWith: nil)
        wait(for: [loaded], timeout: 10)
        return folder
    }
}
