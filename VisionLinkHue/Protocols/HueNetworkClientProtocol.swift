import Foundation

/// Protocol abstraction for HTTP network operations against the Hue Bridge.
/// Enables mocking in integration tests and decouples HTTP transport from
/// business logic in `HueSpatialService` and other network-dependent engines.
@MainActor
protocol HueNetworkClientProtocol {
    
    /// Perform an authenticated GET request.
    func get(url: URL) async throws -> (data: Data, response: URLResponse)
    
    /// Perform an authenticated PUT request with a JSON body.
    func put<T: Codable>(url: URL, body: T) async throws -> (data: Data, response: URLResponse)
    
    /// Perform an authenticated POST request with a JSON body.
    func post<T: Codable>(url: URL, body: T) async throws -> (data: Data, response: URLResponse)
}
