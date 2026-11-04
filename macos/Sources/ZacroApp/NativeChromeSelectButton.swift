import AppKit
import SwiftUI

/// A browser-drawn trigger with AppKit's actual menu tracking, keyboard
/// navigation and pop-up accessibility. SwiftUI Menu extracts its label into
/// an Aqua cell, which loses our layout and reintroduces a leading arrow.
struct NativeChromeSelectButton: NSViewRepresentable {
  let title: String
  let selected: String
  let selectedIndex: Int?
  let options: [String]
  let optionKeys: [AnyHashable]
  let contextID: String
  let colors: NativeSpacePalette
  let enabled: Bool
  let choose: (Int) -> Void

  func makeNSView(context: Context) -> NativeChromeMenuButton { NativeChromeMenuButton(frame: .zero) }
  func updateNSView(_ button: NativeChromeMenuButton, context: Context) {
    button.configure(label: title, value: selected, selected: selectedIndex,
      options: options, optionKeys: optionKeys, contextID: contextID,
      colors: colors, enabled: enabled, choose: choose)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeChromeMenuButton,
    context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 34)
  }
  static func dismantleNSView(_ button: NativeChromeMenuButton, coordinator: ()) {
    button.dismissMenu()
    button.choose = nil
  }
}

@MainActor final class NativeChromeMenuButton: NSButton, NSMenuDelegate {
  var choose: ((Int) -> Void)?
  private var labels: [String] = []
  private var optionKeys: [AnyHashable] = []
  private var contextID = ""
  private var selectedIndex: Int?
  private var palette: NativeSpacePalette?
  private var menuGeneration = UUID()
  private var activeMenu: NSMenu?
  private var hovered = false
  private var hoverArea: NSTrackingArea?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { isEnabled }
  override var intrinsicContentSize: NSSize {
    let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
    return NSSize(width: max(72, ceil(width) + 39), height: 34)
  }

  override init(frame frameRect: NSRect) { super.init(frame: frameRect); install() }
  required init?(coder: NSCoder) { super.init(coder: coder); install() }
  private func install() {
    setButtonType(.momentaryPushIn)
    isBordered = false
    focusRingType = .none
    font = .systemFont(ofSize: 12)
    target = self
    action = #selector(openMenu)
    setAccessibilityRole(.popUpButton)
  }

  func configure(label: String, value: String, selected: Int?, options: [String],
    optionKeys: [AnyHashable], contextID: String,
    colors: NativeSpacePalette, enabled: Bool, choose: @escaping (Int) -> Void) {
    // A menu opened from an older profile/option set cannot choose an index
    // from the replacement set, even if cancellation races its final action.
    if labels != options || self.optionKeys != optionKeys || self.contextID != contextID
      || selectedIndex != selected || !enabled { dismissMenu() }
    let sizeChanged = title != value
    title = value; labels = options; self.optionKeys = optionKeys
    self.contextID = contextID; selectedIndex = selected
    palette = colors; isEnabled = enabled; self.choose = choose
    setAccessibilityLabel(label)
    setAccessibilityValue(value)
    if sizeChanged { invalidateIntrinsicContentSize() }
    needsDisplay = true
  }

  override func updateTrackingAreas() {
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(rect: .zero,
      options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
    addTrackingArea(area); hoverArea = area
    super.updateTrackingAreas()
  }
  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
  override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow !== window { dismissMenu() }
    super.viewWillMove(toWindow: newWindow)
  }
  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
      [" ", "\r", "\n", "\u{f700}", "\u{f701}"].contains(event.charactersIgnoringModifiers ?? "") {
      openMenu(); return
    }
    super.keyDown(with: event)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let colors = palette else { return }
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
    NSColor(hovered && isEnabled ? colors.hover : colors.card.opacity(0.84)).setFill(); shape.fill()
    NSColor(colors.line).setStroke(); shape.lineWidth = 1; shape.stroke()
    if window?.firstResponder === self {
      NSColor(colors.accent).withAlphaComponent(0.7).setStroke()
      shape.lineWidth = 1.5; shape.stroke()
    }
    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
    let glyphRect = CGRect(x: bounds.maxX - 21, y: bounds.midY - 6, width: 12, height: 12)
    let textRect = NSRect(x: bounds.minX + 9, y: bounds.midY - 8,
      width: max(0, glyphRect.minX - 6 - (bounds.minX + 9)), height: 16)
    (title as NSString).draw(in: textRect, withAttributes: [
      .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(colors.ink), .paragraphStyle: paragraph,
    ])
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.setStrokeColor(NSColor(colors.ink).cgColor)
    context.setLineWidth(12 * 1.7 / 24); context.setLineCap(.round); context.setLineJoin(.round)
    context.addPath(NativeGlyph.cgPath("down", in: glyphRect))
    context.strokePath(); context.restoreGState()
  }

  @objc private func openMenu() {
    guard isEnabled, window?.isVisible == true, NSApp.isActive, !labels.isEmpty else { return }
    dismissMenu()
    let generation = UUID(); menuGeneration = generation
    let menu = NSMenu(title: accessibilityLabel() ?? "")
    menu.autoenablesItems = false; menu.delegate = self
    for (index, label) in labels.enumerated() {
      let item = NSMenuItem(title: label, action: #selector(selectItem(_:)), keyEquivalent: "")
      item.target = self; item.tag = index; item.representedObject = generation
      item.state = index == selectedIndex ? .on : .off
      menu.addItem(item)
    }
    activeMenu = menu
    let item = selectedIndex.flatMap { menu.items.indices.contains($0) ? menu.items[$0] : nil }
    menu.popUp(positioning: item, at: NSPoint(x: 9, y: bounds.midY), in: self)
    if activeMenu === menu { activeMenu = nil }
  }
  @objc private func selectItem(_ item: NSMenuItem) {
    guard isEnabled, item.representedObject as? UUID == menuGeneration,
      labels.indices.contains(item.tag) else { return }
    choose?(item.tag)
  }
  func dismissMenu() {
    menuGeneration = UUID()
    activeMenu?.cancelTracking(); activeMenu = nil
  }
  func menuDidClose(_ menu: NSMenu) { if activeMenu === menu { activeMenu = nil } }
}
