import Foundation

public enum HollerKitAPIError: Error, LocalizedError, Sendable, Equatable {
    case missingAuthToken
    case invalidURL(String)
    case invalidResponse
    case serverError(statusCode: Int, code: String, message: String)
    case httpError(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .missingAuthToken:
            return "No authentication token is currently available."
        case .invalidURL(let path):
            return "Invalid HollerKit server URL for path: \(path)."
        case .invalidResponse:
            return "Received an invalid HTTP response from the HollerKit server."
        case .serverError(_, _, let message):
            return message
        case .httpError(let statusCode, let body):
            return body.isEmpty ? "HTTP error \(statusCode)." : "HTTP error \(statusCode): \(body)"
        }
    }

    public var statusCode: Int? {
        switch self {
        case .serverError(let statusCode, _, _), .httpError(let statusCode, _):
            return statusCode
        case .missingAuthToken, .invalidURL, .invalidResponse:
            return nil
        }
    }

    public var isAuthenticationError: Bool {
        switch self {
        case .missingAuthToken:
            return true
        case .serverError(let statusCode, _, _), .httpError(let statusCode, _):
            return statusCode == 401 || statusCode == 403
        case .invalidURL, .invalidResponse:
            return false
        }
    }

    /// Returns `true` when the server rejected an attachment key because its upload grant expired or was already consumed.
    public var isExpiredOrConsumedGrantError: Bool {
        if case .serverError(_, let code, _) = self {
            return code == "expired_or_consumed_grant"
        }
        return false
    }

    /// Returns `true` when the HTTP status code indicates a permanent client validation error.
    public var isPermanentValidationError: Bool {
        guard let statusCode else { return false }
        return statusCode == 400 || statusCode == 413 || statusCode == 415 || statusCode == 422
    }
}

public struct QuestManifestSource: Codable, Equatable, Sendable {
    public var pr: Int?
    public var sha: String?
    public var added: String?

    public init(pr: Int? = nil, sha: String? = nil, added: String? = nil) {
        self.pr = pr
        self.sha = sha
        self.added = added
    }
}

public struct QuestManifestEntry: Codable, Equatable, Sendable {
    public var id: String
    public var contentHash: String?
    public var title: String
    public var area: String
    public var setup: [String]
    public var steps: [String]
    public var expect: [String]
    public var needs: [String]
    public var record: String
    public var start: String?
    public var source: QuestManifestSource?
    public var capture: [QuestCaptureDefinition]?

    public init(
        id: String,
        contentHash: String? = nil,
        title: String,
        area: String,
        setup: [String] = [],
        steps: [String],
        expect: [String],
        needs: [String] = [],
        record: String = "optional",
        start: String? = nil,
        source: QuestManifestSource? = nil,
        capture: [QuestCaptureDefinition]? = nil
    ) {
        self.id = id
        self.contentHash = contentHash
        self.title = title
        self.area = area
        self.setup = setup
        self.steps = steps
        self.expect = expect
        self.needs = needs
        self.record = record
        self.start = start
        self.source = source
        self.capture = capture
    }
}

public struct QuestResultCounts: Codable, Equatable, Sendable {
    public var pass: Int
    public var fail: Int
    public var unsure: Int
    public var abandoned: Int

    public init(pass: Int = 0, fail: Int = 0, unsure: Int = 0, abandoned: Int = 0) {
        self.pass = pass
        self.fail = fail
        self.unsure = unsure
        self.abandoned = abandoned
    }
}

public struct BuildManifestQuestItem: Codable, Equatable, Sendable {
    public var id: String
    public var version: Int
    public var contentHash: String
    public var questStatus: String
    public var boardStatus: String
    public var title: String
    public var area: String
    public var setup: [String]
    public var steps: [String]
    public var expect: [String]
    public var needs: [String]
    public var record: String
    public var start: String?
    public var source: QuestManifestSource?
    public var counts: QuestResultCounts?
    public var latestRun: QuestLatestRun?

    public init(
        id: String,
        version: Int,
        contentHash: String,
        questStatus: String,
        boardStatus: String,
        title: String,
        area: String,
        setup: [String] = [],
        steps: [String],
        expect: [String],
        needs: [String] = [],
        record: String = "optional",
        start: String? = nil,
        source: QuestManifestSource? = nil,
        counts: QuestResultCounts? = nil,
        latestRun: QuestLatestRun? = nil
    ) {
        self.id = id
        self.version = version
        self.contentHash = contentHash
        self.questStatus = questStatus
        self.boardStatus = boardStatus
        self.title = title
        self.area = area
        self.setup = setup
        self.steps = steps
        self.expect = expect
        self.needs = needs
        self.record = record
        self.start = start
        self.source = source
        self.counts = counts
        self.latestRun = latestRun
    }
}

