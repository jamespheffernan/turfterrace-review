import SwiftUI

// MARK: - Spacing

/// The spacing scale (2 · 4 · 8 · 12 · 16 · 20 · 24 · 32) and its semantic roles.
/// No other padding, spacing or frame values, except the 44pt hit target and fixed window/column sizes.
enum TurfSpacing {
  static let xxs: CGFloat = 2
  static let xs: CGFloat = 4
  static let s: CGFloat = 8
  static let m: CGFloat = 12
  static let l: CGFloat = 16
  static let xl: CGFloat = 20
  static let xxl: CGFloat = 24
  static let xxxl: CGFloat = 32

  /// The one leading edge of a screen: library header, status row, picker, banner and list rows (16 / 20).
  static func screenInset(compact: Bool) -> CGFloat { compact ? l : xl }

  /// Padding inside `summonPanel`, the iOS Notes sheet and popovers (16 / 20).
  static func panelInset(compact: Bool) -> CGFloat { compact ? l : xl }

  /// Reader text inline padding, the audio-row content edge and dock pill edges (20 / 32).
  static func readerInset(compact: Bool) -> CGFloat { compact ? xl : xxxl }

  /// Padding inside every card (12). Trim the top by 2 optically when a card starts with a headline.
  static let cardInset: CGFloat = m

  /// Between cards (8).
  static let cardGap: CGFloat = s

  /// Between panel sections: header to first card, then between groups (24).
  static let sectionGap: CGFloat = xxl

  /// Title to subtitle, row title to metadata, label to value (4).
  static let stackTight: CGFloat = xs

  /// Between adjacent buttons and chips (8).
  static let controlGap: CGFloat = s

  /// Queue row vertical padding (12).
  static let rowVertical: CGFloat = m

  /// Dock inset from the screen or column edge (12 compact / 16 regular and Mac).
  static func dockOuter(compact: Bool) -> CGFloat { compact ? m : l }

  /// Padding inside the dock container (8). `dockOuter + dockInner` equals the compact reader inset.
  static let dockInner: CGFloat = s

  /// The minimum hit target on iOS (44).
  static let hitTarget: CGFloat = 44
}

// MARK: - Shape

/// Corner radii. Everything else is a capsule or the system's own shape. Always `style: .continuous`.
enum TurfRadius {
  /// Reader marks and inline code.
  static let mark: CGFloat = 4
  /// Text fields and editors, `pre`, reader images.
  static let field: CGFloat = 10
  /// Cards, chat bubbles, the selection-capture pulse, the banner, the composer quote card.
  static let card: CGFloat = 14
}

// MARK: - Type

/// SwiftUI text roles. All scale with Dynamic Type; no fixed point sizes.
enum TurfType {
  /// "Library" (the system large title on iPhone).
  static let screenTitle: Font = .largeTitle.bold()
  /// `SectionHeader` title, composer header.
  static let panelTitle: Font = .headline
  /// Queue row title, item label in the Items card.
  static let rowTitle: Font = .body.weight(.semibold)
  /// Note comments, chat text, feedback text.
  static let body: Font = .body
  /// Dock primary, secondary and Review labels.
  static let dockLabel: Font = .body.weight(.semibold)
  /// Buttons inside panels and Mac toolbar labels. The default label font of `TurfButtonStyle`.
  static let control: Font = .subheadline.weight(.semibold)
  /// Row metadata, status row, section subtitles, helper text, target state words.
  static let meta: Font = .footnote
  /// Field labels, chat author, the gate line.
  static let metaStrong: Font = .footnote.weight(.semibold)
  /// Timestamps and request detail lines.
  static let caption: Font = .caption
  /// Count badges (11pt floor), with monospaced digits.
  static let badge: Font = .caption2.weight(.bold).monospacedDigit()
  /// Quoted passages in Notes rows and the composer (serif, ties a note to its passage).
  static let quote: Font = .system(.callout, design: .serif)

  /// Reader body size in CSS px for a Dynamic Type size: `round(18 × body_pt / 17)`. Always 18 on macOS.
  static func readerBodySize(for size: DynamicTypeSize) -> CGFloat {
    #if os(macOS)
    return 18
    #else
    switch size {
    case .xSmall: return 15
    case .small: return 16
    case .medium: return 17
    case .large: return 18
    case .xLarge: return 20
    case .xxLarge: return 22
    case .xxxLarge: return 24
    case .accessibility1: return 30
    case .accessibility2: return 35
    case .accessibility3: return 42
    case .accessibility4: return 50
    case .accessibility5: return 56
    @unknown default: return 18
    }
    #endif
  }
}

