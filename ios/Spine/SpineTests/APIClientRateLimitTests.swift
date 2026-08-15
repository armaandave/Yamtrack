import Foundation
import XCTest
@testable import Spine

@MainActor
final class APIClientRateLimitTests: XCTestCase {
    override func tearDown() {
        RateLimitURLProtocol.handler = nil
        super.tearDown()
    }

    func testClientRetriesOneShortRateLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://example.com")!,
            tokenProvider: .shared,
            session: URLSession(configuration: configuration)
        )
        var requestCount = 0
        RateLimitURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 429,
                        httpVersion: nil,
                        headerFields: ["Retry-After": "0"]
                    )!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                #"{"status":"ok","version":"v1","time":"now"}"#.data(using: .utf8)!
            )
        }

        let response: HealthResponse = try await client.get("/health/")

        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(requestCount, 2)
    }
}

private final class RateLimitURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