public struct BuildManifestResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var build: String
    public var pendingCount: Int
    public var quests: [BuildManifestQuestItem]

    public init(ok: Bool = true, build: String, pendingCount: Int, quests: [BuildManifestQuestItem]) {
        self.ok = ok
        self.build = build
        self.pendingCount = pendingCount
        self.quests = quests
    }
}

public struct UploadGrantResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var key: String
    public var url: URL
    public var expiresAt: String

    public init(ok: Bool = true, key: String, url: URL, expiresAt: String) {
        self.ok = ok
        self.key = key
        self.url = url
        self.expiresAt = expiresAt
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

public struct FeedbackEventPayload: Codable, Equatable, Sendable, ExpressibleByDictionaryLiteral {
    public var strings: [String: String]
    public var fields: [String: HollerKitFieldValue]?
    public var durationMs: Double?
    public var startOffsetSeconds: Double?

    public init() {
        self.strings = [:]
        self.fields = nil
        self.durationMs = nil
        self.startOffsetSeconds = nil
    }

    public init(
        strings: [String: String],
        fields: [String: HollerKitFieldValue]? = nil,
        durationMs: Double? = nil,
        startOffsetSeconds: Double? = nil
    ) {
        self.strings = strings
        self.fields = fields
        self.durationMs = durationMs
        self.startOffsetSeconds = startOffsetSeconds
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        var dict: [String: String] = [:]
        for (k, v) in elements {
            dict[k] = v
        }
        self.strings = dict
        self.fields = nil
        self.durationMs = nil
        self.startOffsetSeconds = nil
    }

    public subscript(key: String) -> String? {
        get { strings[key] }
        set { strings[key] = newValue }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var strings: [String: String] = [:]
        var fields: [String: HollerKitFieldValue]?
        var durationMs: Double?
        var startOffsetSeconds: Double?

        for key in container.allKeys {
            if key.stringValue == "fields" {
                if let decodedFields = try? container.decode([String: HollerKitFieldValue].self, forKey: key) {
                    fields = decodedFields
                } else if let str = try? container.decode(String.self, forKey: key) {
                    strings[key.stringValue] = str
                }
            } else if key.stringValue == "durationMs" {
                if let decoded = try? container.decode(Double.self, forKey: key), decoded.isFinite {
                    durationMs = decoded
                } else if let str = try? container.decode(String.self, forKey: key) {
                    strings[key.stringValue] = str
                }
            } else if key.stringValue == "startOffsetSeconds" {
                if let decoded = try? container.decode(Double.self, forKey: key), decoded.isFinite {
                    startOffsetSeconds = decoded
                } else if let str = try? container.decode(String.self, forKey: key) {
                    strings[key.stringValue] = str
                }
            } else if let str = try? container.decode(String.self, forKey: key) {
                strings[key.stringValue] = str
            }
        }
        self.strings = strings
        self.fields = fields
        self.durationMs = durationMs
        self.startOffsetSeconds = startOffsetSeconds
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (k, v) in strings {
            if k == "fields" && fields != nil { continue }
            if k == "durationMs" && durationMs != nil { continue }
            if k == "startOffsetSeconds" && startOffsetSeconds != nil { continue }
            if let key = DynamicCodingKey(stringValue: k) {
                try container.encode(v, forKey: key)
            }
        }
        if let fields, !fields.isEmpty, let key = DynamicCodingKey(stringValue: "fields") {
            try container.encode(fields, forKey: key)
        }
        if let durationMs, durationMs.isFinite, let key = DynamicCodingKey(stringValue: "durationMs") {
            try container.encode(durationMs, forKey: key)
        }
        if let startOffsetSeconds, startOffsetSeconds.isFinite, let key = DynamicCodingKey(stringValue: "startOffsetSeconds") {
            try container.encode(startOffsetSeconds, forKey: key)
        }
    }

    public mutating func clampToSize(maxBytes: Int = 2048) {
        if let d = durationMs, !d.isFinite {
            durationMs = nil
        }
        if let s = startOffsetSeconds, !s.isFinite {
            startOffsetSeconds = nil
        }
        if var curFields = fields {
            curFields = curFields.filter { _, v in
                switch v {
                case .double(let d): return d.isFinite
                default: return true
                }
            }
            fields = curFields.isEmpty ? nil : curFields
        }

        var iterations = 0
        while iterations < 100, let data = try? JSONEncoder().encode(self), data.count > maxBytes {
            iterations += 1
            let overhead = data.count - maxBytes
            var trimmedSomething = false

            if let longest = strings.max(by: { $0.value.count < $1.value.count }), longest.value.count > 16 {
                let trim = min(longest.value.count - 16, max(32, overhead + 24))
                let newLen = max(16, longest.value.count - trim)
                strings[longest.key] = String(longest.value.prefix(newLen)) + "...[truncated]"
                trimmedSomething = true
            }

            if let curFields = fields {
                var longestFieldKey: String?
                var longestFieldCount = 0
                for (k, val) in curFields {
                    if case .string(let s) = val, s.count > longestFieldCount {
                        longestFieldKey = k
                        longestFieldCount = s.count
                    }
                }
                if let k = longestFieldKey, longestFieldCount > 16 {
                    let trim = min(longestFieldCount - 16, max(32, overhead + 24))
                    let newLen = max(16, longestFieldCount - trim)
                    if case .string(let s) = curFields[k] {
                        var updated = curFields
                        updated[k] = .string(String(s.prefix(newLen)) + "...[truncated]")
                        fields = updated
                        trimmedSomething = true
                    }
                }
            }

            if !trimmedSomething {
                let estimateKeysToDrop = max(1, overhead / 40)
                var dropped = 0
                while dropped < estimateKeysToDrop {
                    if let k = strings.keys.first(where: { $0 != "message" && $0 != "category" }) ?? strings.keys.first {
                        strings.removeValue(forKey: k)
                        dropped += 1
                        trimmedSomething = true
                    } else if var curFields = fields, let k = curFields.keys.first {
                        curFields.removeValue(forKey: k)
                        fields = curFields.isEmpty ? nil : curFields
                        dropped += 1
                        trimmedSomething = true
                    } else {
                        break
                    }
                }
                if !trimmedSomething {
                    break
                }
            }
        }

        if let data = try? JSONEncoder().encode(self), data.count > maxBytes {
            fields = nil
            for k in strings.keys where k != "message" && k != "category" {
                strings.removeValue(forKey: k)
            }
            if let msg = strings["message"], let current = try? JSONEncoder().encode(self), current.count > maxBytes {
                let overhead = current.count - maxBytes
                let newLen = max(0, msg.count - overhead - 16)
                strings["message"] = newLen > 0 ? (String(msg.prefix(newLen)) + "...[truncated]") : "...[truncated]"
            }
            if let current = try? JSONEncoder().encode(self), current.count > maxBytes {
                strings = ["message": "...[truncated]"]
            }
        }
    }
}

public struct FeedbackEventInput: Codable, Equatable, Sendable {
    public var offsetSeconds: Double
    public var kind: String
    public var payload: FeedbackEventPayload

    public init(offsetSeconds: Double = 0, kind: String, payload: FeedbackEventPayload = FeedbackEventPayload()) {
        self.offsetSeconds = offsetSeconds.isFinite ? offsetSeconds : 0
        self.kind = kind
        self.payload = payload
        self.payload.clampToSize(maxBytes: 2048)
    }

    public init(offsetSeconds: Double = 0, kind: String, payload: [String: String]) {
        self.offsetSeconds = offsetSeconds.isFinite ? offsetSeconds : 0
        self.kind = kind
        self.payload = FeedbackEventPayload(strings: payload)
        self.payload.clampToSize(maxBytes: 2048)
    }

    private enum CodingKeys: String, CodingKey {
        case offsetSeconds
        case kind
        case payload
    }

    public func encode(to encoder: Encoder) throws {
        var clampedPayload = payload
        clampedPayload.clampToSize(maxBytes: 2048)
        var container = encoder.container(keyedBy: CodingKeys.self)
        let safeOffset = offsetSeconds.isFinite ? offsetSeconds : 0
        try container.encode(safeOffset, forKey: .offsetSeconds)
        try container.encode(kind, forKey: .kind)
        try container.encode(clampedPayload, forKey: .payload)
    }
}

public struct FeedbackAttachmentInput: Codable, Equatable, Sendable {
    public var key: String
    public var kind: String
    public var mimeType: String?
    public var size: Int?
    public var offsetSeconds: Double?
    public var videoStartOffsetSeconds: Double?

    public init(
        key: String,
        kind: String,
        mimeType: String? = nil,
        size: Int? = nil,
        offsetSeconds: Double? = nil,
        videoStartOffsetSeconds: Double? = nil
    ) {
        self.key = key
        self.kind = kind
        self.mimeType = mimeType
        self.size = size
        self.offsetSeconds = offsetSeconds
        self.videoStartOffsetSeconds = videoStartOffsetSeconds
    }
}

public struct FeedbackSubmissionRequest: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var questId: String?
    public var questVersion: Int?
    public var result: String?
    public var build: String
    public var appVersion: String?
    public var device: String?
    public var os: String?
    public var comment: String?
    public var transcript: String?
    public var metadata: [String: String]
    public var stepsChecked: [Bool]
    public var startedAt: String?
    public var endedAt: String?
    public var events: [FeedbackEventInput]
    public var attachments: [FeedbackAttachmentInput]

    public init(
        id: UUID = UUID(),
        kind: String,
        questId: String? = nil,
        questVersion: Int? = nil,
        result: String? = nil,
        build: String,
        appVersion: String? = nil,
        device: String? = nil,
        os: String? = nil,
        comment: String? = nil,
        transcript: String? = nil,
        metadata: [String: String] = [:],
        stepsChecked: [Bool] = [],
        startedAt: String? = nil,
        endedAt: String? = nil,
        events: [FeedbackEventInput] = [],
        attachments: [FeedbackAttachmentInput] = []
    ) {
        self.id = id.uuidString.lowercased()
        self.kind = kind
        self.questId = questId
        self.questVersion = questVersion
        self.result = result
        self.build = build
        self.appVersion = appVersion
        self.device = device
        self.os = os
        self.comment = comment
        self.transcript = transcript
        self.metadata = metadata
        self.stepsChecked = stepsChecked
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.events = events
        self.attachments = attachments
    }

    public mutating func clampToBudget(maxBytes: Int = 240 * 1024) {
        for i in 0..<events.count {
            events[i].payload.clampToSize(maxBytes: 2048)
        }

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self), data.count > maxBytes else { return }

        var droppedCount = 0
        while events.count > 1, let current = try? encoder.encode(self), current.count > maxBytes {
            if events.first?.payload["message"] == "breadcrumbs.truncated" {
                if events.count > 2 {
                    events.remove(at: 1)
                    droppedCount += 1
                } else {
                    break
                }
            } else {
                events.removeFirst()
                droppedCount += 1
            }

            if events.first?.payload["message"] != "breadcrumbs.truncated" {
                var marker = FeedbackEventPayload()
                marker["message"] = "breadcrumbs.truncated"
                marker["category"] = "hollerkit"
                marker["truncated"] = "true"
                marker.fields = ["dropped": .int(droppedCount)]
                events.insert(FeedbackEventInput(offsetSeconds: 0, kind: "breadcrumb", payload: marker), at: 0)
            } else {
                events[0].payload.fields = ["dropped": .int(droppedCount)]
            }
        }
    }
}

