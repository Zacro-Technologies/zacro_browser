import AppKit
import CCefAppKit
import Testing

@testable import CefKit

/// Exercise actual native setters without loading CEF or presenting a window.
@MainActor
@Suite struct ChromePageSurfaceTests {
    @Test func repeatedPreparationPreservesNativePropertiesWithoutWritingThemAgain() throws {
        CEFApplication.install()
        let window = SurfaceWindow(contentRect: CGRect(x: 20, y: 30, width: 320, height: 240),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = SurfaceView(frame: CGRect(origin: .zero, size: window.frame.size))
        window.contentView = content
        window.isOpaque = true
        window.backgroundColor = .white
        window.hasShadow = true
        let frame = window.frame
        let style = window.styleMask
        let layer = try #require(CefChromeBrowser.preparePageLayer(in: window))
        let firstWrites = [window.opacityWrites, window.backgroundWrites, window.shadowWrites,
            content.layerWrites]

        for _ in 0..<20 {
            #expect(CefChromeBrowser.preparePageLayer(in: window) === layer)
        }

        #expect([window.opacityWrites, window.backgroundWrites, window.shadowWrites,
            content.layerWrites] == firstWrites)
        #expect(!window.isOpaque && window.backgroundColor == .clear && !window.hasShadow)
        #expect(content.wantsLayer && content.layer === layer)
        #expect(window.frame == frame && window.styleMask == style && !window.isVisible)
    }

    @Test func preparationRepairsChangedPropertiesAndUsesReplacementContent() throws {
        CEFApplication.install()
        let window = SurfaceWindow(contentRect: CGRect(x: 20, y: 30, width: 320, height: 240),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = SurfaceView(frame: CGRect(origin: .zero, size: window.frame.size))
        window.contentView = content
        let originalLayer = try #require(CefChromeBrowser.preparePageLayer(in: window))
        window.isOpaque = true
        window.backgroundColor = .red
        window.hasShadow = true
        let changedWrites = [window.opacityWrites, window.backgroundWrites, window.shadowWrites]

        #expect(CefChromeBrowser.preparePageLayer(in: window) === originalLayer)
        #expect(!window.isOpaque && window.backgroundColor == .clear && !window.hasShadow)
        #expect(window.opacityWrites > changedWrites[0]
            && window.backgroundWrites > changedWrites[1] && window.shadowWrites > changedWrites[2])

        let replacement = SurfaceView(frame: content.frame)
        window.contentView = replacement
        let replacementLayer = try #require(CefChromeBrowser.preparePageLayer(in: window))
        #expect(replacement.wantsLayer && replacement.layer === replacementLayer)
        #expect(replacementLayer !== originalLayer)
        #expect(!window.isVisible)
    }

    private final class SurfaceWindow: NSWindow {
        var opacityWrites = 0
        var backgroundWrites = 0
        var shadowWrites = 0
        override var isOpaque: Bool {
            get { super.isOpaque }
            set { opacityWrites += 1; super.isOpaque = newValue }
        }
        override var backgroundColor: NSColor! {
            get { super.backgroundColor }
            set { backgroundWrites += 1; super.backgroundColor = newValue }
        }
        override var hasShadow: Bool {
            get { super.hasShadow }
            set { shadowWrites += 1; super.hasShadow = newValue }
        }
    }
    private final class SurfaceView: NSView {
        var layerWrites = 0
        override var wantsLayer: Bool {
            get { super.wantsLayer }
            set { layerWrites += 1; super.wantsLayer = newValue }
        }
    }
}
