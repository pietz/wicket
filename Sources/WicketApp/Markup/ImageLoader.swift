import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// The images pages show (`<image>`), loaded by Wicket alone and never on the main actor: a local
/// file through Quick Look's thumbnails, a web image through `RemoteImages`, both decoded to a
/// bounded bitmap and cached for the session. A page's author never fetches anything itself.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private var loading: [URL: Task<NSImage?, Never>] = [:]
    private let remote: RemoteImages

    init(remote: RemoteImages = RemoteImages()) {
        self.remote = remote
        cache.countLimit = 64
    }

    /// The image if it is loaded already.
    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    /// The image at `url` (a file or an https URL); nil if it can't be had. One load per URL at a
    /// time, however many views ask.
    func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        if let task = loading[url] { return await task.value }
        let remote = remote
        let task = Task<NSImage?, Never> {
            let start = ContinuousClock.now
            let bitmap =
                url.isFileURL ? await LocalImages.thumbnail(url) : try? await remote.fetch(url)
            Perf.log("image (\(url.isFileURL ? "local" : "remote")): \(Perf.ms(since: start))")
            return bitmap.map { NSImage(cgImage: $0.image, size: .zero) }
        }
        loading[url] = task
        let image = await task.value
        loading[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// A decoded bitmap, handed from the decoding task to the main actor. `CGImage` is immutable.
struct Bitmap: @unchecked Sendable {
    let image: CGImage
}

/// Thumbnails of local files: whatever Quick Look can draw (photos, PDFs, videos), at most
/// `RemoteImages.Limits.pixels` on a side.
enum LocalImages {
    @concurrent static func thumbnail(_ url: URL) async -> Bitmap? {
        let side = CGFloat(RemoteImages.Limits.pixels) / 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: 2, representationTypes: .thumbnail)
        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return representation.map { Bitmap(image: $0.cgImage) }
    }
}

/// Web images, fetched under fixed rules: https only and never to the local network, an ephemeral
/// session without cookies, cache or credentials, a redirect only to another allowed URL, at most
/// `Limits.bytes` within `Limits.seconds`, raster formats only, decoded off the main actor to at
/// most `Limits.pixels` on a side.
struct RemoteImages: Sendable {
    enum Limits {
        /// The most an image may weigh as sent.
        static let bytes = 8 * 1024 * 1024
        /// How long a fetch may take, from asking to the last byte.
        static let seconds: TimeInterval = 10
        /// The longest side kept after decoding.
        static let pixels = 2048
    }

    enum Failure: Error, Equatable {
        /// Not https, or a local address.
        case refused
        case status(Int)
        /// Past `Limits.bytes`, by its declared length or by what arrived.
        case tooLarge
        /// Not an image ImageIO decodes as a raster (SVG, HTML, a PDF).
        case notAnImage
    }

    private let session: URLSession

    init(configuration: URLSessionConfiguration = Self.configuration()) {
        session = URLSession(configuration: configuration)
    }

    /// An ephemeral session that keeps and sends nothing: no cookies, cache or credentials.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Limits.seconds
        configuration.timeoutIntervalForResource = Limits.seconds
        configuration.httpAdditionalHeaders = [
            "Accept": "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8"
        ]
        return configuration
    }

    /// Whether Wicket fetches `url`: https to a named or public host, never this Mac or the local
    /// network by its literal address.
    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), !host.isEmpty else {
            return false
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return false }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare.contains(":") {
            // IPv6: loopback, unique local (fc00::/7), link local (fe80::/10), unspecified.
            return
                !(bare == "::1" || bare == "::" || bare.hasPrefix("fc") || bare.hasPrefix("fd")
                || bare.hasPrefix("fe8") || bare.hasPrefix("fe9") || bare.hasPrefix("fea")
                || bare.hasPrefix("feb"))
        }
        let octets = bare.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, bare.split(separator: ".").count == 4 else { return true }
        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
        case (172, 16...31), (100, 64...127): return false
        default: return true
        }
    }

    /// The image at `url`, decoded.
    @concurrent func fetch(_ url: URL) async throws -> Bitmap {
        guard Self.allows(url) else { throw Failure.refused }
        let task = session.dataTask(with: url)
        let collector = Collector()
        task.delegate = collector
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.start(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return try Self.decode(data)
    }

    /// The bitmap in `data`, at most `Limits.pixels` on a side; only raster formats.
    static func decode(_ data: Data) throws -> Bitmap {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source).map({ UTType($0 as String) }) ?? nil,
            type.conforms(to: .image), !type.conforms(to: .svg), !type.conforms(to: .pdf)
        else { throw Failure.notAnImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Limits.pixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.notAnImage
        }
        return Bitmap(image: image)
    }

    /// Gathers one fetch's bytes, stopping it as soon as it is refused or grows past the limit, and
    /// follows a redirect only to a URL Wicket would fetch itself. URLSession calls it on its own
    /// serial queue; the lock covers the hand-off from `fetch`.
    private final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var failure: Failure?
        private var continuation: CheckedContinuation<Data, any Error>?

        func start(_ continuation: CheckedContinuation<Data, any Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lock.withLock { failure = .status(http.statusCode) }
                return completionHandler(.cancel)
            }
            if response.expectedContentLength > Int64(Limits.bytes) {
                lock.withLock { failure = .tooLarge }
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let over = lock.withLock {
                self.data.append(data)
                if self.data.count > Limits.bytes { failure = .tooLarge }
                return failure != nil
            }
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?)
        {
            let (continuation, result): (CheckedContinuation<Data, any Error>?, Result<Data, any Error>) =
                lock.withLock {
                    defer { self.continuation = nil }
                    if let failure { return (self.continuation, .failure(failure)) }
                    if let error { return (self.continuation, .failure(error)) }
                    return (self.continuation, .success(data))
                }
            continuation?.resume(with: result)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(request.url.map(RemoteImages.allows) == true ? request : nil)
        }
    }
}
