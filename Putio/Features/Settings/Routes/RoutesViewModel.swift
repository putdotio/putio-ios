import Foundation
import PutioSDK
import RealmSwift

protocol RoutesViewModelDelegate: AnyObject {
    func stateChanged()
}

class RoutesViewModel {
    enum State {
        case idle
        case loading
        case success
        case failure(error: PutioSDKError)
    }

    enum ActionResult {
        case success
        case failure(error: PutioSDKError)
    }

    typealias ActionCompletion = ((_ result: ActionResult) -> Void)

    weak var delegate: RoutesViewModelDelegate?

    var state: State = .idle {
        didSet {
            self.delegate?.stateChanged()
        }
    }

    private var userSettings = UserSettings()

    init() {
        reloadPersistedState()
    }

    var routes: [PutioRoute] = []

    func getSelectedRouteName() -> String {
        return userSettings.routeName
    }

    private func reloadPersistedState() {
        guard let realm = PutioRealm.open(context: "RoutesViewModel.reloadPersistedState"),
              let persistedSettings = realm.objects(User.self).first?.settings else {
            return
        }

        userSettings = persistedSettings
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

        api.saveAccountSettings(.patch(PutioAccountSettingsPatch(tunnelRouteName: route.name))) { result in
            switch result {
            case .success:
                if let realm = self.userSettings.realm ?? PutioRealm.open(context: "RoutesViewModel.setRoute") {
                    _ = PutioRealm.write(realm, context: "RoutesViewModel.setRoute.write") {
                        self.userSettings.routeName = route.name
                    }
                } else {
                    self.userSettings.routeName = route.name
                    InternalFailurePresenter.log("Unable to load Realm while persisting selected route")
                }

                completion(.success)

            case .failure(let error):
                completion(.failure(error: error))
            }
        }
    }
}
