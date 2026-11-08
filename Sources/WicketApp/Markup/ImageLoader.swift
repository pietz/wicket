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

/// Web images, fetched under fixed rules: https only and never to a host that resolves to this Mac
/// or the local network (checked before the connection, so DNS rebinding in between is possible; an
/// accepted risk), an ephemeral
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
    private let resolve: Resolver

    init(
        configuration: URLSessionConfiguration = Self.configuration(),
        resolve: @escaping Resolver = Self.resolve
    ) {
        session = URLSession(configuration: configuration)
        self.resolve = resolve
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

    /// The addresses a host name or literal (in any spelling) stands for, as 4 or 16 bytes each.
    typealias Resolver = @Sendable (String) async -> [[UInt8]]

    /// Whether Wicket fetches `url`: https to a host whose every address is public unicast. The
    /// host is resolved, so no spelling of this Mac or the local network gets through (`127.1`,
    /// `localhost.`, `[::ffff:127.0.0.1]`, a public name pointing at a private address).
    static func allows(_ url: URL, resolve: Resolver = Self.resolve) async -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else { return false }
        let addresses = await resolve(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        return !addresses.isEmpty && addresses.allSatisfy(isPublic)
    }

    /// Whether `address` is public unicast: not this Mac, the local network, a shared or reserved
    /// range, multicast or broadcast. IPv6 only in global unicast (2000::/3), so mapped, translated
    /// and tunnelled IPv4 forms are refused with it.
    static func isPublic(_ address: [UInt8]) -> Bool {
        switch address.count {
        case 4:
            let (a, b, c) = (address[0], address[1], address[2])
            return
                !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && b & 0xC0 == 64)
                || (a == 169 && b == 254) || (a == 172 && b & 0xF0 == 16) || (a == 192 && b == 168)
                || (a == 192 && b == 0 && (c == 0 || c == 2)) || (a == 198 && b & 0xFE == 18)
                || (a == 198 && b == 51 && c == 100) || (a == 203 && b == 0 && c == 113))
        case 16:
            // 2000::/3, less Teredo (2001::/32), documentation (2001:db8::/32) and 6to4 (2002::/16).
            guard address[0] & 0xE0 == 0x20 else { return false }
            let prefix =
                UInt32(address[0]) << 24 | UInt32(address[1]) << 16 | UInt32(address[2]) << 8
                | UInt32(address[3])
            return prefix != 0x2001_0000 && prefix != 0x2001_0DB8 && prefix >> 16 != 0x2002
        default:
            return false
        }
    }

    /// The system's resolver (`getaddrinfo`), which also reads every literal spelling; never on
    /// the main actor.
    @concurrent static func resolve(_ host: String) async -> [[UInt8]] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0 else { return [] }
        defer { freeaddrinfo(list) }
        var addresses: [[UInt8]] = []
        var next = list
        while let info = next?.pointee {
            next = info.ai_next
            guard let address = info.ai_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    addresses.append(withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) })
                }
            case AF_INET6:
                address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    addresses.append(withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) })
                }
            default:
                continue
            }
        }
        return addresses
    }

    /// The image at `url`, decoded.
    @concurrent func fetch(_ url: URL) async throws -> Bitmap {
        guard await Self.allows(url, resolve: resolve) else { throw Failure.refused }
        let task = session.dataTask(with: url)
        let collector = Collector(resolve: resolve)
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
    /// follows a redirect only to a URL Wicket would fetch itself, checked the same way. URLSession
    /// calls it on its own serial queue; the lock covers the hand-off from `fetch`.
    private final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let resolve: Resolver
        private let lock = NSLock()
        private var data = Data()
        private var failure: Failure?
        private var continuation: CheckedContinuation<Data, any Error>?

        init(resolve: @escaping Resolver) { self.resolve = resolve }

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
            let resolve = resolve
            // Resolved off the session's queue, which other fetches share.
            Task {
                let allowed =
                    if let url = request.url { await RemoteImages.allows(url, resolve: resolve) } else {
                        false
                    }
                completionHandler(allowed ? request : nil)
            }
        }
    }
}
