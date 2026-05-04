import CryptoKit
import Foundation

public struct HollerKitSubmissionResponse: Decodable, Sendable {
    public var ok: Bool
    public var issueUrl: URL?
    public var reportId: String?
}

public struct MultipartClient: Sendable {
    public var endpoint: URL
    public var appSecret: String
    public var session: URLSession

    public init(
        endpoint: URL,
        appSecret: String,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.appSecret = appSecret
        self.session = session
    }

    public func submit(_ payload: HollerKitReportPayload) async throws -> HollerKitSubmissionResponse {
        let boundary = "HollerKit-\(UUID().uuidString)"
        let body = try MultipartBodyBuilder(boundary: boundary).build(payload)
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let signature = Self.signature(body: body, timestamp: timestamp, secret: appSecret)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(timestamp, forHTTPHeaderField: "x-hollerkit-timestamp")
        request.setValue(signature, forHTTPHeaderField: "x-hollerkit-signature")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(HollerKitSubmissionResponse.self, from: data)
    }

    static func signature(body: Data, timestamp: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        var data = Data()
        data.append(body)
        data.append(Data(timestamp.utf8))
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return authenticationCode.map { String(format: "%02x", $0) }.joined()
    }
}

struct MultipartBodyBuilder {
    var boundary: String

    func build(_ payload: HollerKitReportPayload) throws -> Data {
        var body = Data()
        appendField("inputMode", value: payload.inputMode.wireValue, to: &body)
        appendOptionalField("comment", value: payload.comment, to: &body)
        appendJSONField("metadata", value: payload.metadata, to: &body)
        appendJSONField("breadcrumbs", value: payload.breadcrumbs, to: &body)
        appendOptionalField("userIdHash", value: payload.userIdHash, to: &body)

        if let transcript = payload.transcript {
            appendJSONField("transcript", value: transcript, to: &body)
        }

        for image in payload.images {
            appendFile("image", attachment: image, to: &body)
        }

        if let audio = payload.audio {
            appendFile("audio", attachment: audio, to: &body)
        }

        body.appendString("--\(boundary)--\r\n")
        return body
    }

    private func appendOptionalField(_ name: String, value: String?, to body: inout Data) {
        guard let value, !value.isEmpty else { return }
        appendField(name, value: value, to: &body)
    }

    private func appendField(_ name: String, value: String, to body: inout Data) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendString("\(value)\r\n")
    }

    private func appendJSONField<T: Encodable>(_ name: String, value: T, to body: inout Data) {
        guard let data = try? JSONEncoder.hollerKit.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        appendField(name, value: string, to: &body)
    }

    private func appendFile(_ name: String, attachment: HollerKitAttachment, to body: inout Data) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(attachment.filename)\"\r\n")
        body.appendString("Content-Type: \(attachment.mimeType)\r\n\r\n")
        body.append(attachment.data)
        body.appendString("\r\n")
    }
}

private extension JSONEncoder {
    static var hollerKit: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(Data(value.utf8))
    }
}
