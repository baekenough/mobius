import Foundation

public enum ClaudeConfigError: Error { case malformedClaudeJSON }

/// Claude Code 자격증명 3곳(Keychain / .credentials.json / ~/.claude.json oauthAccount)의 읽기·쓰기.
public struct ClaudeConfigIO: Sendable {
    let env: MobiusEnvironment
    let keychain: KeychainClient

    public init(env: MobiusEnvironment, keychain: KeychainClient) {
        self.env = env
        self.keychain = keychain
    }

    // MARK: 읽기

    /// 현재 로그인 상태의 스냅샷. 로그아웃 상태(Keychain·파일 둘 다 없음)면 nil.
    ///
    /// **Keychain을 진실의 원천으로 삼는다** — 실측 결과 이 환경의 Claude Code는
    /// 최신 토큰을 Keychain "Claude Code-credentials"에 쓰고 .credentials.json 파일은
    /// 갱신하지 않는다(낡음). 파일을 우선 읽으면 낡은 토큰이 최신 이메일과 짝지어져
    /// 프로필이 오염된다(실측 버그). 파일은 Keychain이 비었을 때의 폴백일 뿐이다.
    /// 호출측이 매 틱 이걸 부르지 않도록 상위에서 변화 감지로 게이팅한다(승인창 최소화).
    public func readLiveSnapshot() throws -> CredentialsSnapshot? {
        let blob: Data
        if let keychainBlob = try keychain.read(service: env.claudeKeychainService,
                                                account: env.claudeKeychainAccount) {
            blob = keychainBlob
        } else if let fileData = try? Data(contentsOf: env.credentialsFile), !fileData.isEmpty {
            blob = fileData
        } else {
            return nil
        }
        var oauthJSON: Data?
        if let block = try readOAuthAccountDict() {
            oauthJSON = try JSONSerialization.data(withJSONObject: block, options: [.sortedKeys])
        }
        return CredentialsSnapshot(keychainBlob: blob, credentialsFileData: blob,
                                   oauthAccountJSON: oauthJSON)
    }

    public func readOAuthAccountDict() throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: env.claudeJSON) else { return nil }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeConfigError.malformedClaudeJSON
        }
        return dict["oauthAccount"] as? [String: Any]
    }

    public func liveEmail() throws -> String? {
        try readOAuthAccountDict()?["emailAddress"] as? String
    }

    /// 라이브 상태(토큰+계정 열쇠)를 간격을 두고 두 번 읽어 **값이 일치할 때만** 반환한다.
    /// 로그인/전환 도중 토큰(Keychain)과 계정 정보(~/.claude.json)가 순차 갱신되는 찰나엔
    /// 두 읽기가 달라지므로 nil을 반환해 "새 토큰 + 옛 계정 정보" 오저장을 막는다.
    /// ★ 비교는 이메일이 아니라 **열쇠(이메일+조직)**다 — 같은 이메일의 다른 조직으로 바뀌는
    ///   찰나는 이메일만 보면 안정으로 오판한다(실패 기록 23). 통째 JSON 비교는 쓰지 않는다:
    ///   claude가 profileFetchedAt 등을 수시로 다시 써서 정상 상태에서도 두 읽기가 달라진다.
    ///
    /// 파일 mtime 기반 판정은 부적합하다 — 활성 claude 세션이 ~/.claude.json을 자주 쓰므로
    /// "N초간 idle" 조건이 영영 충족되지 않아 로그인 완료 감지가 막힌다(실측 버그). 그래서
    /// 파일이 바쁜지와 무관하게 값 자체를 두 번 비교한다.
    public func readStableLiveSnapshot(gap: Duration = .milliseconds(700))
        async -> (snapshot: CredentialsSnapshot, email: String)? {
        guard let s1 = try? readLiveSnapshot(), let e1 = try? liveEmail() else { return nil }
        try? await Task.sleep(for: gap)
        guard let s2 = try? readLiveSnapshot(), let e2 = try? liveEmail() else { return nil }
        guard s1.keychainBlob == s2.keychainBlob, e1 == e2,
              Self.identity(fromSnapshot: s1)?.key == Self.identity(fromSnapshot: s2)?.key
        else { return nil }
        return (s2, e2)
    }

    // MARK: 쓰기

    public func writeLiveSnapshot(_ snap: CredentialsSnapshot) throws {
        try keychain.write(service: env.claudeKeychainService,
                           account: env.claudeKeychainAccount, data: snap.keychainBlob)
        try writeAtomic(snap.credentialsFileData, to: env.credentialsFile, mode: 0o600)
        try patchOAuthAccount(snap.oauthAccountJSON)
    }

    private func patchOAuthAccount(_ oauthJSON: Data?) throws {
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: env.claudeJSON) {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw ClaudeConfigError.malformedClaudeJSON }
            dict = existing
        }
        if let oauthJSON,
           let block = try JSONSerialization.jsonObject(with: oauthJSON) as? [String: Any] {
            dict["oauthAccount"] = block
        } else {
            dict.removeValue(forKey: "oauthAccount")
        }
        let out = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try writeAtomic(out, to: env.claudeJSON, mode: 0o600)
    }

}

