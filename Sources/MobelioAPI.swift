// MobelioAPI.swift — a client for the Mobelio private API (https://mobelio.org/api). See docs/API-DOC.md.
//
// iOS 15+ / macOS 12+, Swift 5.9 or later (also compiles in Swift 6 language mode).
// Add this one file to the app. Only the refresh token is stored (in the Keychain); the access token
// lives in memory, is refreshed automatically before it expires, and once more if the server says 401.

import Foundation
import Security

// MARK: - Models

/// What /auth/login and /auth/refresh answer with.
public struct TokenPair: Decodable, Sendable {
    public let tokenType: String
    public let accessToken: String
    /// Seconds the access token is valid (900).
    public let expiresIn: Int
    public let refreshToken: String
    /// Seconds the refresh token is valid (up to 30 days).
    public let refreshExpiresIn: Int
}

/// GET /auth/me
public struct Me: Decodable, Sendable {
    public let id: String
    public let username: String
}

/// An account from mobelio.account, as handed out by the claim endpoints.
public struct Account: Decodable, Sendable {
    public let id: Int
    public let email: String?
    public let password: String
}

public enum ActivationResult: String, Encodable, Sendable {
    /// Done: the account stays activated forever.
    case activated
    /// It can't be activated; it's never handed out for activation again.
    case failed
    /// Give it back unchanged, for someone else to take.
    case released
}

public enum UsageResult: String, Encodable, Sendable {
    /// Done: not handed out again until a reset.
    case used
    /// Give it back unchanged.
    case released
}

/// The answer to a report.
public struct Report: Decodable, Sendable {
    public let id: Int
    public let result: String
    public let at: Date
}

/// POST /v1/friend-ids
public struct FriendIDs: Decodable, Sendable {
    public let received: Int
    public let uniqueCount: Int
    public let duplicateCount: Int
    /// IDs on the server's blacklist: never returned, never saved.
    public let blacklistedCount: Int
    /// The IDs never seen before and not blacklisted, in the order sent. They are now saved.
    public let unique: [String]
}

/// POST /v1/reset
public struct ResetResult: Decodable, Sendable {
    public let friendIdsDeleted: Int
    public let accountsReset: Int
}

/// POST /v1/phone-numbers
public struct PhoneNumbersAdded: Decodable, Sendable {
    /// The country they were added to, as the server stores it: "ge" and "+995" come back as "GE" and "995".
    public let countryCode: String
    public let received: Int
    /// New numbers saved, at the end of the list.
    public let addedCount: Int
    /// Already in the list, or repeated in the request.
    public let duplicateCount: Int
}

/// GET /v1/phone-numbers/count
public struct PhoneNumberCount: Decodable, Sendable {
    public let countryCode: String
    /// Every number that country has.
    public let total: Int
    /// Not handed out yet: what next can still return.
    public let available: Int
    /// Already handed out (until a reset).
    public let given: Int
}

/// POST /v1/phone-numbers/reset
public struct PhoneNumbersReset: Decodable, Sendable {
    /// Numbers that had been handed out and are available again.
    public let numbersReset: Int
}

/// GET /v1/accounts/stats
public struct Stats: Decodable, Sendable {
    public struct Activation: Decodable, Sendable {
        public let activated: Int
        public let failed: Int
        public let claimed: Int
        public let remaining: Int
    }
    public struct Usage: Decodable, Sendable {
        public let used: Int
        public let claimed: Int
        public let remaining: Int
    }
    public let total: Int
    public let activation: Activation
    public let usage: Usage
    public let friendIds: Int
}

/// GET /.well-known/jwks.json (only servers that verify tokens themselves need this).
public struct JWKS: Decodable, Sendable {
    public struct Key: Decodable, Sendable {
        public let kty: String
        public let crv: String
        public let x: String
        public let y: String
        public let kid: String
        public let alg: String
        public let use: String
    }
    public let keys: [Key]
}

// MARK: - Errors

public enum MobelioError: Error, Equatable, Sendable {
    /// Login refused: wrong username or password, or the account is disabled. Don't retry automatically:
    /// five failures lock the account for 15 minutes.
    case invalidCredentials
    /// Too many failed logins. Wait this many seconds before trying once more.
    case tooManyAttempts(retryAfter: Int)
    /// The session is over (logged out, expired, password changed…). Show the login screen.
    case sessionExpired
    /// Any other error answer: the HTTP status and the API's `error` code,
    /// e.g. `.api(status: 409, code: "reserved_by_someone_else")`.
    case api(status: Int, code: String)
    /// The server's answer wasn't what this client expects.
    case unexpectedResponse
}

// MARK: - Refresh-token storage

