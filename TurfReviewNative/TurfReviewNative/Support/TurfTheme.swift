import SwiftUI

#if os(iOS)
import UIKit
/// The platform color type behind every Turf token (`UIColor` on iOS, `NSColor` on macOS).
typealias TurfPlatformColor = UIColor
#else
import AppKit
/// The platform color type behind every Turf token (`UIColor` on iOS, `NSColor` on macOS).
typealias TurfPlatformColor = NSColor
#endif

// MARK: - Appearances and resolved values

/// The four appearances every custom token defines (normal and Increase Contrast, light and dark).
enum TurfAppearance: CaseIterable {
  case light, dark, lightHighContrast, darkHighContrast

  var isDark: Bool { self == .dark || self == .darkHighContrast }
  var isHighContrast: Bool { self == .lightHighContrast || self == .darkHighContrast }

  init(isDark: Bool, isHighContrast: Bool) {
    switch (isDark, isHighContrast) {
    case (false, false): self = .light
    case (true, false): self = .dark
    case (false, true): self = .lightHighContrast
    case (true, true): self = .darkHighContrast
    }
  }
}

/// A color resolved to sRGB under one appearance. Components are 0...1.
struct TurfRGBA: Equatable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double

  init(red: Double, green: Double, blue: Double, alpha: Double) {
    self.red = min(max(red, 0), 1)
    self.green = min(max(green, 0), 1)
    self.blue = min(max(blue, 0), 1)
    self.alpha = min(max(alpha, 0), 1)
  }

  /// `0xRRGGBB` plus an alpha. Only the palette table below should use this.
  init(hex: UInt32, alpha: Double = 1) {
    self.init(
      red: Double((hex >> 16) & 0xff) / 255,
      green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255,
      alpha: alpha
    )
  }

  /// `rgba(r, g, b, a)` with 0–255 channels and a 3-decimal alpha, as the reader CSS expects.
  var cssString: String {
    func channel(_ value: Double) -> Int { Int((value * 255).rounded()) }
    return "rgba(\(channel(red)), \(channel(green)), \(channel(blue)), \(String(format: "%.3f", alpha)))"
  }

  var platformColor: TurfPlatformColor {
    #if os(iOS)
    UIColor(red: red, green: green, blue: blue, alpha: alpha)
    #else
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    #endif
  }
}

// MARK: - Palette (the single source)

/// Dynamic platform colors. Every color in the app and in the reader CSS comes from here.
/// System-backed roles are the system colors themselves; custom roles come from the table in `Swatch`.
enum TurfPalette {
  // MARK: Surfaces and text

  /// Reader page, library canvas, detail placeholder, audio row.
  #if os(iOS)
  static let paper: TurfPlatformColor = .systemBackground
  #else
  static let paper: TurfPlatformColor = .textBackgroundColor
  #endif

  /// Sheet and popover canvas. Carries only titles and subtitles (rule S1); controls sit in cards.
  #if os(iOS)
  static let panel: TurfPlatformColor = .systemGroupedBackground
  #else
  static let panel: TurfPlatformColor = .windowBackgroundColor
  #endif

  /// Cards inside panels, the chat assistant bubble, text-field wells on the panel canvas.
  #if os(iOS)
  static let card: TurfPlatformColor = .secondarySystemGroupedBackground
  #else
  static let card: TurfPlatformColor = .controlBackgroundColor
  #endif

  /// All primary text and the reader body.
  #if os(iOS)
  static let ink: TurfPlatformColor = .label
  #else
  static let ink: TurfPlatformColor = .labelColor
  #endif

  /// Secondary text, metadata, subtitles, placeholders we draw. Passes AA on every surface.
  static let muted = dynamic(Swatch.muted)

  /// Decorative glyphs and disabled only (row chevrons, the unset selection ring). Never informational text.
  static let faint = dynamic(Swatch.faint)

  /// Dividers, table rules, the blockquote rule, field outlines. The system separator, unmodified.
  #if os(iOS)
  static let hairline: TurfPlatformColor = .separator
  #else
  static let hairline: TurfPlatformColor = .separatorColor
  #endif

