import Foundation
import Testing

@testable import WicketCore

let ecbSample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" \
    xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
    \t<gesmes:subject>Reference rates</gesmes:subject>
    \t<gesmes:Sender><gesmes:name>European Central Bank</gesmes:name></gesmes:Sender>
    \t<Cube>
    \t\t<Cube time='2026-11-05'>
    \t\t\t<Cube currency='USD' rate='1.1000'/>
    \t\t\t<Cube currency='JPY' rate='176.77'/>
    \t\t\t<Cube currency='GBP' rate='0.8500'/>
    \t\t\t<Cube currency='CHF' rate='0.9143'/>
    \t\t</Cube>
    \t</Cube>
    </gesmes:Envelope>
    """

@Test func parsesECBFeed() throws {
    let rates = try ECBFeed.parse(Data(ecbSample.utf8))
    #expect(rates.source == "ECB")
    #expect(rates.base == "EUR")
    #expect(rates.dayString == "2026-11-05")
    #expect(rates.rates == ["EUR": 1, "USD": 1.1, "JPY": 176.77, "GBP": 0.85, "CHF": 0.9143])
}

@Test(arguments: ["", "<Cube/>", "<Cube time='2026-11-05'></Cube>", "<html><body>Error</body></html>"])
func rejectsInvalidFeed(xml: String) {
    #expect(throws: ECBFeed.ParseError()) { try ECBFeed.parse(Data(xml.utf8)) }
}

@Test func crossRatesThroughTheBase() throws {
    let rates = try ECBFeed.parse(Data(ecbSample.utf8))
    #expect(try #require(rates.convert(110, from: "USD", to: "EUR")).isApproximately(100))
    #expect(try #require(rates.convert(110, from: "USD", to: "GBP")).isApproximately(85))
    #expect(rates.convert(1, from: "USD", to: "XYZ") == nil)
}

extension Double {
    func isApproximately(_ other: Double, tolerance: Double = 1e-9) -> Bool {
        abs(self - other) <= tolerance * max(1, abs(other))
    }
}