public struct SubmittedFeedbackItem: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var questId: String?
    public var questVersion: Int?
    public var area: String?
    public var result: String?
    public var triageStatus: String?
    public var triageSummary: String?
    public var links: [String]?
    public var build: String
    public var appVersion: String?
    public var device: String?
    public var os: String?
    public var submitterId: String
    public var comment: String?
    public var transcript: String?
    public var stepsChecked: [Bool]?
    public var startedAt: String?
    public var endedAt: String?
    public var createdAt: String
    public var updatedAt: String
}

public struct FeedbackSubmissionResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var idempotent: Bool
    public var feedback: SubmittedFeedbackItem
}

public struct PendingQuestItem: Codable, Equatable, Sendable {
    public var id: String
    public var version: Int
    public var contentHash: String
    public var title: String
    public var area: String
    public var setup: [String]
    public var steps: [String]
    public var expect: [String]
    public var needs: [String]
    public var record: String
    public var start: String?
    public var source: QuestManifestSource?
    public var status: String
    public var boardStatus: String?
    public var createdAt: String
    public var retiredAt: String?
    public var counts: QuestResultCounts?
    public var latestRun: QuestLatestRun?
    public var passedOnCurrentVersion: Bool?
}

public struct PendingQuestsResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var build: String
    public var pendingCount: Int
    public var quests: [PendingQuestItem]
}