  /// Neutral translucent fill: secondary buttons, inline code, `pre`, fields inside cards, the decided-dock capsule.
  static let fill = dynamic(Swatch.fill)

  // MARK: Accent (the one tint; also means approved)

  /// App tint: tinted icons and text, links, approved/chosen state text, focus. Never a fill behind white text.
  static let accent = dynamic(Swatch.accent)

  /// Background of the single primary button, the user chat bubble and count badges (mid green in both appearances).
  static let accentFill = dynamic(Swatch.accentFill)

  /// Approved / chosen-option fill (buttons and reader marks) and the info banner.
  static let accentSoft = dynamic(Swatch.accentSoft)

  /// Text and icons on `accentFill` and `destructiveFill`.
  static let onAccent = dynamic(Swatch.onAccent)

  // MARK: Destructive (reject, kill, failed)

  /// Reject, Kill, failed, errors, delete glyphs.
  static let destructive = dynamic(Swatch.destructive)

  /// Background of a primary button whose action is Kill.
  static let destructiveFill = dynamic(Swatch.destructiveFill)

  /// Rejected-state fill (buttons, reader marks) and the system chat message.
  static let destructiveSoft = dynamic(Swatch.destructiveSoft)

  // MARK: Attention (awaiting a decision)

  /// Open review target, parked, needs confirmation, the blocking Send gate, the offline/demo banner icon.
  static let attention = dynamic(Swatch.attention)

  /// Warning banner fill only.
  static let attentionSoft = dynamic(Swatch.attentionSoft)

  // MARK: Reader marks

  /// Reader text selection (`::selection`).
  static let selection = dynamic(Swatch.selection)

  /// Saved annotation marks in the reader; the quote in a Notes row.
  static let highlight = dynamic(Swatch.highlight)

  /// The quote in the composer (a note not yet saved); the first frame of a new mark's settle fade.
  static let highlightActive = dynamic(Swatch.highlightActive)

  // MARK: Resolution

