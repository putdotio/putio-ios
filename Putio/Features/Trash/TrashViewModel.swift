import Foundation
import PutioSDK

protocol TrashViewModelDelegate: AnyObject {
    func stateChanged()
}

class TrashViewModel {
    enum State {
        case idle
        case loading
        case empty
        case loaded
        case refreshing
        case failure(error: Error)
    }

    enum ActionResult {
        case success
        case failure(error: Error)
    }

    typealias ActionCompletion = ((_ result: ActionResult) -> Void)

    weak var delegate: TrashViewModelDelegate?

    var state: State = .idle {
        didSet {
            self.delegate?.stateChanged()
        }
    }

    var cursor: String = ""

    var files: [PutioTrashFile] = [] {
        didSet {
            if files.count == 0 {
                self.state = .empty
            } else {
                self.state = .loaded
            }
        }
    }

    var trashSize: Int64 = 0 {
        didSet {
            guard let realm = PutioRealm.open(context: "TrashViewModel.trashSize"),
                let user = realm.objects(User.self).first else { return }

            _ = PutioRealm.write(realm, context: "TrashViewModel.trashSize") {
                user.trashSize = self.trashSize
            }
        }
    }

    private func fetchData() {
        api.listTrash { result in
            switch result {
            case .success(let data):
                self.cursor = data.cursor
                self.files = data.files
                self.trashSize = data.trash_size

            case .failure(let error):
                self.state = .failure(error: error)
            }
        }
    }

    func fetchFiles() {
        state = .loading
        fetchData()
    }

    func refetchFiles() {
        state = .refreshing
        fetchData()
    }

    func restoreAllFiles(completion: @escaping ActionCompletion) {
        state = .loading

        api.restoreTrashFiles(fileIDs: files.map { $0.id }, cursor: nil) { result in
            switch result {
            case .success:
                completion(.success)
                self.fetchFiles()

            case .failure(let error):
                self.state = .loaded
                completion(.failure(error: error))
            }
        }
    }

    func restoreFiles(fileIDs: [Int], completion: @escaping ActionCompletion) {
        state = .loading

        api.restoreTrashFiles(fileIDs: fileIDs, cursor: nil) { result in
            switch result {
            case .success:
                completion(.success)
                self.fetchFiles()

            case .failure(let error):
                self.state = .loaded
                completion(.failure(error: error))
            }
        }
    }

    func emptyTrash(completion: @escaping ActionCompletion) {
        state = .loading

        api.emptyTrash { result in
            switch result {
            case .success:
                completion(.success)
                self.fetchFiles()

            case .failure(let error):
                self.state = .loaded
                completion(.failure(error: error))
            }
        }
    }

    func deleteFiles(fileIDs: [Int], completion: @escaping ActionCompletion) {
        state = .loading

        api.deleteTrashFiles(fileIDs: fileIDs, cursor: nil) { result in
            switch result {
            case .success:
                completion(.success)
                self.fetchFiles()

            case .failure(let error):
                self.state = .loaded
                completion(.failure(error: error))
            }
        }
    }

    func deleteFile(fileID: Int, completion: @escaping ActionCompletion) {
        api.deleteTrashFiles(fileIDs: [fileID], cursor: nil) { result in
            switch result {
            case .success:
                self.files = self.files.filter { $0.id != fileID }
                completion(.success)

            case .failure(let error):
                completion(.failure(error: error))
            }
        }
    }
}
