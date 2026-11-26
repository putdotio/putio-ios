import Foundation

extension PutioRuntime {
  public convenience init(
    clientID: String,
    clientName: String,
    callbackScheme: String = "putio",
    tokenStore: PutioTokenStore = PutioKeychainTokenStore(),
    signOutIntentStore: PutioSignOutIntentStore = PutioUserDefaultsSignOutIntentStore(),
    urlSession: URLSession = .shared,
    deviceCodePollInterval: Duration = .seconds(3),
    supportIdentityPlatform: String? = nil
  ) {
    self.init(
      clientID: clientID,
      clientName: clientName,
      callbackScheme: callbackScheme,
      tokenStore: tokenStore,
      signOutIntentStore: signOutIntentStore,
      urlSession: urlSession,
      deviceCodePollInterval: deviceCodePollInterval,
      supportIdentityPlatform: supportIdentityPlatform,
      isImageReadable: PutioQRCodeImage.isReadable
    )
  }
}
