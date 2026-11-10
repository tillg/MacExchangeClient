import Foundation

public struct EWSError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { "\(message) (\(code))" }
}

/// Sends SOAP requests to an Exchange EWS endpoint. Answers Basic, NTLM and Negotiate challenges
/// with the account's credentials. Never logs requests, responses or the password.
public final class EWSClient: Sendable {
    public let url: URL
    private let auth: AuthDelegate
    private let session: URLSession

    public init(url: URL, username: String, password: String) {
        self.url = url
        auth = AuthDelegate(URLCredential(user: username, password: password, persistence: .forSession))
        session = URLSession(configuration: .ephemeral)
    }

    /// Sends one EWS operation (the content of `soap:Body`) and returns the parsed response.
    /// With `strict`, any response message that is not `NoError` throws.
    public func call(_ body: String, strict: Bool = true) async throws -> XMLDocument {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.envelope(body).utf8)
        let (data, response) = try await session.data(for: req, delegate: auth)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let doc: XMLDocument
        do { doc = try XMLDocument(data: Self.sanitize(data)) } catch {
            // The parser's message names line and column only, never content.
            throw EWSError(code: "HTTP \(status)", message: status == 401 ? "Sign-in failed"
                           : "Unreadable EWS response (\(data.count) bytes): \(error.localizedDescription)")
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
    /// and `XMLDocument` rejects, failing the whole page. They become U+FFFD instead.
    static func sanitize(_ data: Data) -> Data {
        guard data.range(of: Data("&#".utf8)) != nil else { return data }
        let s = String(decoding: data, as: UTF8.self)
        let range = NSRange(s.startIndex..., in: s)
        guard invalidCharRef.firstMatch(in: s, range: range) != nil else { return data }
        return Data(invalidCharRef.stringByReplacingMatches(in: s, range: range, withTemplate: "&#xFFFD;").utf8)
    }

    nonisolated(unsafe) static let invalidCharRef = try! NSRegularExpression(
        pattern: "&#(?:x0*(?:[0-8bcef]|1[0-9a-f])|0*(?:[0-8]|1[124-9]|2[0-9]|3[01]));", options: .caseInsensitive)

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
            challenge.previousFailureCount == 0 ? (.useCredential, credential) : (.cancelAuthenticationChallenge, nil)
        default:
            (.performDefaultHandling, nil)
        }
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

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}
