import Foundation
import CryptoKit

// AWS Signature Version 4 — minimal S3 client for the BYO-S3 cloud-offload feature
// (docs/CLOUD_SYNC_PLAN.md §3A). Lives in the APP layer, never a shared package, so the documented
// "the five shared packages contain no networking" invariant (docs/PRIVACY_SECURITY.md §1.1) holds.
//
// This is a from-scratch SigV4 signer (the codebase had no AWS SDK and no CryptoKit usage before).
// Only what the uploader needs: PUT (upload an object), GET (re-download for hash verify), HEAD
// (existence check), DELETE (purge-remote on opt-out). Path-style addressing so a bucket name with
// dots still works over TLS: https://s3.<region>.amazonaws.com/<bucket>/<key>.

public struct S3Config: Sendable, Equatable {
    public let bucket: String
    public let region: String
    public let accessKeyId: String
    public let secretAccessKey: String
    /// Object-key prefix inside the bucket (e.g. "noop"), no leading/trailing slash.
    public let prefix: String
    public init(bucket: String, region: String, accessKeyId: String, secretAccessKey: String, prefix: String) {
        self.bucket = bucket; self.region = region
        self.accessKeyId = accessKeyId; self.secretAccessKey = secretAccessKey
        self.prefix = prefix
    }

    var host: String { "s3.\(region).amazonaws.com" }
    var endpoint: URL { URL(string: "https://\(host)")! }
}

public enum S3Error: Error, LocalizedError {
    case badResponse(status: Int, body: String)
    case notFound
    case network(String)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .badResponse(let status, let body): return "S3 error \(status): \(body)"
        case .notFound: return "S3 object not found"
        case .network(let m): return "Network error: \(m)"
        case .notConfigured: return "Cloud sync is not configured"
        }
    }
}

