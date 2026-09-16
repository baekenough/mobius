import XCTest
@testable import MobiusCore

/// 계정 열쇠(이메일 + 조직) 대조 규칙 — 실패 기록 23.
/// 한 이메일이 여러 조직(개인 Max·회사 Team·Enterprise)에 속할 수 있으므로 이메일만으로는
/// 계정을 구분할 수 없다. 조직을 모르는 쪽(구버전 프로필·Codex)은 이메일만으로 맞춰 예전 동작을 지킨다.
final class AccountKeyTests: XCTestCase {
    func testMatchesRequiresSameOrganizationWhenBothKnown() {
        let a = AccountKey(emailAddress: "p@x.com", organizationUuid: "org-A")
        let b = AccountKey(emailAddress: "p@x.com", organizationUuid: "org-B")
        XCTAssertFalse(a.matches(b))
        XCTAssertTrue(a.matches(a))
    }

    func testMatchesFallsBackToEmailWhenEitherSideLacksOrganization() {
        let known = AccountKey(emailAddress: "p@x.com", organizationUuid: "org-A")
        let unknown = AccountKey(emailAddress: "p@x.com")
        XCTAssertTrue(known.matches(unknown))
        XCTAssertTrue(unknown.matches(known))
        XCTAssertFalse(unknown.matches(AccountKey(emailAddress: "other@x.com")))
    }

    private func profile(_ nick: String, _ email: String, org: String,
                         provider: Provider = .claude) -> AccountProfile {
        AccountProfile(id: UUID(), provider: provider, nickname: nick, emailAddress: email,
                       organizationName: "", tierDescription: "", organizationUuid: org)
    }

    /// 같은 이메일에 조직 A·B 프로필이 둘 다 있을 때 A의 열쇠가 B를 잡으면 안 된다 — 정확한 쪽 우선.
    func testFirstAccountPrefersExactOrganizationMatch() {
        let a = profile("a", "p@x.com", org: "org-A")
        let b = profile("b", "p@x.com", org: "org-B")
        let file = AccountsFile(accounts: [a, b])
        XCTAssertEqual(file.firstAccount(provider: .claude,
                                         matching: AccountKey(emailAddress: "p@x.com", organizationUuid: "org-B"))?.id, b.id)
        XCTAssertEqual(file.firstAccount(provider: .claude,
                                         matching: AccountKey(emailAddress: "p@x.com", organizationUuid: "org-A"))?.id, a.id)
        // 둘 다 조직을 아는데 제3의 조직이면 아무것도 잡지 않는다 → 새 프로필이 될 자리
        XCTAssertNil(file.firstAccount(provider: .claude,
                                       matching: AccountKey(emailAddress: "p@x.com", organizationUuid: "org-C")))
        // 프로바이더가 다르면 이메일이 같아도 남
        XCTAssertNil(file.firstAccount(provider: .codex,
                                       matching: AccountKey(emailAddress: "p@x.com", organizationUuid: "org-A")))
    }

    /// 구버전 프로필(조직 미상)만 이메일로 맞춘다 — 정확한 프로필이 있으면 그쪽이 먼저.
    func testFirstAccountUsesLegacyProfileOnlyWhenNoExactMatch() {
        let legacy = profile("legacy", "p@x.com", org: "")
        let exact = profile("exact", "p@x.com", org: "org-A")
        let file = AccountsFile(accounts: [legacy, exact])
        let keyA = AccountKey(emailAddress: "p@x.com", organizationUuid: "org-A")
        XCTAssertEqual(file.firstAccount(provider: .claude, matching: keyA)?.id, exact.id)
        let keyB = AccountKey(emailAddress: "p@x.com", organizationUuid: "org-B")
        XCTAssertEqual(file.firstAccount(provider: .claude, matching: keyB)?.id, legacy.id,
                       "정확한 프로필이 없으면 조직 미상 프로필이 이메일로 맞는다(구버전 동작 유지)")
        // ★ 열쇠 쪽이 조직을 모르는데(옛 claude.json) 이메일이 같은 후보가 둘이면 **nil**이다 —
        //   배열 순서로 아무거나 잡으면 남의 조직 토큰을 그 프로필에 저장하고 setActive까지 간다.
        //   모호하면 손대지 않는다(실패 기록 21): 소비자는 다음 틱에 다시 본다.
        XCTAssertNil(file.firstAccount(provider: .claude,
                                       matching: AccountKey(emailAddress: "p@x.com")))
        // 후보가 하나뿐이면 예전 그대로 이메일로 맞는다 — Codex와 단일 프로필 사용자의 경로다.
        let solo = AccountsFile(accounts: [legacy])
        XCTAssertEqual(solo.firstAccount(provider: .claude,
                                         matching: AccountKey(emailAddress: "p@x.com"))?.id, legacy.id)
    }

