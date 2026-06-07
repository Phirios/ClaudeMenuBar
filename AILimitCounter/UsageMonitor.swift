import Foundation
import Combine
import Security

enum AIProvider: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var processPattern: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    var tokenLabel: String {
        switch self {
        case .claude: return "Claude Code keychain token"
        case .codex: return "Codex session logs"
        }
    }
}

private enum DefaultsKeys {
    static let selectedProvider = "selected_provider"
    static let legacyBundleIdentifier = "com.phirios.ClaudeMenuBar"
}

struct UsageWindow {
    let label: String
    let utilization: Double
    let reset: Date
    let isRepresentative: Bool

    var percent: Int { Int(utilization * 100) }
}

struct UsageData {
    let provider: AIProvider
    let primary: UsageWindow
    let secondary: UsageWindow
    let overage: UsageWindow?
    let fiveHourUtilization: Double
    let fiveHourReset: Date
    let sevenDayUtilization: Double
    let sevenDayReset: Date
    let overageUtilization: Double
    let overageReset: Date
    let representativeClaim: String
    let fallbackPercentage: Double
    let status: String
    let fetchedAt: Date
    let source: String

    var fiveHourPercent: Int { Int(fiveHourUtilization * 100) }
    var sevenDayPercent: Int { Int(sevenDayUtilization * 100) }
    var overagePercent: Int { Int(overageUtilization * 100) }
}

