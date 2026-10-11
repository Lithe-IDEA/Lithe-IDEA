import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
struct DatabaseGridAppearanceTests {
    @Test func mutationHighlightResolvesTheCurrentAppearanceAndPreservesAlpha() throws {
        let source = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(deviceRed: 248.0 / 255, green: 1.0 / 255, blue: 239.0 / 255, alpha: 0.5)
                : NSColor(deviceRed: 8.0 / 255, green: 32.0 / 255, blue: 248.0 / 255, alpha: 0.5)
        })
        // Resolve the same dynamic highlight in both appearances; do not capture the first one.
        let highlighted = LitheTheme.DatabaseGrid.mutationBackground(source, highlighted: true)
        let normal = LitheTheme.DatabaseGrid.mutationBackground(source, highlighted: false)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var highlight: NSColor?
            var original: NSColor?
            var unchanged: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                highlight = NSColor(highlighted).usingColorSpace(.deviceRGB)
                original = NSColor(source).usingColorSpace(.deviceRGB)
                unchanged = NSColor(normal).usingColorSpace(.deviceRGB)
            }
            let rgb = try #require(highlight)
            #expect(original == unchanged)
            #expect(abs(rgb.alphaComponent - 0.5) < 0.001)
            let expected: [CGFloat] = name == .darkAqua ? [1, 17.0 / 255, 1] : [0, 16.0 / 255, 232.0 / 255]
            for (actual, expected) in zip([rgb.redComponent, rgb.greenComponent, rgb.blueComponent], expected) {
                #expect(abs(actual - expected) < 0.001)
            }
        }
    }
}
