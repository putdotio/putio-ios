import Foundation
import PutioAPI
import RealmSwift

protocol RoutesViewModelDelegate: class {
    func stateChanged()
}

class RoutesViewModel {
    enum State {
        case idle
        case loading
        case success
        case failure(error: PutioAPIError)
    }

    enum ActionResult {
        case success
        case failure(error: PutioAPIError)
    }

    typealias ActionCompletion = ((_ result: ActionResult) -> Void)

    weak var delegate: RoutesViewModelDelegate?

    var state: State = .idle {
        didSet {
            self.delegate?.stateChanged()
        }
    }

    private var userSettings: UserSettings = {
        let realm = try! Realm()
        return realm.objects(User.self).first!.settings!
    }()

    var routes: [PutioRoute] = []

    func getSelectedRouteName() -> String {
        return userSettings.routeName
    }

    func fetchRoutes() {
        state = .loading

        api.getRoutes { result in
            switch result {
            case .success(let routes):
                self.routes = routes
                self.state = .success

            case .failure(let error):
                self.state = .failure(error: error)
            }
        }
    }

    func setRoute(route: PutioRoute, completion: @escaping ActionCompletion) {
        state = .loading

        api.saveAccountSettings(body: ["tunnel_route_name": route.name]) { result in
            switch result {
            case .success:
                let realm = try! Realm()
                try! realm.write {
                    self.userSettings.routeName = route.name
                }

                completion(.success)

            case .failure(let error):
                completion(.failure(error: error))
            }
        }
    }
}
