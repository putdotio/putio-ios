import Foundation
import Synchronization

#if canImport(FoundationNetworking)
  @_exported import FoundationNetworking
#endif

package enum PortableFormat {
  #if canImport(Darwin)
    private static let relativeDateFormatters = Mutex<[Locale: RelativeDateTimeFormatter]>([:])

    package static func relativeDate(_ date: Date, relativeTo referenceDate: Date, locale: Locale)
      -> String
    {
      relativeDateFormatters.withLock { formatters in
        let formatter: RelativeDateTimeFormatter
        if let cached = formatters[locale] {
          formatter = cached
        } else {
          formatter = RelativeDateTimeFormatter()
          formatter.locale = locale
          formatter.dateTimeStyle = .named
          formatter.unitsStyle = .full
          formatters[locale] = formatter
        }
        return formatter.localizedString(for: date, relativeTo: referenceDate)
      }
    }

    package static func storage(
      _ value: Double, unit: UnitInformationStorage,
      numberStyle: FloatingPointFormatStyle<Double>, locale: Locale
    ) -> String {
      Measurement(value: value, unit: unit).formatted(
        .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: numberStyle)
          .locale(locale))
    }
  #else
    package static func relativeDate(_ date: Date, relativeTo referenceDate: Date, locale: Locale)
      -> String
    {
      Date.AnchoredRelativeFormatStyle(
        anchor: date, presentation: .named, unitsStyle: .wide, locale: locale
      ).format(referenceDate)
    }

    package static func storage(
      _ value: Double, unit: UnitInformationStorage,
      numberStyle: FloatingPointFormatStyle<Double>, locale: Locale
    ) -> String {
      "\(value.formatted(numberStyle.locale(locale))) \(unit.symbol)"
    }
  #endif
}

#if !canImport(Darwin)
  extension String {
    package struct LocalizationValue: ExpressibleByStringInterpolation, Sendable {
      package struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var key = ""
        fileprivate var arguments: [Argument] = []

        package init(literalCapacity: Int, interpolationCount: Int) {}

        package mutating func appendLiteral(_ literal: String) {
          key += literal.replacingOccurrences(of: "%", with: "%%")
        }

        package mutating func appendInterpolation<Value: BinaryInteger>(_ value: Value) {
          key += "%lld"
          arguments.append(.integer(Int64(value)))
        }

        package mutating func appendInterpolation<Value>(_ value: Value) {
          key += "%@"
          arguments.append(.text(String(describing: value)))
        }
      }

      fileprivate enum Argument: Sendable {
        case integer(Int64)
        case text(String)

        func text(locale: Locale) -> String {
          switch self {
          case .integer(let value): value.formatted(.number.locale(locale))
          case .text(let value): value
          }
        }
      }

      fileprivate let key: String
      fileprivate let arguments: [Argument]

      package init(stringLiteral value: String) {
        key = value.replacingOccurrences(of: "%", with: "%%")
        arguments = []
      }

      package init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
      }
    }

    package init(
      localized value: LocalizationValue, bundle: Bundle? = nil, locale: Locale = .current,
      comment: StaticString? = nil
    ) {
      let format = PortableStringCatalog.format(for: value, in: bundle ?? .main)
      self = PortableStringCatalog.substitute(value.arguments, into: format, locale: locale)
    }
  }

  private enum PortableStringCatalog {
    private struct Catalog: Decodable {
      struct Entry: Decodable {
        let localizations: [String: Localization]?
      }
      struct Localization: Decodable {
        struct Unit: Decodable { let value: String }
        struct Variant: Decodable { let stringUnit: Unit }
        struct Variations: Decodable { let plural: [String: Variant]? }
        let stringUnit: Unit?
        let variations: Variations?
      }
      let sourceLanguage: String
      let strings: [String: Entry]
    }

    private enum PluralCategory: String {
      case one
      case other

      init(count: Int64?) {
        switch count {
        case 1: self = .one
        default: self = .other
        }
      }
    }

    private static let catalogs = Mutex<[String: Catalog?]>([:])

    static func format(for value: String.LocalizationValue, in bundle: Bundle) -> String {
      guard let catalog = catalog(in: bundle),
        let localization = catalog.strings[value.key]?.localizations?[catalog.sourceLanguage]
      else { return value.key }
      if let plural = localization.variations?.plural {
        let count = value.arguments.lazy.compactMap { argument -> Int64? in
          if case .integer(let number) = argument { number } else { nil }
        }.first
        let variant = plural[PluralCategory(count: count).rawValue] ?? plural["other"]
        return variant?.stringUnit.value ?? value.key
      }
      return localization.stringUnit?.value ?? value.key
    }

    static func substitute(
      _ arguments: [String.LocalizationValue.Argument], into format: String, locale: Locale
    ) -> String {
      var result = ""
      var remaining = arguments.makeIterator()
      var index = format.startIndex
      while index < format.endIndex {
        let rest = format[index...]
        if rest.hasPrefix("%%") {
          result += "%"
          index = format.index(index, offsetBy: 2)
        } else if rest.hasPrefix("%lld") {
          result += remaining.next()?.text(locale: locale) ?? ""
          index = format.index(index, offsetBy: 4)
        } else if rest.hasPrefix("%@") {
          result += remaining.next()?.text(locale: locale) ?? ""
          index = format.index(index, offsetBy: 2)
        } else {
          result.append(format[index])
          index = format.index(after: index)
        }
      }
      return result
    }

    private static func catalog(in bundle: Bundle) -> Catalog? {
      catalogs.withLock { cache in
        if let cached = cache[bundle.bundlePath] { return cached }
        let catalog = bundle.url(forResource: "Localizable", withExtension: "xcstrings")
          .flatMap { try? Data(contentsOf: $0) }
          .flatMap { try? JSONDecoder().decode(Catalog.self, from: $0) }
        cache[bundle.bundlePath] = catalog
        return catalog
      }
    }
  }
#endif
