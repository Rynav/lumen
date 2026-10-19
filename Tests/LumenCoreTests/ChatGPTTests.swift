import Foundation
import Testing
@testable import LumenCore

@Suite struct ChatGPTTests {
    @Test func authorizationUsesDynamicRegistrationAndPKCE() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(OpenAIIdentity.challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let redirect = "http://127.0.0.1:54321/auth/callback"
        let url = try ChatGPTAuthorization.authorizationURL(account: nil, hostID: "urn:uuid:fixture",
            redirect: redirect, state: "state", nonce: "nonce", verifier: verifier)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "auth.openai.com")
        #expect(fields["client_id"] == "dynamic_agent_client")
        #expect(fields["agent_name_hint"] == "Lumen")
        #expect(fields["redirect_uri"] == redirect)
        #expect(fields["scope"]?.contains("chatgpt.tokens.use.direct") == true)
        #expect(fields["resource"] == "https://api.openai.com/v1")
        let account = ChatGPTAccount(clientID: "oaiapp_existing", subject: "subject", email: "a+b@example.invalid", tokens: nil)
        let returning = try ChatGPTAuthorization.authorizationURL(account: account, hostID: "urn:uuid:fixture",
            redirect: redirect, state: "fresh", nonce: "nonce", verifier: verifier)
        let returningItems = try #require(URLComponents(url: returning, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(returningItems.contains(URLQueryItem(name: "client_id", value: account.clientID)))
        #expect(!returningItems.contains { $0.name == "agent_name_hint" || $0.name == "id_token_hint" })
        let retry = try ChatGPTAuthorization.authorizationURL(account: nil, hostID: "urn:uuid:fixture",
            redirect: redirect, state: "fresh", nonce: "nonce", verifier: verifier, pendingClientID: "oaiapp_pending")
        let retryItems = try #require(URLComponents(url: retry, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(retryItems.contains(URLQueryItem(name: "client_id", value: "oaiapp_pending")))
        #expect(!retryItems.contains { $0.name == "agent_name_hint" })
        #expect(String(decoding: ChatGPTAuthorization.form(["token": "a+b&c=d"]), as: UTF8.self) == "token=a%2Bb%26c%3Dd")
    }

    @Test func callbackRejectsUnverifiedOrChangedRegistrations() throws {
        func callback(_ query: String) throws -> URL {
            try #require(URL(string: "http://127.0.0.1/auth/callback?" + query))
        }
        let result = try ChatGPTAuthorization.validateCallback(callback("state=s&code=c&client_id=oaiapp_new"), state: "s", previousClientID: nil)
        #expect(result.clientID == "oaiapp_new")
        #expect(try ChatGPTAuthorization.validateCallback(callback("state=s&code=c"), state: "s", previousClientID: "oaiapp_existing").clientID == "oaiapp_existing")
        for query in ["state=bad&code=c&client_id=oaiapp_new", "state=s&code=c", "state=s&code=c&client_id=dynamic_agent_client", "state=s&state=s&code=c&client_id=oaiapp_new", "state=s&client_id=oaiapp_new"] {
            #expect(throws: ChatGPTAuthError.invalidCallback) { try ChatGPTAuthorization.validateCallback(callback(query), state: "s", previousClientID: nil) }
        }
        #expect(throws: ChatGPTAuthError.invalidCallback) {
            try ChatGPTAuthorization.validateCallback(callback("state=s&code=c&client_id=oaiapp_other"), state: "s", previousClientID: "oaiapp_existing")
        }
        #expect(throws: ChatGPTAuthError.denied) { try ChatGPTAuthorization.validateCallback(callback("state=s&error=access_denied"), state: "s", previousClientID: nil) }
    }

    @Test func signedIdentityIsVerifiedNotJustDecoded() throws {
        let jwks = JSONValue.object(["keys": .array([.object(["kid": .string("fixture"), "kty": .string("RSA"), "n": .string(modulus), "e": .string("AQAB")])])])
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let claims = try OpenAIIdentity.validate(signedToken, jwks: jwks, clientID: "oaiapp_fixture", nonce: "test-nonce", now: now)
        #expect(claims["sub"]?.string == "test-subject")
        for (client, nonce, date) in [("wrong", "test-nonce", now), ("oaiapp_fixture", "wrong", now),
                                      ("oaiapp_fixture", "test-nonce", now.addingTimeInterval(4_000)),
                                      ("oaiapp_fixture", "test-nonce", now.addingTimeInterval(-1_000))] {
            #expect(throws: ChatGPTAuthError.invalidIdentity) {
                try OpenAIIdentity.validate(signedToken, jwks: jwks, clientID: client, nonce: nonce, now: date)
            }
        }
        for token in [wrongIssuer, String(signedToken.dropLast(10)), "not.a.token", "e30.e30.e30"] {
            #expect(throws: (any Error).self) { try OpenAIIdentity.validate(token, jwks: jwks, clientID: "oaiapp_fixture", nonce: "test-nonce", now: now) }
        }
    }

    @Test func credentialsRequirePlanPermissionAndRotateTogether() throws {
        let now = Date(timeIntervalSince1970: 100)
        let response = Data(#"{"access_token":"access","refresh_token":"replacement","id_token":"identity","token_type":"Bearer","expires_in":3600,"scope":"openid offline_access chatgpt.tokens.use.direct"}"#.utf8)
        let tokens = try ChatGPTAuthorization.tokenResponse(response, now: now)
        #expect(tokens.refreshToken == "replacement")
        #expect(tokens.expiresAt == now.addingTimeInterval(3_600))
        #expect(try JSONDecoder().decode(ChatGPTAccount.Tokens.self, from: JSONEncoder().encode(tokens)) == tokens)
        let denied = String(decoding: response, as: UTF8.self).replacingOccurrences(of: "chatgpt.tokens.use.direct", with: "profile")
        #expect(throws: ChatGPTAuthError.planUnavailable) { try ChatGPTAuthorization.tokenResponse(Data(denied.utf8)) }
        let missingRefresh = String(decoding: response, as: UTF8.self).replacingOccurrences(of: "replacement", with: "")
        #expect(throws: ChatGPTAuthError.invalidIdentity) { try ChatGPTAuthorization.tokenResponse(Data(missingRefresh.utf8)) }
    }

    @Test func responsesRequestUsesPlanCompatibleHistoryAndTools() throws {
        let reasoning = JSONValue.object(["type": .string("reasoning"), "id": .string("rs_fixture"), "encrypted_content": .string("opaque")])
        let call = ToolCall(id: "call", name: "read_file", arguments: #"{"path":"README.md"}"#)
        let body = try ChatGPTProvider.requestBody(messages: [Message(role: .system, text: "Inspect safely"),
            Message(role: .user, text: "Read"), Message(role: .assistant, parts: [.providerItem(reasoning), .toolCall(call)]),
            Message(role: .tool, parts: [.toolResult(ToolResult(callID: "call", content: "contents"))])], model: "account-model", tools: ToolRegistry.definitions)
        let value = try JSONDecoder().decode(JSONValue.self, from: body)
        #expect(value["store"] == .bool(false))
        #expect(value["stream"] == .bool(true))
        #expect(value["instructions"] == .string("Inspect safely"))
        #expect(value["input"]?.array?[1] == reasoning)
        #expect(value["input"]?.array?[2]["namespace"] == .string("workspace"))
        #expect(value["input"]?.array?[3]["type"] == .string("function_call_output"))
        #expect(value["tools"]?.array?.first?["type"] == .string("namespace"))
        #expect(value["previous_response_id"] == nil && value["max_output_tokens"] == nil)
        let request = try ChatGPTProvider.request(path: "responses", token: "fixture", body: body)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    }

    @Test func responsesRequestEncodesImagesInline() throws {
        let image = ImageAttachment(mediaType: "image/png", data: Data([0xAB, 0xCD]))
        let body = try ChatGPTProvider.requestBody(messages: [
            Message(role: .user, parts: [.text("Look"), .image(image)])
        ], model: "account-model", tools: [])
        let value = try JSONDecoder().decode(JSONValue.self, from: body)
        let content = value["input"]?.array?.first?["content"]?.array
        #expect(value["input"]?.array?.first?["role"] == .string("user"))
        #expect(content?[0]["type"] == .string("input_text"))
        #expect(content?[1]["type"] == .string("input_image"))
        #expect(content?[1]["image_url"] == .string(image.dataURL))
    }

    @Test func streamRequiresCompletionAndReportsPlanLimits() throws {
        var decoder = ChatGPTProvider.StreamDecoder()
        #expect(try decoder.consume(#"{"type":"response.output_text.delta","delta":"Hello"}"#) == [.text("Hello")])
        #expect(try decoder.consume(#"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call","name":"read_file","namespace":"workspace","arguments":"{\"path\":\"a\"}"}}"#) == [.toolCall(ToolCall(id: "call", name: "read_file", arguments: #"{"path":"a"}"#))])
        #expect(throws: ProviderError.incompleteStream) { try decoder.finish() }
        #expect(try decoder.consume(#"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":12,"output_tokens":4}}}"#) == [.usage(TokenUsage(inputTokens: 12, outputTokens: 4)), .finished])
        try decoder.finish()
        var failed = ChatGPTProvider.StreamDecoder()
        #expect(throws: ProviderError.self) { try failed.consume(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"private details"}}}"#) }
        var incomplete = ChatGPTProvider.StreamDecoder()
        #expect(throws: ProviderError.incompleteStream) { try incomplete.consume(#"{"type":"response.incomplete"}"#) }
    }

    @Test func accountCatalogAndTransportStayOffline() async throws {
        let id = UUID().uuidString
        let script = ProviderFixtureProtocol.Script([
            .init(body: #"{"models":[{"slug":"second","display_name":"Second","visibility":"list"},{"slug":"hidden","visibility":"hide"},{"slug":"first","visibility":"list"}]}"#)
        ])
        ProviderFixtureProtocol.registry.set(script, for: id)
        defer { ProviderFixtureProtocol.registry.set(nil, for: id) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderFixtureProtocol.self]
        config.httpAdditionalHeaders = ["X-Fixture": id]
        let provider = ChatGPTProvider(token: { "fixture-not-a-real-token" }, transport: HTTPTransport(configuration: config))
        #expect(try await provider.listModels() == ["second", "first"])
        #expect(script.requestCount == 1)
    }

    // Recorded, test-only RSA signatures. No private key or live OpenAI credentials.
    private let modulus = "lM87pkB87hf9eRovBC_Qo7aXsctkXYKhZIQ3fcv7DQA_vjWBGCJ401h2UITJA1oR3vw0UBBsLTYMuf-D-7yP91y114iwmMXfd_m4OQA0cXWLX2AoJ3G8qvfJsqmUycTn3ND7QOWMqvKoADiuhn1GnPLY6PRmOBfTV1Ju74CIFiw_R_iqIJBJRlEY-BwekWuKY_wUBxiCOtOPtB1h-FMzmHUH9QJBqxQRzht6DEYEiMbLQhg0T1zT5PbLSFJLh9YKxW6Bq47hJj85fZzPUPHpIXMPBOyZ3XVzkTwANq7Vthx_Krk9pdAW03wzmdvXwg4vcumXzWSWTwGX7gTsKX_q4Q"
    private let signedToken = "eyJhbGciOiJSUzI1NiIsImtpZCI6ImZpeHR1cmUifQ.eyJpc3MiOiJodHRwczovL2F1dGgub3BlbmFpLmNvbSIsInN1YiI6InRlc3Qtc3ViamVjdCIsImF1ZCI6Im9haWFwcF9maXh0dXJlIiwibm9uY2UiOiJ0ZXN0LW5vbmNlIiwiZW1haWwiOiJmaXh0dXJlQGV4YW1wbGUuaW52YWxpZCIsImlhdCI6MTgwMDAwMDAwMCwiZXhwIjoxODAwMDAzNjAwfQ.UYI2Qnt1G_tkhEWJiNtKeTGkjJyKc2-hrKUp43n3VDlQYEZC-5rACcrboqRDNF8C4iplOMPQLoqIzdMiNnudAF7SrsQiJKllDSKVeYl8sIHulF99XcFlp6qrEI0YKQFUSabV_n9dtC7QPl4gUk9XWgyczJs4xn4cMJWSy035RqSrEzA-hz2doXY7aTJhVuzW-EzJ-05VkKhannWQS3g4YM33mL3tzU407x3ZZrBYLMTe1axAaKDX5xTDqQXn_xkpLUNg1IJuyqsWn5dYhEBpmrui-IFrEtDLhWZ6AoVafOn9lRZCneXAeG2l_mqKiZMkUwBHaSkfldBlNj2lEsnEPg"
    private let wrongIssuer = "eyJhbGciOiJSUzI1NiIsImtpZCI6ImZpeHR1cmUifQ.eyJpc3MiOiJodHRwczovL2F0dGFja2VyLmludmFsaWQiLCJzdWIiOiJ0ZXN0LXN1YmplY3QiLCJhdWQiOiJvYWlhcHBfZml4dHVyZSIsIm5vbmNlIjoidGVzdC1ub25jZSIsImVtYWlsIjoiZml4dHVyZUBleGFtcGxlLmludmFsaWQiLCJpYXQiOjE4MDAwMDAwMDAsImV4cCI6MTgwMDAwMzYwMH0.amBUdhJT-ypMo28ZDoIqcXW9iSRgl6zxs-VcUXisxB2ElD2G14huO3YqEskkvp4wySir1hUlwf_8E087T8mYm4g2QiPeaMcR7KocLWk7_RTSwbAvjAevsNSa5s2O9DPahLfSZ8YNZQOLQX28yGLMEmQSuCBYhc154tSacngOwFb879EY1H4sMZn23XR0FnZhozPuGgGxCAa_PcTl2s6y23VmOSs0LFWf1cj-3KeutRseyqG_nq005ySSZ8W9j4R2pDopwgSS7YVNgM5rx7zaDLq3N9awONFZk-OcI_lv_YyGy8xe7hcPbAg1K8QIlABIlObRcyVUPLErbfeHb0BQ_A"
}
