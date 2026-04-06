import Foundation
import Combine

struct UsageData {
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

    var fiveHourPercent: Int { Int(fiveHourUtilization * 100) }
    var sevenDayPercent: Int { Int(sevenDayUtilization * 100) }
    var overagePercent: Int { Int(overageUtilization * 100) }
}

class UsageMonitor: ObservableObject {
    @Published var currentUsage: UsageData?
    @Published var error: String?
    @Published var isLoading = false

    var onUpdate: (() -> Void)?
    private var timer: Timer?

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
        request.setValue(token, forHTTPHeaderField: "x-api-key")
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

                let headers = httpResponse.allHeaderFields

                guard let fiveHUtil = self?.headerDouble(headers, "anthropic-ratelimit-unified-5h-utilization"),
                      let sevenDUtil = self?.headerDouble(headers, "anthropic-ratelimit-unified-7d-utilization") else {
                    self?.error = "Rate limit headers not found (HTTP \(httpResponse.statusCode))"
                    self?.onUpdate?()
                    return
                }

                let fiveHReset = self?.headerTimestamp(headers, "anthropic-ratelimit-unified-5h-reset") ?? Date()
                let sevenDReset = self?.headerTimestamp(headers, "anthropic-ratelimit-unified-7d-reset") ?? Date()
                let overageUtil = self?.headerDouble(headers, "anthropic-ratelimit-unified-overage-utilization") ?? 0
                let overageReset = self?.headerTimestamp(headers, "anthropic-ratelimit-unified-overage-reset") ?? Date()
                let status = self?.headerString(headers, "anthropic-ratelimit-unified-status") ?? "unknown"
                let claim = self?.headerString(headers, "anthropic-ratelimit-unified-representative-claim") ?? ""
                let fallback = self?.headerDouble(headers, "anthropic-ratelimit-unified-fallback-percentage") ?? 0

                self?.currentUsage = UsageData(
                    fiveHourUtilization: fiveHUtil,
                    fiveHourReset: fiveHReset,
                    sevenDayUtilization: sevenDUtil,
                    sevenDayReset: sevenDReset,
                    overageUtilization: overageUtil,
                    overageReset: overageReset,
                    representativeClaim: claim,
                    fallbackPercentage: fallback,
                    status: status,
                    fetchedAt: Date()
                )
                self?.onUpdate?()
            }
        }.resume()
    }

    private func getToken() -> String? {
        // Read token from a cache file to avoid keychain permission prompts.
        // The file is populated by a helper script or on first run from keychain.
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/claude-menubar-token")

        if let cached = try? String(contentsOf: cacheURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !cached.isEmpty {
            return cached
        }

        // Fallback: try to read from keychain and cache it
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return nil
        }

        // Cache it so next time no keychain prompt
        try? token.write(to: cacheURL, atomically: true, encoding: .utf8)
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
