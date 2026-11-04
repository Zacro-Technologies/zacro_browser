import AppKit
import SwiftUI

/// A native editable field inside the browser's own surface. AppKit receives
/// pointer, selection and IME input directly, including an empty field.
struct NativeChromeTextInput: View {
  let placeholder: String
  @Binding var text: String
  let colors: NativeSpacePalette
  let identifier: String
  var maximumLength: Int? = nil
  @Environment(\.isEnabled) private var enabled
  @Environment(\.nativeChromeControlContext) private var contextID

  var body: some View {
    NativeChromeTextInputField(placeholder: placeholder, text: $text, identifier: identifier,
      maximumLength: maximumLength, ink: NSColor(colors.ink), muted: NSColor(colors.muted),
      enabled: enabled, contextID: contextID)
      .frame(maxWidth: .infinity).frame(height: 16)
      .padding(.horizontal, 9).padding(.vertical, 7)
      .background(colors.card.opacity(0.84), in: RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7).strokeBorder(colors.line, lineWidth: 1)
          .allowsHitTesting(false).accessibilityHidden(true)
      }
  }
}

private struct NativeChromeTextInputField: NSViewRepresentable {
  let placeholder: String
  @Binding var text: String
  let identifier: String
  let maximumLength: Int?
  let ink: NSColor
  let muted: NSColor
  let enabled: Bool
  let contextID: String

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(frame: .zero)
    field.isEditable = true; field.isSelectable = true
    field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
    field.font = .systemFont(ofSize: 12); field.isContinuous = true
    field.maximumNumberOfLines = 1; field.cell?.wraps = false; field.cell?.isScrollable = true
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    context.coordinator.field = field
    field.delegate = context.coordinator
    return field
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? max(1, nsView.intrinsicContentSize.width), height: 16)
  }
  func updateNSView(_ field: NSTextField, context: Context) {
    let coordinator = context.coordinator
    if let previous = coordinator.parent,
      previous.contextID != contextID || previous.identifier != identifier || !enabled {
      coordinator.retiring = true
      coordinator.endOwnedEditing(field)
      coordinator.retiring = false
    }
    coordinator.parent = self
    field.identifier = NSUserInterfaceItemIdentifier(identifier)
    field.setAccessibilityIdentifier(identifier); field.setAccessibilityLabel(placeholder)
    field.textColor = ink; field.isEnabled = enabled
    field.placeholderAttributedString = NSAttributedString(string: placeholder,
      attributes: [.foregroundColor: muted, .font: NSFont.systemFont(ofSize: 12)])
    (field.currentEditor() as? NSTextView)?.insertionPointColor = ink
    guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
    coordinator.render(text, in: field)
  }
  static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
    coordinator.retiring = true
    coordinator.endOwnedEditing(field)
    field.delegate = nil; coordinator.parent = nil; coordinator.field = nil
  }

  @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
    weak var field: NSTextField?
    var parent: NativeChromeTextInputField?
    var retiring = false

    func endOwnedEditing(_ field: NSTextField) {
      guard self.field === field, let window = field.window, let editor = field.currentEditor(),
        editor.window === window, window.firstResponder === editor else { return }
      _ = window.makeFirstResponder(nil)
    }
    func render(_ value: String, in field: NSTextField) {
      let editor = field.currentEditor() as? NSTextView
      guard editor?.hasMarkedText() != true else { return }
      guard field.stringValue != value || editor.map({ $0.string != value }) == true else { return }
      let selection = editor?.selectedRanges
      if field.stringValue != value { field.stringValue = value }
      if let editor, editor.string != value { editor.string = value }
      // Assigning an unchanged model value must not move the insertion point.
      if let editor, let selection {
        let length = (value as NSString).length
        editor.selectedRanges = selection.map { selected in
          let range = selected.rangeValue
          let start = range.location == NSNotFound ? length : min(length, range.location)
          return NSValue(range: NSRange(location: start, length: min(range.length, length - start)))
        }
      }
    }
    private func publish(_ notification: Notification) {
      guard !retiring, let parent, let field, notification.object as? NSTextField === field,
        field.isEnabled else { return }
      let editor = field.currentEditor() as? NSTextView
      guard editor?.hasMarkedText() != true else { return }
      let raw = editor?.string ?? field.stringValue
      let canonical = parent.maximumLength.map { String(raw.prefix(max(0, $0))) } ?? raw
      if canonical != raw { render(canonical, in: field) }
      if parent.text != canonical { parent.text = canonical }
    }
    func controlTextDidChange(_ notification: Notification) { publish(notification) }
    func controlTextDidEndEditing(_ notification: Notification) { publish(notification) }
  }
}
