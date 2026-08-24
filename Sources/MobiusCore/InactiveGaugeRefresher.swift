import Foundation

/// 비활성 계정 게이지 갱신에 필요한 **프로바이더별 능력**. `InactiveGaugeRefresher`가 이 네 가지만
/// 보고 "만료 판정 → (필요하면) refresh → 원자 검증 저장 → usage 조회" 루프를 돌린다.
///
/// ★ **게이지 전용 방화벽**(CLAUDE.md: Codex 재인증 자동 감지는 의도적으로 미구현):
/// 이 프로토콜의 어떤 구현도 `setNeedsReauth`·`AutoSwitchEngine`·`rateLimit` 기록을 유발해선
/// 안 된다. 실패는 전부 "게이지를 마지막 값에 둔다"로 끝난다 — 시끄러운 401이 자동 전환의
/// 폴백 후보를 죽이면 안 되기 때문이다.
public protocol InactiveGaugeProvider: Sendable {
    var provider: Provider { get }

    /// 저장 스냅샷 바이트에서 access 토큰 만료를 읽는다. 못 읽으면 nil — 만료 판정을 건너뛰고
    /// 그냥 조회한다(401은 무해하게 stale로 끝난다).
    func accessTokenExpiry(fromSecret secret: Data) -> Date?

    /// 만료된 스냅샷을 되살린다. 200이면 회전본 바이트를 돌려주고, 그 외에는 아무것도 돌려주지
    /// 않는다(기존 스냅샷 보존 — 회전 토큰 유실 방지의 capture-or-nothing 계약).
    func refresh(secret: Data) async -> InactiveGaugeRefreshOutcome

    /// 회전본을 저장 스냅샷으로 받아들여도 되는가. **credential lock 안에서 동기로 호출**되므로
    /// 네트워크·파일 접근 없는 순수 판정이어야 한다(형태 인식 + 신원 일치 + refresh 토큰 존재).
    func acceptsRotatedSecret(_ rotated: Data, forEmail email: String) -> Bool

    /// 사용량 조회. **읽기 전용** — 자격증명을 쓰지 않고 토큰을 회전시키지 않는다.
    func probeUsage(secret: Data, now: Date) async -> InactiveGaugeProbeOutcome
}

/// 게이지 전용 refresh 결과. 재인증(needsReauth) 케이스가 없다 — 죽은 토큰도 마킹이 아니라
/// 긴 백오프로만 처리한다.
public enum InactiveGaugeRefreshOutcome: Equatable, Sendable {
    /// 200 — 회전된 토큰을 반영한 새 스냅샷 바이트. 호출측이 (활성 재확인 + 검증 후) 원자 저장한다.
    case refreshed(Data)
    /// refresh 토큰 폐기(세션 종료) — refresh로는 되살릴 수 없다. 아무것도 마킹하지 않고
    /// 긴 쿨다운으로 물러난다.
    case invalidated
    /// 네트워크/5xx/기타 — 일시적. 죽음으로 단정하지 않고 다음 기회에 재시도.
    case transient
}

/// 게이지 전용 조회 결과. 어떤 실패도 계정을 죽었다고 마킹하지 않는다.
public enum InactiveGaugeProbeOutcome: Equatable, Sendable {
    case usage(UsageSnapshot)   // 200 — 게이지 갱신
    case stale                  // 401/403 또는 만료 토큰 — 게이지를 마지막 값에 둔다(무해)
    case transient              // 네트워크/일시 오류 — 다음 기회에 재시도
}

/// `InactiveGaugeRefresher`가 쓰는 비밀 스냅샷 저장소의 최소 계약. `AccountStore`가 그대로
/// 만족하며, 테스트는 인메모리 구현을 넣어 네트워크·파일 없이 루프를 검증한다.
public protocol GaugeSecretStore: AnyObject, Sendable {
    func secretData(for id: UUID) throws -> Data?
    func setSecretData(_ data: Data, for id: UUID) throws
    @discardableResult
    func withCredentialLock<T>(_ id: UUID, _ body: () throws -> T) rethrows -> T
}

extension AccountStore: GaugeSecretStore {}

