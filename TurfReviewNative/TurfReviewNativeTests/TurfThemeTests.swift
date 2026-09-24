import XCTest
#if os(macOS)
import AppKit
@testable import TurfReviewMac
#else
import UIKit
@testable import TurfReviewNative
#endif

final class TurfThemeTests: XCTestCase {
  // MARK: - Reader CSS

  func testCSSVariablesCarryTheResolvedAccentAndNoRetiredColors() {
    let css = TurfTheme.cssVariables

    XCTAssertTrue(css.contains("--turf-accent: rgba(53, 114, 86, 1.000);"), css)
    XCTAssertTrue(css.contains("--turf-accent: rgba(116, 196, 155, 1.000);"), css)
    XCTAssertFalse(css.lowercased().contains("#39775b"))
    XCTAssertFalse(css.contains("124, 137"))
    XCTAssertFalse(css.contains("224, 96, 64"))
    // The block never sets `color-scheme` itself; only media queries mention it.
    XCTAssertFalse(css.replacingOccurrences(of: "prefers-color-scheme", with: "").contains("color-scheme"))
  }

  func testCSSVariablesDeclareEveryTokenTheReaderConsumes() {
    let css = TurfTheme.cssVariables
    let names = [
      "--turf-paper", "--turf-ink", "--turf-muted", "--turf-faint", "--turf-hairline", "--turf-fill",
      "--turf-accent", "--turf-accent-fill", "--turf-accent-soft", "--turf-on-accent",
      "--turf-destructive", "--turf-destructive-soft", "--turf-attention", "--turf-attention-soft",
      "--turf-selection", "--turf-highlight", "--turf-highlight-active",
      "--turf-radius-mark: 4px", "--turf-radius-field: 10px", "--turf-radius-card: 14px",
      "--turf-ease-out: cubic-bezier(0.16, 1, 0.3, 1)",
      "--turf-duration-quick: 180ms", "--turf-duration-settle: 700ms",
    ]
    for name in names {
      XCTAssertTrue(css.contains(name), "missing \(name)")
    }
    XCTAssertTrue(css.hasPrefix(":root {"))
    XCTAssertTrue(css.contains("@media (prefers-color-scheme: dark) {"))
    #if os(iOS)
    XCTAssertTrue(css.contains("@media (prefers-contrast: more) {"))
    XCTAssertTrue(css.contains("@media (prefers-color-scheme: dark) and (prefers-contrast: more) {"))
    #endif
  }

  func testDarkAccentIsItsOwnColor() throws {
    let light = try XCTUnwrap(TurfPalette.resolve(TurfPalette.accent, in: .light))
    let dark = try XCTUnwrap(TurfPalette.resolve(TurfPalette.accent, in: .dark))
    XCTAssertEqual(light.cssString, "rgba(53, 114, 86, 1.000)")
    XCTAssertEqual(dark.cssString, "rgba(116, 196, 155, 1.000)")
  }

  // MARK: - AccentColor asset

  func testAccentColorAssetMatchesPaletteInEveryAppearance() throws {
    let bundle = Bundle(for: ReviewStore.self)
    #if os(iOS)
    let asset = try XCTUnwrap(UIColor(named: "AccentColor", in: bundle, compatibleWith: nil))
    #else
    let asset = try XCTUnwrap(NSColor(named: "AccentColor", bundle: bundle))
    #endif

    var checked = 0
    for appearance in TurfAppearance.allCases {
      guard let expected = TurfPalette.resolve(TurfPalette.accent, in: appearance) else { continue }
      let actual = try XCTUnwrap(TurfPalette.resolve(asset, in: appearance), "\(appearance)")
      XCTAssertEqual(actual.cssString, expected.cssString, "AccentColor differs in \(appearance)")
      checked += 1
    }
    #if os(iOS)
    XCTAssertEqual(checked, 4)
    #else
    XCTAssertGreaterThanOrEqual(checked, 2)
    #endif
  }

  // MARK: - Contrast (design direction 2.4)

