import Foundation

/// The sandbox itself, as it reports from inside: a Linux virtual machine
/// with its own kernel and distribution, sharing Mac folders over virtiofs.
struct SandboxSystem: Equatable, Sendable {
    var kernel: String          // "7.0.14"
    var arch: String            // "aarch64"
    var distribution: String?   // "Ubuntu 26.04.1 LTS"
    var cpus: Int?
    var memory: String?         // "8.9 GiB"
    /// Mount point → filesystem type (e.g. "virtiofs"), for the shared folders.
    var mountTypes: [String: String]

    /// "Ubuntu 26.04" from "Ubuntu 26.04.1 LTS".
    var shortDistribution: String? {
        guard let d = distribution else { return nil }
        let words = d.split(separator: " ")
        guard words.count >= 2 else { return d }
        let version = words[1].split(separator: ".").prefix(2).joined(separator: ".")
        return "\(words[0]) \(version)"
    }

    /// "Linux 7.0.14 (aarch64), Ubuntu 26.04.1 LTS, 8 CPUs, 8.9 GiB memory".
    var details: String {
        ["Linux \(kernel) (\(arch))", distribution, cpus.map { $0 == 1 ? "1 CPU" : "\($0) CPUs" },
         memory.map { "\($0) memory" }]
            .compactMap { $0 }
            .formatted(.list(type: .and, width: .narrow))
    }

    /// The probe run inside the sandbox; prints key=value lines.
    static let probe = #"echo "kernel=$(uname -r)"; echo "arch=$(uname -m)"; . /etc/os-release 2>/dev/null && echo "distro=$PRETTY_NAME"; echo "cpus=$(nproc 2>/dev/null)"; awk '/MemTotal/{print "memkb="$2}' /proc/meminfo; awk '$1=="host"{print "mount="$2" "$3}' /proc/mounts"#

    init?(probeOutput: String) {
        var values: [String: String] = [:]
        var mounts: [String: String] = [:]
        for line in probeOutput.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...])
            if key == "mount" {
                let parts = value.split(separator: " ")
                if parts.count == 2 { mounts[String(parts[0])] = String(parts[1]) }
            } else {
                values[key] = value
            }
        }
        guard let kernel = values["kernel"], !kernel.isEmpty else { return nil }
        self.kernel = kernel.split(separator: "-").first.map(String.init) ?? kernel
        arch = values["arch"] ?? ""
        distribution = values["distro"].flatMap { $0.isEmpty ? nil : $0 }
        cpus = values["cpus"].flatMap(Int.init)
        memory = values["memkb"].flatMap(Double.init).map {
            "\(($0 / 1_048_576).formatted(.number.precision(.fractionLength(1)))) GiB"
        }
        mountTypes = mounts
    }
}
