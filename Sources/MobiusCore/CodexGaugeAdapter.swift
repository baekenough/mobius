import Foundation

/// Codex의 `InactiveGaugeProvider` 구현 — 비활성 codex 계정의 게이지를 되살린다.
/// 기존 부품(`CodexAuthBlob` / `CodexTokenRefresher` / `CodexUsageProber` / `CodexConfigIO`)을
/// 그대로 조립만 한다. 판정 로직은 여기서 새로 만들지 않는다.
///
/// 활성 codex 계정은 세션 로그 in-band 경로(`AppState.processCodexBatches`)가 담당하므로
/// 이 어댑터의 대상이 아니다. `wham/usage`는 codex가 이미 폴링하는 상태 엔드포인트라 추가
/// 쿼터 부담이 없다.
public struct CodexGaugeAdapter: InactiveGaugeProvider {
    public let provider = Provider.codex

    private let io: CodexConfigIO
    private let refresher: CodexTokenRefresher
    private let prober: CodexUsageProber

    public init(io: CodexConfigIO,
                refresher: CodexTokenRefresher = CodexTokenRefresher(),
                prober: CodexUsageProber = CodexUsageProber()) {
        self.io = io
        self.refresher = refresher
        self.prober = prober
    }

    public func accessTokenExpiry(fromSecret secret: Data) -> Date? {
        CodexAuthBlob.accessTokenExpiry(fromAuthJSON: secret)
    }

    public func refresh(secret: Data) async -> InactiveGaugeRefreshOutcome {
        switch await refresher.refresh(authJSON: secret) {
        case .refreshed(let rotated): return .refreshed(rotated)
        case .invalidated:            return .invalidated
        case .transient:              return .transient
        }
    }

    /// 형태 인식 + 신원 일치 + 비어있지 않은 refresh 토큰. 셋 중 하나라도 어긋나면 회전본을
    /// 버린다 — 손상·타 계정 바이트가 스냅샷을 덮어쓰는 실패 클래스(실패 기록 1/13)를 막는다.
    public func acceptsRotatedSecret(_ rotated: Data, forEmail email: String) -> Bool {
        io.recognizesSecret(rotated)
            && CodexConfigIO.email(fromAuthJSON: rotated) == email
            && CodexTokenRefresher.refreshToken(fromAuthJSON: rotated)?.isEmpty == false
    }

    public func probeUsage(secret: Data, now: Date) async -> InactiveGaugeProbeOutcome {
        switch await prober.probe(authJSON: secret, now: now) {
        case .usage(let snap): return .usage(snap)
        case .stale:           return .stale
        case .transient:       return .transient
        }
    }
}
