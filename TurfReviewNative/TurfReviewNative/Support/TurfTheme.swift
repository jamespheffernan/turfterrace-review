import SwiftUI

enum TurfTheme {
  static let paper = Color(hex: 0xF7F2E8)
  static let panel = Color(hex: 0xFFFCF5)
  static let ink = Color(hex: 0x211F1B)
  static let muted = Color(hex: 0x6F6A61)
  static let hairline = Color(hex: 0xDDD1BF)
  static let accent = Color(hex: 0x007C89)
  static let coral = Color(hex: 0xC95F45)
  static let moss = Color(hex: 0x687F4E)
  static let plum = Color(hex: 0x5B4662)
  static let gold = Color(hex: 0xC99A38)

  static func statusColor(_ status: String) -> Color {
    switch DownstreamStatus(status).normalizedValue {
    case "pending": return accent
    case "parked": return gold
    case "processed": return moss
    case "archived", "dismissed": return muted
    case "killed", "failed", "blocked_system", "blocked_decision": return coral
    default: return plum
    }
  }
}

extension Color {
  init(hex: UInt, opacity: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xff) / 255,
      green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255,
      opacity: opacity
    )
  }
}

extension View {
  func turfPanel() -> some View {
    self
      .background(TurfTheme.panel)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(TurfTheme.hairline, lineWidth: 1)
      )
  }
}
