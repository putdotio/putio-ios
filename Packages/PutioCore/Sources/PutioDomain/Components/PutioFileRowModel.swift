import Foundation

public struct PutioFileRowModel: Equatable, Sendable {
  public enum Kind: CaseIterable, Sendable {
    case folder
    case video
    case audio
    case image
    case pdf
    case text
    case archive
    case file
  }

  public let name: String
  public let kind: Kind
  public let locationText: String?
  public let sizeText: String?
  public let dateText: String?
  public let secondaryText: String?
  public let isOnDevice: Bool
  public let isWatched: Bool
  public let showsDisclosure: Bool
  public let downloadState: PutioDownloadState

  public init(
    name: String,
    kind: Kind,
    locationText: String? = nil,
    sizeText: String? = nil,
    dateText: String? = nil,
    secondaryText: String? = nil,
    isOnDevice: Bool = false,
    isWatched: Bool = false,
    showsDisclosure: Bool = true,
    downloadState: PutioDownloadState = .idle
  ) {
    self.name = name
    self.kind = kind
    self.locationText = locationText
    self.sizeText = sizeText
    self.dateText = dateText
    self.secondaryText = secondaryText
    self.isOnDevice = isOnDevice
    self.isWatched = isWatched
    self.showsDisclosure = showsDisclosure
    self.downloadState = downloadState
  }

  public static func sizeText(bytes: Int64, locale: Locale = .current) -> String {
    guard bytes > 0 else { return "0 B" }
    return bytes.formatted(ByteCountFormatStyle(style: .file, locale: locale))
  }

  package var icon: PutioIcon { kind.icon }

  #if os(tvOS)
    package var detailText: String? {
      let parts = [sizeText, dateText].compactMap { $0 }
      return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
  #endif
}

extension PutioFileRowModel.Kind {
  public var icon: PutioIcon {
    #if os(tvOS)
      switch self {
      case .folder: .folderFill
      case .video: .fileVideo
      case .audio: .fileAudio
      case .image: .image
      case .pdf, .text, .archive, .file: .file
      }
    #else
      switch self {
      case .folder: .folderFill
      case .video: .fileVideoFill
      case .audio: .fileAudioFill
      case .image: .fileImageFill
      case .pdf: .filePdfFill
      case .text: .fileTextFill
      case .archive: .fileZipFill
      case .file: .fileFill
      }
    #endif
  }
}