  /// Resolves a token (or any platform color) to sRGB under one appearance.
  /// Returns nil when the platform cannot build that appearance (some macOS high-contrast appearances).
  static func resolve(_ color: TurfPlatformColor, in appearance: TurfAppearance) -> TurfRGBA? {
    #if os(iOS)
    let traits = UITraitCollection(userInterfaceStyle: appearance.isDark ? .dark : .light)
      .modifyingTraits { $0.accessibilityContrast = appearance.isHighContrast ? .high : .normal }
    let resolved = color.resolvedColor(with: traits)
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
    return TurfRGBA(red: red, green: green, blue: blue, alpha: alpha)
    #else
    guard let nsAppearance = NSAppearance(named: appearance.appearanceName) else { return nil }
    var resolved: NSColor?
    nsAppearance.performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(.sRGB)
    }
    guard let resolved else { return nil }
    return TurfRGBA(
      red: resolved.redComponent,
      green: resolved.greenComponent,
      blue: resolved.blueComponent,
      alpha: resolved.alphaComponent
    )
    #endif
  }

  // MARK: Table (section 2.2 of the design direction)

  /// Light / dark / HC light / HC dark values for one custom role.
  struct Swatch {
    let light: TurfRGBA
    let dark: TurfRGBA
    let lightHighContrast: TurfRGBA
    let darkHighContrast: TurfRGBA

    func value(for appearance: TurfAppearance) -> TurfRGBA {
      switch appearance {
      case .light: return light
      case .dark: return dark
      case .lightHighContrast: return lightHighContrast
      case .darkHighContrast: return darkHighContrast
      }
    }

    private init(_ light: TurfRGBA, _ dark: TurfRGBA, _ lightHC: TurfRGBA, _ darkHC: TurfRGBA) {
      self.light = light
      self.dark = dark
      self.lightHighContrast = lightHC
      self.darkHighContrast = darkHC
    }

    /// Opaque role: four hex values.
    private static func solid(_ light: UInt32, _ dark: UInt32, _ lightHC: UInt32, _ darkHC: UInt32) -> Swatch {
      Swatch(TurfRGBA(hex: light), TurfRGBA(hex: dark), TurfRGBA(hex: lightHC), TurfRGBA(hex: darkHC))
    }

    /// Translucent role: each appearance's base color at its own alpha.
    private static func tinted(
      _ base: Swatch,
      _ light: Double, _ dark: Double, _ lightHC: Double, _ darkHC: Double
    ) -> Swatch {
      func at(_ color: TurfRGBA, _ alpha: Double) -> TurfRGBA {
        TurfRGBA(red: color.red, green: color.green, blue: color.blue, alpha: alpha)
      }
      return Swatch(
        at(base.light, light),
        at(base.dark, dark),
        at(base.lightHighContrast, lightHC),
        at(base.darkHighContrast, darkHC)
      )
    }

    static let muted = solid(0x67676C, 0xA0A0A7, 0x4A4A4F, 0xC4C4CA)
    static let faint = solid(0xAEAEB2, 0x636366, 0x8E8E93, 0x8E8E93)
    static let fill = tinted(solid(0x767680, 0x767680, 0x767680, 0x767680), 0.12, 0.24, 0.18, 0.32)

    static let accent = solid(0x357256, 0x74C49B, 0x2A5C45, 0x9ADBB9)
    static let accentFill = solid(0x357256, 0x357256, 0x2A5C45, 0x2A5C45)
    static let accentSoft = tinted(accent, 0.12, 0.16, 0.18, 0.22)
    static let onAccent = solid(0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF)

    static let destructive = solid(0xBD3629, 0xFF8A80, 0x9B2A20, 0xFFA8A0)
    static let destructiveFill = solid(0xBD3629, 0xBD3629, 0x9B2A20, 0x9B2A20)
    static let destructiveSoft = tinted(destructive, 0.12, 0.16, 0.18, 0.22)

    static let attention = solid(0x955A00, 0xE9A847, 0x7A4700, 0xF5C57E)
    static let attentionSoft = tinted(attention, 0.12, 0.16, 0.18, 0.22)

    static let selection = tinted(accent, 0.22, 0.30, 0.30, 0.38)
    private static let highlighter = solid(0xFFCC00, 0xFFD426, 0xFFCC00, 0xFFD426)
    static let highlight = tinted(highlighter, 0.32, 0.30, 0.45, 0.30)
    static let highlightActive = tinted(highlighter, 0.55, 0.40, 0.65, 0.40)
  }

  private static func dynamic(_ swatch: Swatch) -> TurfPlatformColor {
    #if os(iOS)
    return UIColor { traits in
      let appearance = TurfAppearance(
        isDark: traits.userInterfaceStyle == .dark,
        isHighContrast: traits.accessibilityContrast == .high
      )
      return swatch.value(for: appearance).platformColor
    }
    #else
    return NSColor(name: nil) { appearance in
      let match = appearance.bestMatch(from: [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
      ])
      let resolved: TurfAppearance
      switch match {
      case .darkAqua?: resolved = .dark
      case .accessibilityHighContrastAqua?: resolved = .lightHighContrast
      case .accessibilityHighContrastDarkAqua?: resolved = .darkHighContrast
      default: resolved = .light
      }
      return swatch.value(for: resolved).platformColor
    }
    #endif
  }
}

#if os(macOS)
private extension TurfAppearance {
  var appearanceName: NSAppearance.Name {
    switch self {
    case .light: return .aqua
    case .dark: return .darkAqua
    case .lightHighContrast: return .accessibilityHighContrastAqua
    case .darkHighContrast: return .accessibilityHighContrastDarkAqua
    }
  }
}
#endif

// MARK: - SwiftUI tokens

