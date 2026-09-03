import XCTest
@testable import AR_Problem_Solver

final class ClaudeClientTests: XCTestCase {

    private func makeClient(
        key: String? = "sk-ant-test",
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> ClaudeClient {
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ClaudeClient(session: URLSession(configuration: config), apiKeyProvider: { key })
    }

    private func http(_ url: URL, _ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    // MARK: - checkConnection

    func testCheckConnectionOK() async {
        let client = makeClient { request in
            XCTAssertEqual(request.url, ClaudeAPI.modelsEndpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), ClaudeAPI.version)
            let body = #"{"data":[{"id":"claude-sonnet-5"},{"id":"claude-haiku-4-5"}]}"#
            return (self.http(request.url!, 200), Data(body.utf8))
        }
        let result = await client.checkConnection()
        XCTAssertEqual(result, .ok(models: 2))
        XCTAssertTrue(result.isOK)
    }

    func testCheckConnectionUnauthorized() async {
        let client = makeClient { request in
            (self.http(request.url!, 401), Data(#"{"error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        }
        let result = await client.checkConnection()
        XCTAssertEqual(result, .unauthorized)
    }

    func testCheckConnectionMissingKey() async {
        let client = makeClient(key: nil) { _ in
            XCTFail("should not hit the network without a key")
            return (self.http(ClaudeAPI.modelsEndpoint, 200), Data())
        }
        let result = await client.checkConnection()
        XCTAssertEqual(result, .missingKey)
    }

    func testCheckConnectionUnreachable() async {
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let result = await client.checkConnection()
        if case .unreachable = result { } else { XCTFail("expected .unreachable, got \(result)") }
    }

    // MARK: - solve

    func testSolveReturnsText() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url, ClaudeAPI.endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            let body = #"{"content":[{"type":"text","text":"PROBLEM: x\nSTEP 1: y\nDONE"}],"stop_reason":"end_turn"}"#
            return (self.http(request.url!, 200), Data(body.utf8))
        }
        let text = try await client.solve(imageJPEG: Data([0xFF, 0xD8, 0xFF]))
        XCTAssertTrue(text.contains("STEP 1: y"))
    }

    func testSolveRetriesOnceOn429ThenSucceeds() async throws {
        let calls = Counter()
        let client = makeClient { request in
            let n = calls.increment()
            if n == 1 {
                return (self.http(request.url!, 429, headers: ["retry-after": "0"]), Data("{}".utf8))
            }
            return (self.http(request.url!, 200), Data(#"{"content":[{"type":"text","text":"ok"}]}"#.utf8))
        }
        let text = try await client.solve(imageJPEG: Data([0x1]))
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(calls.value, 2)
    }

    func testSolveThrowsMissingKey() async {
        let client = makeClient(key: "") { _ in (self.http(ClaudeAPI.endpoint, 200), Data()) }
        do {
            _ = try await client.solve(imageJPEG: Data([0x1]))
            XCTFail("expected throw")
        } catch ClaudeError.missingAPIKey {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

// MARK: - Test doubles

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    @discardableResult func increment() -> Int { lock.lock(); defer { lock.unlock() }; _value += 1; return _value }
}

/// Intercepts URLSession traffic in tests.
final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