    /// 조직 미상 프로필이 여럿이면 **열쇠가 조직을 알아도** 고르지 않는다 — backfill이 실패한
    /// (비밀 파일이 없는) 프로필이 같은 이메일로 둘 남은 경우다. 정확히 맞는 프로필이 없는데
    /// 이메일 폴백 후보가 여럿이라면 어느 쪽인지 알 방법이 없다.
    func testFirstAccountStaysSilentWhenSeveralLegacyProfilesShareEmail() {
        let a = profile("legacy-a", "p@x.com", org: "")
        let b = profile("legacy-b", "p@x.com", org: "")
        let file = AccountsFile(accounts: [a, b])
        XCTAssertNil(file.firstAccount(provider: .claude,
                                       matching: AccountKey(emailAddress: "p@x.com",
                                                            organizationUuid: "org-A")))
        XCTAssertNil(file.firstAccount(provider: .claude,
                                       matching: AccountKey(emailAddress: "p@x.com")))
        // 조직을 채운 프로필이 하나 생기면 그 열쇠는 다시 정확히 맞는다.
        var healed = file
        healed.accounts[0].organizationUuid = "org-A"
        XCTAssertEqual(healed.firstAccount(provider: .claude,
                                           matching: AccountKey(emailAddress: "p@x.com",
                                                                organizationUuid: "org-A"))?.id, a.id)
    }

    func testSuggestedNicknameDisambiguatesSameEmailByOrganization() {
        let first = profile("leo", "leo@x.com", org: "org-A")
        let file = AccountsFile(accounts: [first])
        // 처음 보는 이메일은 앞부분 그대로
        XCTAssertEqual(file.suggestedNickname(provider: .claude, for: ProviderIdentity(
            emailAddress: "ann@x.com", organizationName: "Acme", tierDescription: "Team")), "ann")
        // 같은 이메일의 회사 조직 → 조직 이름을 붙인다
        XCTAssertEqual(file.suggestedNickname(provider: .claude, for: ProviderIdentity(
            emailAddress: "leo@x.com", organizationName: "acme-team", tierDescription: "Team",
            organizationUuid: "org-B")), "leo-acme-team")
        // 같은 이메일의 개인 구독 → 자동 생성 조직 이름은 정보가 없으니 등급을 붙인다
        XCTAssertEqual(file.suggestedNickname(provider: .claude, for: ProviderIdentity(
            emailAddress: "leo@x.com", organizationName: "leo@x.com's Organization",
            tierDescription: "Max 20X", organizationUuid: "org-C")), "leo-max-20x")
        // 그래도 겹치면 번호
        let crowded = AccountsFile(accounts: [first, profile("leo-max-20x", "leo@x.com", org: "org-C")])
        XCTAssertEqual(crowded.suggestedNickname(provider: .claude, for: ProviderIdentity(
            emailAddress: "leo@x.com", organizationName: "leo@x.com's Organization",
            tierDescription: "Max 20X", organizationUuid: "org-D")), "leo-max-20x-2")
        // 다른 프로바이더 풀은 별개
        XCTAssertEqual(file.suggestedNickname(provider: .codex, for: ProviderIdentity(
            emailAddress: "leo@x.com", organizationName: "", tierDescription: "Plus")), "leo")
    }

    func testNicknameSlug() {
        XCTAssertEqual(AccountsFile.nicknameSlug("Raven Enterprise"), "raven-enterprise")
        XCTAssertEqual(AccountsFile.nicknameSlug("  acme-team "), "acme-team")
        XCTAssertEqual(AccountsFile.nicknameSlug("Max 20X"), "max-20x")
        XCTAssertEqual(AccountsFile.nicknameSlug("!!!"), "")
    }

    func testSubtitleJoinsOnlyNonEmptyParts() {
        var p = profile("a", "leo@x.com", org: "o")
        p.organizationName = "acme-team"; p.tierDescription = "Team"
        XCTAssertEqual(p.subtitle, "acme-team · Team")
        p.tierDescription = ""
        XCTAssertEqual(p.subtitle, "acme-team", "등급이 비면 구분자 꼬리가 남지 않아야 한다")
        p.organizationName = "leo@x.com's Organization"; p.tierDescription = "Max 20X"
        XCTAssertEqual(p.subtitle, "Max 20X")
        p.tierDescription = ""
        XCTAssertEqual(p.subtitle, "")
    }

    func testOrganizationLabelHidesPersonalAutoOrganization() {
        XCTAssertEqual(profile("a", "leo@x.com", org: "o").organizationLabel, "")
        var p = profile("a", "leo@x.com", org: "o")
        p.organizationName = "leo@x.com's Organization"
        XCTAssertEqual(p.organizationLabel, "")
        p.organizationName = "acme-team"
        XCTAssertEqual(p.organizationLabel, "acme-team")
    }
}
