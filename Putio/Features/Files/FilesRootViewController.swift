import UIKit
import PutioSDK

class FilesRootViewController: FilesViewController {
    let filesDebouncer = Debouncer(delay: 0.2)
    let searchDebouncer = Debouncer(delay: 0.2)
    var searchController: UISearchController?

    enum Mode {
        case files
        case search(cachedFiles: [PutioFile])
    }

    var mode: Mode = .files {
        didSet {
            handleModeTransition()
        }
    }

    override func configureStateMachine() {
        super.configureStateMachine()
        let emptySearchResultsView = EmptyStateView.instantiateFromInterfaceBuilder()
        emptySearchResultsView.configure(
            heading: NSLocalizedString("No search result", comment: ""),
            description: NSLocalizedString("We couldn't find anything for that.", comment: "")
        )
        stateMachine.addView(emptySearchResultsView, forState: "emptySearchResults")
    }

    override func configureAppearance() {
        super.configureAppearance()

        navigationItem.title = NSLocalizedString("Your Files", comment: "")

        configureSearchbar()
    }

    func configureSearchbar() {
        definesPresentationContext = true

        searchController = UISearchController(searchResultsController: nil)
        searchController?.searchBar.delegate = self
        searchController?.searchBar.returnKeyType = .done
        searchController?.obscuresBackgroundDuringPresentation = false
        searchController?.hidesNavigationBarDuringPresentation = false

        if let searchController = searchController {
            Stylize.searchBar(searchController.searchBar)
        }

        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.title = NSLocalizedString("Your Files", comment: "")
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        searchController?.isActive = false
    }

    override func handlePossibleNetworkTransition() {
        switch mode {
        case .files:
            fetchData(withLoader: true)

        case .search:
            guard let searchText = searchController?.searchBar.text else { return }
            performSearch(keyword: searchText)
        }
    }

    func handleModeTransition() {
        switch mode {
        case .files:
            tableView.reloadData()
            tableView.refreshControl = UIRefreshControl()
            tableView.refreshControl?.addTarget(self, action: #selector(fetchData), for: .valueChanged)

            filesDebouncer.run {
                self.fetchData(withLoader: false)
            }

        case .search:
            tableView.reloadData()
            tableView.refreshControl = nil
        }
    }

    func performSearch(keyword: String) {
        switch mode {
        case .files:
            mode = .search(cachedFiles: viewModel.files)
        default:
            break
        }

        stateMachine.transitionToState(.view("loading"))

        api.searchFiles(keyword: keyword, perPage: 50) { result in
            switch result {
            case .success(let data):
                self.viewModel.files = data.files
                self.tableView.reloadData()

                if self.viewModel.files.count == 0 {
                    return self.stateMachine.transitionToState(.view("emptySearchResults"))
                }

                return self.stateMachine.transitionToState(.none)

            case .failure(let error):
                switch error.type {
                case .httpError:
                    self.stateMachine.transitionToState(.view("error"))

                case .networkError:
                    self.stateMachine.transitionToState(.view("offline"))

                case .decodingError, .unknownError:
                    self.stateMachine.transitionToState(.view("error"))
                }
            }
        }
    }

    func cancelSearch() {
        switch mode {
        case .search(let cachedFiles):
            viewModel.files = cachedFiles
            mode = .files

        case .files:
            break
        }
    }
}

extension FilesRootViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        guard searchText != "" else {
            return cancelSearch()
        }

        searchDebouncer.run {
            self.performSearch(keyword: searchText)
        }
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        cancelSearch()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
