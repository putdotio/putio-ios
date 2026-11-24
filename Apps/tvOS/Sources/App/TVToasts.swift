import Observation
import PutioCore

@MainActor
@Observable
final class TVToasts {
  var current: PutioToast?

  func show(_ toast: PutioToast) {
    current = toast
  }
}