  private enum Surface {
    // Light
    static let white = TurfRGBA(hex: 0xFFFFFF)
    static let groupedLight = TurfRGBA(hex: 0xF2F2F7)
    static let macWindowLight = TurfRGBA(hex: 0xECECEC)
    // Dark
    static let black = TurfRGBA(hex: 0x000000)
    static let cardBase = TurfRGBA(hex: 0x1C1C1E)
    static let cardElevated = TurfRGBA(hex: 0x2C2C2E)
    static let macPaperDark = TurfRGBA(hex: 0x1E1E1E)
    static let macWindowDark = TurfRGBA(hex: 0x323232)

    static let lightPaperAndPanels = [white, groupedLight, macWindowLight]
    static let darkPaperAndPanels = [black, cardBase, cardElevated, macPaperDark, macWindowDark]
    static let lightCards = [white]
    static let darkCards = [cardBase, cardElevated, macPaperDark]
    static let lightPapers = [white]
    static let darkPapers = [black, macPaperDark]
  }

  private struct Pair {
    let name: String
    let text: TurfPlatformColor
    /// A translucent (or opaque) layer between the text and the surface.
    let layer: TurfPlatformColor?
    let lightSurfaces: [TurfRGBA]
    let darkSurfaces: [TurfRGBA]
    var minimum: Double = 4.5
    /// False for pairs whose Increase Contrast values are not specified to rise in text contrast.
    var checkHighContrast = true
  }

  private var pairs: [Pair] {
    let paperPanels = (Surface.lightPaperAndPanels, Surface.darkPaperAndPanels)
    let cards = (Surface.lightCards, Surface.darkCards)
    let papers = (Surface.lightPapers, Surface.darkPapers)
    return [
      Pair(name: "ink on paper", text: TurfPalette.ink, layer: nil,
           lightSurfaces: [Surface.white], darkSurfaces: [Surface.black, Surface.cardElevated]),
      Pair(name: "muted on paper / panel / Mac window", text: TurfPalette.muted, layer: nil,
           lightSurfaces: paperPanels.0, darkSurfaces: paperPanels.1),
      Pair(name: "accent on paper / panel", text: TurfPalette.accent, layer: nil,
           lightSurfaces: paperPanels.0, darkSurfaces: paperPanels.1),
      Pair(name: "accent on accentSoft over card", text: TurfPalette.accent, layer: TurfPalette.accentSoft,
           lightSurfaces: cards.0, darkSurfaces: cards.1),
      Pair(name: "accent on fill over card", text: TurfPalette.accent, layer: TurfPalette.fill,
           lightSurfaces: cards.0, darkSurfaces: cards.1),
      Pair(name: "onAccent on accentFill", text: TurfPalette.onAccent, layer: TurfPalette.accentFill,
           lightSurfaces: cards.0, darkSurfaces: cards.1),
      Pair(name: "onAccent on destructiveFill", text: TurfPalette.onAccent, layer: TurfPalette.destructiveFill,
           lightSurfaces: cards.0, darkSurfaces: cards.1),
      Pair(name: "destructive on paper / panel", text: TurfPalette.destructive, layer: nil,
           lightSurfaces: paperPanels.0, darkSurfaces: paperPanels.1),
      Pair(name: "destructive on destructiveSoft over card", text: TurfPalette.destructive,
           layer: TurfPalette.destructiveSoft, lightSurfaces: cards.0, darkSurfaces: cards.1),
      Pair(name: "destructive on fill over card", text: TurfPalette.destructive, layer: TurfPalette.fill,
           lightSurfaces: cards.0, darkSurfaces: cards.1),
      Pair(name: "attention on paper / panel", text: TurfPalette.attention, layer: nil,
           lightSurfaces: paperPanels.0, darkSurfaces: paperPanels.1),
      Pair(name: "attention on attentionSoft over paper", text: TurfPalette.attention,
           layer: TurfPalette.attentionSoft, lightSurfaces: papers.0, darkSurfaces: papers.1),
      Pair(name: "ink on fill over card", text: TurfPalette.ink, layer: TurfPalette.fill,
           lightSurfaces: cards.0, darkSurfaces: cards.1),
      Pair(name: "ink on highlight", text: TurfPalette.ink, layer: TurfPalette.highlight,
           lightSurfaces: [Surface.white], darkSurfaces: [Surface.black, Surface.cardElevated]),
      // The composer shows the draft quote on an elevated card in dark mode.
      Pair(name: "ink on highlightActive", text: TurfPalette.ink, layer: TurfPalette.highlightActive,
           lightSurfaces: [Surface.white], darkSurfaces: [Surface.black, Surface.cardElevated]),
      Pair(name: "ink on selection", text: TurfPalette.ink, layer: TurfPalette.selection,
           lightSurfaces: [Surface.white], darkSurfaces: [Surface.black], checkHighContrast: false),
      // Non-text (graphics need 3:1).
      Pair(name: "attention underline on paper", text: TurfPalette.attention, layer: nil,
           lightSurfaces: [Surface.white], darkSurfaces: [Surface.black], minimum: 3),
      Pair(name: "accentFill edge against a black page", text: TurfPalette.accentFill, layer: nil,
           lightSurfaces: [Surface.white], darkSurfaces: [Surface.black], minimum: 3, checkHighContrast: false),
    ]
  }