class UsageMonitor: ObservableObject {
    @Published var currentUsage: UsageData?
    @Published var error: String?
    @Published var isLoading = false
    @Published var selectedProvider: AIProvider {
        didSet {
            guard oldValue != selectedProvider else { return }
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: DefaultsKeys.selectedProvider)
            UserDefaults.standard.synchronize()
            currentUsage = nil
            error = nil
            startMonitoring()
        }
    }

    var onUpdate: (() -> Void)?
    private var timer: Timer?

    init() {
        let stored = Self.storedProviderRawValue()
        selectedProvider = AIProvider(rawValue: stored ?? "") ?? .claude
    }

    private static func storedProviderRawValue() -> String? {
        if let stored = UserDefaults.standard.string(forKey: DefaultsKeys.selectedProvider) {
            return stored
        }

        let legacyDefaults = UserDefaults(suiteName: DefaultsKeys.legacyBundleIdentifier)
        guard let legacyProvider = legacyDefaults?.string(forKey: DefaultsKeys.selectedProvider) else {
            return nil
        }

        UserDefaults.standard.set(legacyProvider, forKey: DefaultsKeys.selectedProvider)
        UserDefaults.standard.synchronize()
        return legacyProvider
    }

    var refreshInterval: TimeInterval {
        get {
            let val = UserDefaults.standard.double(forKey: "refresh_interval")
            return val > 0 ? val : 300
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "refresh_interval")
            startMonitoring()
        }
    }

    func startMonitoring() {
        timer?.invalidate()
        fetchUsage()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.fetchUsage()
        }
    }

    func fetchUsage() {
        switch selectedProvider {
        case .claude:
            fetchClaudeUsage()
        case .codex:
            fetchCodexUsage()
        }
    }

    private func fetchClaudeUsage() {
        guard let token = getToken() else {
            error = "Claude Code auth token not found"
            onUpdate?()
            return
        }

        isLoading = true
        error = nil

        // Minimal request to get rate limit headers
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] _, response, err in
            DispatchQueue.main.async {
                self?.isLoading = false

                if let err = err {
                    self?.error = err.localizedDescription
                    self?.onUpdate?()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.error = "Invalid response"
                    self?.onUpdate?()
                    return
                }

                // If 401, try keychain for a fresher token before giving up
                if httpResponse.statusCode == 401 {
                    if let freshToken = self?.getKeychainToken(), freshToken != token {
                        self?.cacheToken(freshToken)
                        self?.isLoading = true
                        self?.retryFetchUsage(token: freshToken)
                        return
                    }
                    self?.clearCachedToken()
                    self?.error = "Auth token expired. Re-login to Claude Code."
                    self?.onUpdate?()
                    return
                }

                self?.handleResponse(httpResponse)
            }
        }.resume()
    }

    private var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/claude-menubar-token")
    }

    private func clearCachedToken() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    func cacheToken(_ token: String) {
        try? token.write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    func getKeychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return token
    }

    private func retryFetchUsage(token: String) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] _, response, err in
            DispatchQueue.main.async {
                self?.isLoading = false
                if let err = err {
                    self?.error = err.localizedDescription
                    self?.onUpdate?()
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.error = "Invalid response"
                    self?.onUpdate?()
                    return
                }
                self?.handleResponse(httpResponse)
            }
        }.resume()
    }

    private func handleResponse(_ httpResponse: HTTPURLResponse) {
        let headers = httpResponse.allHeaderFields

        guard let fiveHUtil = headerDouble(headers, "anthropic-ratelimit-unified-5h-utilization"),
              let sevenDUtil = headerDouble(headers, "anthropic-ratelimit-unified-7d-utilization") else {
            error = "Rate limit headers not found (HTTP \(httpResponse.statusCode))"
            onUpdate?()
            return
        }

        let fiveHReset = headerTimestamp(headers, "anthropic-ratelimit-unified-5h-reset") ?? Date()
        let sevenDReset = headerTimestamp(headers, "anthropic-ratelimit-unified-7d-reset") ?? Date()
        let overageUtil = headerDouble(headers, "anthropic-ratelimit-unified-overage-utilization") ?? 0
        let overageReset = headerTimestamp(headers, "anthropic-ratelimit-unified-overage-reset") ?? Date()
        let status = headerString(headers, "anthropic-ratelimit-unified-status") ?? "unknown"
        let claim = headerString(headers, "anthropic-ratelimit-unified-representative-claim") ?? ""
        let fallback = headerDouble(headers, "anthropic-ratelimit-unified-fallback-percentage") ?? 0

        let primary = UsageWindow(
            label: "5h",
            utilization: fiveHUtil,
            reset: fiveHReset,
            isRepresentative: claim == "five_hour"
        )
        let secondary = UsageWindow(
            label: "7d",
            utilization: sevenDUtil,
            reset: sevenDReset,
            isRepresentative: claim == "seven_day"
        )
        let overage = overageUtil > 0 ? UsageWindow(
            label: "Ovg",
            utilization: overageUtil,
            reset: overageReset,
            isRepresentative: false
        ) : nil

        currentUsage = UsageData(
            provider: .claude,
            primary: primary,
            secondary: secondary,
            overage: overage,
            fiveHourUtilization: fiveHUtil,
            fiveHourReset: fiveHReset,
            sevenDayUtilization: sevenDUtil,
            sevenDayReset: sevenDReset,
            overageUtilization: overageUtil,
            overageReset: overageReset,
            representativeClaim: claim,
            fallbackPercentage: fallback,
            status: status,
            fetchedAt: Date(),
            source: "Anthropic rate-limit headers"
        )
        onUpdate?()
    }

    private func fetchCodexUsage() {
        isLoading = true
        error = nil

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = self?.readLatestCodexRateLimits()
            DispatchQueue.main.async {
                self?.isLoading = false
                switch result {
                case .success(let usage):
                    self?.currentUsage = usage
                    self?.error = nil
                case .failure(let message):
                    self?.currentUsage = nil
                    self?.error = message
                case .none:
                    self?.currentUsage = nil
                    self?.error = "Codex usage unavailable"
                }
                self?.onUpdate?()
            }
        }
    }

    private enum CodexReadResult {
        case success(UsageData)
        case failure(String)
    }

    private func readLatestCodexRateLimits() -> CodexReadResult {
        let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")

        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .failure("Codex session directory not found")
        }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, modified))
        }

        for file in files.sorted(by: { $0.modified > $1.modified }) {
            guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard let usage = parseCodexRateLimitLine(String(line), sourceURL: file.url) else { continue }
                return .success(usage)
            }
        }

        return .failure("No Codex rate-limit events found yet")
    }

    private func parseCodexRateLimitLine(_ line: String, sourceURL: URL) -> UsageData? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any],
              let primaryRaw = limits["primary"] as? [String: Any],
              let secondaryRaw = limits["secondary"] as? [String: Any],
              let primaryUsed = jsonDouble(primaryRaw["used_percent"]),
              let primaryReset = jsonDouble(primaryRaw["resets_at"]),
              let secondaryUsed = jsonDouble(secondaryRaw["used_percent"]),
              let secondaryReset = jsonDouble(secondaryRaw["resets_at"]) else {
            return nil
        }

        let reachedType = limits["rate_limit_reached_type"] as? String
        let status = reachedType == nil ? "allowed" : "blocked"
        let primary = UsageWindow(
            label: "5h",
            utilization: primaryUsed / 100,
            reset: Date(timeIntervalSince1970: primaryReset),
            isRepresentative: primaryUsed >= secondaryUsed
        )
        let secondary = UsageWindow(
            label: "7d",
            utilization: secondaryUsed / 100,
            reset: Date(timeIntervalSince1970: secondaryReset),
            isRepresentative: secondaryUsed > primaryUsed
        )
        let plan = limits["plan_type"] as? String
        let source = plan == nil
            ? "Latest Codex session log"
            : "Latest Codex session log (\(plan!))"

        return UsageData(
            provider: .codex,
            primary: primary,
            secondary: secondary,
            overage: nil,
            fiveHourUtilization: primary.utilization,
            fiveHourReset: primary.reset,
            sevenDayUtilization: secondary.utilization,
            sevenDayReset: secondary.reset,
            overageUtilization: 0,
            overageReset: Date(),
            representativeClaim: primary.isRepresentative ? "five_hour" : "seven_day",
            fallbackPercentage: 0,
            status: status,
            fetchedAt: Date(),
            source: sourceURL.lastPathComponent + " - " + source
        )
    }

    private func jsonDouble(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func getToken() -> String? {
        if let cached = try? String(contentsOf: cacheURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !cached.isEmpty {
            return cached
        }
        guard let token = getKeychainToken() else { return nil }
        cacheToken(token)
        return token
    }

    private func headerDouble(_ headers: [AnyHashable: Any], _ key: String) -> Double? {
        for (k, v) in headers {
            if let kStr = k as? String, kStr.lowercased() == key.lowercased(),
               let vStr = v as? String, let num = Double(vStr) {
                return num
            }
        }
        return nil
    }

    private func headerTimestamp(_ headers: [AnyHashable: Any], _ key: String) -> Date? {
        for (k, v) in headers {
            if let kStr = k as? String, kStr.lowercased() == key.lowercased(),
               let vStr = v as? String, let num = TimeInterval(vStr) {
                return Date(timeIntervalSince1970: num)
            }
        }
        return nil
    }

    private func headerString(_ headers: [AnyHashable: Any], _ key: String) -> String? {
        for (k, v) in headers {
            if let kStr = k as? String, kStr.lowercased() == key.lowercased(),
               let vStr = v as? String {
                return vStr
            }
        }
        return nil
    }
}