/// SwiftUI mirrors of `TurfPalette`, same names, all dynamic.
enum TurfTheme {
  /// Reader page, library canvas, detail placeholder, audio row.
  static let paper = color(TurfPalette.paper)
  /// Sheet and popover canvas. Titles and subtitles only; controls go in a `turfCard()`.
  static let panel = color(TurfPalette.panel)
  /// Cards inside panels, the assistant chat bubble, field wells on the panel canvas.
  static let card = color(TurfPalette.card)
  /// Primary text (`Color.primary`).
  static let ink = Color.primary
  /// Secondary text and metadata. Never on a highlight or a soft fill.
  static let muted = color(TurfPalette.muted)
  /// Decorative glyphs and disabled only. Never informational text.
  static let faint = color(TurfPalette.faint)
  /// Dividers and rules (system separator, 1pt).
  static let hairline = color(TurfPalette.hairline)
  /// Neutral translucent fill for secondary buttons, code, fields inside cards.
  static let fill = color(TurfPalette.fill)

  /// The app tint: tinted text and icons, links, approved/chosen text. Not for fills behind white text.
  static let accent = color(TurfPalette.accent)
  /// Primary-button, user-bubble and badge background. Use this, never `accent`, under white text.
  static let accentFill = color(TurfPalette.accentFill)
  /// Approved / chosen fill and the info banner.
  static let accentSoft = color(TurfPalette.accentSoft)
  /// Text and icons on `accentFill` and `destructiveFill`.
  static let onAccent = color(TurfPalette.onAccent)

  /// Reject, Kill, failed, errors, delete glyphs.
  static let destructive = color(TurfPalette.destructive)
  /// Background of a Kill primary button.
  static let destructiveFill = color(TurfPalette.destructiveFill)
  /// Rejected-state fill and the system chat message.
  static let destructiveSoft = color(TurfPalette.destructiveSoft)

  /// Awaiting a decision: open targets, parked, needs confirmation, the Send gate, offline/demo banner icon.
  static let attention = color(TurfPalette.attention)
  /// Warning banner fill only.
  static let attentionSoft = color(TurfPalette.attentionSoft)

  /// Reader text selection.
  static let selection = color(TurfPalette.selection)
  /// A saved note's highlighter (reader marks, the quote in a Notes row).
  static let highlight = color(TurfPalette.highlight)
  /// A draft note's highlighter (the composer quote).
  static let highlightActive = color(TurfPalette.highlightActive)

  /// The tone that represents a downstream status everywhere (library, panels, dock).
  static func statusTone(_ status: String) -> TurfTone {
    switch DownstreamStatus(status).normalizedValue {
    case "processed", "succeeded", "completed", "done", "approved", "ready":
      return .accent
    case "killed", "failed", "error", "rejected", "blocked", "blocked_system", "blocked_decision":
      return .destructive
    case "parked", "open", "needs_confirmation", "needs confirmation", "waiting_external", "waiting external":
      return .attention
    default:
      return .neutral
    }
  }

  /// Text color for a status (`statusTone(status).text`).
  static func statusColor(_ status: String) -> Color {
    statusTone(status).text
  }

  /// The reader's `--turf-*` custom properties: every color token resolved under light, dark and both
  /// Increase Contrast appearances, plus the shape and motion tokens. Built once. Never sets `color-scheme`.
  static let cssVariables: String = TurfCSS.makeVariables()

  private static func color(_ platformColor: TurfPlatformColor) -> Color {
    #if os(iOS)
    Color(uiColor: platformColor)
    #else
    Color(nsColor: platformColor)
    #endif
  }
}

// MARK: - Tones

/// A semantic tone. Pick one per state and read its roles; never pick raw colors for status.
enum TurfTone: Equatable {
  case accent, destructive, attention, neutral

  /// Text in this tone (on paper or card only; rule S1).
  var text: Color {
    switch self {
    case .accent: return TurfTheme.accent
    case .destructive: return TurfTheme.destructive
    case .attention: return TurfTheme.attention
    case .neutral: return TurfTheme.ink
    }
  }

  /// Glyphs and dots in this tone.
  var icon: Color {
    switch self {
    case .accent: return TurfTheme.accent
    case .destructive: return TurfTheme.destructive
    case .attention: return TurfTheme.attention
    case .neutral: return TurfTheme.muted
    }
  }

