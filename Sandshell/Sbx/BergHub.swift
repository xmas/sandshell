import Foundation

/// The berg kit's hub (`kits/berg`): the Iceberg hub this Mac's berg is
/// signed in to (`berg login`), as a sandbox reaches it, and the sbx secret
/// that signs the sandbox's berg in to it. The token itself is never read
/// here: sbx runs a command that reads it from berg's config on the Mac each
/// time it needs it, and its proxy puts it on requests to the hub — the
/// sandbox's `BERG_TOKEN` is only a placeholder.
struct BergHub: Equatable {
    /// The hub as a sandbox reaches it (the kit's `hub`).
    var url: String
    /// Its host as sbx's proxy names it (the sign-in secret's host): one on
    /// this Mac is reached at host.docker.internal, which the proxy calls localhost.
    var host: String
    /// The kit's network rule (`hubHost`): the host, with the port for one on this Mac.
    var allow: String

    /// The kit's name: its folder in `kits/`, its repository on ghcr.io.
    static let kitName = "berg"

    /// Whether `ref` is the berg kit, however it was added: by name, from the
    /// app or its published image, a clone of xmas/sandshell-kits, or that
    /// repository's git reference. Anything else takes no hub or sign-in.
    static func isKit(_ ref: String) -> Bool {
        if KitStore.bundledKitName(ref) == kitName { return true }
        let t = ref.hasSuffix("/") ? String(ref.dropLast()) : ref
        if t.hasSuffix("/sandshell-kits/\(kitName)") { return true }
        guard t.hasPrefix("git+"), t.contains("/sandshell-kits"), let fragment = t.split(separator: "#").last else { return false }
        return fragment.split(separator: "&").map(String.init).contains("dir=\(kitName)")
    }

    /// berg's config (`internal/cliconfig`: Go's user config dir), unless
    /// `BERG_CONFIG` says otherwise.
    static var configURL: URL {
        if let path = ProcessInfo.processInfo.environment["BERG_CONFIG"], !path.isEmpty { return URL(filePath: path) }
        return URL.applicationSupportDirectory.appending(path: "berg/config.json")
    }

    /// The hub berg on this Mac is signed in to, or nil when it isn't.
    static func current(config: URL = configURL) -> BergHub? {
        // Only the hub's address is decoded: the token stays in the file.
        struct Config: Decodable { var hubURL: String? }
        guard let data = try? Data(contentsOf: config),
              let hub = (try? JSONDecoder().decode(Config.self, from: data))?.hubURL else { return nil }
        return BergHub(hubURL: hub)
    }

    /// A hub address as a sandbox reaches it: one on this Mac (localhost)
    /// is the Mac's host.docker.internal there.
    init?(hubURL: String) {
        guard var parts = URLComponents(string: hubURL.trimmingCharacters(in: .whitespaces)),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        let onThisMac = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        parts.host = onThisMac ? "host.docker.internal" : host
        parts.scheme = scheme
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.string else { return nil }
        self.url = url
        if onThisMac {
            self.host = "localhost"
            self.allow = "localhost:\(parts.port ?? (scheme == "https" ? 443 : 80))"
        } else {
            self.host = host
            self.allow = host
        }
    }

    /// `--kit-arg`s for `sbx create` / `sbx kit add` with the berg kit.
    var kitArguments: [String] {
        ["--kit-arg", "\(Self.kitName).hub=\(url)", "--kit-arg", "\(Self.kitName).hubHost=\(allow)"]
    }

    /// `sbx secret set-custom …`: the sandbox's BERG_TOKEN is a placeholder
    /// that sbx's proxy swaps for the token berg keeps on this Mac, on
    /// requests to the hub. sbx re-reads it when it's needed, so a new
    /// `berg login` carries over.
    func secretArguments(config: URL = BergHub.configURL) -> [String] {
        let path = config.path(percentEncoded: false).replacing("'", with: #"'\''"#)
        // (Local custom secrets go by host and env var: `--name` is cloud-only.)
        return ["secret", "set-custom", "--host", host, "--env", "BERG_TOKEN",
                "--command", "/usr/bin/plutil -extract token raw -o - '\(path)'"]
    }
}