/// **비활성 계정 게이지 갱신 루프** — 프로바이더 어댑터 하나만 갈아끼우면 재사용된다.
///
/// 원래 이 루프는 `AppState`(테스트 타깃이 없는 `MobiusApp`)에 Codex 전용으로 인라인돼 있었다.
/// TOCTOU 재확인·capture-or-nothing 저장 같은 **자격증명 안전 불변식이 테스트 밖에** 있었고,
/// 세 번째 프로바이더는 이 120여 줄을 통째로 복제해야 했다. 코어로 끌어내려 두 문제를 함께 푼다.
///
/// `@MainActor`는 **기존 실행 컨텍스트를 그대로 보존한 것**이다 — 이 루프는 `AppState`(메인 액터)
/// 안에 있었고, 호출측이 활성 계정 판정을 동기 클로저로 넘긴다. 스냅샷 읽기/쓰기가 메인 스레드에서
/// 도는 것도 기존과 같다(계정당 수 KB). 다른 컨텍스트로 옮기는 것은 `activeID` 조회의 동기 계약부터
/// 바꿔야 하는 별개 변경이라 이 PR에서는 하지 않았다.
/// (`AccountStore`의 credential lock은 NSLock이라 어느 스레드에서 쥐어도 상호배제된다 — 액터 선택과
/// 무관하다. 여기서 @MainActor를 고른 이유는 락이 아니라 위의 호출 계약이다.)
///
/// 대상은 **비활성 계정만**이다 — 활성 계정을 refresh하면 실행 중인 CLI 세션이 메모리에 든
/// 시작 시점 토큰이 서버 회전으로 무효화된다(클로버 → 세션 파괴). 호출측이 활성/전환중 계정을
/// 걸러 넘기고, 이 루프가 저장 직전 credential lock 안에서 **다시** 확인한다.
@MainActor
public final class InactiveGaugeRefresher {
    /// 갱신 대상 — 게이지 루프에 필요한 최소 정보만 옮긴다(프로필 전체를 끌고 오지 않는다).
    public struct Target: Equatable, Sendable {
        public var id: UUID
        /// 회전본 신원 검증의 기준값. 다른 계정의 바이트가 스냅샷을 덮어쓰는 것을 막는다.
        public var emailAddress: String
        public init(id: UUID, emailAddress: String) {
            self.id = id
            self.emailAddress = emailAddress
        }
    }

    private let adapter: any InactiveGaugeProvider
    private let store: any GaugeSecretStore
    private let retryCooldown: TimeInterval
    private let deadRefreshCooldown: TimeInterval

    /// 계정당 refresh 재시도 쿨다운 기록 — transient 실패가 팝오버마다 회전 시도로 반복되는 것을 막는다.
    /// 첫 시도는 게이팅되지 않으므로(distantPast) 게이지 프리즈 해소는 그대로 유지된다.
    private var lastRefreshAttemptAt: [UUID: Date] = [:]
    /// 죽은 refresh 토큰 계정의 긴 백오프 — 어차피 401이라 refresh/probe를 아예 건너뛴다.
    private var deadUntil: [UUID: Date] = [:]

    public var provider: Provider { adapter.provider }

    /// refresh 토큰이 폐기된(죽은) 계정의 긴 백오프 — 어차피 401이므로 이 시각 전까지
    /// refresh/probe를 아예 건너뛴다. 게이지 전용 상수라 이 컴포넌트가 단일 출처다.
    /// `nonisolated` — 기본 인자 표현식은 비격리 문맥에서 평가된다(Swift 6에서는 오류).
    nonisolated public static let defaultDeadRefreshCooldown: TimeInterval = 24 * 3600

    /// - Parameters:
    ///   - retryCooldown: transient 실패 후 계정당 재시도 간격. 호출측(AppState)이 Claude 경로와
    ///     같은 값을 쓰므로 주입받는다.
    public init(adapter: any InactiveGaugeProvider,
                store: any GaugeSecretStore,
                retryCooldown: TimeInterval,
                deadRefreshCooldown: TimeInterval = InactiveGaugeRefresher.defaultDeadRefreshCooldown) {
        self.adapter = adapter
        self.store = store
        self.retryCooldown = retryCooldown
        self.deadRefreshCooldown = deadRefreshCooldown
    }

