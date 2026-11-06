import Foundation

/// Unit and currency names the calculator understands, resolved to Foundation units and ISO codes.
///
/// Each unit's symbol and its English singular and plural names come from Foundation
/// (`Dimension.symbol`, `MeasurementFormatter`); the table below only adds the spellings Foundation
/// doesn't produce. Exact spellings win over case-folded ones, so `Mbit` stays megabits while `mb`
/// means megabytes, and the first unit registered under a folded name keeps it.
struct UnitCatalog: Sendable {
    static let shared = UnitCatalog()

    private let exact: [String: Dimension]
    private let folded: [String: Dimension]
    /// Every alias's word count is at most this, so lookups try no longer phrases.
    let maxWords: Int

    func unit(_ name: String) -> Dimension? {
        exact[name] ?? folded[name.lowercased()]
    }

    /// The kind of quantity a unit measures, for messages ("length"). Units of one kind convert.
    static func kind(of unit: Dimension) -> String {
        switch unit {
        case is UnitLength: "length"
        case is UnitMass: "mass"
        case is UnitTemperature: "temperature"
        case is UnitVolume: "volume"
        case is UnitSpeed: "speed"
        case is UnitArea: "area"
        case is UnitDuration: "time"
        case is UnitInformationStorage: "data size"
        default: "quantity"
        }
    }

    /// Compared by what they measure: a custom `UnitDuration` isn't the class of Foundation's own.
    static func sameKind(_ a: Dimension, _ b: Dimension) -> Bool {
        kind(of: a) == kind(of: b)
    }

    // MARK: Table

    private struct Entry {
        var unit: Dimension
        var aliases: [String] = []
        /// Register Foundation's symbol and English names too. Off where the symbol misleads.
        var foundationNames = true
        /// Replaces Foundation's conversion factor, which it stores rounded for some customary
        /// units (a pound is 0.453592 kg, a km/h 0.277778 m/s). Exact legal definitions instead.
        var exactFactor: Double?
    }

    /// The unit to convert with: Foundation's own, or the same unit with its exact factor.
    private static func conversionUnit(_ entry: Entry) -> Dimension {
        guard let factor = entry.exactFactor else { return entry.unit }
        let symbol = entry.unit.symbol
        let converter = UnitConverterLinear(coefficient: factor)
        switch entry.unit {
        case is UnitMass: return UnitMass(symbol: symbol, converter: converter)
        case is UnitVolume: return UnitVolume(symbol: symbol, converter: converter)
        case is UnitSpeed: return UnitSpeed(symbol: symbol, converter: converter)
        default: preconditionFailure("No exact factor support for \(symbol)")
        }
    }

    private static let usGallon = 3.785411784  // litres
    private static let usFluidOunce = usGallon / 128

