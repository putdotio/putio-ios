import SwiftUI

public enum PutioTVTypeScale {
  public static let minimumSize: CGFloat = 26

  private static let regular = "GTAmerica-Rg"
  private static let medium = "GTAmerica-Md"
  private static let mono = "BerkeleyMonoVariable-Regular"

  public static let title = PutioFontRole(
    fontName: medium, size: 56, lineHeight: 66 / 56, textStyle: .title)
  public static let emptyTitle = PutioFontRole(
    fontName: medium, size: 40, lineHeight: 48 / 40, textStyle: .title2)
  public static let panelTitle = PutioFontRole(
    fontName: medium, size: 36, lineHeight: 44 / 36, textStyle: .title3)
  public static let rowTitle = PutioFontRole(
    fontName: regular, size: 30, lineHeight: 38 / 30, textStyle: .body)
  public static let action = PutioFontRole(
    fontName: regular, size: 30, lineHeight: 38 / 30, textStyle: .body)
  public static let body = PutioFontRole(
    fontName: regular, size: 28, lineHeight: 38 / 28, textStyle: .body)
  public static let button = PutioFontRole(
    fontName: medium, size: 28, lineHeight: 36 / 28, textStyle: .headline)
  public static let label = PutioFontRole(
    fontName: medium, size: 26, lineHeight: 34 / 26, textStyle: .subheadline)
  public static let caption = PutioFontRole(
    fontName: regular, size: 26, lineHeight: 34 / 26, textStyle: .caption)
  public static let numeric = PutioFontRole(
    fontName: mono, size: 26, lineHeight: 34 / 26, textStyle: .caption)

  static let roles = [
    title, emptyTitle, panelTitle, rowTitle, action, body, button, label, caption, numeric,
  ]
}