    /// 한 라운드 실행. 호출측 Task 안에서 돌며, 취소되면 **다음 계정으로 진입하지 않는다** —
    /// 대기는 현재 계정의 진행 중 HTTP(refresh 후 probe까지 최대 2회 순차) 완료까지로 바운드된다.
    ///
    /// - Parameters:
    ///   - targets: 비활성 + 게이지 캐시 만료 계정 (호출측이 걸러 넘긴다).
    ///   - activeID: **매 계정마다 새로 읽는** 라이브 활성 계정 — 루프가 도는 사이 자동/수동
    ///     전환으로 활성이 바뀔 수 있다(TOCTOU).
    ///   - excludedID: 전환이 진행 중이라 건드리면 안 되는 계정(낙관적 표시 중인 대상).
    ///   - onUsage: 계정 하나가 끝날 때마다 **즉시** 호출된다 — 라운드가 끝날 때까지 기다리지
    ///     않고 게이지가 하나씩 차오르게 하기 위한 것(기존 UI 동작 유지).
    /// - Returns: 갱신에 성공한 계정별 usage 스냅샷. 호출측이 영속 여부를 판단한다.
    public func refreshRound(targets: [Target],
                             now: Date,
                             activeID: () -> UUID?,
                             excludedID: () -> UUID?,
                             onUsage: (UUID, UsageSnapshot) -> Void = { _, _ in }) async
                             -> [UUID: UsageSnapshot] {
        var updated: [UUID: UsageSnapshot] = [:]
        for target in targets {
            if Task.isCancelled { break }
            let id = target.id
            if let until = deadUntil[id], now < until { continue }
            guard let secret = try? store.secretData(for: id) else { continue }
            var probeBytes = secret

            // 저장 access 토큰이 이미 만료됐으면 게이지를 못 읽어 얼어붙는다(GET엔 회전이 없어
            // 만료 토큰으로 조회하면 401만 받는다) → refresh로 미리 되살린다.
            if id != activeID(), id != excludedID(),
               let exp = adapter.accessTokenExpiry(fromSecret: secret), exp <= now {
                guard now.timeIntervalSince(lastRefreshAttemptAt[id] ?? .distantPast) >= retryCooldown
                else { continue }
                lastRefreshAttemptAt[id] = now
                // ★ 취소 쉴드: refresh POST는 서버에서 refresh 토큰을 **회전**시킨다. 왕복 중에
                //   취소되면 회전본을 못 받아 저장 스냅샷의 구 토큰이 죽고 계정이 벽돌이 된다.
                //   자식 Task로 감싸 상위 취소가 전파되지 않게 한다.
                let adapter = self.adapter   // 쉴드 Task가 self를 잡지 않도록 값만 캡처
                let outcome = await Task { await adapter.refresh(secret: secret) }.value
                switch outcome {
                case .refreshed(let rotated):
                    // ★ 원자 capture: credential lock 안에서 (1) 활성 재확인(TOCTOU — 그 사이
                    //   전환으로 활성이 됐으면 라이브 자격증명이 authoritative이므로 회전본을
                    //   버린다), (2) 스냅샷 재확인(HTTP 왕복 중 adopt/재로그인이 끼면 신규 로그인
                    //   스냅샷을 구 세션 회전본으로 덮는 edge 차단), (3) 신원/형태 검증, (4) 원자
                    //   저장. 하나라도 어긋나면 저장 스냅샷을 **덮어쓰지 않는다**.
                    //   ★ 단, "덮어쓰지 않음"이 곧 무해는 아니다 — 200을 받은 시점에 서버측 회전은
                    //     이미 커밋돼 구 refresh 토큰이 소비된 상태다. 회전본을 버리면 스냅샷에는
                    //     소비된 토큰이 남아 다음 라운드가 .invalidated를 받고 24시간 백오프로 들어간다
                    //     (게이지만 얼고, 게이지 전용 방화벽이라 아무것도 마킹하지 않는다). 그래서 이
                    //     경로에 도달하는 빈도 자체를 호출측이 줄인다 — 전환 진입 시 quiesce, 매 계정
                    //     활성 fresh-read, 그리고 refresh POST의 취소 쉴드.
                    //     저장 실패(4번)도 같은 결과가 되며, 게이지 경로에는 Claude의 .storeFailed →
                    //     needsReauth 같은 복구 표면이 없다(마킹 금지가 이 컴포넌트의 계약이다).
                    let stored: Data? = store.withCredentialLock(id) { () -> Data? in
                        guard id != activeID() else { return nil }
                        guard let current = try? store.secretData(for: id), current == secret
                        else { return nil }
                        guard adapter.acceptsRotatedSecret(rotated, forEmail: target.emailAddress)
                        else { return nil }
                        do { try store.setSecretData(rotated, for: id) } catch { return nil }
                        return rotated
                    }
                    guard let stored else { continue }   // 활성이 됨 / 검증 실패 — 이번 라운드 스킵
                    probeBytes = stored
                    lastRefreshAttemptAt[id] = nil       // 성공 — 쿨다운 해제
                    deadUntil[id] = nil
                case .invalidated:
                    deadUntil[id] = now.addingTimeInterval(deadRefreshCooldown)
                    continue
                case .transient:
                    // refresh POST는 위 취소 쉴드 덕에 여기 도달하는 transient가 순수 네트워크/5xx다
                    // (우리 자신의 취소로 인한 transient는 이 분기에 올 수 없다).
                    continue                              // 쿨다운 뒤 재시도(게이지는 마지막 값 유지)
                }
            }

            // 게이지 조회 — (가능하면 갱신된) 바이트로. 읽기 전용, 아무것도 마킹하지 않는다.
            switch await adapter.probeUsage(secret: probeBytes, now: now) {
            case .usage(let snap):
                updated[id] = snap
                onUsage(id, snap)
            case .stale, .transient:
                continue                                  // 게이지를 마지막 스냅샷에 둔다
            }
        }
        return updated
    }

    // MARK: 테스트 관찰용 (백오프가 실제로 걸렸는지) — 공개 API 아님(@testable로만 보인다)

    /// 죽은 토큰 백오프가 걸린 시각 — 이 시각 전까지는 refresh/probe를 건너뛴다.
    func deadBackoffUntil(_ id: UUID) -> Date? { deadUntil[id] }
    /// 마지막 refresh 시도 시각 — 성공하면 해제(nil)된다.
    func lastRefreshAttempt(_ id: UUID) -> Date? { lastRefreshAttemptAt[id] }
}