    // Foundation has no day, week, month or year; these use the average Gregorian year.
    private static let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400))
    private static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))
    private static let year = UnitDuration(
        symbol: "yr", converter: UnitConverterLinear(coefficient: 365.2425 * 86_400))
    private static let month = UnitDuration(
        symbol: "mo", converter: UnitConverterLinear(coefficient: 365.2425 * 86_400 / 12))

    // Order matters only where folded spellings collide: the earlier entry keeps the name.
    private static let entries: [Entry] = [
        // Length
        Entry(unit: UnitLength.kilometers, aliases: ["kms"]),
        Entry(unit: UnitLength.meters, aliases: ["m"]),
        Entry(unit: UnitLength.centimeters),
        Entry(unit: UnitLength.millimeters),
        Entry(unit: UnitLength.micrometers, aliases: ["um"]),
        Entry(unit: UnitLength.nanometers),
        Entry(unit: UnitLength.miles),
        Entry(unit: UnitLength.yards),
        Entry(unit: UnitLength.feet),
        Entry(unit: UnitLength.inches),
        Entry(unit: UnitLength.nauticalMiles),
        Entry(unit: UnitLength.lightyears, aliases: ["lightyear", "lightyears"]),
        // Mass
        Entry(unit: UnitMass.kilograms, aliases: ["kilo", "kilos"]),
        Entry(unit: UnitMass.grams, aliases: ["g"]),
        Entry(unit: UnitMass.milligrams),
        Entry(unit: UnitMass.metricTons, aliases: ["tonne", "tonnes"]),
        Entry(unit: UnitMass.pounds, aliases: ["lbs"], exactFactor: 0.45359237),
        Entry(unit: UnitMass.ounces, exactFactor: 0.45359237 / 16),
        Entry(unit: UnitMass.stones, exactFactor: 0.45359237 * 14),
        // Temperature
        Entry(unit: UnitTemperature.celsius, aliases: ["c", "celsius", "degc"]),
        Entry(unit: UnitTemperature.fahrenheit, aliases: ["f", "fahrenheit", "degf"]),
        Entry(unit: UnitTemperature.kelvin, aliases: ["kelvin"]),
        // Volume
        Entry(unit: UnitVolume.liters, aliases: ["l"]),
        Entry(unit: UnitVolume.milliliters),
        Entry(unit: UnitVolume.centiliters),
        Entry(unit: UnitVolume.deciliters),
        Entry(unit: UnitVolume.cubicMeters, aliases: ["m3"]),
        Entry(unit: UnitVolume.cubicCentimeters, aliases: ["cm3", "cc"]),
        Entry(unit: UnitVolume.gallons, exactFactor: usGallon),
        Entry(unit: UnitVolume.quarts, exactFactor: usGallon / 4),
        Entry(unit: UnitVolume.pints, exactFactor: usGallon / 8),
        // Foundation's `cups` is the 240 mL metric cup with the symbol "c"; recipes mean the US cup.
        Entry(
            unit: UnitVolume(symbol: "cup", converter: UnitConverterLinear(coefficient: usFluidOunce * 8)),
            aliases: ["cup", "cups"], foundationNames: false),
        Entry(unit: UnitVolume.fluidOunces, aliases: ["floz"], exactFactor: usFluidOunce),
        Entry(unit: UnitVolume.tablespoons, exactFactor: usFluidOunce / 2),
        Entry(unit: UnitVolume.teaspoons, exactFactor: usFluidOunce / 6),
        // Speed
        Entry(unit: UnitSpeed.kilometersPerHour, aliases: ["kph", "kmh"], exactFactor: 1 / 3.6),
        Entry(unit: UnitSpeed.milesPerHour),
        Entry(unit: UnitSpeed.metersPerSecond),
        Entry(unit: UnitSpeed.knots, aliases: ["kt", "kts"], exactFactor: 1852 / 3600),
        // Area
        Entry(unit: UnitArea.squareMeters, aliases: ["m2", "sqm", "sq m"]),
        Entry(unit: UnitArea.squareKilometers, aliases: ["km2", "sq km"]),
        Entry(unit: UnitArea.squareCentimeters, aliases: ["cm2", "sq cm"]),
        Entry(unit: UnitArea.squareFeet, aliases: ["ft2", "sqft", "sq ft"]),
        Entry(unit: UnitArea.squareMiles, aliases: ["mi2", "sq mi"]),
        Entry(unit: UnitArea.acres),
        Entry(unit: UnitArea.hectares),
        // Time
        Entry(unit: UnitDuration.seconds, aliases: ["s", "secs"]),
        Entry(unit: UnitDuration.minutes, aliases: ["mins"]),
        Entry(unit: UnitDuration.hours, aliases: ["h", "hrs"]),
        Entry(unit: UnitDuration.milliseconds),
        Entry(unit: day, aliases: ["day", "days"]),
        Entry(unit: week, aliases: ["w", "week", "weeks", "wks"]),
        Entry(unit: month, aliases: ["month", "months"]),
        Entry(unit: year, aliases: ["y", "year", "years", "yrs"]),
        // Data size: bytes register first so a folded `mb` is megabytes.
        Entry(unit: UnitInformationStorage.bytes, aliases: ["b"]),
        Entry(unit: UnitInformationStorage.kilobytes, aliases: ["kb"]),
        Entry(unit: UnitInformationStorage.megabytes),
        Entry(unit: UnitInformationStorage.gigabytes),
        Entry(unit: UnitInformationStorage.terabytes),
        Entry(unit: UnitInformationStorage.petabytes),
        Entry(unit: UnitInformationStorage.kibibytes),
        Entry(unit: UnitInformationStorage.mebibytes),
        Entry(unit: UnitInformationStorage.gibibytes),
        Entry(unit: UnitInformationStorage.tebibytes),
        // Foundation's bit symbols (`kb`, `Mb`) read as bytes to most people; spell bits out.
        Entry(unit: UnitInformationStorage.bits, aliases: ["bit", "bits"], foundationNames: false),
        Entry(
            unit: UnitInformationStorage.kilobits, aliases: ["kbit", "kilobit", "kilobits"],
            foundationNames: false),
        Entry(
            unit: UnitInformationStorage.megabits, aliases: ["Mbit", "megabit", "megabits"],
            foundationNames: false),
        Entry(
            unit: UnitInformationStorage.gigabits, aliases: ["Gbit", "gigabit", "gigabits"],
            foundationNames: false),
    ]

    private init() {
        var exact: [String: Dimension] = [:]
        var folded: [String: Dimension] = [:]
        let formatter = MeasurementFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .long

        for entry in Self.entries {
            let target = Self.conversionUnit(entry)
            var names = entry.aliases
            if entry.foundationNames {
                let unit = entry.unit
                names.append(unit.symbol)
                names.append(formatter.string(from: unit))  // plural: "kilometers"
                let singular = formatter.string(from: Measurement(value: 1, unit: unit))
                names.append(String(singular.dropFirst(2)))  // drop the "1 "
            }
            for name in names {
                let british = name.replacing("meter", with: "metre").replacing("liter", with: "litre")
                for spelling in Set([name, british]) {
                    if exact[spelling] == nil { exact[spelling] = target }
                    let key = spelling.lowercased()
                    if folded[key] == nil { folded[key] = target }
                }
            }
        }
        self.exact = exact
        self.folded = folded
        maxWords = folded.keys.map { $0.split(separator: " ").count }.max() ?? 1
    }
}

/// Currency names: ISO 4217 codes (from Foundation), a few unambiguous signs and English nouns.
enum CurrencyNames {
    static let signs: [Character: String] = [
        "$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR", "₩": "KRW", "₺": "TRY", "₪": "ILS",
    ]

    private static let nouns: [String: String] = [
        "euro": "EUR", "euros": "EUR", "dollar": "USD", "dollars": "USD", "yen": "JPY",
    ]

    private static let codes = Set(Locale.Currency.isoCurrencies.map { $0.identifier.uppercased() })

    /// The ISO code a word names, if any: `usd`, `EUR`, `euros`.
    static func code(_ word: String) -> String? {
        if word.count == 3 {
            let upper = word.uppercased()
            if codes.contains(upper) { return upper }
        }
        return nouns[word.lowercased()]
    }
}
