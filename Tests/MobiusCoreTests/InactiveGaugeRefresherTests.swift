import XCTest
@testable import MobiusCore

// 픽스처는 파일 스코프에 둔다 — @Sendable 스텁 클로저 안에서 쓰이므로 액터 격리 밖이어야 한다.
private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
private let accountID = UUID()
private let accountEmail = "dev@corp.com"
private let freshSecret = Data("fresh-token".utf8)
private let rotatedSecret = Data("rotated-token".utf8)

private func makeSnapshot(_ percent: Double) -> UsageSnapshot {
    UsageSnapshot(fiveHourPercent: percent, fiveHourResetsAt: nil,
                  sevenDayPercent: nil, sevenDayResetsAt: nil, fetchedAt: fixedNow)
}

/// 비활성 게이지 루프의 자격증명 안전 불변식 검증. 이 루프는 원래 `AppState`(테스트 타깃 없는
/// MobiusApp)에 인라인돼 있어 TOCTOU 재확인·capture-or-nothing 저장이 전부 테스트 밖에 있었다.
/// 코어로 내려온 지금은 네트워크·파일 없이 전부 재현한다.
@MainActor
final class InactiveGaugeRefresherTests: XCTestCase {

    // MARK: 테스트 더블

    /// 인메모리 비밀 스냅샷 저장소. `withCredentialLock` 안에서 무엇을 읽고 썼는지 관찰한다.
    final class FakeStore: GaugeSecretStore, @unchecked Sendable {
        var secrets: [UUID: Data] = [:]
        var writes: [(UUID, Data)] = []
        /// 락 진입 시점에 호출 — "HTTP 왕복 중 스냅샷이 바뀌는" 상황을 주입한다.
        var onLockEnter: (() -> Void)?

        func secretData(for id: UUID) throws -> Data? { secrets[id] }

        func setSecretData(_ data: Data, for id: UUID) throws {
            secrets[id] = data
            writes.append((id, data))
        }

        @discardableResult
        func withCredentialLock<T>(_ id: UUID, _ body: () throws -> T) rethrows -> T {
            onLockEnter?()
            return try body()
        }
    }

    /// 프로바이더 어댑터 스텁 — 만료/refresh/검증/probe를 전부 주입한다.
    struct FakeAdapter: InactiveGaugeProvider {
        let provider = Provider.codex
        var expiry: @Sendable (Data) -> Date?
        var refreshResult: @Sendable (Data) async -> InactiveGaugeRefreshOutcome
        var accepts: @Sendable (Data, String) -> Bool = { _, _ in true }
        var probeResult: @Sendable (Data) async -> InactiveGaugeProbeOutcome

        func accessTokenExpiry(fromSecret secret: Data) -> Date? { expiry(secret) }
        func refresh(secret: Data) async -> InactiveGaugeRefreshOutcome { await refreshResult(secret) }
        func acceptsRotatedSecret(_ rotated: Data, forEmail email: String) -> Bool { accepts(rotated, email) }
        func probeUsage(secret: Data, now: Date) async -> InactiveGaugeProbeOutcome { await probeResult(secret) }
    }

    // MARK: 픽스처

    let now = fixedNow
    let id = accountID
    let email = accountEmail
    var target: InactiveGaugeRefresher.Target { .init(id: id, emailAddress: email) }

    let fresh = freshSecret
    let rotated = rotatedSecret

    /// 관찰용 카운터를 공유하기 위한 참조 상자 (스텁이 struct라 값 캡처가 안 되므로).
    final class Counters: @unchecked Sendable {
        var refreshCalls = 0
        var probedBytes: [Data] = []
    }

