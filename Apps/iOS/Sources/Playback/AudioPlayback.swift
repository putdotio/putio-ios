import AVKit
import PutioCore
import SwiftUI

struct PutioAudioRoutePicker: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let picker = AVRoutePickerView()
    picker.tintColor = UIColor(PutioTheme.Colors.textPrimary)
    picker.activeTintColor = UIColor(PutioTheme.Colors.accent)
    return picker
  }

  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