private struct ErrorEnvelopeResponse: Decodable {
    struct ErrorDetail: Decodable {
        var code: String
        var message: String
    }

    var ok: Bool?
    var error: ErrorDetail
}

private struct BuildManifestRequestPayload: Encodable {
    var appVersion: String?
    var quests: [QuestManifestEntry]
}

private struct UploadGrantRequestPayload: Encodable {
    var feedbackId: String
    var kind: String
    var mimeType: String
    var size: Int
}

public struct APIClient: Sendable {
    public static let protocolVersion = "1"

    public var server: URL
    public var auth: @Sendable () async throws -> String?
    public var session: URLSession

    public init(
        server: URL,
        auth: @escaping @Sendable () async throws -> String?,
        session: URLSession = .shared
    ) {
        self.server = server
        self.auth = auth
        self.session = session
    }

    public init(configuration: HollerKitConfiguration) {
        self.init(
            server: configuration.server,
            auth: configuration.auth,
            session: configuration.urlSession
        )
    }

    public func resolveToken() async throws -> String {
        guard let rawToken = try await auth() else {
            throw HollerKitAPIError.missingAuthToken
        }
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HollerKitAPIError.missingAuthToken
        }
        return trimmed
    }

    public func syncBuildManifest(
        build: String,
        appVersion: String?,
        quests: [QuestManifestEntry],
        token: String? = nil
    ) async throws -> BuildManifestResponse {
        let resolvedToken = try await resolvedBearerToken(token)
        let encodedBuild = Self.encodePathSegment(build)
        let payload = BuildManifestRequestPayload(appVersion: appVersion, quests: quests)
        return try await sendJSONRequest(
            method: "POST",
            path: "/v1/builds/\(encodedBuild)/manifest",
            token: resolvedToken,
            body: payload
        )
    }

    public func requestUploadGrant(
        feedbackId: UUID,
        kind: String,
        mimeType: String,
        size: Int,
        token: String? = nil
    ) async throws -> UploadGrantResponse {
        let resolvedToken = try await resolvedBearerToken(token)
        let payload = UploadGrantRequestPayload(
            feedbackId: feedbackId.uuidString.lowercased(),
            kind: kind,
            mimeType: mimeType,
            size: size
        )
        return try await sendJSONRequest(
            method: "POST",
            path: "/v1/uploads",
            token: resolvedToken,
            body: payload
        )
    }

    public func uploadFile(
        url: URL,
        data: Data,
        mimeType: String
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 45
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HollerKitAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: responseData, encoding: .utf8) ?? ""
            throw HollerKitAPIError.httpError(statusCode: httpResponse.statusCode, body: bodyText)
        }
    }

    public func submitFeedback(
        _ request: FeedbackSubmissionRequest,
        token: String? = nil
    ) async throws -> FeedbackSubmissionResponse {
        var sanitizedRequest = request
        sanitizedRequest.clampToBudget()
        let resolvedToken = try await resolvedBearerToken(token)
        return try await sendJSONRequest(
            method: "POST",
            path: "/v1/feedback",
            token: resolvedToken,
            body: sanitizedRequest
        )
    }

    public func fetchPendingQuests(
        build: String,
        token: String? = nil
    ) async throws -> [PendingQuestItem] {
        let resolvedToken = try await resolvedBearerToken(token)
        let encodedBuild = Self.encodePathSegment(build)
        let response: PendingQuestsResponse = try await sendRequest(
            method: "GET",
            path: "/v1/builds/\(encodedBuild)/pending",
            token: resolvedToken,
            bodyData: nil
        )
        return response.quests
    }

    private func resolvedBearerToken(_ overrideToken: String?) async throws -> String {
        if let overrideToken {
            let trimmed = overrideToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return try await resolveToken()
    }

    private func sendJSONRequest<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        token: String,
        body: Body
    ) async throws -> Response {
        let encoder = JSONEncoder()
        let bodyData = try encoder.encode(body)
        return try await sendRequest(
            method: method,
            path: path,
            token: token,
            bodyData: bodyData
        )
    }

    private func sendRequest<Response: Decodable>(
        method: String,
        path: String,
        token: String,
        bodyData: Data?
    ) async throws -> Response {
        let url = try endpointURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "hollerkit-protocol")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HollerKitAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let errorEnvelope = try? JSONDecoder().decode(ErrorEnvelopeResponse.self, from: data) {
                throw HollerKitAPIError.serverError(
                    statusCode: httpResponse.statusCode,
                    code: errorEnvelope.error.code,
                    message: errorEnvelope.error.message
                )
            }
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw HollerKitAPIError.httpError(statusCode: httpResponse.statusCode, body: bodyText)
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    func endpointURL(for path: String) throws -> URL {
        let baseString = server.absoluteString.replacingOccurrences(
            of: "/+$",
            with: "",
            options: .regularExpression
        )
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: baseString + normalizedPath) else {
            throw HollerKitAPIError.invalidURL(path)
        }
        return url
    }

    private static func encodePathSegment(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}
