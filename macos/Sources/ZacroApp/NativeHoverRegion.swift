import SwiftUI

/// Pointer feedback invalidates only this row's contents, not the browser shell
/// and every retained Space page. Native focus and button behavior stay with
/// the supplied content, including independently hovered nested controls.
struct NativeHoverRegion<Content: View>: View {
  var isEnabled = true
  @ViewBuilder var content: (Bool) -> Content
  @State private var hovered = false

  var body: some View {
    content(hovered)
      .onHover { value in
        let next = isEnabled && value
        if hovered != next { hovered = next }
      }
      .onChange(of: isEnabled) { _, enabled in if !enabled { hovered = false } }
      .onDisappear { hovered = false }
  }
}
