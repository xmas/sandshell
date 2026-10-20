import Foundation

/// What was installed in a sandbox since it was made — apt packages (and the
/// apt sources and keys added for them), pip packages, npm globals, uv and
/// pipx tools — read from inside it (`probeScript`), and the kit that installs
/// it all again on a rebuilt sandbox (`kitSpec`).
///
/// "Since it was made" is after the sandbox's first startup (the first
/// `=== dispatcher run` in sbx's kit startup log, else the birth of `/`):
/// everything the image and the kits put there is older.
struct SandboxChanges: Equatable, Sendable {
    /// When the sandbox was made (seconds since 1970), if known.
    var baseline: Double?
    /// apt packages asked for since (and still installed), sorted.
    var aptPackages: [String] = []
    /// apt sources and keyrings added or changed since.
    var aptFiles: [AptFile] = []
    /// Hosts the apt sources fetch from (the kit's network allowances).
    var aptHosts: [String] = []
    var python: [PythonPackage] = []
    var npm: [NpmPackage] = []
    var uvTools: [String] = []
    var pipxTools: [String] = []
    /// What changed that the kit can't reinstall (a local .deb, a binary in
    /// /usr/local/bin, …): said, not captured.
    var notes: [String] = []

    struct AptFile: Equatable, Sendable, Codable {
        var path: String
        /// The file's contents, base64.
        var data: String
    }
    struct PythonPackage: Equatable, Sendable, Codable {
        var name: String
        var version: String
        /// Installed for the agent user (`--user`) rather than system-wide.
        var user: Bool
    }
    struct NpmPackage: Equatable, Sendable, Codable {
        var name: String
        var version: String
        /// The global prefix belongs to root (install as root), else the agent.
        var root: Bool
    }

    var isEmpty: Bool {
        aptPackages.isEmpty && aptFiles.isEmpty && python.isEmpty && npm.isEmpty && uvTools.isEmpty && pipxTools.isEmpty
    }