    private func makeRefresher(store: FakeStore,
                               counters: Counters,
                               expired: Bool,
                               refresh: @escaping @Sendable (Data) async -> InactiveGaugeRefreshOutcome
                                   = { _ in .transient },
                               accepts: @escaping @Sendable (Data, String) -> Bool = { _, _ in true },
                               probe: @escaping @Sendable (Data) async -> InactiveGaugeProbeOutcome
                                   = { _ in .stale },
                               retryCooldown: TimeInterval = 600) -> InactiveGaugeRefresher {
        let expiryDate = expired ? now.addingTimeInterval(-60) : now.addingTimeInterval(3600)
        let adapter = FakeAdapter(
            expiry: { _ in expiryDate },
            refreshResult: { secret in counters.refreshCalls += 1; return await refresh(secret) },
            accepts: accepts,
            probeResult: { secret in counters.probedBytes.append(secret); return await probe(secret) })
        return InactiveGaugeRefresher(adapter: adapter, store: store,
                                      retryCooldown: retryCooldown,
                                      deadRefreshCooldown: 24 * 3600)
    }

    // MARK: 만료되지 않은 토큰 — refresh 없이 조회만

    func testFreshTokenSkipsRefreshAndProbesStoredBytes() async {
        let store = FakeStore(); store.secrets[id] = fresh
        let counters = Counters()
        let sut = makeRefresher(store: store, counters: counters, expired: false,
                                probe: { _ in .usage(makeSnapshot(12)) })

        let updated = await sut.refreshRound(targets: [target], now: now,
                                             activeID: { nil }, excludedID: { nil })

        XCTAssertEqual(counters.refreshCalls, 0, "만료 전에는 회전시키지 않는다")
        XCTAssertEqual(counters.probedBytes, [fresh])
        XCTAssertEqual(updated[id]?.fiveHourPercent, 12)
        XCTAssertTrue(store.writes.isEmpty, "게이지 조회만으로 스냅샷을 쓰지 않는다")
    }

    // MARK: 활성/전환중 계정은 절대 refresh하지 않는다 (클로버 방지)

