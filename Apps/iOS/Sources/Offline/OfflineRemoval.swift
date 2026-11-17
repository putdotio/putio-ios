import Foundation

struct PutioOfflineRemovalCopy: Equatable {
  let isPad: Bool

  var actionTitle: String {
    isPad
      ? String(localized: "Remove from this iPad")
      : String(localized: "Remove from this iPhone")
  }

  func title(count: Int) -> String {
    switch (count == 1, isPad) {
    case (true, true): String(localized: "Remove from this iPad?")
    case (true, false): String(localized: "Remove from this iPhone?")
    case (false, true): String(localized: "Remove \(count) downloads from this iPad?")
    case (false, false): String(localized: "Remove \(count) downloads from this iPhone?")
    }
  }

  func message(names: [String]) -> String {
    switch (names.count == 1 ? names.first : nil, isPad) {
    case (let name?, true):
      String(
        localized: "“\(name)” stays in your put.io files. Only the copy on this iPad is removed.")
    case (let name?, false):
      String(
        localized: "“\(name)” stays in your put.io files. Only the copy on this iPhone is removed.")
    case (nil, true):
      String(
        localized:
          "The files stay in your put.io account. Only the copies on this iPad are removed.")
    case (nil, false):
      String(
        localized:
          "The files stay in your put.io account. Only the copies on this iPhone are removed.")
    }
  }

  func failureTitle(count: Int) -> String {
    count == 1
      ? String(localized: "Could not remove download")
      : String(localized: "Could not remove downloads")
  }

  func failureMessage(count: Int) -> String {
    switch (count == 1, isPad) {
    case (true, true):
      String(
        localized:
          "Nothing was removed because this iPad could not save the change. Remove the download again."
      )
    case (true, false):
      String(
        localized:
          "Nothing was removed because this iPhone could not save the change. Remove the download again."
      )
    case (false, true):
      String(
        localized:
          "Nothing was removed because this iPad could not save the change. Remove the downloads again."
      )
    case (false, false):
      String(
        localized:
          "Nothing was removed because this iPhone could not save the change. Remove the downloads again."
      )
    }
  }
}
