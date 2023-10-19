import Foundation
import PutioAPI

class FilesViewModel {
    var fileID: Int = 0

    var file: PutioFile? {
        didSet {
            if let file = self.file {
                self.fileID = file.id
            }
        }
    }

    var files: [PutioFile] = []

    func getSelectableFiles() -> [PutioFile] {
        return files.filter {!$0.isSharedRoot}
    }
}