  /// Translucent state fill (tinted buttons, chosen/rejected marks, banners).
  var soft: Color {
    switch self {
    case .accent: return TurfTheme.accentSoft
    case .destructive: return TurfTheme.destructiveSoft
    case .attention: return TurfTheme.attentionSoft
    case .neutral: return TurfTheme.fill
    }
  }

  /// Filled-button background. Attention and neutral have no filled form and render like tinted.
  var fill: Color {
    switch self {
    case .accent: return TurfTheme.accentFill
    case .destructive: return TurfTheme.destructiveFill
    case .attention: return TurfTheme.attentionSoft
    case .neutral: return TurfTheme.fill
    }
  }

  /// Text and icons on `fill`.
  var onFill: Color {
    switch self {
    case .accent, .destructive: return TurfTheme.onAccent
    case .attention: return TurfTheme.attention
    case .neutral: return TurfTheme.ink
    }
  }
}

// MARK: - Reader CSS generation

private enum TurfCSS {
  /// CSS variable name → token. Order is the emitted order.
  static let colorTokens: [(name: String, color: TurfPlatformColor)] = [
    ("--turf-paper", TurfPalette.paper),
    ("--turf-ink", TurfPalette.ink),
    ("--turf-muted", TurfPalette.muted),
    ("--turf-faint", TurfPalette.faint),
    ("--turf-hairline", TurfPalette.hairline),
    ("--turf-fill", TurfPalette.fill),
    ("--turf-accent", TurfPalette.accent),
    ("--turf-accent-fill", TurfPalette.accentFill),
    ("--turf-accent-soft", TurfPalette.accentSoft),
    ("--turf-on-accent", TurfPalette.onAccent),
    ("--turf-destructive", TurfPalette.destructive),
    ("--turf-destructive-soft", TurfPalette.destructiveSoft),
    ("--turf-attention", TurfPalette.attention),
    ("--turf-attention-soft", TurfPalette.attentionSoft),
    ("--turf-selection", TurfPalette.selection),
    ("--turf-highlight", TurfPalette.highlight),
    ("--turf-highlight-active", TurfPalette.highlightActive),
  ]

  static let nonColorTokens: [(name: String, value: String)] = [
    ("--turf-radius-mark", "\(Int(TurfRadius.mark))px"),
    ("--turf-radius-field", "\(Int(TurfRadius.field))px"),
    ("--turf-radius-card", "\(Int(TurfRadius.card))px"),
    ("--turf-ease-out", "cubic-bezier(0.16, 1, 0.3, 1)"),
    ("--turf-duration-quick", "180ms"),
    ("--turf-duration-settle", "700ms"),
  ]

  static func makeVariables() -> String {
    var css = ""
    if let light = declarations(for: .light) {
      let extras = nonColorTokens.map { "  \($0.name): \($0.value);" }
      css += ":root {\n" + (light + extras).joined(separator: "\n") + "\n}\n"
    }
    let blocks: [(query: String, appearance: TurfAppearance)] = [
      ("(prefers-color-scheme: dark)", .dark),
      ("(prefers-contrast: more)", .lightHighContrast),
      ("(prefers-color-scheme: dark) and (prefers-contrast: more)", .darkHighContrast),
    ]
    for block in blocks {
      guard let lines = declarations(for: block.appearance) else { continue }
      css += "@media \(block.query) {\n  :root {\n"
        + lines.map { "  \($0)" }.joined(separator: "\n")
        + "\n  }\n}\n"
    }
    return css
  }

  /// One declaration per color token, or nil if the appearance cannot be built on this platform.
  private static func declarations(for appearance: TurfAppearance) -> [String]? {
    var lines: [String] = []
    for token in colorTokens {
      guard let value = TurfPalette.resolve(token.color, in: appearance) else { return nil }
      lines.append("  \(token.name): \(value.cssString);")
    }
    return lines
  }
}
