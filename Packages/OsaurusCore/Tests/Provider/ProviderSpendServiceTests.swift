//
//  ProviderSpendServiceTests.swift
//  osaurusTests
//
//  Pins the pure extraction logic behind the Context Budget popover's Spend
//  section: OpenRouter/DeepInfra response parsing, DeepInfra cent handling,
//  month-range generation, and remote.json provider-ID mapping. Network and
//  keychain reads live in the service itself and are not exercised here.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ProviderSpendServiceTests {

    // MARK: - OpenRouter

    @Test func openRouterLineExtractsDailyUSD() {
        let line = ProviderSpendService.openRouterLine(
            from: ["usage_daily": 0.1234, "usage_weekly": 2.5, "usage": 9.99])
        #expect(line.configured)
        #expect(line.usd == 0.1234)
        #expect(line.label == "Today")
        #expect(line.note == nil)
    }

    @Test func openRouterLineMissingFieldIsNil() {
        let line = ProviderSpendService.openRouterLine(from: [:])
        #expect(line.configured)
        #expect(line.usd == nil)
    }

    // MARK: - DeepInfra

    @Test func deepInfraLineSumsMonthlyCents() {
        let line = ProviderSpendService.deepInfraLine(from: [
            "months": [
                ["period": "2026.08", "total_cost": 100],
                ["period": "2026.09", "total_cost": 250],
            ]
        ])
        // 350 cents -> $3.50.
        #expect(line.usd == 3.5)
        #expect(line.configured)
        #expect(line.label == "This month")
        #expect(line.note == "DeepInfra reports monthly totals only")
    }

    @Test func deepInfraLineAcceptsDoubleAndStringCents() {
        let line = ProviderSpendService.deepInfraLine(from: [
            "months": [
                ["period": "2026.09", "total_cost": 100.0],
                ["period": "2026.10", "total_cost": "050"],
            ]
        ])
        #expect(line.usd == 1.5)
    }

    @Test func deepInfraLineEmptyMonthsIsZeroWithoutNote() {
        let line = ProviderSpendService.deepInfraLine(from: ["months": []])
        #expect(line.usd == 0)
        #expect(line.note == nil)
    }

    @Test func deepInfraLineMissingMonthsIsZero() {
        let line = ProviderSpendService.deepInfraLine(from: [:])
        #expect(line.usd == 0)
    }

    // MARK: - Month ranges

    @Test func monthsInRangeSpansMonthBoundary() {
        // Build dates in the LOCAL calendar (monthsInRange uses Calendar.current)
        // at clearly-different-month times so the assertion is timezone-proof.
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 23))!
        let end = cal.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 1))!
        let months = ProviderSpendService.monthsInRange(start: start, end: end)
        #expect(months == ["2026.08", "2026.09"])
    }

    @Test func monthsInRangeSingleMonth() {
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!
        let months = ProviderSpendService.monthsInRange(start: date, end: date)
        #expect(months == ["2026.07"])
    }

    // MARK: - Provider ID mapping

    @Test func providerUUIDsParseRemoteJson() {
        let json = """
            {"providers": [
                {"name": "OpenRouter", "id": "4C02D654-8275-4AA9-9405-47EE2F9125A2"},
                {"name": "DeepInfra", "id": "A4D9ACDB-44DE-40F7-AFCC-9855ABBE893F"}
            ]}
            """
        let map = ProviderSpendService.providerUUIDs(parsing: Data(json.utf8))
        #expect(map["OpenRouter"] == "4C02D654-8275-4AA9-9405-47EE2F9125A2")
        #expect(map["DeepInfra"] == "A4D9ACDB-44DE-40F7-AFCC-9855ABBE893F")
        #expect(map.count == 2)
    }

    @Test func providerUUIDsHandlesEmptyProviders() {
        let map = ProviderSpendService.providerUUIDs(parsing: Data("{}".utf8))
        #expect(map.isEmpty)
    }

    @Test func providerUUIDsIgnoresRowsMissingNameOrId() {
        let json = """
            {"providers": [
                {"name": "OpenRouter"},
                {"id": "4C02D654-8275-4AA9-9405-47EE2F9125A2"}
            ]}
            """
        let map = ProviderSpendService.providerUUIDs(parsing: Data(json.utf8))
        #expect(map.isEmpty)
    }
}
