import Foundation
import UniformTypeIdentifiers

extension PutioRuntime {
  public func resolveCastAudio(fileID: PutioFileID) async throws -> PutioCastMedia {
    try await resolveCastAudio(fileID: fileID, contentType: Self.audioContentType(fileName:))
  }

  static func audioContentType(fileName: String) -> String {
    let fileExtension = (fileName as NSString).pathExtension
    return UTType(filenameExtension: fileExtension, conformingTo: .audio)?.preferredMIMEType
      ?? "audio/mpeg"
  }
}
