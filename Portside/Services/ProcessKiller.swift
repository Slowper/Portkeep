import Darwin
import Foundation

/// Signals a process tree without crossing host boundaries (shell, editor, agent).
enum ProcessKiller {
    struct Outcome: Sendable {
        var signalled: [Int32]
        var failed: [Int32]

        var succeeded: Bool { !signalled.isEmpty || failed.isEmpty }
    }

    /// `lineage.treePIDs` when we have them, otherwise just `fallback`.
    static func pids(lineage: ProcessLineage?, fallback: Int32) -> [Int32] {
        var list = lineage?.treePIDs ?? []
        if fallback > 0, !list.contains(fallback) { list.append(fallback) }
        return list.filter { $0 > 1 }
    }

    static func stop(pids: [Int32], force: Bool = false) -> Outcome {
        LaunchdControl.bootoutUserJobs(covering: pids)
        var outcome = Outcome(signalled: [], failed: [])
        let signal = force ? SIGKILL : SIGTERM
        for pid in pids {
            if kill(pid, signal) == 0 || errno == ESRCH {
                outcome.signalled.append(pid)
            } else {
                outcome.failed.append(pid)
            }
        }
        return outcome
    }

    /// After a graceful SIGTERM, finish anything still alive.
    static func escalate(_ pids: [Int32], after delay: Duration = .milliseconds(1500)) async {
        try? await Task.sleep(for: delay)
        for pid in pids where kill(pid, 0) == 0 {
            _ = kill(pid, SIGKILL)
        }
    }
}
