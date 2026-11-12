import Foundation
import MailModel

public struct EWSError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { "\(message) (\(code))" }
}

/// Sends SOAP requests to an Exchange EWS endpoint. Answers Basic, NTLM and Negotiate challenges
/// with the account's credentials. Never logs requests, responses or the password.
public final class EWSClient: Sendable {
    public let url: URL
    private let credential: URLCredential
    private let session: URLSession

    public init(url: URL, username: String, password: String) {
        self.url = url
        credential = URLCredential(user: username, password: password, persistence: .forSession)
        session = URLSession(configuration: .ephemeral)
    }

    /// Sends one EWS operation (the content of `soap:Body`) and returns the parsed response.
    /// With `strict`, any response message that is not `NoError` throws.
    public func call(_ body: String, strict: Bool = true) async throws -> XMLDocument {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.envelope(body).utf8)
        // One delegate per request, so it can tell whether this request's credentials were rejected.
        let auth = AuthDelegate(credential)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req, delegate: auth) } catch {
            throw Self.mapError(error, credentialsRejected: auth.rejected)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw AuthenticationError() }
        let doc: XMLDocument
        do { doc = try XMLDocument(data: Self.sanitize(data)) } catch {
            // The parser's message names line and column only, never content.
            throw EWSError(code: "HTTP \(status)",
                           message: "Unreadable EWS response (\(data.count) bytes): \(error.localizedDescription)")
        }
        if let fault = doc.first("Fault") {
            throw EWSError(code: fault.text("ResponseCode") ?? "SOAP fault", message: fault.text("faultstring") ?? "Server error")
        }
        if strict, let bad = doc.all("ResponseCode").first(where: { $0.stringValue != "NoError" }) {
            let text = bad.parent?.text("MessageText") ?? "Request failed"
            throw EWSError(code: bad.stringValue ?? "", message: text)
        }
        return doc
    }

    /// Exchange writes control characters from old mails as references like `&#8;`, which XML 1.0 forbids
    /// and `XMLDocument` rejects, failing the whole page. So are references to U+FFFE, U+FFFF, surrogates and
    /// numbers past U+10FFFF. They all become U+FFFD instead.
    static func sanitize(_ data: Data) -> Data {
        guard data.range(of: Data("&#".utf8)) != nil else { return data }
        let s = String(decoding: data, as: UTF8.self) as NSString
        var out = "", last = 0
        for m in charRef.matches(in: s as String, range: NSRange(location: 0, length: s.length)) {
            let digits = s.substring(with: m.range(at: 1))
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            if let v = value, isXMLChar(v) { continue }
            out += s.substring(with: NSRange(location: last, length: m.range.location - last)) + "&#xFFFD;"
            last = m.range.location + m.range.length
        }
        guard last > 0 else { return data }
        return Data((out + s.substring(from: last)).utf8)
    }

    static let charRef = try! NSRegularExpression(pattern: "&#(x[0-9a-f]+|[0-9]+);", options: .caseInsensitive)

    /// XML 1.0's `Char`: tab, line feed, carriage return, and everything from U+0020 except surrogates, U+FFFE and U+FFFF.
    static func isXMLChar(_ v: UInt32) -> Bool {
        v == 0x9 || v == 0xA || v == 0xD || (0x20...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v)
            || (0x10000...0x10FFFF).contains(v)
    }

    /// A request cancelled because the server rejected the password is a sign-in failure, not a network error.
    static func mapError(_ error: Error, credentialsRejected: Bool) -> Error {
        credentialsRejected && (error as? URLError)?.code == .cancelled ? AuthenticationError() : error
    }

    static func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
        <soap:Header><t:RequestServerVersion Version="Exchange2013_SP1"/></soap:Header>
        <soap:Body>\(body)</soap:Body>
        </soap:Envelope>
        """
    }
}

private final class AuthDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let credential: URLCredential
    private let lock = NSLock()
    private var _rejected = false
    /// The server asked again after the credentials were sent once: the password is wrong.
    var rejected: Bool { lock.withLock { _rejected } }
    init(_ credential: URLCredential) { self.credential = credential }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        if ProcessInfo.processInfo.environment["EWS_DEBUG"] != nil {
            let status = (challenge.failureResponse as? HTTPURLResponse)?.statusCode ?? 0
            FileHandle.standardError.write(Data("EWS auth: \(method) failures=\(challenge.previousFailureCount) status=\(status)\n".utf8))
        }
        return switch method {
        case NSURLAuthenticationMethodNegotiate:
            // Kerberos with DOMAIN\user and a password fails off the domain; let the server fall back to NTLM.
            (.rejectProtectionSpace, nil)
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodNTLM:
            // One attempt per request: retrying a wrong password could lock the domain account.
            challenge.previousFailureCount == 0 ? (.useCredential, credential) : reject()
        default:
            (.performDefaultHandling, nil)
        }
    }

    private func reject() -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        lock.withLock { _rejected = true }
        return (.cancelAuthenticationChallenge, nil)
    }
}

/// XPath helpers that ignore namespaces.
extension XMLNode {
    func all(_ name: String) -> [XMLNode] { (try? nodes(forXPath: ".//*[local-name()='\(name)']")) ?? [] }
    func first(_ name: String) -> XMLNode? { all(name).first }
    func children(_ name: String) -> [XMLNode] { (try? nodes(forXPath: "./*[local-name()='\(name)']")) ?? [] }
    func child(_ name: String) -> XMLNode? { children(name).first }
    func text(_ name: String) -> String? { first(name)?.stringValue }
    func attr(_ name: String) -> String? { (self as? XMLElement)?.attribute(forName: name)?.stringValue }
    var elementChildren: [XMLNode] { (children ?? []).filter { $0.kind == .element } }
}

/// Text for a request. Characters XML 1.0 forbids (controls other than tab, line feed and carriage return, and
/// U+FFFE, U+FFFF) are left out: one of them, pasted from Word or a PDF, would make the whole request malformed.
func xmlEscape(_ s: String) -> String {
    let text = s.unicodeScalars.contains(where: forbiddenInXML)
        ? String(String.UnicodeScalarView(s.unicodeScalars.filter { !forbiddenInXML($0) })) : s
    return text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

private func forbiddenInXML(_ c: Unicode.Scalar) -> Bool {
    c.value < 0x20 ? c != "\t" && c != "\n" && c != "\r" : c.value == 0xFFFE || c.value == 0xFFFF
}
