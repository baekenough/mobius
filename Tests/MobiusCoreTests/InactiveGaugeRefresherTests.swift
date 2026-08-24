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
        /// 쓰기 실패 주입 (디스크 풀 등) — capture-or-nothing 계약 검증용.
        var failWrites = false
        /// 락 진입 시점에 호출 — "HTTP 왕복 중 스냅샷이 바뀌는" 상황을 주입한다.
        /// 자기 자신을 인자로 넘겨, 훅이 스토어를 캡처해 참조 순환을 만들지 않게 한다.
        var onLockEnter: ((FakeStore) -> Void)?

        func secretData(for id: UUID) throws -> Data? { secrets[id] }

        struct WriteFailed: Error {}

        func setSecretData(_ data: Data, for id: UUID) throws {
            if failWrites { throw WriteFailed() }
            secrets[id] = data
            writes.append((id, data))
        }

        @discardableResult
        func withCredentialLock<T>(_ id: UUID, _ body: () throws -> T) rethrows -> T {
            onLockEnter?(self)
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
    /// 테스트는 전부 메인 액터에서 직렬로 돌아 실제 경합은 없다.
    final class Counters: @unchecked Sendable {
        var refreshCalls = 0
        var probedBytes: [Data] = []
    }

    /// @Sendable 스텁 클로저가 관찰값을 쓰기 위한 상자 — 지역 var 직접 변형(Swift 6 금지)을 피한다.
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
        init(_ value: T) { self.stored = value }
    }

    /// 1회성 게이트 — 스텁이 특정 지점에 도달했음을 테스트에 알리고(open), 테스트가 열어줄 때까지
    /// 스텁을 세워둔다(wait). 취소 타이밍을 sleep 없이 결정론적으로 고정하기 위한 것이다.
    /// 스텁 본문은 nonisolated async 컨텍스트에서 돌므로 실제로 스레드 안전해야 한다.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            lock.lock()
            opened = true
            let pending = waiters
            waiters = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened { lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
            }
        }
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
        let becameActive = Box(false)
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in becameActive.value = true; return .refreshed(rotatedSecret) },
                                probe: { _ in .usage(makeSnapshot(40)) })

        let updated = await sut.refreshRound(targets: [target], now: now,
                                             activeID: { becameActive.value ? accountID : nil },
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
        store.onLockEnter = { $0.secrets[accountID] = relogin }
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
        let seenEmail = Box<String?>(nil)
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in .refreshed(rotatedSecret) },
                                accepts: { _, email in seenEmail.value = email; return true })

        _ = await sut.refreshRound(targets: [target], now: now,
                                   activeID: { nil }, excludedID: { nil })

        XCTAssertEqual(seenEmail.value, email, "검증 기준은 그 계정의 이메일이어야 한다")
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
            XCTAssertEqual(counters.refreshCalls, 0, "만료 전이므로 회전 시도 자체가 없다")
        }
    }

    /// refresh는 성공해 회전본이 저장됐는데 그 직후 조회가 실패한 경우. 저장을 되돌리지 않고
    /// 게이지만 마지막 값에 남는다 — 다음 라운드는 신선한 토큰으로 곧바로 조회한다.
    func testProbeFailureAfterSuccessfulRefreshKeepsRotatedSnapshot() async {
        let store = FakeStore(); store.secrets[id] = fresh
        let counters = Counters()
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in .refreshed(rotatedSecret) },
                                probe: { _ in .transient })

        let updated = await sut.refreshRound(targets: [target], now: now,
                                             activeID: { nil }, excludedID: { nil })

        XCTAssertTrue(updated.isEmpty, "게이지는 마지막 값에 남는다")
        XCTAssertEqual(store.secrets[id], rotatedSecret, "조회 실패가 저장된 회전본을 되돌리지 않는다")
        XCTAssertNil(sut.lastRefreshAttempt(id), "refresh는 성공했으므로 쿨다운은 해제 상태")
        XCTAssertNil(sut.deadBackoffUntil(id), "조회 실패는 죽은 토큰이 아니므로 백오프 없음")
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

    /// 순서만 보면 "라운드 끝에 모아서 두 번 호출"과 구분되지 않는다. 조회와 반영을 한 로그에
    /// 섞어 적어, a의 게이지가 **b를 조회하기 전에** 반영됨을 고정한다.
    func testOnUsageFiresBeforeTheNextAccountIsProbed() async {
        let a = UUID(), b = UUID()
        let store = FakeStore()
        store.secrets[a] = fresh; store.secrets[b] = fresh
        let counters = Counters()
        let log = Box<[String]>([])
        let sut = makeRefresher(store: store, counters: counters, expired: false,
                                probe: { _ in log.value.append("probe"); return .usage(makeSnapshot(5)) })

        var order: [UUID] = []
        let updated = await sut.refreshRound(
            targets: [.init(id: a, emailAddress: email), .init(id: b, emailAddress: email)],
            now: now, activeID: { nil }, excludedID: { nil },
            onUsage: { id, _ in log.value.append("usage"); order.append(id) })

        XCTAssertEqual(log.value, ["probe", "usage", "probe", "usage"],
                       "반영이 다음 계정 조회 뒤로 밀리면 [probe, probe, usage, usage]가 된다")
        XCTAssertEqual(order, [a, b], "계정 순서대로")
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

    // MARK: 취소 — 쉴드는 회전을 완주시키고, 루프는 다음 계정으로 넘어가지 않는다

    /// PR #7 리뷰의 차단 지적(회전 유실 brick 창)에 대응하는 불변식. 전환 진입의 quiesce가
    /// 라운드를 취소해도 **진행 중인 refresh POST는 끊기지 않고 저장까지 완주**해야 한다.
    /// 중간에 끊기면 서버는 회전을 커밋했는데 회전본은 유실돼 그 계정이 벽돌이 된다.
    func testRefreshIsShieldedFromCancellationAndStillStoresRotated() async {
        let store = FakeStore(); store.secrets[accountID] = freshSecret
        let counters = Counters()
        let entered = Gate(), mayReturn = Gate()
        let cancelledInsideRefresh = Box(true)
        let sut = makeRefresher(
            store: store, counters: counters, expired: true,
            refresh: { _ in
                entered.open()                                  // 테스트에 "POST 발사됨" 알림
                await mayReturn.wait()                          // 테스트가 취소를 걸 시간을 준다
                cancelledInsideRefresh.value = Task.isCancelled  // 쉴드가 취소를 막았는가
                return .refreshed(rotatedSecret)
            },
            probe: { _ in .usage(makeSnapshot(9)) })

        let round = Task { @MainActor in
            await sut.refreshRound(targets: [self.target], now: fixedNow,
                                   activeID: { nil }, excludedID: { nil })
        }
        await entered.wait()
        round.cancel()          // ← 전환 진입 시 quiesce가 하는 일
        mayReturn.open()
        let updated = await round.value

        XCTAssertFalse(cancelledInsideRefresh.value,
                       "쉴드 Task는 상위 취소를 상속하지 않아야 한다")
        XCTAssertEqual(store.secrets[accountID], rotatedSecret,
                       "취소가 회전본 저장을 막으면 그 계정은 벽돌이 된다")
        XCTAssertEqual(updated[accountID]?.fiveHourPercent, 9)
    }

    /// 취소의 효력은 "다음 계정으로 진입하지 않는다"까지다 — 대기가 현재 계정의 진행 중 HTTP
    /// 완료까지로 바운드된다는 quiesce 설계의 근거.
    func testCancellationStopsBeforeEnteringTheNextAccount() async {
        let first = UUID(), second = UUID()
        let store = FakeStore()
        store.secrets[first] = freshSecret
        store.secrets[second] = freshSecret
        let counters = Counters()
        let entered = Gate(), mayReturn = Gate()
        let sut = makeRefresher(
            store: store, counters: counters, expired: false,
            probe: { _ in
                entered.open()
                await mayReturn.wait()
                return .usage(makeSnapshot(3))
            })

        let round = Task { @MainActor in
            await sut.refreshRound(
                targets: [.init(id: first, emailAddress: accountEmail),
                          .init(id: second, emailAddress: accountEmail)],
                now: fixedNow, activeID: { nil }, excludedID: { nil })
        }
        await entered.wait()    // 첫 계정 조회 진행 중
        round.cancel()
        mayReturn.open()
        let updated = await round.value

        XCTAssertEqual(counters.probedBytes.count, 1, "두 번째 계정에는 진입하지 않는다")
        XCTAssertEqual(updated.count, 1, "첫 계정의 결과는 버리지 않는다")
        XCTAssertNotNil(updated[first])
        XCTAssertNil(updated[second])
    }

    // MARK: 저장 실패 — 성공으로 둔갑시키지 않는다 (brick 경로)

    /// PR #7 리뷰의 두 번째 차단 지적. 회전본 쓰기가 실패했는데 성공으로 처리하면, 스냅샷에는
    /// 이미 서버에서 소비된 구 refresh 토큰이 남은 채 쿨다운까지 풀려 그 계정이 벽돌이 된다.
    /// `try?`로 되돌아가면 이 테스트가 죽는다.
    func testStoreFailureIsNotTreatedAsSuccess() async {
        let store = FakeStore()
        store.secrets[id] = fresh
        store.failWrites = true
        let counters = Counters()
        let sut = makeRefresher(store: store, counters: counters, expired: true,
                                refresh: { _ in .refreshed(rotatedSecret) },
                                probe: { _ in .usage(makeSnapshot(50)) })

        let updated = await sut.refreshRound(targets: [target], now: now,
                                             activeID: { nil }, excludedID: { nil })

        XCTAssertTrue(updated.isEmpty, "저장 못 한 회전본으로 게이지를 갱신하면 안 된다")
        XCTAssertTrue(counters.probedBytes.isEmpty, "저장 실패 시 이번 라운드는 그 계정을 건너뛴다")
        XCTAssertEqual(store.secrets[id], fresh, "저장 스냅샷은 그대로")
        XCTAssertEqual(sut.lastRefreshAttempt(id), now,
                       "성공이 아니므로 재시도 쿨다운이 해제되면 안 된다")
    }
}
