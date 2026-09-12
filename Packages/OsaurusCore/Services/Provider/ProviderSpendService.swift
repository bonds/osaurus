//
//  ProviderSpendService.swift
//  osaurus
//
//  Spend for the Context Budget popover: exact OpenRouter (daily/weekly/monthly)
//  and DeepInfra (monthly) totals fetched from each provider's usage API, using
//  the same macOS Keychain store the app writes provider keys to. Provider APIs
//  expose aggregate totals only (no per-session USD), so rows carry their real
//  granularity; per-session Router spend comes from the session's persisted
//  `routerBilling` in the view layer.
//

import Foundation

@MainActor
public final class ProviderSpendService: ObservableObject {
    public static let shared = ProviderSpendService()

    /// One provider's spend line, labeled with the granularity the provider
    /// actually reports so the UI never fabricates a per-session figure.
    public struct Line: Equatable, Sendable {
        public let configured: Bool
        public let usd: Double?
        public let label: String
        public let note: String?

        public init(configured: Bool, usd: Double?, label: String, note: String? = nil) {
            self.configured = configured
            self.usd = usd
            self.label = label
            self.note = note
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let openrouter: Line
        public let deepinfra: Line
        public let generatedAt: Date

        public init(openrouter: Line, deepinfra: Line, generatedAt: Date) {
            self.openrouter = openrouter
            self.deepinfra = deepinfra
            self.generatedAt = generatedAt
        }
    }

    @Published public private(set) var snapshot: Snapshot?
    @Published public private(set) var isLoading = false
    public private(set) var lastError: String?

    /// Usage endpoints are aggregate; a short cache keeps popover re-opens from
    /// hammering them on every hover.
    private static let cacheInterval: TimeInterval = 60

    private var lastFetch = Date.distantPast
    private var inflight: Task<Void, Never>?

    /// Fallbacks in case remote.json moves; these are the current UUIDs.
    private static let fallbackOpenRouterUUID = "4C02D654-8275-4AA9-9405-47EE2F9125A2"
    private static let fallbackDeepInfraUUID = "A4D9ACDB-44DE-40F7-AFCC-9855ABBE893F"

    public init() {}

    /// Refresh only when the cached snapshot is older than `cacheInterval`.
    public func refreshIfStale() async {
        guard Date().timeIntervalSince(lastFetch) > Self.cacheInterval else { return }
        await refresh()
    }

    public func refresh() async {
        guard inflight == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            isLoading = true
            defer { isLoading = false }

            let now = Date()
            let startOfToday = Calendar.current.startOfDay(for: now)

            let uuids = Self.providerUUIDs()
            let openrouterKey = Self.apiKey(
                for: uuids["OpenRouter"] ?? Self.fallbackOpenRouterUUID)
            let deepinfraKey = Self.apiKey(
                for: uuids["DeepInfra"] ?? Self.fallbackDeepInfraUUID)

            let openrouter: Line
            if let openrouterKey,
                let data = await Self.fetchJSON(
                    URL(string: "https://openrouter.ai/api/v1/key")!,
                    bearer: openrouterKey),
                let inner = data["data"] as? [String: Any]
            {
                openrouter = Self.openRouterLine(from: inner)
            } else {
                openrouter = Line(
                    configured: openrouterKey != nil,
                    usd: nil,
                    label: "Today",
                    note: openrouterKey == nil ? "key not found" : nil
                )
            }

            let deepinfra: Line
            if let deepinfraKey {
                let months = Self.monthsInRange(start: startOfToday, end: now)
                if let first = months.first,
                    let last = months.last,
                    let data = await Self.fetchJSON(
                        URL(
                            string:
                                "https://api.deepinfra.com/payment/usage?from=\(first)&to=\(last)"
                        )!,
                        bearer: deepinfraKey)
                {
                    deepinfra = Self.deepInfraLine(from: data)
                } else {
                    deepinfra = Line(
                        configured: true, usd: nil, label: "This month", note: nil)
                }
            } else {
                deepinfra = Line(
                    configured: false, usd: nil, label: "This month",
                    note: "key not found")
            }

            snapshot = Snapshot(
                openrouter: openrouter, deepinfra: deepinfra, generatedAt: now)
            lastFetch = now
        }
        inflight = task
        await task.value
        inflight = nil
    }

    // MARK: - Pure extraction (unit-tested, callable off the main actor)

    /// Extract the daily OpenRouter spend from the `/api/v1/key` response.
    nonisolated static func openRouterLine(from data: [String: Any]) -> Line {
        Line(configured: true, usd: data["usage_daily"] as? Double, label: "Today")
    }

    /// Extract the overlapping-months DeepInfra spend from `/payment/usage`.
    /// `total_cost` is in cents; accept Int, Double, or stringified forms.
    nonisolated static func deepInfraLine(from data: [String: Any]) -> Line {
        let months = data["months"] as? [[String: Any]] ?? []
        let cents = months.compactMap { centsValue($0["total_cost"]) }.reduce(0, +)
        return Line(
            configured: true,
            usd: Double(cents) / 100.0,
            label: "This month",
            note: months.isEmpty ? nil : "DeepInfra reports monthly totals only"
        )
    }

    /// `yyyy.MM` labels covering `[start, end]`. Enumerates month intervals
    /// (start-of-month anchors) so a range crossing a boundary keeps BOTH
    /// overlapping months — stepping `+1 month` from e.g. Aug 31 lands on
    /// Sep 30, which is past a Sep 1 `end` and silently drops September.
    nonisolated static func monthsInRange(start: Date, end: Date) -> [String] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM"
        var out: [String] = []
        let endAnchor = calendar.dateInterval(of: .month, for: end)?.start ?? end
        var cursor = calendar.dateInterval(of: .month, for: start)?.start ?? start
        while cursor <= endAnchor {
            let month = formatter.string(from: cursor)
            if !out.contains(month) { out.append(month) }
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor)
            else { break }
            cursor = next
        }
        return out
    }

    /// `provider name -> id` from the app's own `remote.json`.
    nonisolated static func providerUUIDs(parsing data: Data) -> [String: String] {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let providers = obj["providers"] as? [[String: Any]]
        else { return [:] }
        var map: [String: String] = [:]
        for provider in providers {
            if let name = provider["name"] as? String, let id = provider["id"] as? String {
                map[name] = id
            }
        }
        return map
    }

    // MARK: - Private

    private static func providerUUIDs() -> [String: String] {
        guard let data = try? Data(contentsOf: OsaurusPaths.remoteProviderConfigFile())
        else { return [:] }
        return providerUUIDs(parsing: data)
    }

    private static func apiKey(for uuid: String) -> String? {
        guard let providerUUID = UUID(uuidString: uuid) else { return nil }
        return RemoteProviderKeychain.getAPIKey(for: providerUUID)
    }

    nonisolated static func centsValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private static func fetchJSON(_ url: URL, bearer: String?) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
