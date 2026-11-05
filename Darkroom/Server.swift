import Foundation
import Security

/// The app's key for darkroom-api.php, kept in the Keychain (this device only).
enum Keychain {
    private static let service = "ca.knotwork.darkroom.key"

    static func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ key: String) {
        delete()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecValueData as String: Data(key.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

struct ServerError: LocalizedError {
    let message: String, status: Int
    /// The key no longer works (signed out elsewhere, or the password changed).
    var signedOut: Bool { status == 401 }
    /// Worth sending again later: no connection, or the server is struggling.
    var retry: Bool { status == 0 || status >= 500 || status == 429 }
    var errorDescription: String? { message }
}

/// Talks to knotwork.ca. Every call sends the app key as a Bearer token.
struct Server {
    var base: URL
    var key: String?

    static var defaultBase: URL {
        let s = Bundle.main.object(forInfoDictionaryKey: "DarkroomServer") as? String
        return URL(string: s ?? "") ?? URL(string: "https://knotwork.ca")!
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func request(_ path: String, method: String = "GET", body: JSON? = nil) async throws -> JSON {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.httpMethod = method
        if let key { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONEncoder().encode(body)
        }
        return try await send(r)
    }

    /// A file (the process PDF), not the API's JSON.
    func data(_ path: String) async throws -> Data {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.timeoutInterval = 60
        if let key { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await Self.session.data(for: r) }
        catch { throw ServerError(message: "No connection to knotwork.ca", status: 0) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, data.starts(with: Data("%PDF".utf8)) else {
            let j = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
            throw ServerError(message: j["error"].string ?? "Server error (\(status))", status: status == 200 ? 400 : status)
        }
        return data
    }

    /// The API's photo upload (multipart, field "image").
    func upload(jpeg: Data, photoId: Int) async throws -> JSON {
        let boundary = "kw-\(UUID().uuidString)"
        var r = URLRequest(url: URL(string: "darkroom-api.php?res=photo_image&id=\(photoId)", relativeTo: base)!)
        r.httpMethod = "POST"
        r.timeoutInterval = 120
        if let key { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var b = Data()
        b.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"print.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        b.append(jpeg)
        b.append(Data("\r\n--\(boundary)--\r\n".utf8))
        r.httpBody = b
        return try await send(r)
    }

    private func send(_ r: URLRequest) async throws -> JSON {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await Self.session.data(for: r) }
        catch { throw ServerError(message: "No connection to knotwork.ca", status: 0) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        guard (200..<300).contains(status), j["ok"].flag else {
            let msg = j["error"].string ?? (status == 401 ? "Signed out" : "Server error (\(status))")
            throw ServerError(message: msg, status: status == 200 ? 400 : status)
        }
        return j["data"]
    }

    // MARK: Calls

    func signIn(password: String, deviceName: String) async throws -> String {
        let d = try await request("darkroom-app-auth.php", method: "POST",
                                  body: .object(["password": .string(password), "device_name": .string(deviceName)]))
        guard let k = d["key"].string else { throw ServerError(message: "Server error", status: 500) }
        return k
    }
    func signOut() async { _ = try? await request("darkroom-app-auth.php", method: "DELETE") }
    func sync() async throws -> JSON { try await request("darkroom-api.php?res=sync") }
}
