import Foundation

public struct ChatGPTAccount: Codable, Equatable, Sendable {
    public var clientID: String
    public var subject: String
    public var email: String?
    public var tokens: Tokens?

    public struct Tokens: Codable, Equatable, Sendable {
        var accessToken: String
        var refreshToken: String
        var idToken: String
        var scopes: [String]
        var expiresAt: Date
    }
}

public enum ChatGPTAuthError: LocalizedError, Equatable {
    case invalidIdentity, invalidCallback, denied, callbackUnavailable, timeout, signedOut, planUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: "The OpenAI account identity could not be verified. Try signing in again."
        case .invalidCallback: "The sign-in callback could not be verified. Start a new sign-in."
        case .denied: "ChatGPT authorization was declined or is unavailable for this account."
        case .callbackUnavailable: "Could not start the local sign-in listener."
        case .timeout: "Sign-in timed out. Try again."
        case .signedOut: "Sign in with ChatGPT in Settings to use your plan."
        case .planUnavailable: "ChatGPT plan usage was not authorized. Enable app access in ChatGPT settings and sign in again."
        }
    }
}

public actor ChatGPTAuthorization {
    public static let shared = ChatGPTAuthorization()
    public nonisolated static var usageURL: URL { URL(string: "https://chatgpt.com/settings/usage") ?? URL(fileURLWithPath: "/") }
    private let keychain: KeychainStore
    private let transport: HTTPTransport
    private var refreshes: [UUID: Task<String, any Error>] = [:]
    private var pendingClientIDs: [UUID: String] = [:]
    static let resource = "https://api.openai.com/v1"
    static let issuer = "https://auth.openai.com"

    public init() { keychain = KeychainStore(); transport = HTTPTransport() }
    init(keychain: KeychainStore, transport: HTTPTransport) { self.keychain = keychain; self.transport = transport }

    public func signIn(profileID: UUID, openBrowser: @escaping @MainActor @Sendable (URL) -> Bool) async throws -> ChatGPTAccount {
        let previous = try keychain.loadChatGPTAccounts()[profileID]
        let issuedClientID = previous?.clientID ?? pendingClientIDs[profileID]
        let hostID = try keychain.chatGPTHostID()
        let listener = try LoopbackCallback()
        defer { listener.stop() }
        let port = try await listener.port()
        let redirect = "http://127.0.0.1:\(port)/auth/callback"
        let state = try OpenAIIdentity.random(), nonce = try OpenAIIdentity.random(), verifier = try OpenAIIdentity.random()
        let url = try Self.authorizationURL(account: previous, hostID: hostID, redirect: redirect, state: state,
                                             nonce: nonce, verifier: verifier, pendingClientID: issuedClientID)
        guard await openBrowser(url) else { throw ChatGPTAuthError.callbackUnavailable }
        let callback = try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await listener.callback() }
            group.addTask { try await Task.sleep(for: .seconds(600)); throw ChatGPTAuthError.timeout }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
        let result = try Self.validateCallback(callback, state: state, previousClientID: issuedClientID)
        pendingClientIDs[profileID] = result.clientID
        let data = try await request(path: "/api/accounts/oauth/token", fields: [
            "grant_type": "authorization_code", "client_id": result.clientID, "code": result.code,
            "code_verifier": verifier, "redirect_uri": redirect, "resource": Self.resource
        ])
        let account = try await validatedAccount(data: data, clientID: result.clientID, nonce: nonce, previous: previous)
        try Task.checkCancellation()
        try save(account, profileID: profileID, replacing: previous)
        pendingClientIDs[profileID] = nil
        return account
    }

    static func authorizationURL(account: ChatGPTAccount?, hostID: String, redirect: String, state: String, nonce: String,
                                 verifier: String, pendingClientID: String? = nil) throws -> URL {
        let issued = account?.clientID ?? pendingClientID
        var fields = ["client_id": issued ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
            "response_type": "code", "redirect_uri": redirect, "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": resource, "state": state, "nonce": nonce, "code_challenge_method": "S256", "code_challenge": OpenAIIdentity.challenge(verifier)]
        if issued == nil { fields["agent_name_hint"] = "Lumen" }
        if let hint = account?.tokens?.idToken { fields["id_token_hint"] = hint }
        if let email = account?.email { fields["login_hint"] = email }
        var components = URLComponents(string: issuer + "/api/accounts/authorize")
        components?.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw ChatGPTAuthError.invalidCallback }
        return url
    }

    static func validateCallback(_ url: URL, state: String, previousClientID: String?) throws -> (code: String, clientID: String) {
        guard url.scheme == "http", url.host == "127.0.0.1", url.path == "/auth/callback",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              Set(items.map(\.name)).count == items.count else { throw ChatGPTAuthError.invalidCallback }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["state"] == state else { throw ChatGPTAuthError.invalidCallback }
        guard values["error"] == nil else { throw ChatGPTAuthError.denied }
        guard let code = values["code"], !code.isEmpty,
              let clientID = values["client_id"] ?? previousClientID,
              clientID.hasPrefix("oaiapp_"), clientID.count > 7,
              previousClientID == nil || clientID == previousClientID else { throw ChatGPTAuthError.invalidCallback }
        return (code, clientID)
    }

    public func accessToken(profileID: UUID) async throws -> String {
        guard let account = try keychain.loadChatGPTAccounts()[profileID], let tokens = account.tokens else { throw ChatGPTAuthError.signedOut }
        guard tokens.scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTAuthError.planUnavailable }
        if tokens.expiresAt > Date().addingTimeInterval(60) { return tokens.accessToken }
        if let pending = refreshes[profileID] { return try await pending.value }
        let task = Task { try await self.refresh(profileID: profileID, account: account, tokens: tokens) }
        refreshes[profileID] = task
        defer { refreshes[profileID] = nil }
        return try await task.value
    }

    private func refresh(profileID: UUID, account: ChatGPTAccount, tokens: ChatGPTAccount.Tokens) async throws -> String {
        let data = try await request(path: "/api/accounts/oauth/token", fields: ["grant_type": "refresh_token",
            "client_id": account.clientID, "refresh_token": tokens.refreshToken, "resource": Self.resource])
        let refreshed = try await validatedAccount(data: data, clientID: account.clientID, nonce: nil, previous: account)
        try Task.checkCancellation()
        try save(refreshed, profileID: profileID, replacing: account)
        guard let token = refreshed.tokens?.accessToken else { throw ChatGPTAuthError.signedOut }
        return token
    }

    /// Retain the verified registration, but clear all tokens even if remote revocation fails.
    public func signOut(profileID: UUID, remove: Bool = false) async throws -> Bool {
        pendingClientIDs[profileID] = nil
        refreshes[profileID]?.cancel()
        refreshes[profileID] = nil
        var accounts = try keychain.loadChatGPTAccounts()
        guard var account = accounts[profileID] else { return true }
        let refreshToken = account.tokens?.refreshToken
        account.tokens = nil
        accounts[profileID] = remove ? nil : account
        try keychain.saveChatGPTAccounts(accounts)
        guard let refreshToken else { return true }
        do {
            let discovery = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/.well-known/openid-configuration"))
            guard let endpoint = discovery["revocation_endpoint"]?.string,
                  let url = URL(string: endpoint), url.scheme == "https", url.host == "auth.openai.com",
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
            _ = try await request(path: url.path, fields: ["token": refreshToken, "token_type_hint": "refresh_token", "client_id": account.clientID])
            return true
        } catch { return false }
    }

    private func save(_ account: ChatGPTAccount, profileID: UUID, replacing previous: ChatGPTAccount?) throws {
        var accounts = try keychain.loadChatGPTAccounts()
        guard accounts[profileID] == previous else { throw ChatGPTAuthError.signedOut }
        accounts[profileID] = account
        try keychain.saveChatGPTAccounts(accounts)
    }

    private func validatedAccount(data: Data, clientID: String, nonce: String?, previous: ChatGPTAccount?) async throws -> ChatGPTAccount {
        let tokens = try Self.tokenResponse(data)
        let jwks = try JSONDecoder().decode(JSONValue.self, from: await request(path: "/.well-known/jwks.json"))
        let claims = try OpenAIIdentity.validate(tokens.idToken, jwks: jwks, clientID: clientID, nonce: nonce)
        guard let subject = claims["sub"]?.string, previous == nil || previous?.subject == subject else { throw ChatGPTAuthError.invalidIdentity }
        return ChatGPTAccount(clientID: clientID, subject: subject, email: claims["email"]?.string, tokens: tokens)
    }

    static func tokenResponse(_ data: Data, now: Date = Date()) throws -> ChatGPTAccount.Tokens {
        let response = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let access = response["access_token"]?.string, !access.isEmpty,
              let refresh = response["refresh_token"]?.string, !refresh.isEmpty,
              let id = response["id_token"]?.string, response["token_type"]?.string?.lowercased() == "bearer",
              let expires = response["expires_in"]?.number, expires > 60, expires <= 86_400,
              let scope = response["scope"]?.string else { throw ChatGPTAuthError.invalidIdentity }
        let scopes = scope.split(separator: " ").map(String.init)
        guard scopes.contains("chatgpt.tokens.use.direct") else { throw ChatGPTAuthError.planUnavailable }
        try HTTPTransport.validateHeaders(["Authorization": access])
        return .init(accessToken: access, refreshToken: refresh, idToken: id, scopes: scopes, expiresAt: now.addingTimeInterval(expires))
    }

    private func request(path: String, fields: [String: String]? = nil) async throws -> Data {
        guard let url = URL(string: Self.issuer + path) else { throw ChatGPTAuthError.invalidCallback }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let fields {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(fields)
        }
        let operation = transport.begin()
        defer { transport.finish(operation) }
        // Auth exchanges are one-shot: never retry a potentially consumed code or rotating refresh token.
        let (bytes, response) = try await operation.session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw ChatGPTAuthError.invalidIdentity }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            guard data.count <= 262_144 else { throw ChatGPTAuthError.invalidIdentity }
        }
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPTransport.responseError(status: response.statusCode, body: data)
        }
        return data
    }

    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
    }
}
