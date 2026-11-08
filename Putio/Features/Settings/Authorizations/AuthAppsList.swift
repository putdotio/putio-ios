import PutioSDK

enum AuthAppsList {
    static func removingGrant(
        id grantID: Int,
        from apps: [PutioOAuthGrant]
    ) -> (apps: [PutioOAuthGrant], removedIndex: Int?) {
        guard let index = apps.firstIndex(where: { $0.id == grantID }) else {
            return (apps, nil)
        }

        var remaining = apps
        remaining.remove(at: index)
        return (remaining, index)
    }
}