public actor S3Client {
    private let config: S3Config
    private let session: URLSession

    public init(config: S3Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Full object key for a `(deviceId, day, stream)` payload, e.g.
    /// `noop/<deviceId>/2026-07-01/hrSample.csv.z`.
    public nonisolated func objectKey(deviceId: String, day: String, stream: String) -> String {
        let parts = [config.prefix, deviceId, day, "\(stream).csv.z"].filter { !$0.isEmpty }
        return parts.joined(separator: "/")
    }

    // MARK: - Verbs

    /// Upload `data` to `key`. Returns the object's sha256 (hex) — the same digest signed as
    /// x-amz-content-sha256, which the ledger stores for later verify.
    @discardableResult
    public func putObject(key: String, data: Data, contentType: String = "application/octet-stream") async throws -> String {
        let payloadHash = Self.sha256Hex(data)
        let (_, resp) = try await send(method: "PUT", key: key, queryItems: [], body: data,
                                       payloadHash: payloadHash, extraHeaders: ["content-type": contentType])
        try Self.check(resp, allow404: false)
        return payloadHash
    }

    /// Download `key`. Throws `.notFound` on a 404.
    public func getObject(key: String) async throws -> Data {
        let (data, resp) = try await send(method: "GET", key: key, queryItems: [], body: nil,
                                          payloadHash: Self.emptyHash, extraHeaders: [:])
        if (resp as? HTTPURLResponse)?.statusCode == 404 { throw S3Error.notFound }
        try Self.check(resp, allow404: false)
        return data
    }

    /// True if `key` exists (HEAD 200), false on 404.
    public func objectExists(key: String) async throws -> Bool {
        let (_, resp) = try await send(method: "HEAD", key: key, queryItems: [], body: nil,
                                       payloadHash: Self.emptyHash, extraHeaders: [:])
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return false }
        try Self.check(resp, allow404: false)
        return true
    }

    public func deleteObject(key: String) async throws {
        let (_, resp) = try await send(method: "DELETE", key: key, queryItems: [], body: nil,
                                       payloadHash: Self.emptyHash, extraHeaders: [:])
        // S3 DELETE returns 204; a 404 is fine (already gone).
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 || code == 204 || (200..<300).contains(code) { return }
        try Self.check(resp, allow404: true)
    }

    /// A cheap round-trip that proves the credentials + bucket work: HEAD a well-known key that need
    /// not exist (404 is success — it means we authenticated and reached the bucket; 403 means bad
    /// credentials or wrong bucket).
    public func validateAccess() async throws {
        let key = objectKey(deviceId: "_healthcheck", day: "_", stream: "_")
        _ = try await objectExists(key: key)
    }

    // MARK: - Signing core

    private func send(method: String, key: String, queryItems: [(String, String)], body: Data?,
                      payloadHash: String, extraHeaders: [String: String]) async throws
        -> (Data, URLResponse) {
        // Build the canonical URI for PATH-STYLE addressing: /<bucket>/<key…>, each segment
        // percent-encoded (slashes between segments preserved). Path-style keeps a bucket name with
        // dots working over TLS (virtual-hosted would break the wildcard cert). The bucket MUST be the
        // first path segment — S3 otherwise reads the key's first segment as the bucket and 301s.
        let canonicalURI = "/" + ([config.bucket] + key.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
            .map { Self.uriEncode($0, encodeSlash: true) }
            .joined(separator: "/")
        let canonicalQuery = queryItems
            .map { (Self.uriEncode($0.0, encodeSlash: true), Self.uriEncode($0.1, encodeSlash: true)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let now = Self.timestamp()
        let amzDate = now.amz
        let dateStamp = now.date

        var headers: [String: String] = [
            "host": config.host,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate,
        ]
        for (k, v) in extraHeaders { headers[k.lowercased()] = v }

        let sortedHeaderKeys = headers.keys.sorted()
        let canonicalHeaders = sortedHeaderKeys.map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
        let signedHeaders = sortedHeaderKeys.joined(separator: ";")

        let canonicalRequest = [
            method, canonicalURI, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(config.region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope, Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(secret: config.secretAccessKey, dateStamp: dateStamp,
                                         region: config.region, service: "s3")
        let signature = Self.hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        let authorization = "AWS4-HMAC-SHA256 "
            + "Credential=\(config.accessKeyId)/\(scope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"

        var urlString = config.endpoint.absoluteString + canonicalURI
        if !canonicalQuery.isEmpty { urlString += "?" + canonicalQuery }
        guard let url = URL(string: urlString) else { throw S3Error.network("bad URL") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        // Bypass the URL cache entirely. Otherwise URLSession caches a GET response and then attaches a
        // conditional `If-Modified-Since` to a later request for the SAME key — which S3 rejects on a
        // PUT/DELETE with 501 "A header you provided implies functionality that is not implemented".
        // S3 objects must never be HTTP-cached by this client anyway (we verify by re-download + hash).
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.httpBody = body ?? Data()
        req.setValue(String((body ?? Data()).count), forHTTPHeaderField: "Content-Length")
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }

        do {
            return try await session.data(for: req)
        } catch {
            throw S3Error.network(error.localizedDescription)
        }
    }

    private static func check(_ resp: URLResponse, allow404: Bool) throws {
        guard let http = resp as? HTTPURLResponse else { throw S3Error.network("no HTTP response") }
        if (200..<300).contains(http.statusCode) { return }
        if http.statusCode == 404 { if allow404 { return }; throw S3Error.notFound }
        throw S3Error.badResponse(status: http.statusCode, body: "")
    }

    // MARK: - Crypto helpers

    static let emptyHash = sha256Hex(Data())

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    static func hmacHex(key: Data, data: Data) -> String {
        hmac(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func signingKey(secret: String, dateStamp: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secret)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }

    /// RFC 3986 unreserved-set percent encoding, matching AWS's canonicalization (uppercase hex,
    /// space -> %20, and `/` only preserved when `encodeSlash` is false).
    static func uriEncode(_ s: String, encodeSlash: Bool) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        var out = ""
        for byte in s.utf8 {
            let ch = Character(UnicodeScalar(byte))
            if unreserved.contains(ch) {
                out.append(ch)
            } else if ch == "/" && !encodeSlash {
                out.append(ch)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    // MARK: - Deterministic timestamp

    struct Stamp { let amz: String; let date: String }

    static func timestamp(_ now: Date = Date()) -> Stamp {
        let amz = DateFormatter()
        amz.locale = Locale(identifier: "en_US_POSIX")
        amz.timeZone = TimeZone(identifier: "UTC")
        amz.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyyMMdd"
        return Stamp(amz: amz.string(from: now), date: day.string(from: now))
    }
}
