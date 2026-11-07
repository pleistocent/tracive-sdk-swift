import SwiftUI
import UIKit

/// Your brand on Tracive's screens, in light and dark. The terms line above the Send button ignores
/// it: the user must always be able to read what they agree to.
public struct TraciveReportTheme: Sendable {
  /// For buttons and highlights. Transparency is ignored, and a colour too close to the background
  /// is shifted until it can be seen. Nil uses Tracive's.
  public let primaryColor: UIColor?
  /// In points, from 0 to 28. Nil uses Tracive's.
  public let cornerRadius: CGFloat?

  public init(primaryColor: UIColor, cornerRadius: CGFloat? = nil) {
    self.primaryColor = primaryColor
    self.cornerRadius = cornerRadius
  }

  public init(primaryColor: Color? = nil, cornerRadius: CGFloat? = nil) {
    self.primaryColor = primaryColor.map { UIColor($0) }
    self.cornerRadius = cornerRadius
  }
}

struct ResolvedReportTheme {
  let primary: Color
  let onPrimary: Color
  let radius: CGFloat

  private static let tracivePrimary = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.663, green: 0.780, blue: 1, alpha: 1)
      : UIColor(red: 0.251, green: 0.373, blue: 0.565, alpha: 1)
  }

  init(_ theme: TraciveReportTheme) {
    let wanted = theme.primaryColor ?? Self.tracivePrimary
    let primary = UIColor { traits in Self.visible(wanted, traits: traits) }
    self.primary = Color(primary)
    onPrimary = Color(UIColor { traits in Self.readable(on: primary.resolvedColor(with: traits)) })
    radius = min(max(theme.cornerRadius ?? 12, 0), 28)
  }

  /// What the primary colour sits on: both screens are modal, which in dark mode is the lighter
  /// elevated grey, whatever level the trait reports while the sheet is still animating in.
  static func surface(_ traits: UITraitCollection) -> UIColor {
    let elevated = UITraitCollection(userInterfaceLevel: .elevated)
    return UIColor.secondarySystemBackground.resolvedColor(
      with: UITraitCollection(traitsFrom: [traits, elevated])
    )
  }

  private static func visible(_ wanted: UIColor, traits: UITraitCollection) -> UIColor {
    let surface = surface(traits)
    let extreme = UIColor.label.resolvedColor(with: traits)
    let opaque = wanted.resolvedColor(with: traits).withAlphaComponent(1)
    var color = opaque
    var fraction: CGFloat = 0
    while contrast(color, surface) < 3, fraction < 1 {
      fraction += 0.1
      color = mix(opaque, extreme, fraction)
    }
    return color
  }

  private static func readable(on color: UIColor) -> UIColor {
    contrast(color, .white) >= contrast(color, .black) ? .white : .black
  }

  static func contrast(_ first: UIColor, _ second: UIColor) -> CGFloat {
    let a = luminance(first) + 0.05
    let b = luminance(second) + 0.05
    return max(a, b) / min(a, b)
  }

  private static func luminance(_ color: UIColor) -> CGFloat {
    let (red, green, blue, _) = components(color)
    func linear(_ value: CGFloat) -> CGFloat {
      value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  private static func mix(_ from: UIColor, _ to: UIColor, _ fraction: CGFloat) -> UIColor {
    let a = components(from)
    let b = components(to)
    return UIColor(
      red: a.0 + (b.0 - a.0) * fraction,
      green: a.1 + (b.1 - a.1) * fraction,
      blue: a.2 + (b.2 - a.2) * fraction,
      alpha: 1
    )
  }

  private static func components(_ color: UIColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return (red, green, blue, alpha)
  }
}
