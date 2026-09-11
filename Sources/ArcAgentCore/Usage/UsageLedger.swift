import Foundation

// MARK: - Usage ledger (Hermes `usage_pricing.py` + `credits_tracker.py` +
// `account_usage.py`), local-JSON persistence.

/// Canonical per-request usage (Hermes `CanonicalUsage`).
public struct CanonicalUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var reasoningTokens: Int
    public var requestCount: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0,
                cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0,
                reasoningTokens: Int = 0, requestCount: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.requestCount = requestCount
    }

    public static func + (lhs: CanonicalUsage, rhs: CanonicalUsage) -> CanonicalUsage {
        CanonicalUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            requestCount: lhs.requestCount + rhs.requestCount
        )
    }

    public static let zero = CanonicalUsage()
}

/// A route identifies how a request was billed: provider + model + base URL
/// (Hermes `BillingRoute`).
public struct BillingRoute: Sendable, Equatable, Hashable, Codable {
    public let provider: String
    public let model: String
    public let baseURL: String
    public let billingMode: String

    public init(provider: String, model: String, baseURL: String = "", billingMode: String = "per_token") {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.billingMode = billingMode
    }
}

/// Pricing per million tokens (Hermes `PricingEntry`).
public struct PricingEntry: Sendable, Equatable, Codable {
    public let provider: String
    public let model: String
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double?
    public let cacheWritePerMillion: Double?
    public let requestPerMillion: Double?
    public let source: String

    public init(provider: String, model: String,
                inputPerMillion: Double, outputPerMillion: Double,
                cacheReadPerMillion: Double? = nil, cacheWritePerMillion: Double? = nil,
                requestPerMillion: Double? = nil, source: String = "vendor") {
        self.provider = provider
        self.model = model
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.requestPerMillion = requestPerMillion
        self.source = source
    }
}

/// Cost result (Hermes `CostResult`).
public struct CostResult: Sendable, Equatable {
    public let cost: Double
    public let matchedModel: String?
    public let source: String?

    public init(cost: Double, matchedModel: String?, source: String?) {
        self.cost = cost
        self.matchedModel = matchedModel
        self.source = source
    }
}

/// Official pricing table (provider, model) → entry. Representative subset
/// of Hermes' table keyed the same way; `source` = "official".
public struct PricingTable {
    public static let entries: [PricingEntry] = [
        // OpenAI
        PricingEntry(provider: "openai", model: "gpt-4o", inputPerMillion: 2.50, outputPerMillion: 10.00,
                     cacheReadPerMillion: 1.25, cacheWritePerMillion: 5.00, source: "official"),
        PricingEntry(provider: "openai", model: "gpt-4o-mini", inputPerMillion: 0.15, outputPerMillion: 0.60,
                     cacheReadPerMillion: 0.075, cacheWritePerMillion: 0.30, source: "official"),
        PricingEntry(provider: "openai", model: "gpt-5", inputPerMillion: 1.25, outputPerMillion: 10.00,
                     cacheReadPerMillion: 0.125, cacheWritePerMillion: 1.25, source: "official"),
        // Anthropic
        PricingEntry(provider: "anthropic", model: "claude-sonnet-4-5", inputPerMillion: 3.00, outputPerMillion: 15.00,
                     cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75, source: "official"),
        PricingEntry(provider: "anthropic", model: "claude-opus-4-5", inputPerMillion: 5.00, outputPerMillion: 25.00,
                     cacheReadPerMillion: 0.50, cacheWritePerMillion: 6.25, source: "official"),
        PricingEntry(provider: "anthropic", model: "claude-haiku-4-5", inputPerMillion: 1.00, outputPerMillion: 5.00,
                     cacheReadPerMillion: 0.10, cacheWritePerMillion: 1.25, source: "official"),
        // Google
        PricingEntry(provider: "google", model: "gemini-2.5-pro", inputPerMillion: 1.25, outputPerMillion: 10.00,
                     cacheReadPerMillion: 0.3125, source: "official"),
        PricingEntry(provider: "google", model: "gemini-2.5-flash", inputPerMillion: 0.30, outputPerMillion: 2.50,
                     cacheReadPerMillion: 0.075, source: "official"),
        // DeepSeek
        PricingEntry(provider: "deepseek", model: "deepseek-chat", inputPerMillion: 0.27, outputPerMillion: 1.10,
                     cacheReadPerMillion: 0.07, source: "official"),
        PricingEntry(provider: "deepseek", model: "deepseek-reasoner", inputPerMillion: 0.55, outputPerMillion: 2.19,
                     cacheReadPerMillion: 0.14, source: "official"),
    ]

    /// Find the exact or best prefix match for a model name (Hermes looks up
    /// exact match, then the longest slug-prefix match).
    public static func lookup(provider: String, model: String) -> PricingEntry? {
        let lower = model.lowercased()
        if let exact = entries.first(where: { $0.provider == provider && $0.model.lowercased() == lower }) {
            return exact
        }
        return entries
            .filter { $0.provider == provider && lower.hasPrefix($0.model.lowercased()) }
            .max { $0.model.count < $1.model.count }
    }
}