    func testActiveAccountIsNeverRefreshed() async {
        let store = FakeStore(); store.secrets[id] = fresh
        let counters = Counters()
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in .refreshed(rotatedSecret) })

        _ = await sut.refreshRound(targets: [target], now: now,
                                   activeID: { accountID }, excludedID: { nil })

        XCTAssertEqual(counters.refreshCalls, 0, "활성 계정 refresh = 실행 중 세션 파괴")
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testPendingSwitchTargetIsNeverRefreshed() async {
        let store = FakeStore(); store.secrets[id] = fresh
        let counters = Counters()
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in .refreshed(rotatedSecret) })

        _ = await sut.refreshRound(targets: [target], now: now,
                                   activeID: { nil }, excludedID: { accountID })

        XCTAssertEqual(counters.refreshCalls, 0, "전환 진행 중인 계정은 건드리지 않는다")
    }

    // MARK: 만료 → refresh 성공 → 회전본 저장 후 그 바이트로 조회

    func testExpiredTokenRefreshesStoresRotatedAndProbesWithIt() async {
        let store = FakeStore(); store.secrets[id] = fresh
        let counters = Counters()
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in .refreshed(rotatedSecret) },
                                probe: { _ in .usage(makeSnapshot(40)) })

        let updated = await sut.refreshRound(targets: [target], now: now,
                                             activeID: { nil }, excludedID: { nil })

        XCTAssertEqual(counters.refreshCalls, 1)
        XCTAssertEqual(store.secrets[id], rotated, "회전본이 원자 저장돼야 한다")
        XCTAssertEqual(counters.probedBytes, [rotated], "조회는 갱신된 바이트로")
        XCTAssertEqual(updated[id]?.fiveHourPercent, 40)
        XCTAssertNil(sut.lastRefreshAttempt(id), "성공하면 재시도 쿨다운이 해제된다")
    }

    // MARK: TOCTOU — HTTP 왕복 중 그 계정이 활성이 되면 회전본을 버린다

    func testRotatedSecretDiscardedWhenAccountBecameActiveDuringRefresh() async {
        let store = FakeStore(); store.secrets[id] = fresh
        let counters = Counters()
        var becameActive = false
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in becameActive = true; return .refreshed(rotatedSecret) },
                                probe: { _ in .usage(makeSnapshot(40)) })

        let updated = await sut.refreshRound(targets: [target], now: now,
                                             activeID: { becameActive ? accountID : nil },
                                             excludedID: { nil })

        XCTAssertTrue(store.writes.isEmpty, "활성이 됐으면 라이브 자격증명이 authoritative")
        XCTAssertEqual(store.secrets[id], fresh, "기존 스냅샷 보존")
        XCTAssertTrue(counters.probedBytes.isEmpty, "이번 라운드는 그 계정을 건너뛴다")
        XCTAssertTrue(updated.isEmpty)
    }

    // MARK: 왕복 중 adopt/재로그인으로 스냅샷이 바뀌면 구 회전본으로 덮지 않는다

    func testRotatedSecretDiscardedWhenSnapshotChangedDuringRefresh() async {
        let store = FakeStore(); store.secrets[id] = fresh
        let relogin = Data("relogin-token".utf8)
        store.onLockEnter = { store.secrets[accountID] = relogin }
        let counters = Counters()
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in .refreshed(rotatedSecret) })

        _ = await sut.refreshRound(targets: [target], now: now,
                                   activeID: { nil }, excludedID: { nil })

        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(store.secrets[id], relogin, "신규 로그인 스냅샷을 구 세션 회전본으로 덮지 않는다")
    }

    // MARK: 신원/형태 검증 실패 — 손상·타 계정 바이트가 스냅샷을 덮지 못한다

    func testRotatedSecretRejectedByAdapterIsNotStored() async {
        let store = FakeStore(); store.secrets[id] = fresh
        let counters = Counters()
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in .refreshed(rotatedSecret) },
                                accepts: { _, _ in false })

        _ = await sut.refreshRound(targets: [target], now: now,
                                   activeID: { nil }, excludedID: { nil })

        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(store.secrets[id], fresh)
        XCTAssertTrue(counters.probedBytes.isEmpty)
    }

    func testAcceptsRotatedSecretReceivesProfileEmail() async {
        let store = FakeStore(); store.secrets[id] = fresh
        let counters = Counters()
        var seenEmail: String?
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in .refreshed(rotatedSecret) },
                                accepts: { _, email in seenEmail = email; return true })

        _ = await sut.refreshRound(targets: [target], now: now,
                                   activeID: { nil }, excludedID: { nil })

        XCTAssertEqual(seenEmail, email, "검증 기준은 그 계정의 이메일이어야 한다")
    }

    // MARK: 죽은 refresh 토큰 — 마킹 없이 긴 백오프만

    func testInvalidatedRefreshSetsLongBackoffAndMarksNothing() async {
        let store = FakeStore(); store.secrets[id] = fresh
        let counters = Counters()
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in .invalidated })

        let updated = await sut.refreshRound(targets: [target], now: now,
                                             activeID: { nil }, excludedID: { nil })

        XCTAssertTrue(updated.isEmpty)
        XCTAssertTrue(counters.probedBytes.isEmpty, "죽은 토큰은 조회도 하지 않는다")
        XCTAssertEqual(sut.deadBackoffUntil(id), now.addingTimeInterval(24 * 3600))
        XCTAssertTrue(store.writes.isEmpty, "게이지 전용 — 아무것도 마킹하지 않는다")
    }

    func testDeadBackoffSkipsAccountUntilItExpires() async {
        let store = FakeStore(); store.secrets[id] = fresh
        let counters = Counters()
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in .invalidated })

        _ = await sut.refreshRound(targets: [target], now: now,
                                   activeID: { nil }, excludedID: { nil })
        XCTAssertEqual(counters.refreshCalls, 1)

        // 백오프 안 — 아예 건너뛴다
        _ = await sut.refreshRound(targets: [target], now: now.addingTimeInterval(3600),
                                   activeID: { nil }, excludedID: { nil })
        XCTAssertEqual(counters.refreshCalls, 1)

        // 백오프가 지나면 다시 시도한다
        _ = await sut.refreshRound(targets: [target], now: now.addingTimeInterval(25 * 3600),
                                   activeID: { nil }, excludedID: { nil })
        XCTAssertEqual(counters.refreshCalls, 2)
    }

    // MARK: transient 실패 — 계정당 재시도 쿨다운으로 백오프

    func testTransientFailureBacksOffUntilRetryCooldownElapses() async {
        let store = FakeStore(); store.secrets[id] = fresh
        let counters = Counters()
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in .transient }, retryCooldown: 600)

        _ = await sut.refreshRound(targets: [target], now: now,
                                   activeID: { nil }, excludedID: { nil })
        XCTAssertEqual(counters.refreshCalls, 1)
        XCTAssertTrue(counters.probedBytes.isEmpty, "만료 토큰으로는 조회하지 않는다")

        // 쿨다운 안 — 팝오버를 다시 열어도 회전 시도를 반복하지 않는다
        _ = await sut.refreshRound(targets: [target], now: now.addingTimeInterval(300),
                                   activeID: { nil }, excludedID: { nil })
        XCTAssertEqual(counters.refreshCalls, 1)

        // 쿨다운 경과 — 재시도
        _ = await sut.refreshRound(targets: [target], now: now.addingTimeInterval(601),
                                   activeID: { nil }, excludedID: { nil })
        XCTAssertEqual(counters.refreshCalls, 2)
    }

    // MARK: 조회 실패는 게이지를 마지막 값에 둔다

    func testProbeStaleOrTransientYieldsNoUsageAndNoMarking() async {
        for outcome in [InactiveGaugeProbeOutcome.stale, .transient] {
            let store = FakeStore(); store.secrets[id] = fresh
            let counters = Counters()
            let sut = makeRefresher(store: store, counters: counters, expired: false,
                                    probe: { _ in outcome })

            let updated = await sut.refreshRound(targets: [target], now: now,
                                                 activeID: { nil }, excludedID: { nil })

            XCTAssertTrue(updated.isEmpty)
            XCTAssertTrue(store.writes.isEmpty)
        }
    }

    // MARK: 여러 계정 — 하나가 실패해도 나머지는 계속 돈다

    func testOneAccountFailureDoesNotStopTheRound() async {
        let dead = UUID(), good = UUID()
        let store = FakeStore()
        store.secrets[dead] = Data("dead".utf8)
        store.secrets[good] = fresh
        let counters = Counters()
        let adapter = FakeAdapter(
            expiry: { $0 == Data("dead".utf8) ? fixedNow.addingTimeInterval(-60)
                                              : fixedNow.addingTimeInterval(3600) },
            refreshResult: { _ in counters.refreshCalls += 1; return .invalidated },
            probeResult: { secret in counters.probedBytes.append(secret); return .usage(makeSnapshot(7)) })
        let sut = InactiveGaugeRefresher(adapter: adapter, store: store,
                                         retryCooldown: 600, deadRefreshCooldown: 24 * 3600)

        let updated = await sut.refreshRound(
            targets: [.init(id: dead, emailAddress: email), .init(id: good, emailAddress: email)],
            now: now, activeID: { nil }, excludedID: { nil })

        XCTAssertNil(updated[dead])
        XCTAssertEqual(updated[good]?.fiveHourPercent, 7)
    }

    // MARK: onUsage — 라운드가 끝나기 전에 계정 단위로 즉시 반영된다

    func testOnUsageFiresPerAccountDuringTheRound() async {
        let a = UUID(), b = UUID()
        let store = FakeStore()
        store.secrets[a] = fresh; store.secrets[b] = fresh
        let counters = Counters()
        let sut = makeRefresher(store: store, counters: counters, expired: false,
                                probe: { _ in .usage(makeSnapshot(5)) })

        var order: [UUID] = []
        let updated = await sut.refreshRound(
            targets: [.init(id: a, emailAddress: email), .init(id: b, emailAddress: email)],
            now: now, activeID: { nil }, excludedID: { nil },
            onUsage: { id, _ in order.append(id) })

        XCTAssertEqual(order, [a, b], "게이지가 계정 순서대로 하나씩 차오른다")
        XCTAssertEqual(updated.count, 2)
    }

    // MARK: 스냅샷이 없는 계정은 조용히 건너뛴다

    func testMissingSecretSkipsAccount() async {
        let store = FakeStore()   // 비어 있음
        let counters = Counters()
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in .refreshed(rotatedSecret) })

        let updated = await sut.refreshRound(targets: [target], now: now,
                                             activeID: { nil }, excludedID: { nil })

        XCTAssertTrue(updated.isEmpty)
        XCTAssertEqual(counters.refreshCalls, 0)
    }
}