public protocol RefreshTokenStore: Sendable {
    func load() -> String?
    func save(_ token: String)
    func clear()
}

/// Keeps the refresh token in the Keychain, readable only on this device, after its first unlock.
public struct KeychainRefreshTokenStore: RefreshTokenStore {
    private let service: String

    public init(service: String = "org.mobelio.api") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "refresh_token",
        ]
    }

    public func load() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) {
        clear()
        var query = query
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Client

public actor MobelioAPI {
    public static let productionURL = URL(string: "https://mobelio.org/api/")!

    private let baseURL: URL
    private let session: URLSession
    private let store: any RefreshTokenStore
    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    /// The refresh in progress, if any: everyone who needs one waits for this same request.
    private var refreshing: Task<Void, Error>?

    public init(
        baseURL: URL = MobelioAPI.productionURL,
        session: URLSession = .shared,
        store: any RefreshTokenStore = KeychainRefreshTokenStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.store = store
    }

    /// True when a session is stored, so the user doesn't need to type the password again.
    public var isLoggedIn: Bool { store.load() != nil }

    // MARK: Auth

    /// POST /auth/login — starts a session and stores its tokens.
    public func login(username: String, password: String) async throws {
        let (data, response) = try await send("POST", "auth/login", body: ["username": username, "password": password])
        switch response.statusCode {
        case 200:
            save(try decode(TokenPair.self, data))
        case 401:
            throw MobelioError.invalidCredentials
        case 429:
            let seconds = Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 900
            throw MobelioError.tooManyAttempts(retryAfter: seconds)
        default:
            throw apiError(data, response)
        }
    }

    /// POST /auth/logout — ends the session on the server and forgets the tokens here.
    public func logout() async {
        if let refreshToken = store.load() {
            _ = try? await send("POST", "auth/logout", body: ["refresh_token": refreshToken])
        }
        forgetTokens()
    }

    /// GET /auth/me — who the current access token belongs to.
    public func me() async throws -> Me {
        try await authorized("GET", "auth/me")
    }

    /// GET /.well-known/jwks.json — the public signing key.
    public func publicKeys() async throws -> JWKS {
        let (data, response) = try await send("GET", ".well-known/jwks.json")
        guard response.statusCode == 200 else { throw apiError(data, response) }
        return try decode(JWKS.self, data)
    }

    // MARK: Accounts

    /// POST /v1/accounts/activation/next — reserves the next account to activate for 15 minutes.
    /// Returns nil when there is none left.
    public func claimNextAccountToActivate() async throws -> Account? {
        try await claim("v1/accounts/activation/next")
    }

    /// POST /v1/accounts/{id}/activation — reports what happened to an account.
    @discardableResult
    public func reportActivation(accountID: Int, result: ActivationResult, reason: String? = nil) async throws -> Report {
        try await authorized("POST", "v1/accounts/\(accountID)/activation", body: ActivationReport(result: result, reason: reason))
    }

    /// POST /v1/accounts/usage/next — reserves the next unused account (activated or not) for 30 minutes.
    /// Returns nil when there is none left.
    public func claimNextAccountToUse() async throws -> Account? {
        try await claim("v1/accounts/usage/next")
    }

    /// POST /v1/accounts/{id}/usage — reports an account used, or gives it back.
    @discardableResult
    public func reportUsage(accountID: Int, result: UsageResult) async throws -> Report {
        try await authorized("POST", "v1/accounts/\(accountID)/usage", body: ["result": result.rawValue])
    }

    /// GET /v1/accounts/stats — counts for every queue.
    public func stats() async throws -> Stats {
        try await authorized("GET", "v1/accounts/stats")
    }

    // MARK: Friend IDs and reset

    /// POST /v1/friend-ids — sends up to 500 IDs; returns (and saves) the ones never seen before and not blacklisted.
    public func submitFriendIDs(_ ids: [String]) async throws -> FriendIDs {
        try await authorized("POST", "v1/friend-ids", body: ["ids": ids])
    }

    /// POST /v1/reset — deletes every saved friend ID and clears every account's usage.
    /// Activation is never touched. This can't be undone.
    @discardableResult
    public func reset() async throws -> ResetResult {
        try await authorized("POST", "v1/reset", body: ["confirm": "RESET"])
    }

    // MARK: Phone numbers

    /// POST /v1/phone-numbers — adds one or more numbers (up to 1000 per call) to the end of that country's list.
    /// `countryCode` is 1–8 letters or digits, e.g. "GE" (case doesn't matter; a leading "+" is ignored).
    /// Numbers that country already has are skipped.
    @discardableResult
    public func addPhoneNumbers(_ numbers: [String], countryCode: String) async throws -> PhoneNumbersAdded {
        try await authorized("POST", "v1/phone-numbers", body: PhoneNumbersToAdd(countryCode: countryCode, numbers: numbers))
    }

    /// POST /v1/phone-numbers/next?country_code=GE&count=N — that country's next numbers not handed out yet,
    /// in the order added (1 to 500, default 1). They aren't handed out again until a reset. Fewer, or none,
    /// when that country's list runs out.
    public func nextPhoneNumbers(countryCode: String, count: Int = 1) async throws -> [String] {
        let next: PhoneNumbers = try await authorized(
            "POST", "v1/phone-numbers/next?country_code=\(queryValue(countryCode))&count=\(count)")
        return next.numbers
    }

    /// GET /v1/phone-numbers/count?country_code=GE — how many numbers that country has, and how many are left.
    public func phoneNumberCount(countryCode: String) async throws -> PhoneNumberCount {
        try await authorized("GET", "v1/phone-numbers/count?country_code=\(queryValue(countryCode))")
    }

    /// POST /v1/phone-numbers/reset — makes every number, in every country, available again; next starts over
    /// from the first.
    @discardableResult
    public func resetPhoneNumbers() async throws -> PhoneNumbersReset {
        try await authorized("POST", "v1/phone-numbers/reset", body: ["confirm": "RESET"])
    }

    // MARK: Plumbing

    private struct PhoneNumbers: Decodable, Sendable {
        let numbers: [String]
    }

    private struct PhoneNumbersToAdd: Encodable, Sendable {
        let countryCode: String
        let numbers: [String]

        enum CodingKeys: String, CodingKey {
            case countryCode = "country_code"
            case numbers
        }
    }

    /// Percent-encodes everything but letters, digits and -._~, so a value like "+995" survives a query string.
    private func queryValue(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private struct ActivationReport: Encodable, Sendable {
        let result: ActivationResult
        let reason: String?
    }

    private struct Claimed: Decodable, Sendable {
        let account: Account
    }

    private func claim(_ path: String) async throws -> Account? {
        do {
            let claimed: Claimed = try await authorized("POST", path)
            return claimed.account
        } catch MobelioError.api(status: 404, code: "no_accounts_left") {
            return nil
        }
    }

    /// Sends a request with the access token. Refreshes it first when it expires within a minute,
    /// and once more (then retries the request once) if the server still answers 401.
    private func authorized<Response: Decodable>(
        _ method: String,
        _ path: String,
        body: (any Encodable & Sendable)? = nil
    ) async throws -> Response {
        if accessToken == nil || accessTokenExpiry.timeIntervalSinceNow < 60 {
            try await refreshOnce()
        }
        var (data, response) = try await send(method, path, body: body, token: accessToken)
        if response.statusCode == 401 {
            try await refreshOnce()
            (data, response) = try await send(method, path, body: body, token: accessToken)
        }
        guard (200..<300).contains(response.statusCode) else { throw apiError(data, response) }
        return try decode(Response.self, data)
    }

    /// One refresh at a time: a refresh token works only once, so two parallel refreshes would end the session.
    private func refreshOnce() async throws {
        if let refreshing {
            return try await refreshing.value
        }
        let task = Task { try await refresh() }
        refreshing = task
        defer { refreshing = nil }
        try await task.value
    }

    /// POST /auth/refresh — swaps the stored refresh token for a new pair.
    private func refresh() async throws {
        guard let refreshToken = store.load() else { throw MobelioError.sessionExpired }
        let (data, response) = try await send("POST", "auth/refresh", body: ["refresh_token": refreshToken])
        switch response.statusCode {
        case 200:
            save(try decode(TokenPair.self, data))
        case 400, 401:
            forgetTokens() // used up, expired or ended: only a new login helps
            throw MobelioError.sessionExpired
        default:
            throw apiError(data, response) // e.g. 5xx: keep the tokens and try again later
        }
    }

    private func save(_ tokens: TokenPair) {
        store.save(tokens.refreshToken) // always the newest: each refresh token works once
        accessToken = tokens.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))
    }

    private func forgetTokens() {
        store.clear()
        accessToken = nil
        accessTokenExpiry = .distantPast
    }

    private func send(
        _ method: String,
        _ path: String,
        body: (any Encodable & Sendable)? = nil,
        token: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobelioError.unexpectedResponse }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
            }
            return date
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw MobelioError.unexpectedResponse
        }
    }

    private func apiError(_ data: Data, _ response: HTTPURLResponse) -> MobelioError {
        struct ErrorBody: Decodable { let error: String }
        let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "unknown"
        return .api(status: response.statusCode, code: code)
    }
}
