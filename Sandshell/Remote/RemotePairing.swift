import CryptoKit
import Foundation
import Security

/// A device paired with this Mac for Remote Control: its browser holds a
/// token (an HttpOnly cookie); this Mac keeps only the token's hash.
struct RemoteDevice: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// SHA-256 of its token, hex.
    let tokenHash: String
    let pairedAt: Date
    var lastSeen: Date?
    /// Where it last connected from.
    var lastAddress: String?
}

/// The devices paired with this Mac (in the app's defaults: only token hashes).
@MainActor
final class RemoteDevices: ObservableObject {
    static let shared = RemoteDevices()

    @Published private(set) var devices: [RemoteDevice] = []
    private let defaults: UserDefaults
    private static let key = "remoteDevices"
    /// When `lastSeen` was last written (it changes on every request).
    private var lastSaved: Date = .distantPast

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([RemoteDevice].self, from: data) {
            devices = saved
        }
    }

    /// Pair a new device: its record, and the token to hand it (once).
    func add(name: String) -> (device: RemoteDevice, token: String) {
        let token = Self.newSecret()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = RemoteDevice(id: UUID(), name: trimmed.isEmpty ? "Device" : String(trimmed.prefix(60)),
                                  tokenHash: Self.hash(token), pairedAt: .now)
        devices.append(device)
        save()
        return (device, token)
    }

    func device(forToken token: String) -> RemoteDevice? {
        let hash = Self.hash(token)
        return devices.first { $0.tokenHash == hash }
    }

    func revoke(_ id: UUID) {
        devices.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        devices[i].name = String(trimmed.prefix(60))
        save()
    }

    /// A device made a request (saved at most once a minute).
    func touch(_ id: UUID, from address: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].lastSeen = .now
        devices[i].lastAddress = address
        if Date.now.timeIntervalSince(lastSaved) > 60 { save() }
    }

    private func save() {
        lastSaved = .now
        if let data = try? JSONEncoder().encode(devices) { defaults.set(data, forKey: Self.key) }
    }

    nonisolated static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 32 random bytes, base64url.
    nonisolated static func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
}

/// Pairing a new device: a short-lived offer this Mac shows — a 6-digit code
/// to type, and a one-time link (its secret in the fragment) for a QR code or
/// AirDrop. One device per offer; five wrong codes end it.
@MainActor
final class RemotePairing: ObservableObject {
    static let shared = RemotePairing()

    struct Offer: Equatable {
        let code: String
        let secret: String
        let expires: Date
        var wrongTries = 0
    }

    enum Outcome: Equatable {
        case paired(RemoteDevice, token: String)
        /// No offer up, or it ran out.
        case noOffer
        case wrongCode
        /// Too many wrong codes: the offer is gone.
        case locked
    }

    static let lifetime: TimeInterval = 5 * 60
    static let maxWrongTries = 5

    @Published private(set) var offer: Offer?
    /// The last device paired (the pairing window says so).
    @Published private(set) var lastPaired: RemoteDevice?
    private let devices: RemoteDevices
    private let now: () -> Date

    init(devices: RemoteDevices = .shared, now: @escaping () -> Date = { .now }) {
        self.devices = devices
        self.now = now
    }

    /// A fresh offer (replacing any other).
    @discardableResult
    func start() -> Offer {
        let offer = Offer(code: Self.newCode(), secret: RemoteDevices.newSecret(), expires: now() + Self.lifetime)
        self.offer = offer
        lastPaired = nil
        return offer
    }

    func cancel() { offer = nil }

    /// The offer, if it hasn't run out.
    var current: Offer? {
        guard let offer, offer.expires > now() else { return nil }
        return offer
    }

    /// A device answered with the code (typed) or the link's secret.
    func redeem(code: String?, secret: String?, name: String) -> Outcome {
        guard let current else { offer = nil; return .noOffer }
        let digits = code?.filter(\.isNumber)
        let matches = (digits.map { !$0.isEmpty && $0 == current.code } ?? false)
            || (secret.map { !$0.isEmpty && $0 == current.secret } ?? false)
        guard matches else {
            var updated = current
            updated.wrongTries += 1
            if updated.wrongTries >= Self.maxWrongTries {
                offer = nil
                Log.info(.app, "remote: pairing ended after \(Self.maxWrongTries) wrong codes")
                return .locked
            }
            offer = updated
            return .wrongCode
        }
        offer = nil
        let (device, token) = devices.add(name: name)
        lastPaired = device
        Log.info(.app, "remote: paired “\(device.name)”")
        return .paired(device, token: token)
    }

    /// 6 random digits.
    nonisolated static func newCode() -> String {
        var n: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &n) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        return String(format: "%06u", n % 1_000_000)
    }
}
