import Foundation

/// The endpoint one turn will actually use, plus where the choice came from.
///
/// Every surface resolves through ``ProviderEndpointResolver`` so the web UI,
/// the CLI and the daemon cannot disagree about which base URL a turn talks to.
/// The value is deliberately honest: `source` and `label` name the decision, so
/// a stale surface preset can be told apart from a config edit without reading
/// either file.
public struct ProviderEndpoint: Sendable, Equatable, CustomStringConvertible {

    /// Where the winning base URL came from.
    public enum Source: String, Sendable, Equatable {
        /// an explicit CLI flag or environment override.
        case flag
        /// the surface's own configuration: a web UI model preset, a profile pin.
        case preset
        /// `~/.arc/config.json`'s `model` block.
        case config
        /// the built-in OpenAI default.
        case fallback
    }

    /// The resolved base URL (IPv6 literals keep their brackets).
    public let baseURL: URL
    /// The model name the surface will request.
    public let model: String
    /// The provider name the surface will report.
    public let provider: String
    /// Which layer supplied the base URL.
    public let source: Source
    /// The surface's human label for its choice (preset name, profile name).
    public let label: String?

    public init(
        baseURL: URL,
        model: String,
        provider: String,
        source: Source,
        label: String? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.provider = provider
        self.source = source
        self.label = label
    }

    /// `host:port` in the one form a reader can act on — an IPv6 literal keeps
    /// its brackets, because a bare `fdfd:…:8000` is indistinguishable from a
    /// truncated list of addresses.
    public var authority: String {
        let host = baseURL.host ?? baseURL.absoluteString
        guard let port = baseURL.port else { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// `model @ base URL (source: label)` — the line the logs and the UI show.
    public var description: String {
        let origin = label.map { "\(source.rawValue): \($0)" } ?? source.rawValue
        return "\(model) @ \(baseURL.absoluteString) (\(origin))"
    }
}

/// Why a configured endpoint could not become a URL.
public enum ProviderEndpointError: Error, Equatable, CustomStringConvertible {
    /// The configured string is not usable as an HTTP base URL. `detail` names
    /// the specific defect when one is known (an unbracketed IPv6 literal is
    /// the case that reads as a hostname and silently becomes DNS noise).
    case unparseable(baseURL: String, source: ProviderEndpoint.Source, detail: String)

    public var description: String {
        switch self {
        case .unparseable(let baseURL, let source, let detail):
            return "invalid base URL '\(baseURL)' (from \(source.rawValue)): \(detail)"
        }
    }
}

/// The one precedence rule for every surface: an explicit choice wins, then
/// `~/.arc/config.json`'s `model` block, then the built-in default.
///
/// A blank string counts as absent — the web UI's add-configuration form submits
/// empty fields for untouched options, and an empty base URL must not shadow a
/// configured one. A string that is present but unusable throws: silently
/// substituting a placeholder (the old `https://invalid.invalid` fallback) is
/// what turned a typo into an unexplained transport failure.
public enum ProviderEndpointResolver {

    /// The built-in default when neither a surface nor the config names one.
    public static let fallbackBaseURL = URL(string: "https://api.openai.com/v1")!

    /// A surface's explicit selection (CLI flags/env, a web UI preset, a profile
    /// pin). Every field is optional: an unset field defers to the config.
    public struct Choice: Sendable, Equatable {
        public var baseURL: String?
        public var model: String?
        public var provider: String?
        public var source: ProviderEndpoint.Source
        public var label: String?

        public init(
            baseURL: String? = nil,
            model: String? = nil,
            provider: String? = nil,
            source: ProviderEndpoint.Source = .preset,
            label: String? = nil
        ) {
            self.baseURL = baseURL
            self.model = model
            self.provider = provider
            self.source = source
            self.label = label
        }
    }

    /// Resolve the endpoint for one turn.
    ///
    /// - Parameters:
    ///   - choice: the surface's explicit selection, or `nil` for a surface
    ///     that only reads the config.
    ///   - config: the `model` block the config file resolved.
    /// - Throws: ``ProviderEndpointError/unparseable(baseURL:source:detail:)``
    ///   when the winning string cannot become an HTTP URL.
    public static func resolve(
        choice: Choice?,
        config: ModelConfig
    ) throws -> ProviderEndpoint {
        let chosenBase = blankToNil(choice?.baseURL)
        let configBase = blankToNil(config.baseURL)

        let baseString: String
        let source: ProviderEndpoint.Source
        if let chosenBase {
            baseString = chosenBase
            source = choice?.source ?? .preset
        } else if let configBase {
            baseString = configBase
            source = .config
        } else {
            baseString = fallbackBaseURL.absoluteString
            source = .fallback
        }

        let url = try parse(baseString, source: source)

        return ProviderEndpoint(
            baseURL: url,
            model: blankToNil(choice?.model) ?? config.defaultModel,
            provider: blankToNil(choice?.provider) ?? config.provider,
            source: source,
            label: choice?.label
        )
    }

    /// Parse one base URL string, naming the defect when it is unusable.
    ///
    /// `URL(string:)` alone is too lenient to gate on: it accepts `http://fdfd:a87e::1:8000/v1`
    /// as host `fdfd` with no port, which then fails as a DNS lookup on a name
    /// nobody can read. The authority is therefore checked structurally.
    public static func parse(_ baseString: String, source: ProviderEndpoint.Source) throws -> URL {
        if let issue = authorityIssue(baseString) {
            throw ProviderEndpointError.unparseable(
                baseURL: baseString, source: source, detail: issue
            )
        }
        guard let url = URL(string: baseString), let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"), url.host != nil
        else {
            throw ProviderEndpointError.unparseable(
                baseURL: baseString, source: source,
                detail: "expected an absolute http(s) URL"
            )
        }
        return url
    }

    /// The structural defect in a base URL string's authority, when there is one.
    ///
    /// An IPv6 literal must be bracketed (`http://[fdfd::1]:8000/v1`); unbracketed,
    /// the last colon group reads as a port and the rest as an unroutable host.
    static func authorityIssue(_ baseString: String) -> String? {
        guard let schemeEnd = baseString.range(of: "://") else {
            return "missing scheme (expected http:// or https://)"
        }
        let authority = baseString[schemeEnd.upperBound...]
            .prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.isEmpty else { return "missing host" }

        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else {
                return "unclosed IPv6 bracket — expected [address]:port"
            }
            let after = authority[authority.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else {
                    return "unexpected characters after the IPv6 literal — expected [address]:port"
                }
                let port = after.dropFirst()
                guard !port.isEmpty else { return "missing port after ':'" }
                guard port.allSatisfy(\.isNumber) else {
                    return "port '\(port)' is not a number"
                }
            }
            return nil
        }

        // a bare authority may carry at most one ':' (the port); more means an
        // unbracketed IPv6 literal, which no client can route.
        let colonCount = authority.filter { $0 == ":" }.count
        if colonCount > 1 {
            return "an IPv6 literal needs square brackets — write [\(authority)] instead"
        }
        if let colon = authority.firstIndex(of: ":") {
            let port = authority[authority.index(after: colon)...]
            guard !port.isEmpty else { return "missing port after ':'" }
            guard port.allSatisfy(\.isNumber) else {
                return "port '\(port)' is not a number"
            }
        }
        return nil
    }

    private static func blankToNil(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return nil
        }
        return t
    }
}
