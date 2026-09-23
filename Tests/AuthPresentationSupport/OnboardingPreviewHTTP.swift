import CoreModels
import CoreNetworking
import Foundation

actor OnboardingPreviewHTTP: HTTPClient {
    private var approved = false
    func approve() { approved = true }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let body: String
        switch endpoint.path {
        case "/api/v2/system/info": body = #"{"api_major":2}"#
        case "/api/v2/auth/device/capability":
            body = #"{"state":"available","protocol_versions":[2],"allowed":true}"#
        case "/api/v2/auth/device/start":
            body = """
            {"device_code":"fixture","user_code":"ABCD-EFGH","match_code":"calm river",
             "verification_uri":"https://silo.example.test/pair",
             "verification_uri_complete":"https://silo.example.test/pair?code=ABCD-EFGH",
             "expires_in":600,"interval":1}
            """
        case "/api/v2/auth/device/poll":
            body = """
            {"status":"\(approved ? "approved" : "pending")","poll_after":1,"temporary":false,
             "tokens":{"access_token":"fixture","refresh_token":"fixture","expires_in":3600,
             "user":{"id":"fixture","username":"Alex"}}}
            """
        case "/api/v2/profiles":
            body = """
            {"items":[{"id":"alex","name":"Alex","has_pin":false,"is_child":false},
            {"id":"sam","name":"Sam","has_pin":true,"is_child":false},
            {"id":"kids","name":"Kids","has_pin":true,"is_child":true}]}
            """
        default: throw AppError.notFound
        }
        return (Data(body.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
