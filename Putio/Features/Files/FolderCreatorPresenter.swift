import Foundation
import UIKit
import PutioAPI

protocol FolderCreatorPresenter {}

extension FolderCreatorPresenter where Self: UIViewController {
    func createFolderCreatorAlert(parentID: Int, completion: @escaping (Bool, Error?) -> Void) -> UIAlertController {
        let createFolderAlert = UIAlertController(
            title: "Create New Folder",
            message: nil,
            preferredStyle: .alert
        )

        createFolderAlert.addTextField { (textField) -> Void in
            textField.placeholder = "Folder Name"
            textField.autocorrectionType = .no
        }

        createFolderAlert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))

        createFolderAlert.addAction(UIAlertAction(title: "Create", style: .default, handler: { (_) in
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