// MARK: - ProviderConfigIO (secret data = CredentialsSnapshot JSON — 기존 비밀 파일 포맷 그대로)

extension ClaudeConfigIO: ProviderConfigIO {
    public var provider: Provider { .claude }

    public func readLiveSecretData() throws -> Data? {
        guard let snap = try readLiveSnapshot() else { return nil }
        return try JSONEncoder().encode(snap)
    }

    public func liveIdentity() throws -> ProviderIdentity? {
        guard let block = try readOAuthAccountDict() else { return nil }
        return Self.identity(fromOAuthBlock: block)
    }

    /// 이메일 + organizationUuid — `liveEmail`과 같은 파일 한 번 읽기(승인창 없음).
    public func liveAccountKey() throws -> AccountKey? {
        guard let block = try readOAuthAccountDict() else { return nil }
        return Self.identity(fromOAuthBlock: block)?.key
    }

    /// oauthAccount 블록 → 표시용 신원. 라이브 읽기와 스냅샷 기반 등록(AccountStore)이 공유.
    /// organizationUuid가 없는 옛 claude.json이면 ""(조직 미상)으로 둔다 — 이메일만으로 대조된다.
    public static func identity(fromOAuthBlock block: [String: Any]) -> ProviderIdentity? {
        guard let email = block["emailAddress"] as? String else { return nil }
        return ProviderIdentity(emailAddress: email,
                                organizationName: block["organizationName"] as? String ?? "",
                                tierDescription: tierDescription(from: block),
                                organizationUuid: block["organizationUuid"] as? String ?? "")
    }

    /// 저장 스냅샷의 oauthAccount 블록에서 신원을 꺼낸다 — 라이브를 보지 않으므로 "그 스냅샷이
    /// 어느 계정·조직의 것인가"를 정확히 답한다(구버전 프로필의 조직 UUID 채우기, CLI capture).
    public static func identity(fromSnapshot snap: CredentialsSnapshot) -> ProviderIdentity? {
        guard let json = snap.oauthAccountJSON,
              let block = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }
        return identity(fromOAuthBlock: block)
    }

    /// "default_claude_max_20x" → "Max 20x" 정도의 사람이 읽는 문자열로.
    /// Team 워크스페이스의 oauthAccount는 organizationType·organizationRateLimitTier가 **둘 다 null**이고
    /// `seatTier: "team_tier_1"`만 온다(실측 2026-09-11) — 그래서 seatTier까지 폴백한다("Team Tier 1").
    static func tierDescription(from block: [String: Any]) -> String {
        let tier = (block["organizationRateLimitTier"] as? String)
            ?? (block["organizationType"] as? String)
            ?? (block["seatTier"] as? String) ?? ""
        return tier.replacingOccurrences(of: "default_", with: "")
            .replacingOccurrences(of: "claude_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    public func readStableLiveSecretData(gap: Duration) async -> (data: Data, email: String)? {
        guard let (snap, email) = await readStableLiveSnapshot(gap: gap),
              let data = try? JSONEncoder().encode(snap) else { return nil }
        return (data, email)
    }

    public func writeLiveSecretData(_ data: Data) throws {
        try writeLiveSnapshot(try JSONDecoder().decode(CredentialsSnapshot.self, from: data))
    }

    /// Claude secret은 CredentialsSnapshot JSON이다 — 디코드되면 Claude 형태.
    /// Codex auth.json(keychainBlob/credentialsFileData 키 없음)은 여기서 디코드 실패한다.
    public func recognizesSecret(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(CredentialsSnapshot.self, from: data)) != nil
    }
}
