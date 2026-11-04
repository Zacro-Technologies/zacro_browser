import AppKit
import SwiftUI
import ZacroCore

/// Actual shared chrome components rendered in an unpresented owned window.
/// Native menu pop-up drawing and desktop composition are separate gates.
@MainActor enum NativeChromeControlRenderEvidence {
  static func capture(directory: URL) async throws {
    guard CommandLine.arguments.contains("--native-integration-acceptance"),
      ProcessInfo.processInfo.environment["ZACRO_RENDER_EVIDENCE"] == "1" else { return }
    for dark in [false, true] {
      for width in [CGFloat(340), CGFloat(560)] {
        let colors = NativeSpacePalette(theme: SpaceTheme(), dark: dark)
        let size = NSSize(width: width, height: 540)
        let view = NSHostingView(rootView: Controls(colors: colors)
          .environment(\.colorScheme, dark ? .dark : .light)
          .frame(width: size.width, height: size.height).background(colors.chrome))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        await Task.yield()
        view.layoutSubtreeIfNeeded()
        try NativeViewRenderEvidence.capture("chrome-controls-\(dark ? "dark" : "light")-\(Int(width))", window: window)
      }
    }
  }

  private struct Controls: View {
    let colors: NativeSpacePalette
    @State private var enabled = true
    @State private var disabled = false
    @State private var checked = true
    @State private var expanded = true
    @State private var selection = "system"
    @State private var value = "Reading and research"
    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        Text("Browser controls").font(.system(size: 17, weight: .semibold))
        HStack(spacing: 12) {
          ForEach(["sidebar", "back", "forward", "reload", "pageControls", "extension", "sparkle", "shield"], id: \.self) {
            NativeGlyph($0, size: 18)
          }
        }.foregroundStyle(colors.accent)
        HStack(spacing: 10) {
          Button("Save changes") {}.buttonStyle(NativeChromeButtonStyle(colors: colors, prominent: true))
          Button("Cancel") {}.buttonStyle(NativeChromeButtonStyle(colors: colors))
          Button("Unavailable") {}.buttonStyle(NativeChromeButtonStyle(colors: colors)).disabled(true)
        }
        Toggle("Restore session", isOn: $enabled).toggleStyle(NativeChromeToggleStyle(colors: colors))
        Toggle("Unavailable setting", isOn: $disabled).toggleStyle(NativeChromeToggleStyle(colors: colors)).disabled(true)
        Toggle("Include the selected pages", isOn: $checked).toggleStyle(NativeChromeCheckboxStyle(colors: colors))
        NativeChromeSelect(title: "Appearance", selection: $selection,
          options: [("system", "Follow system"), ("light", "Light"), ("dark", "Dark")], colors: colors)
        TextField("Name", text: $value).textFieldStyle(NativeChromeTextFieldStyle(colors: colors))
        DisclosureGroup("Layout & motion", isExpanded: $expanded) {
          Text("The same original glyph and custom disclosure surface are used in browser settings.")
            .font(.system(size: 12)).foregroundStyle(colors.muted).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
        }.disclosureGroupStyle(NativeChromeDisclosureStyle(colors: colors))
        HStack(spacing: 16) {
          ProgressView().progressViewStyle(NativeChromeProgressStyle(colors: colors))
          ProgressView(value: 0.62).progressViewStyle(NativeChromeProgressStyle(colors: colors))
        }
        Text("Continuous pane contour · no content outline").font(.system(size: 11)).foregroundStyle(colors.muted)
        NativePaneShape(radius: 12).fill(colors.surface).frame(height: 42)
        Spacer(minLength: 0)
      }.padding(20).font(.system(size: 12)).foregroundStyle(colors.ink)
    }
  }
}
