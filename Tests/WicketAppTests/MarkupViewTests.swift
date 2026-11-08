import AppKit
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WicketCore

@testable import WicketApp

/// The document views' rules that don't need a screen: every component has a view, columns
/// collapse, tones map to colors, images load under their caps; and how long a full page lays out.
@MainActor
struct MarkupViewTests {
    @Test func everyComponentHasARegisteredView() {
        for component in Markup.components {
            #expect(ComponentViews.draws(component), "\(component) has no view in ComponentViews")
        }
        #expect(ComponentViews.registered.count == Markup.components.count)
    }

    /// Columns sit side by side while each is at least 150 pt at small text, scaled with the text:
    /// three fit the default palette at medium, stack at large; two stack only when narrow.
    @Test func columnsCollapseWhenNarrowOrLarge() {
        #expect(!ColumnsLayout.stacks(count: 3, width: 560, textSize: .medium))
        #expect(ColumnsLayout.stacks(count: 3, width: 560, textSize: .large))
        #expect(!ColumnsLayout.stacks(count: 2, width: 560, textSize: .larger))
        #expect(ColumnsLayout.stacks(count: 2, width: 300, textSize: .medium))
        #expect(!ColumnsLayout.stacks(count: 2, width: 330, textSize: .small))
        #expect(ColumnsLayout.stacks(count: 1, width: 900, textSize: .small))
    }

    @Test func tonesAreDistinctSystemColors() {
        let tones: [WicketCore.Document.Tone] = [.info, .positive, .warning, .negative]
        #expect(tones.map(ToneStyle.color) == [.blue, .green, .orange, .red])
        // Every tone a callout can have has its symbol.
        #expect(tones.allSatisfy { Callout.symbols[$0] != nil })
    }

    @Test func textSizesScaleFromSmall() {
        #expect(TextSize.small.points(13) == 13)
        #expect(TextSize.medium.points(13) == 15)
        #expect(TextSize.larger.scale > TextSize.large.scale)
    }

    /// Typing on a page is printable text, never a control or function key (the arrows).
    @Test func onlyPrintableKeysType() {
        #expect(PaletteRootView.isTyped("a"))
        #expect(PaletteRootView.isTyped("ü"))
        #expect(!PaletteRootView.isTyped("\r"))
        #expect(!PaletteRootView.isTyped("\u{1B}"))
        #expect(!PaletteRootView.isTyped("\u{F700}"))
        #expect(!PaletteRootView.isTyped(""))
    }

    @Test func chartSummaryNamesItsExtremes() throws {
        let markup = """
            <chart kind="line" title="Daily high" unit="°C">
            <point label="Mon" value="9"/><point label="Wed" value="7"/><point label="Fri" value="10"/>
            </chart>
            """
        let chart = try #require(Markup.document(markup).blocks.first?.component(WicketCore.Chart.self))
        #expect(ChartView.summary(chart) == "Line chart, 3 values: lowest 7 °C at Wed, highest 10 °C at Fri")
        #expect(ChartView.range(chart) == "7–10 °C")
    }

    // MARK: Images

    @Test func onlyHTTPSToPublicHostsIsFetched() {
        #expect(RemoteImages.allows(URL(string: "https://upload.wikimedia.org/a.jpg")!))
        #expect(RemoteImages.allows(URL(string: "https://8.8.8.8/a.png")!))
        #expect(!RemoteImages.allows(URL(string: "http://example.com/a.png")!))
        #expect(!RemoteImages.allows(URL(string: "file:///tmp/a.png")!))
        for local in [
            "https://localhost/a", "https://printer.local/a", "https://127.0.0.1/a", "https://10.0.0.2/a",
            "https://192.168.1.1/a", "https://172.20.0.1/a", "https://169.254.1.1/a", "https://[::1]/a",
            "https://[fe80::1]/a", "https://[fd00::1]/a",
        ] {
            #expect(!RemoteImages.allows(URL(string: local)!), "\(local)")
        }
    }

    @Test func aSessionKeepsAndSendsNothing() {
        let configuration = RemoteImages.configuration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.timeoutIntervalForResource == RemoteImages.Limits.seconds)
    }

    @Test func decodingBoundsTheBitmapAndRefusesWhatIsNotARaster() throws {
        let big = try #require(Self.png(width: 4000, height: 1000))
        let bitmap = try RemoteImages.decode(big)
        #expect(max(bitmap.image.width, bitmap.image.height) == RemoteImages.Limits.pixels)
        #expect(throws: RemoteImages.Failure.notAnImage) { try RemoteImages.decode(Data("<svg/>".utf8)) }
        #expect(throws: RemoteImages.Failure.notAnImage) { try RemoteImages.decode(Data("<html>".utf8)) }
    }

    @Test func fetchesStopAtTheByteLimitAndOnErrors() async throws {
        let remote = RemoteImages(configuration: StubProtocol.configuration())
        let small = try #require(Self.png(width: 10, height: 10))
        StubProtocol.serve("https://img.example/ok.png", body: small)
        let ok = try await remote.fetch(URL(string: "https://img.example/ok.png")!)
        #expect(ok.image.width == 10)

        StubProtocol.serve("https://img.example/huge.png", body: Data(count: RemoteImages.Limits.bytes + 1))
        await #expect(throws: RemoteImages.Failure.tooLarge) {
            try await remote.fetch(URL(string: "https://img.example/huge.png")!)
        }
        StubProtocol.serve("https://img.example/gone.png", body: Data(), status: 404)
        await #expect(throws: RemoteImages.Failure.status(404)) {
            try await remote.fetch(URL(string: "https://img.example/gone.png")!)
        }
        await #expect(throws: RemoteImages.Failure.refused) {
            try await remote.fetch(URL(string: "http://img.example/ok.png")!)
        }
    }

    // MARK: Performance

    /// Lays out a 64 KiB page (every gallery example repeated) at the palette's width, as the card
    /// measures it, and logs how long that took. A guard against a pathological layout, not a
    /// benchmark: the bound is generous for a debug build.
    @Test func aFullPageLaysOutQuickly() throws {
        var markup = ""
        let examples = Markup.components.map { $0.example.markup }.joined(separator: "\n\n")
        while markup.utf8.count < Markup.Limits.bytes - examples.utf8.count - 2 {
            markup += examples + "\n\n"
        }
        var parser = Markup.Parser()
        let parseStart = ContinuousClock.now
        let document = parser.parse(markup).document
        let parse = ContinuousClock.now - parseStart
        let view = DocumentView(
            document: document, metadata: [], textSize: .medium, scroll: nil, onMeasure: { _ in })
        let start = ContinuousClock.now
        let host = NSHostingView(rootView: view.frame(width: 600))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        let layout = ContinuousClock.now - start
        print(
            "64 KiB page: \(markup.utf8.count) bytes, \(document.blocks.count) blocks, \(document.targets.count) targets; parse \(parse), first layout \(layout), height \(height)"
        )
        #expect(document.blocks.count > 100)
        #expect(layout < .seconds(5))
    }

    private static func png(width: Int, height: Int) -> Data? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Answers requests from canned bodies, so fetches run without the network.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var responses: [String: (Data, Int)] = [:]
    private static let lock = NSLock()

    static func serve(_ url: String, body: Data, status: Int = 200) {
        lock.withLock { responses[url] = (body, status) }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = RemoteImages.configuration()
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let (body, status) = Self.lock.withLock { Self.responses[url.absoluteString] } ?? (Data(), 404)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In chunks, as a network delivers them, so the limit is checked as the bytes arrive.
        var offset = 0
        while offset < body.count {
            let end = min(offset + 256 * 1024, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