  func testTextBearingPairsMeetWCAGAA() throws {
    var failures: [String] = []
    var checked = 0
    for appearance in TurfAppearance.allCases {
      for pair in pairs where !appearance.isHighContrast || pair.checkHighContrast {
        guard let text = TurfPalette.resolve(pair.text, in: appearance) else { continue }
        let layer = pair.layer.flatMap { TurfPalette.resolve($0, in: appearance) }
        let surfaces = appearance.isDark ? pair.darkSurfaces : pair.lightSurfaces
        for surface in surfaces {
          let background = layer.map { Self.composite($0, over: surface) } ?? surface
          let ratio = Self.contrast(Self.composite(text, over: background), background)
          checked += 1
          if ratio < pair.minimum {
            failures.append(
              "\(pair.name) [\(appearance)] over \(surface.cssString): \(String(format: "%.2f", ratio))"
            )
          }
        }
      }
    }
    XCTAssertGreaterThan(checked, 60)
    XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
  }

  // MARK: - Status tones

  func testStatusToneMapping() {
    XCTAssertEqual(TurfTheme.statusTone("Processed"), .accent)
    XCTAssertEqual(TurfTheme.statusTone(" approved "), .accent)
    XCTAssertEqual(TurfTheme.statusTone("blocked_system"), .destructive)
    XCTAssertEqual(TurfTheme.statusTone("rejected"), .destructive)
    XCTAssertEqual(TurfTheme.statusTone("needs confirmation"), .attention)
    XCTAssertEqual(TurfTheme.statusTone("parked"), .attention)
    XCTAssertEqual(TurfTheme.statusTone("pending"), .neutral)
    XCTAssertEqual(TurfTheme.statusTone("archived"), .neutral)
  }

  func testReaderBodySizeFollowsDynamicType() {
    #if os(iOS)
    XCTAssertEqual(TurfType.readerBodySize(for: .large), 18)
    XCTAssertEqual(TurfType.readerBodySize(for: .accessibility3), 42)
    XCTAssertEqual(TurfType.readerBodySize(for: .xSmall), 15)
    #else
    XCTAssertEqual(TurfType.readerBodySize(for: .accessibility3), 18)
    #endif
    XCTAssertEqual(TurfLayout.readerColumnWidth(readerSize: 18), 712)
  }

  // MARK: - WCAG 2.x helpers

  private static func composite(_ top: TurfRGBA, over bottom: TurfRGBA) -> TurfRGBA {
    let a = top.alpha
    return TurfRGBA(
      red: top.red * a + bottom.red * (1 - a),
      green: top.green * a + bottom.green * (1 - a),
      blue: top.blue * a + bottom.blue * (1 - a),
      alpha: 1
    )
  }

  private static func luminance(_ color: TurfRGBA) -> Double {
    func linear(_ channel: Double) -> Double {
      channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
  }

  private static func contrast(_ a: TurfRGBA, _ b: TurfRGBA) -> Double {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }
}
