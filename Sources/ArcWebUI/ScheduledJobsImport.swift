import ArcAgentCore
import Foundation

/// Phase-2 convergence: the cron store is the single source of truth for
/// scheduled jobs, so the legacy `scheduledJobs` array in the UI's
/// `settings.json` is imported once and dropped from the file.
public enum ScheduledJobsImport {

    /// The legacy shape: just enough of the settings file to lift the array.
    private struct Legacy: Decodable {
        let scheduledJobs: [CronJob]
    }

    /// Import legacy jobs into `store` (by id, never overwriting) and rewrite
    /// the settings file without the key.
    ///
    /// Idempotent by construction: an absent key is a completed import, so a
    /// job deleted later (from the UI or `arc cron`) is never resurrected by a
    /// subsequent boot.
    public static func runIfNeeded(into store: any CronStore, settingsURL: URL? = nil) async {
        let url = settingsURL ?? AppState.settingsURL
        guard let data = try? Data(contentsOf: url),
              let legacy = try? JSONDecoder().decode(Legacy.self, from: data),
              !legacy.scheduledJobs.isEmpty
        else { return }

        for job in legacy.scheduledJobs where (try? await store.get(id: job.id)) == nil {
            try? await store.save(job)
        }

        // drop the key: from here on the store owns jobs, and the UI no longer
        // persists `scheduledJobs` (it is a render cache).
        if var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root.removeValue(forKey: "scheduledJobs")
            if let out = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) {
                try? out.write(to: url, options: .atomic)
            }
        }
    }
}