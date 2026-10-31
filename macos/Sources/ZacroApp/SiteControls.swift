import AppKit
import SwiftUI

/// A snapshot of the selected native page and its real engine actions. No page
/// credentials, cookie state or invented extension metadata belongs in this view.
@MainActor
struct SiteControlActions {
  var url: URL?
  var title: String = ""
  var profileName: String = "Personal"
  var isPrivate = false
  var isBookmarked = false
  var zoomPercent: Int = 100
  var bookmark: () -> Void = {}
  var printPage: () -> Void = {}
  var find: () -> Void = {}
  var zoomIn: () -> Void = {}
  var zoomOut: () -> Void = {}
  var resetZoom: () -> Void = {}
  var developerTools: () -> Void = {}
  var showExtensions: () -> Void = {}
  var manageExtensions: () -> Void = {}
  var extensionStore: () -> Void = {}

  var hasWebPage: Bool { ["http", "https"].contains(url?.scheme?.lowercased() ?? "") }
  var origin: String {
    guard let url, let host = url.host else { return "No website open" }
    return host + (url.port.map { ":\($0)" } ?? "")
  }
}

/// Native, quiet translucent site controls. Chromium's own Extensions surface
/// owns the real installed-extension list until a supported metadata/action API
/// can supply an equivalent custom toolbar.
struct SiteControls: View {
  let actions: SiteControlActions
  var accent: Color = .accentColor
  @Environment(\.dismiss) private var dismiss
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 17) {
      HStack(spacing: 8) {
        if let url = actions.url, actions.hasWebPage {
          ShareLink(item: url) {
            quickGlyph("square.and.arrow.up", label: "Share page")
          }
          .buttonStyle(.plain)
          .help("Share page")
        } else {
          Button {
          } label: {
            quickGlyph("square.and.arrow.up", label: "Share page")
          }
          .buttonStyle(.plain).disabled(true)
        }
        Button {
          guard let url = actions.url else { return }
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(url.absoluteString, forType: .string)
          copied = true
        } label: {
          quickGlyph(
            copied ? "checkmark" : "link", label: copied ? "Address copied" : "Copy address")
        }
        .buttonStyle(.plain).disabled(!actions.hasWebPage).help("Copy address")
        Button {
          perform(actions.bookmark)
        } label: {
          quickGlyph(
            actions.isBookmarked ? "bookmark.fill" : "bookmark",
            label: actions.isBookmarked ? "Remove bookmark" : "Bookmark page")
        }.buttonStyle(.plain).disabled(!actions.hasWebPage)
        Button {
          perform(actions.printPage)
        } label: {
          quickGlyph("printer", label: "Print page")
        }
        .buttonStyle(.plain).disabled(!actions.hasWebPage)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Extensions").font(.system(size: 14, weight: .semibold))
        actionRow("Use extensions", symbol: "puzzlepiece.extension", action: actions.showExtensions)
          .disabled(!actions.hasWebPage || actions.isPrivate)
        HStack(spacing: 9) {
          Button("Manage", action: { perform(actions.manageExtensions) })
          Spacer()
          Button("Browse extensions", action: { perform(actions.extensionStore) })
        }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
          .disabled(actions.isPrivate)
      }

      Divider().opacity(0.55)

      VStack(spacing: 7) {
        HStack(spacing: 10) {
          rowIcon("textformat.size")
          Text("Zoom").font(.system(size: 13, weight: .medium))
          Spacer()
          Button(action: actions.zoomOut) {
            Image(systemName: "minus").frame(width: 24, height: 26)
          }
          .help("Zoom out")
          Button("\(actions.zoomPercent)%", action: actions.resetZoom)
            .monospacedDigit().frame(minWidth: 40).help("Reset zoom")
          Button(action: actions.zoomIn) { Image(systemName: "plus").frame(width: 24, height: 26) }
            .help("Zoom in")
        }.buttonStyle(.plain).disabled(!actions.hasWebPage)
        actionRow("Find in page", symbol: "doc.text.magnifyingglass", action: actions.find)
          .disabled(!actions.hasWebPage)
        actionRow("Developer tools", symbol: "hammer", action: actions.developerTools)
          .disabled(!actions.hasWebPage)
      }

      Divider().opacity(0.55)

      HStack(alignment: .top, spacing: 10) {
        Image(systemName: actions.url?.scheme == "https" ? "lock" : "globe")
          .foregroundStyle(accent).padding(.top, 2)
        VStack(alignment: .leading, spacing: 4) {
          Text(actions.origin).font(.system(size: 12, weight: .semibold)).lineLimit(1)
          Text(connectionLabel).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 3)
        Image(systemName: actions.isPrivate ? "eye.slash" : "person.crop.circle")
          .foregroundStyle(.secondary)
          .help(actions.isPrivate ? "Private · \(actions.profileName)" : actions.profileName)
      }
    }
    .padding(17)
    .frame(width: 310)
    .background(accent.opacity(0.035))
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .tint(accent)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Site controls")
  }

  private var connectionLabel: String {
    guard actions.hasWebPage else {
      return actions.isPrivate ? "Private profile" : actions.profileName
    }
    let transport =
      actions.url?.scheme?.lowercased() == "https"
      ? "HTTPS connection" : "Unencrypted HTTP connection"
    return actions.isPrivate ? "\(transport) · Private" : transport
  }

  private func quickGlyph(_ symbol: String, label: String) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 18, weight: .medium))
      .foregroundStyle(accent)
      .frame(maxWidth: .infinity)
      .frame(height: 43)
      .background(
        Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous)
      )
      .accessibilityLabel(label)
  }

  private func rowIcon(_ symbol: String) -> some View {
    Image(systemName: symbol).font(.system(size: 15, weight: .medium))
      .foregroundStyle(accent)
      .frame(width: 33, height: 33)
      .background(accent.opacity(0.09), in: Circle())
  }

  private func actionRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View
  {
    Button {
      perform(action)
    } label: {
      HStack(spacing: 10) {
        rowIcon(symbol)
        Text(title).font(.system(size: 13, weight: .medium))
        Spacer()
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
      }.contentShape(Rectangle())
    }.buttonStyle(.plain)
  }

  private func perform(_ action: @escaping () -> Void) {
    dismiss()
    // Let AppKit dismiss the popover before Chromium opens its native menu,
    // print dialog or developer-tools window.
    DispatchQueue.main.async(execute: action)
  }
}
