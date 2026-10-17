import AppKit
import Foundation

/// Kit startup tracking: after a workspace container comes up, read the
/// sandbox's dispatcher log (`/var/log/sbx-kit-startup.log`) and publish a
/// per-kit outcome so the UI can show failures/warnings/"still installing"
/// instead of leaving them buried inside the container.
extension WorkspaceController {
    /// How long to keep following an in-progress dispatcher before giving up
    /// (a kit can legitimately wait a minute on a host service).
    private static let kitStartupFollowLimit: TimeInterval = 5 * 60
    private static let kitStartupPollInterval: UInt64 = 3_000_000_000   // 3 s

    /// Kit entries for the container an agent's sessions run in, or nil when
    /// nothing has been read yet.
    func kitStartupStatus(for agent: AgentKind) -> KitStartupStatus? { kitStartup[agent] }

    /// The workspace's kit refs as `sbx` names them in the startup log.
    var kitNames: [String] { resolvedKits().map(KitStartupParser.kitName(forRef:)) }

    /// Start (or restart) following the startup log for an agent's container.
    /// Polls every few seconds until the dispatcher logs completion or aborts.
    func refreshKitStartup(for agent: AgentKind) {
        kitStartupTasks[agent]?.cancel()
        let name = containerName(for: agent)
        let kitRefs = kits(for: agent, from: resolvedKits())
        kitStartupTasks[agent] = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(Self.kitStartupFollowLimit)
            var lastSignature: String?
            while !Task.isCancelled {
                guard let self else { return }
                let status = await Self.readKitStartup(container: name, kitRefs: kitRefs)
                if Task.isCancelled { return }
                self.kitStartup[agent] = status
                if status.signature != lastSignature {
                    lastSignature = status.signature
                    Self.logKitStartup(status)
                }
                // Done: dispatcher finished or aborted, or the log isn't readable
                // (stopped container, no dispatcher) — nothing more will arrive.
                if status.fetchError != nil || !status.isInProgress { break }
                if Date() > deadline {
                    Log.error(.workspace, "kit startup in “\(name)” still in progress after \(Int(Self.kitStartupFollowLimit))s; stopped following")
                    break
                }
                try? await Task.sleep(nanoseconds: Self.kitStartupPollInterval)
            }
            // Cancelled: a newer follower (or none) holds the slot now.
            if Task.isCancelled { return }
            self?.kitStartupTasks[agent] = nil
        }
    }

    /// Follow the log only if we have no reading yet and aren't already following.
    func refreshKitStartupIfNeeded(for agent: AgentKind) {
        guard kitStartup[agent] == nil, kitStartupTasks[agent] == nil else { return }
        refreshKitStartup(for: agent)
    }

    /// Forget the reading (container is being rebuilt or is gone).
    func resetKitStartup(for agent: AgentKind) {
        kitStartupTasks[agent]?.cancel()
        kitStartupTasks[agent] = nil
        kitStartup[agent] = nil
    }

    /// Open the full dispatcher log for an agent's container in a terminal
    /// window (one per container; re-opening focuses it).
    func openKitLog(for agent: AgentKind) {
        if let existing = kitLogWindows[agent] {
            existing.focus()
            return
        }
        let name = containerName(for: agent)
        let sbx = SbxCommand.shellQuote(PathFixer.sbxPath())
        // The dispatcher appends one block per container boot (a stop/start or
        // `sbx kit add` recreate re-runs it), so the file accumulates history.
        // The banner only ever reflects the most recent run; show the same here
        // and say how many earlier runs were left out (with the flag to see them).
        let log = KitStartupParser.logPath
        let inner = """
        runs=$(grep -c '^=== dispatcher run' \(log) 2>/dev/null || echo 0)
        if [ "$runs" -gt 1 ]; then
          awk '/^=== dispatcher run/{buf=""} {buf=buf $0 "\\n"} END{printf "%s", buf}' \(log)
          printf '\\n[Sandshell] Most recent run shown; %s earlier run(s) omitted. Full log: sbx exec %s cat %s\\n' "$((runs-1))" \(SbxCommand.shellQuote(name)) \(log)
        else
          cat \(log) 2>&1
        fi
        printf '\\n[Sandshell] end of kit startup log — press Return to close. '; read _
        """
        let body = """
        #!/bin/bash
        echo "# Kit startup log for sandbox '\(name)' (\(log)) — most recent run"
        echo
        exec \(sbx) exec -it \(SbxCommand.shellQuote(name)) sh -c \(SbxCommand.shellQuote(inner))
        """
        let wc = HostTerminalWindowController(
            title: "Kit Startup Log — \(name)", scriptBody: body,
            workingDirectory: workspace.rootURL.path, theme: theme)
        wc.onClose = { [weak self] in self?.kitLogWindows[agent] = nil }
        kitLogWindows[agent] = wc
        wc.focus()
    }

    // MARK: - Internals

    private static func readKitStartup(container: String, kitRefs: [String]) async -> KitStartupStatus {
        do {
            let text = try await SbxClient.shared.readFile(inSandbox: container, path: KitStartupParser.logPath)
            let report = KitStartupParser.parse(text)
            return KitStartupStatus.make(containerName: container, kitRefs: kitRefs, report: report,
                                         fetchError: report == nil ? "startup log has no dispatcher run" : nil)
        } catch {
            return KitStartupStatus.make(containerName: container, kitRefs: kitRefs, report: nil,
                                         fetchError: error.localizedDescription)
        }
    }

    private static func logKitStartup(_ status: KitStartupStatus) {
        if let err = status.fetchError {
            Log.info(.workspace, "kit startup in “\(status.containerName)”: log unavailable (\(err))")
            return
        }
        let summary = status.entries.map { "\($0.name)=\($0.outcome.label)" }.joined(separator: ", ")
        let phase = status.isComplete ? "complete" : (status.report?.isAborted == true ? "ABORTED" : "in progress")
        if status.hasProblems {
            Log.error(.workspace, "kit startup in “\(status.containerName)” \(phase): \(summary)")
            for p in status.problems where !p.detail.isEmpty {
                Log.error(.workspace, "  \(p.name): \(p.detail.joined(separator: " | "))")
            }
        } else {
            Log.info(.workspace, "kit startup in “\(status.containerName)” \(phase): \(summary.isEmpty ? "no kits" : summary)")
        }
    }
}