public enum UsagePricing {
    /// Estimate the cost of a request (Hermes `estimate_usage_cost`):
    /// input + output + cache read/write + per-request, all per-million.
    public static func estimate(route: BillingRoute, usage: CanonicalUsage) -> CostResult {
        guard let entry = PricingTable.lookup(provider: route.provider, model: route.model) else {
            return CostResult(cost: 0, matchedModel: nil, source: nil)
        }
        var cost = 0.0
        cost += Double(usage.inputTokens) / 1_000_000 * entry.inputPerMillion
        cost += Double(usage.outputTokens) / 1_000_000 * entry.outputPerMillion
        if let rate = entry.cacheReadPerMillion {
            cost += Double(usage.cacheReadTokens) / 1_000_000 * rate
        }
        if let rate = entry.cacheWritePerMillion {
            cost += Double(usage.cacheWriteTokens) / 1_000_000 * rate
        }
        if let rate = entry.requestPerMillion {
            cost += Double(usage.requestCount) / 1_000_000 * rate
        }
        return CostResult(cost: cost, matchedModel: entry.model, source: entry.source)
    }

    /// Compact human format (Hermes `format_token_count_compact`): 1.2K/3.4M.
    public static func formatCompact(_ count: Int) -> String {
        if count >= 1_000_000 {
            let v = Double(count) / 1_000_000
            return String(format: v >= 10 ? "%.0fM" : "%.1fM", v)
        }
        if count >= 1_000 {
            let v = Double(count) / 1_000
            return String(format: v >= 10 ? "%.0fK" : "%.1fK", v)
        }
        return "\(count)"
    }
}

// MARK: - Ledger persistence

/// One day of usage (Hermes daily aggregation windows).
public struct UsageDay: Codable, Sendable, Equatable {
    public let date: String                 // yyyy-MM-dd
    public var usage: CanonicalUsage
    public var byRoute: [String: CanonicalUsage]
    public var cost: Double

    public init(date: String, usage: CanonicalUsage = .zero, byRoute: [String: CanonicalUsage] = [:], cost: Double = 0) {
        self.date = date
        self.usage = usage
        self.byRoute = byRoute
        self.cost = cost
    }
}

/// A simple JSON-ledger store: one `usage.json` with per-day buckets under
/// `~/.arc-agent/` (usage is local state, unlike Tessera sessions). An actor
/// per the First Law — no locks.
public actor UsageLedger {

    public let fileURL: URL
    private var days: [String: UsageDay]

    public init(fileURL: URL? = nil) {
        let resolved = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".arc-agent/usage.json")
        self.fileURL = resolved
        if let data = try? Data(contentsOf: resolved),
           let decoded = try? JSONDecoder().decode([String: UsageDay].self, from: data) {
            days = decoded
        } else {
            days = [:]
        }
    }

    /// Record one turn's usage (Hermes records per-response; aggrégation by
    /// day happens lazily here).
    public func record(route: BillingRoute, usage: CanonicalUsage) {
        let key = Self.dayString(Date())
        var day = days[key] ?? UsageDay(date: key)
        day.usage = day.usage + usage
        let routeKey = "\(route.provider)/\(route.model)"
        var routeUsage = day.byRoute[routeKey] ?? .zero
        routeUsage = routeUsage + usage
        day.byRoute[routeKey] = routeUsage
        day.cost += UsagePricing.estimate(route: route, usage: usage).cost
        days[key] = day
        save()
    }

    public func day(_ date: String) -> UsageDay? { days[date] }

    public func total() -> CanonicalUsage {
        days.values.reduce(.zero) { $0 + $1.usage }
    }

    public func totalCost() -> Double {
        days.values.reduce(0) { $0 + $1.cost }
    }

    public func save() {
        if let data = try? JSONEncoder().encode(days) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public static func dayString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - Insights (Hermes `insights.py`)

/// Daily aggregation + cost estimate for UI views.
public enum InsightsEngine {
    public struct DayInsight: Sendable, Equatable {
        public let date: String
        public let tokens: Int
        public let cost: Double
        public let requests: Int
    }

    /// Hourly bucket shape for sparkline-style charts.
    public struct Hourly: Sendable, Equatable {
        public let hour: Int
        public let tokens: Int
    }

    public static func daily(_ days: [UsageDay]) -> [DayInsight] {
        days.sorted { $0.date < $1.date }.map {
            DayInsight(date: $0.date,
                       tokens: $0.usage.inputTokens + $0.usage.outputTokens + $0.usage.cacheReadTokens + $0.usage.cacheWriteTokens,
                       cost: $0.cost,
                       requests: $0.usage.requestCount)
        }
    }

    /// Top models by tokens (Hermes insights model ranking).
    public static func topModels(_ days: [UsageDay], limit: Int = 5) -> [(route: String, usage: CanonicalUsage)] {
        var merged: [String: CanonicalUsage] = [:]
        for day in days {
            for (route, usage) in day.byRoute {
                merged[route, default: .zero] = merged[route, default: .zero] + usage
            }
        }
        return merged.sorted { a, b in
            (a.value.inputTokens + a.value.outputTokens) > (b.value.inputTokens + b.value.outputTokens)
        }.prefix(limit).map { ($0.key, $0.value) }
    }
}

// MARK: - Trace upload (Hermes `trace_upload.py`)

/// Builds Claude-Code-format JSONL trace lines and uploads them to a
/// configured endpoint (Hermes uploads traces for agent telemetry).
public enum TraceUpload {
    /// One JSONL line (Claude-Code trace-record shape).
    public static func traceLine(
        sessionID: String,
        timestamp: Date,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        durationMs: Int,
        message: String
    ) -> [String: Any] {
        [
            "timestamp": Int(timestamp.timeIntervalSince1970 * 1000),
            "session_id": sessionID,
            "type": "assistant",
            "model": model,
            "usage": ["input_tokens": inputTokens, "output_tokens": outputTokens],
            "duration_ms": durationMs,
            "message": message,
        ]
    }

    /// Upload trace lines to an endpoint (HTTP POST, best-effort).
    public static func upload(lines: [[String: Any]], to url: URL, apiKey: String?) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: lines)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