    /// "3 apt packages, 1 npm package" (empty when nothing).
    var summary: String {
        func count(_ n: Int, _ what: String) -> String? {
            n == 0 ? nil : "\(n) \(what)\(n == 1 ? "" : "s")"
        }
        return [count(aptPackages.count, "apt package"), count(aptFiles.count, "apt source"),
                count(python.count, "Python package"), count(npm.count, "npm package"),
                count(uvTools.count + pipxTools.count, "Python tool")]
            .compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Reading the sandbox

    /// Runs inside the sandbox (as its agent user; `sudo -n` for root-only
    /// reads isn't needed: the logs and package dirs are world-readable) and
    /// prints one JSON object (`Probe`).
    static let probeScript = #"""
    command -v python3 >/dev/null 2>&1 || { echo '{"error":"python3 is not installed in the sandbox"}'; exit 0; }
    exec python3 - <<'PY'
    import base64, datetime, glob, gzip, json, os, re, subprocess
    def mtime(p):
        try: return os.lstat(p).st_mtime
        except OSError: return 0
    baseline = None
    try:
        for line in open('/var/log/sbx-kit-startup.log', errors='replace'):
            m = re.match(r'=== dispatcher run (\S+) ===', line)
            if m:
                baseline = datetime.datetime.strptime(m.group(1), '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
                break
    except (OSError, ValueError): pass
    if baseline is None:
        try: baseline = float(subprocess.run(['stat', '-c', '%W', '/'], capture_output=True, text=True).stdout.strip()) or None
        except ValueError: pass
    out = {'baseline': baseline, 'aptHistory': '', 'installed': [], 'aptFiles': [], 'aptHosts': [],
           'python': [], 'npm': [], 'uvTools': [], 'pipxTools': [], 'notes': []}
    newer = lambda p: baseline is not None and mtime(p) > baseline + 1
    history = []
    for f in sorted(glob.glob('/var/log/apt/history.log*')):
        try:
            history.append((gzip.open if f.endswith('.gz') else open)(f, 'rt', errors='replace').read())
        except OSError: pass
    out['aptHistory'] = '\n\n'.join(history)
    try:
        q = subprocess.run(['dpkg-query', '-W', '-f', '${Package}\t${db:Status-Abbrev}\n'], capture_output=True, text=True).stdout
        out['installed'] = [l.split('\t')[0] for l in q.splitlines() if l.split('\t')[-1].startswith('ii')]
    except OSError: pass
    srcs = ['/etc/apt/sources.list'] + glob.glob('/etc/apt/sources.list.d/*')
    for p in srcs + glob.glob('/etc/apt/keyrings/*') + glob.glob('/usr/share/keyrings/*') + glob.glob('/etc/apt/trusted.gpg.d/*'):
        if os.path.isfile(p) and newer(p) and os.path.getsize(p) < 512 * 1024:
            try: out['aptFiles'].append({'path': p, 'data': base64.b64encode(open(p, 'rb').read()).decode()})
            except OSError: pass
    hosts = set()
    for p in srcs:
        try:
            text = '\n'.join(l for l in open(p, errors='replace').read().splitlines() if not l.lstrip().startswith('#'))
            hosts.update(re.findall(r'https?://([^/\s:]+)', text))
        except OSError: pass
    out['aptHosts'] = sorted(hosts)
    home = os.path.expanduser('~')
    sites = [(d, False) for d in glob.glob('/usr/local/lib/python3*/dist-packages') + glob.glob('/usr/local/lib/python3*/site-packages')]
    sites += [(d, True) for d in glob.glob(home + '/.local/lib/python3*/site-packages')]
    for d, user in sites:
        for info in glob.glob(d + '/*.dist-info'):
            if not newer(info): continue
            try:
                installer = open(info + '/INSTALLER').read().strip() if os.path.exists(info + '/INSTALLER') else ''
                if installer == 'debian': continue
                meta = open(info + '/METADATA', errors='replace').read()
                name = re.search(r'^Name: (.+)$', meta, re.M).group(1).strip()
                version = re.search(r'^Version: (.+)$', meta, re.M).group(1).strip()
                out['python'].append({'name': name, 'version': version, 'user': user})
            except (OSError, AttributeError): pass
    try:
        root = subprocess.run(['npm', 'root', '-g'], capture_output=True, text=True, timeout=20).stdout.strip()
    except (OSError, subprocess.SubprocessError): root = ''
    if root and os.path.isdir(root):
        owned_by_root = os.stat(root).st_uid == 0
        dirs = []
        for e in os.listdir(root):
            p = os.path.join(root, e)
            dirs += [os.path.join(p, s) for s in os.listdir(p)] if e.startswith('@') and os.path.isdir(p) else [p]
        for p in dirs:
            if not newer(p): continue
            try:
                pkg = json.load(open(p + '/package.json'))
                out['npm'].append({'name': pkg['name'], 'version': pkg.get('version', ''), 'root': owned_by_root})
            except (OSError, ValueError, KeyError): pass
    for d, key in [(home + '/.local/share/uv/tools', 'uvTools'), (home + '/.local/share/pipx/venvs', 'pipxTools')]:
        for p in glob.glob(d + '/*'):
            if newer(p): out[key].append(os.path.basename(p))
    for d in ['/usr/local/bin', home + '/.local/bin', home + '/go/bin', home + '/.cargo/bin']:
        for p in glob.glob(d + '/*'):
            if not (newer(p) and os.path.isfile(p)) or os.path.islink(p): continue
            try: first = open(p, 'rb').readline(200)
            except OSError: first = b''
            # A pip / uv / pipx entry point comes back with its package.
            if first.startswith(b'#!') and b'python' in first: continue
            out['notes'].append(p)
    print(json.dumps(out))
    PY
    """#

    /// What `probeScript` prints.
    struct Probe: Decodable {
        var error: String?
        var baseline: Double?
        var aptHistory: String?
        var installed: [String]?
        var aptFiles: [AptFile]?
        var aptHosts: [String]?
        var python: [PythonPackage]?
        var npm: [NpmPackage]?
        var uvTools: [String]?
        var pipxTools: [String]?
        var notes: [String]?
    }

    /// The changes in a probe's output; throws when the sandbox couldn't be read.
    static func parse(_ json: String) throws -> SandboxChanges {
        guard let line = json.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("{") }),
              let probe = try? JSONDecoder().decode(Probe.self, from: Data(line.utf8)) else {
            throw SbxError.command("Couldn’t read what changed in the sandbox.")
        }
        if let error = probe.error { throw SbxError.command(error) }
        var changes = SandboxChanges(baseline: probe.baseline)
        let apt = aptRequests(history: probe.aptHistory ?? "", after: probe.baseline)
        let installed = Set(probe.installed ?? [])
        changes.aptPackages = apt.packages.filter { installed.contains($0) }.sorted()
        changes.aptFiles = probe.aptFiles ?? []
        changes.aptHosts = probe.aptHosts ?? []
        // Debian's own python3-* live in /usr/lib/python3 and aren't read; pip's
        // own upgrade of itself isn't a change worth replaying.
        changes.python = (probe.python ?? []).filter { $0.name.lowercased() != "pip" }
            .sorted { ($0.user ? 1 : 0, $0.name.lowercased()) < ($1.user ? 1 : 0, $1.name.lowercased()) }
        changes.npm = (probe.npm ?? []).sorted { $0.name < $1.name }
        changes.uvTools = (probe.uvTools ?? []).sorted()
        changes.pipxTools = (probe.pipxTools ?? []).sorted()
        changes.notes = apt.notes + (probe.notes ?? []).sorted().map { "\($0) (added by hand: not captured)" }
        return changes
    }

    /// The packages apt was asked to install after `baseline` and not removed
    /// again since, from apt's history log (blocks in any order). Local .deb
    /// files can't be fetched again: they're notes.
    static func aptRequests(history: String, after baseline: Double?) -> (packages: [String], notes: [String]) {
        struct Entry { var date: Date; var verb: String; var packages: [String] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var entries: [Entry] = []
        var notes: [String] = []
        for block in history.components(separatedBy: "\n\n") {
            var date: Date?
            var command: String?
            for line in block.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("Start-Date:") {
                    let text = line.dropFirst("Start-Date:".count).split(separator: " ", omittingEmptySubsequences: true)
                        .joined(separator: " ")
                    date = formatter.date(from: text)
                } else if line.hasPrefix("Commandline:") {
                    command = String(line.dropFirst("Commandline:".count)).trimmingCharacters(in: .whitespaces)
                }
            }
            guard let date, let command else { continue }
            if let baseline, date.timeIntervalSince1970 <= baseline { continue }
            let words = command.split(separator: " ").map(String.init)
            guard let verbIndex = words.firstIndex(where: { ["install", "remove", "purge", "reinstall"].contains($0) })
            else { continue }
            var packages: [String] = []
            for word in words[(verbIndex + 1)...] where !word.hasPrefix("-") {
                if word.contains("/") || word.hasSuffix(".deb") {
                    notes.append("\(word) (a local package file: not captured)")
                    continue
                }
                // pkg=1.2, pkg:arm64, pkg/noble → pkg
                let name = word.split(whereSeparator: { "=:".contains($0) }).first.map(String.init) ?? word
                if !name.isEmpty { packages.append(name) }
            }
            entries.append(Entry(date: date, verb: words[verbIndex], packages: packages))
        }
        var wanted: [String] = []
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            if entry.verb == "install" || entry.verb == "reinstall" {
                for p in entry.packages where !wanted.contains(p) { wanted.append(p) }
            } else {
                wanted.removeAll { entry.packages.contains($0) }
            }
        }
        return (wanted, notes)
    }

    // MARK: The kit

    /// A kit name for `sandbox`'s changes: `<sandbox>-env`, in kit-name characters.
    static func kitName(for sandbox: String) -> String {
        let cleaned = sandbox.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(cleaned).split(separator: "-").joined(separator: "-") + "-env"
    }

    /// `spec.yaml` for a mixin kit that installs these changes again, for
    /// `agent`'s sandboxes (`requires.agent`).
    func kitSpec(name: String, sandbox: String, agent: String, capturedAt: Date = .now) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var hosts = Set<String>()
        var steps: [(command: String, user: String, description: String)] = []
        if !aptFiles.isEmpty {
            let writes = aptFiles.map { f in
                "mkdir -p \(shellQuote((f.path as NSString).deletingLastPathComponent)) && "
                    + "printf %s \(shellQuote(f.data)) | base64 -d > \(shellQuote(f.path))"
            }
            steps.append((writes.joined(separator: " && "), "0", "Restore the apt sources and keys added in \(sandbox)"))
        }
        if !aptPackages.isEmpty {
            hosts.formUnion(aptHosts)
            steps.append(("apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "
                            + aptPackages.map(shellQuote).joined(separator: " "),
                          "0", "Install the apt packages added in \(sandbox)"))
        }
        let systemPython = python.filter { !$0.user }, userPython = python.filter(\.user)
        if !python.isEmpty { hosts.formUnion(["pypi.org", "files.pythonhosted.org"]) }
        if !systemPython.isEmpty {
            steps.append(("python3 -m pip install --break-system-packages "
                            + systemPython.map { shellQuote("\($0.name)==\($0.version)") }.joined(separator: " "),
                          "0", "Install the Python packages added in \(sandbox)"))
        }
        if !userPython.isEmpty {
            steps.append(("python3 -m pip install --user --break-system-packages "
                            + userPython.map { shellQuote("\($0.name)==\($0.version)") }.joined(separator: " "),
                          "1000", "Install the agent's Python packages added in \(sandbox)"))
        }
        if !npm.isEmpty { hosts.insert("registry.npmjs.org") }
        for (root, packages) in [(true, npm.filter(\.root)), (false, npm.filter { !$0.root })] where !packages.isEmpty {
            steps.append(("npm install -g --no-audit --no-fund "
                            + packages.map { shellQuote($0.version.isEmpty ? $0.name : "\($0.name)@\($0.version)") }
                                .joined(separator: " "),
                          root ? "0" : "1000", "Install the npm packages added in \(sandbox)"))
        }
        if !uvTools.isEmpty || !pipxTools.isEmpty { hosts.formUnion(["pypi.org", "files.pythonhosted.org"]) }
        if !uvTools.isEmpty {
            steps.append((uvTools.map { "uv tool install \(shellQuote($0))" }.joined(separator: " && "),
                          "1000", "Install the uv tools added in \(sandbox)"))
        }
        if !pipxTools.isEmpty {
            steps.append((pipxTools.map { "pipx install \(shellQuote($0))" }.joined(separator: " && "),
                          "1000", "Install the pipx tools added in \(sandbox)"))
        }

        var yaml = """
        schemaVersion: "2"
        kind: mixin
        name: \(name)
        displayName: \(q("What was added in \(sandbox)"))
        description: >-
          Captured by Sandshell from the sandbox \(sandbox) on \(ISO8601DateFormatter().string(from: capturedAt)):
          installs again what was added there since it was made\(summary.isEmpty ? "" : " (\(summary))").
        requires:
          agent: \(agent)

        """
        if !hosts.isEmpty {
            yaml += "permissions:\n  network:\n    allow:\n"
            yaml += hosts.sorted().map { "      - \(q($0))\n" }.joined()
        }
        yaml += "setup:\n  install:\n"
        if steps.isEmpty {
            yaml += "    - command: 'true'\n      user: \"1000\"\n      description: Nothing was added\n"
        }
        for step in steps {
            yaml += "    - command: \(q(step.command))\n      user: \"\(step.user)\"\n      description: \(q(step.description))\n"
        }
        if !notes.isEmpty {
            yaml += "# Not captured (reinstall these by hand):\n" + notes.map { "#   \($0)\n" }.joined()
        }
        return yaml
    }
}