// MARK: - Layout

/// Reading-column geometry shared by the reader CSS, the audio row and the dock.
enum TurfLayout {
  /// The reader measure in em (about 70 characters of New York).
  static let readerMeasureEm: CGFloat = 36

  /// Width of the reading column, text plus both regular insets: `36 × readerSize + 64` (712 at 18).
  static func readerColumnWidth(readerSize: CGFloat) -> CGFloat {
    readerMeasureEm * readerSize + 2 * TurfSpacing.readerInset(compact: false)
  }
}

// MARK: - Motion

/// The only animation curves in the app. Apply them through `turfAnimation`, `withTurfAnimation`
/// and the `turfLift` / `turfSettle` transitions so Reduce Motion is always honored.
enum TurfMotion {
  /// Direct feedback: press, chosen tint, badge count, selection mark, submitting spinner swap.
  static let quick: Animation = .snappy(duration: 0.18)
  /// Content swaps: list insert/remove, tab switch, row state, pending → decided, download glyph, banner.
  static let content: Animation = .smooth(duration: 0.28)
  /// Spatial entrances: composer stages, selection pulse, new note/chat row lift.
  static let panel: Animation = .spring(duration: 0.36, bounce: 0.12)
  /// The one authored moment: a decision landing in the dock or Mac toolbar.
  static let confirm: Animation = .spring(duration: 0.44, bounce: 0.18)
  /// Removals and dismissals; always faster than the matching entrance.
  static let exit: Animation = .easeOut(duration: 0.16)
  /// Substitute for every token under Reduce Motion: a plain crossfade timing.
  static let reduced: Animation = .easeInOut(duration: 0.2)

  /// Entrance offset in points.
  static let lift: CGFloat = 8
  /// Button press scale (dropped under Reduce Motion).
  static let pressScale: CGFloat = 0.97
  /// Loading indicators appear only if loading lasts this long.
  static let loadingRevealDelay: Duration = .milliseconds(400)

  /// `animation`, or `reduced` when Reduce Motion is on.
  static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
    reduceMotion ? reduced : animation
  }
}

/// `withAnimation` through the Turf tokens: uses `TurfMotion.reduced` when `reduceMotion` is true.
func withTurfAnimation<R>(
  _ animation: Animation,
  reduceMotion: Bool,
  _ body: () throws -> R
) rethrows -> R {
  try withAnimation(TurfMotion.resolved(animation, reduceMotion: reduceMotion), body)
}

extension AnyTransition {
  /// Entrance that rises `TurfMotion.lift` points while fading in; removal fades. Opacity only under Reduce Motion.
  static func turfLift(reduceMotion: Bool) -> AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .opacity.combined(with: .offset(y: TurfMotion.lift)),
      removal: .opacity
    )
  }

  /// Entrance that settles from a slightly smaller scale while fading in; removal fades. Opacity only under Reduce Motion.
  static func turfSettle(reduceMotion: Bool) -> AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .asymmetric(
      insertion: .opacity.combined(with: .scale(scale: 0.96)),
      removal: .opacity
    )
  }
}

private struct TurfAnimationModifier<Value: Equatable>: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let animation: Animation
  let reducedAnimation: Animation?
  let value: Value

  func body(content: Content) -> some View {
    content.animation(reduceMotion ? reducedAnimation : animation, value: value)
  }
}

// MARK: - Surfaces

private struct TurfFieldModifier: ViewModifier {
  let isFocused: Bool
  let isInvalid: Bool

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: TurfRadius.field, style: .continuous)
    content
      .background(TurfTheme.fill, in: shape)
      .overlay {
        shape
          .strokeBorder(isInvalid ? TurfTheme.destructive : TurfTheme.accent, lineWidth: 1)
          .opacity(isFocused || isInvalid ? 1 : 0)
          .turfAnimation(TurfMotion.quick, value: isFocused || isInvalid)
          .allowsHitTesting(false)
      }
  }
}

