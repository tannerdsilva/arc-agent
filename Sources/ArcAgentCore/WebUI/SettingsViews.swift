import Foundation
import WebUI
import WebUIDesignSystem

/// the settings page: a read-only snapshot of the frozen startup
/// configuration plus the registered cron jobs. server-rendered per request;
/// configuration changes belong to the next process start (`arc config` or
/// the config file), so there is nothing editable here.
public enum SettingsViews {

	public static func renderSettingsPage(config: ArcConfig, cronJobs: [CronJob]) -> String {
		VStack(alignment: .leading, spacing: 16) {
			Heading("Settings", level: .h2)

			WebUICard(variant: .outlined) {
				VStack(alignment: .leading, spacing: 8) {
					Heading("General", level: .h3)
					WebUIDescriptionList([
						("Model", config.model.defaultModel),
						("Provider", config.model.provider),
						("Base URL", config.model.baseURL ?? "(default)"),
						("Approval mode", config.security.approvalMode),
						("Max iterations", "\(config.agent.maxIterations)"),
						("Max context tokens", config.model.contextLength.map(String.init) ?? "(auto)"),
						("Memory", config.memory.enabled ? "on (max \(config.memory.maxSize) chars)" : "off"),
						("Web UI", "http://\(config.web.host):\(config.web.port)\(config.web.authEnabled ? " · auth on" : "")"),
					])
				}
			}
			.maxWidth("640px")

			WebUICard(variant: .outlined) {
				VStack(alignment: .leading, spacing: 12) {
					Heading("Cron jobs", level: .h3)
					if cronJobs.isEmpty {
						WebUIEmptyState(
							icon: .clock,
							title: "No cron jobs",
							message: "Jobs are configured in the cron store."
						)
					} else {
						WebUITable(
							headers: ["Name", "Schedule", "Active", "Last run", "Runs"],
							rows: cronJobs.map { job in
								[
									Text(job.name),
									Text(job.schedule),
									Text(job.isActive ? "yes" : "no"),
									Text(job.lastRunAt.map(Self.shortDate) ?? "never"),
									Text("\(job.runCount)"),
								]
							},
							compact: true
						)
					}
				}
			}
		}
		.render()
	}

	private static func shortDate(_ date: Date) -> String {
		Self.dateFormatter.string(from: date)
	}

	private static let dateFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm"
		return formatter
	}()
}
