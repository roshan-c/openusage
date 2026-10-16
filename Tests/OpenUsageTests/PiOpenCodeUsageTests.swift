import XCTest
@testable import OpenUsage

/// Real JSONL parsing with isolated scan caches: pi's Go/Zen usage reaches the OpenCode card.
@MainActor
final class PiOpenCodeUsageTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private func line(id: String, provider: String, tokens: Int = 150, cost: String = "0.5") -> String {
        """
        {"type":"message","id":"\(id)","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"\(provider)","model":"composer-2.5","usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":\(tokens),"cost":{"total":\(cost)}}}}
        """
    }

    private func fixture(_ lines: [String]) throws -> (URL, PiUsageScanner) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8
        )
        return (directory, PiUsageScanner(
            environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": directory.path]),
            incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>()
        ))
    }

    private func provider(
        pi: PiUsageScanner, sqlite: OpenCodeFakeSQLite = OpenCodeFakeSQLite(), paths: [String] = []
    ) -> OpenCodeProvider {
        let now = self.now
        return OpenCodeProvider(
            authStore: openCodeAuthStore(files: FakeFiles(), sqlite: OpenCodeFakeSQLite(), databasePaths: []),
            usageClient: OpenCodeUsageClient(http: FakeHTTPClient(
                response: HTTPResponse(statusCode: 500, headers: [:], body: Data())
            )),
            usageScanner: OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { paths }),
            piUsageScanner: pi,
            now: { now }
        )
    }

    func testPiOnlyGoAndZenProduceHistoryTilesAndDetectionWithoutOpenCodeLogin() async throws {
        let (_, pi) = try fixture([
            line(id: "go", provider: "opencode-go"),
            line(id: "zen", provider: "opencode", tokens: 250, cost: "0.25"),
            line(id: "codex", provider: "openai-codex", tokens: 900, cost: "9"),
            line(id: "claude", provider: "anthropic", tokens: 800, cost: "8")
        ])
        let runtime = provider(pi: pi)
        let detected = await runtime.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await runtime.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        let day = try XCTUnwrap(snapshot.usageHistory?.series.daily.first)
        XCTAssertEqual(day.totalTokens, 400)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.75, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.usageHistory?.modelUsage?.daily.first?.models.first?.totalTokens, 400)
    }

    func testNativeAndPiUsageAreMergedAndReplayedPiMessagesCountOnce() async throws {
        let (directory, pi) = try fixture([line(id: "go", provider: "opencode-go")])
        try line(id: "go", provider: "opencode-go").write(
            to: directory.appendingPathComponent("fork.jsonl"), atomically: true, encoding: .utf8
        )
        let path = "/oc/opencode.db"
        let db = "[" + openCodeRow("2026-07-12T11:00:00.000Z", "2.0", 1000, "native-model", "opencode") + "]"
        let runtime = provider(pi: pi, sqlite: OpenCodeFakeSQLite(data: [path: db]), paths: [path])
        for _ in 0..<2 {
            let snapshot = await runtime.refresh()
            let day = try XCTUnwrap(snapshot.usageHistory?.series.daily.first)
            XCTAssertEqual(day.totalTokens, 1150)
            XCTAssertEqual(try XCTUnwrap(day.costUSD), 2.5, accuracy: 0.000_001)
            XCTAssertEqual(snapshot.usageHistory?.modelUsage?.daily.first?.models.count, 2)
        }
    }

    func testRecordedZeroCostIsKeptEvenWhenTheModelHasCatalogPricing() throws {
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [
                "composer-2.5": ModelRates(inputPerMillion: 10, outputPerMillion: 20,
                                          cacheWritePerMillion: 10, cacheReadPerMillion: 1)
            ]),
            secondary: PricingCatalog(entries: [:])
        )
        for provider in ["opencode-go", "opencode"] {
            let entry = try XCTUnwrap(PiUsageScanner.parseLine(Data(line(
                id: provider, provider: provider, cost: "0"
            ).utf8)))
            XCTAssertEqual(entry.cardID, "opencode")
            let scan = PiUsageScanner.aggregate(
                entries: [entry], cardID: "opencode", since: .distantPast, pricing: pricing
            )
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 150)
            XCTAssertEqual(scan.series.daily.first?.costUSD, 0)
            XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
        }
    }

    func testOtherPiProvidersDoNotDetectOpenCodeOrHideMissingCredentials() async throws {
        let (_, pi) = try fixture([line(id: "claude", provider: "anthropic")])
        let runtime = provider(pi: pi)
        let detected = await runtime.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await runtime.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertNil(snapshot.usageHistory)
    }

    func testPiUsageRemainsAvailableWhenNativeDatabaseCannotBeRead() async throws {
        let (_, pi) = try fixture([line(id: "go", provider: "opencode-go")])
        let path = "/oc/opencode.db"
        let snapshot = await provider(
            pi: pi, sqlite: OpenCodeFakeSQLite(failing: [path]), paths: [path]
        ).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 150)
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }
}