extension View {
  /// `.animation(_:value:)` through the Turf tokens: uses `TurfMotion.reduced` when Reduce Motion is on.
  func turfAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
    modifier(TurfAnimationModifier(animation: animation, reducedAnimation: TurfMotion.reduced, value: value))
  }

  /// Like `turfAnimation(_:value:)`, but with an explicit Reduce Motion substitute; `nil` means instant.
  /// Use `nil` for list insert/remove and tab switches, which the motion list makes instant under Reduce Motion.
  func turfAnimation<V: Equatable>(_ animation: Animation, reduced: Animation?, value: V) -> some View {
    modifier(TurfAnimationModifier(animation: animation, reducedAnimation: reduced, value: value))
  }

  /// A card: `card` fill, 14pt continuous corners, no stroke, no shadow. Pass `nil` to pad it yourself.
  func turfCard(padding: CGFloat? = TurfSpacing.cardInset) -> some View {
    self
      .padding(padding ?? 0)
      .background(TurfTheme.card)
      .clipShape(RoundedRectangle(cornerRadius: TurfRadius.card, style: .continuous))
  }

  /// A text-field well: `fill` background, 10pt corners, and a 1pt stroke only when focused (accent)
  /// or invalid (destructive). The stroke fades with `quick`. Adds no padding.
  func turfField(isFocused: Bool = false, isInvalid: Bool = false) -> some View {
    modifier(TurfFieldModifier(isFocused: isFocused, isInvalid: isInvalid))
  }
}

// MARK: - Buttons

/// The app's one button shape: a capsule, `TurfType.control` labels (a label's own `.font` wins),
/// 16pt horizontal padding, 44pt minimum height on iOS and 32pt on macOS.
struct TurfButtonStyle: ButtonStyle {
  enum Prominence {
    /// `tone.fill` background, `tone.onFill` text. Reserve for the single primary action.
    case filled
    /// `tone.soft` background, `tone.text` text. Neutral tinted is `fill` + ink.
    case tinted
  }

  let prominence: Prominence
  let tone: TurfTone
  var fullWidth = false

  func makeBody(configuration: Configuration) -> some View {
    TurfButtonBody(configuration: configuration, prominence: prominence, tone: tone, fullWidth: fullWidth)
  }
}

extension ButtonStyle where Self == TurfButtonStyle {
  /// A filled capsule (primary action). `.turfFilled(.destructive)` for Kill.
  static func turfFilled(_ tone: TurfTone = .accent, fullWidth: Bool = false) -> TurfButtonStyle {
    TurfButtonStyle(prominence: .filled, tone: tone, fullWidth: fullWidth)
  }

  /// A tinted capsule (secondary actions and state-carrying choices).
  static func turfTinted(_ tone: TurfTone = .neutral, fullWidth: Bool = false) -> TurfButtonStyle {
    TurfButtonStyle(prominence: .tinted, tone: tone, fullWidth: fullWidth)
  }
}

private struct TurfButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let prominence: TurfButtonStyle.Prominence
  let tone: TurfTone
  let fullWidth: Bool

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  #if os(iOS)
  private let minHeight: CGFloat = TurfSpacing.hitTarget
  #else
  private let minHeight: CGFloat = TurfSpacing.xxxl
  #endif

  var body: some View {
    configuration.label
      .font(TurfType.control)
      .foregroundStyle(prominence == .filled ? tone.onFill : tone.text)
      .padding(.horizontal, TurfSpacing.l)
      .padding(.vertical, TurfSpacing.s)
      .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: minHeight)
      .background(prominence == .filled ? tone.fill : tone.soft, in: Capsule())
      .contentShape(Capsule())
      .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
      .scaleEffect(configuration.isPressed && !reduceMotion ? TurfMotion.pressScale : 1)
      .turfAnimation(TurfMotion.quick, value: configuration.isPressed)
  }
}

// MARK: - Small components

/// A count badge: `accentFill` capsule with `onAccent` digits, animated count, hidden at 0.
struct TurfCountBadge: View {
  let count: Int

  @ScaledMetric(relativeTo: .caption2) private var minimumSize: CGFloat = 18
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(count: Int) {
    self.count = count
  }

  var body: some View {
    if count > 0 {
      // Capped at 99 so the badge keeps its size and matches the panel title.
      let shown = min(count, 99)
      Text(shown, format: .number)
        .font(TurfType.badge)
        .foregroundStyle(TurfTheme.onAccent)
        .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(shown)))
        .padding(.horizontal, TurfSpacing.xs)
        .frame(minWidth: minimumSize, minHeight: minimumSize)
        .background(TurfTheme.accentFill, in: Capsule())
        .turfAnimation(TurfMotion.quick, value: count)
    }
  }
}

/// An 8pt status dot (scales with `.footnote`) in the tone's icon color. Hidden from VoiceOver;
/// pair it with a text label.
struct TurfStatusDot: View {
  let tone: TurfTone

  @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 8

  init(tone: TurfTone) {
    self.tone = tone
  }

  var body: some View {
    Circle()
      .fill(tone.icon)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}
