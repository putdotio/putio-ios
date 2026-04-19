import Foundation
import UIKit
import PutioSDK

protocol FolderCreatorPresenter {}

extension FolderCreatorPresenter where Self: UIViewController {
    func createFolderCreatorAlert(parentID: Int, completion: @escaping (Bool, Error?) -> Void) -> UIAlertController {
        let createFolderAlert = UIAlertController(
            title: NSLocalizedString("Create New Folder", comment: ""),
            message: nil,
            preferredStyle: .alert
        )

        createFolderAlert.addTextField { textField in
            textField.placeholder = NSLocalizedString("Folder Name", comment: "")
            textField.autocorrectionType = .no
        }

        createFolderAlert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: nil))

        createFolderAlert.addAction(UIAlertAction(title: NSLocalizedString("Create", comment: ""), style: .default, handler: { (_) in
            let folderName = createFolderAlert.textFields![0].text!

            api.createFolder(name: folderName, parentID: parentID, completion: { result in
                switch result {
                case .success:
                    completion(true, nil)
                case .failure(let error):
                    completion(false, error)
                }
            })
        }))

        return createFolderAlert
    }
}
