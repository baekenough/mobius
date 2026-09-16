import XCTest
@testable import MobiusCore

final class ClaudeConfigIOTests: XCTestCase {
    var tmp: URL!
    var env: MobiusEnvironment!
    var kc: InMemoryKeychain!
    var io: ClaudeConfigIO!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-test-\(UUID().uuidString)")
        env = MobiusEnvironment(home: tmp, localUser: "tester")
        try FileManager.default.createDirectory(at: env.claudeDir,
                                                withIntermediateDirectories: true)
        kc = InMemoryKeychain()
        io = ClaudeConfigIO(env: env, keychain: kc)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func seedLive(email: String = "p@x.com") throws {
        try kc.write(service: env.claudeKeychainService, account: env.claudeKeychainAccount,
                     data: Data(#"{"tok":"secret-A"}"#.utf8))
        try Data(#"{"tok":"secret-A"}"#.utf8).write(to: env.credentialsFile)
        let claudeJSON = #"{"otherKey":42,"oauthAccount":{"emailAddress":"\#(email)","organizationName":"Org"}}"#
        try Data(claudeJSON.utf8).write(to: env.claudeJSON)
    }

    func testReadLiveSnapshot() throws {
        try seedLive()
        let snap = try XCTUnwrap(io.readLiveSnapshot())
        XCTAssertEqual(snap.keychainBlob, Data(#"{"tok":"secret-A"}"#.utf8))
        XCTAssertEqual(snap.credentialsFileData, Data(#"{"tok":"secret-A"}"#.utf8))
        XCTAssertEqual(try io.liveEmail(), "p@x.com")
    }

    func testReadReturnsNilWithoutKeychain() throws {
        XCTAssertNil(try io.readLiveSnapshot())
    }

    /// 안정 읽기는 두 읽기 사이에 **조직이 바뀌면**(같은 이메일·같은 토큰이라도) 불안정으로 본다 —
    /// 같은 이메일의 다른 워크스페이스로 로그인이 끝나는 찰나에 옛 토큰과 새 조직이 짝지어지는 것을 막는다.
    func testStableReadRejectsOrganizationChangeBetweenReads() async throws {
        try seedLive()
        func claudeJSON(org: String) -> Data {
            Data(#"{"oauthAccount":{"emailAddress":"p@x.com","organizationName":"O","organizationUuid":"\#(org)"}}"#.utf8)
        }
        try claudeJSON(org: "org-A").write(to: env.claudeJSON)
        let stable = await io.readStableLiveSnapshot(gap: .milliseconds(50))
        XCTAssertNotNil(stable, "변화가 없으면 안정")

        let url = env.claudeJSON
        let flip = Task.detached {
            try? await Task.sleep(for: .milliseconds(120))
            try? claudeJSON(org: "org-B").write(to: url)
        }
        let unstable = await io.readStableLiveSnapshot(gap: .milliseconds(400))
        await flip.value
        XCTAssertNil(unstable, "토큰·이메일이 같아도 조직이 바뀌면 불안정으로 봐야 한다")
    }

    /// 계정 열쇠 = 이메일 + organizationUuid. 조직 필드가 없는 옛 claude.json은 ""(조직 미상).
    func testLiveAccountKeyCarriesOrganizationUuid() throws {
        try seedLive()
        XCTAssertEqual(try io.liveAccountKey(), AccountKey(emailAddress: "p@x.com"))

        let withOrg = #"{"oauthAccount":{"emailAddress":"p@x.com","organizationName":"acme-team","organizationType":"claude_team","organizationUuid":"5d1f0c9e-0000-0000-0000-000000000000"}}"#
        try Data(withOrg.utf8).write(to: env.claudeJSON)
        XCTAssertEqual(try io.liveAccountKey(),
                       AccountKey(emailAddress: "p@x.com", organizationUuid: "5d1f0c9e-0000-0000-0000-000000000000"))
        let identity = try XCTUnwrap(io.liveIdentity())
        XCTAssertEqual(identity.organizationUuid, "5d1f0c9e-0000-0000-0000-000000000000")
        XCTAssertEqual(identity.organizationName, "acme-team")
        XCTAssertEqual(identity.tierDescription, "Team")

        // Team 워크스페이스 실측: organizationType·organizationRateLimitTier가 null, seatTier만 온다
        let teamSeat = #"{"oauthAccount":{"emailAddress":"p@x.com","organizationName":"acme-team","organizationType":null,"organizationRateLimitTier":null,"seatTier":"team_tier_1","organizationUuid":"5d1f0c9e-0000-0000-0000-000000000000"}}"#
        try Data(teamSeat.utf8).write(to: env.claudeJSON)
        XCTAssertEqual(try XCTUnwrap(io.liveIdentity()).tierDescription, "Team Tier 1",
                       "등급 필드가 전부 null이면 seatTier로 폴백해야 부제가 비지 않는다")
        try Data(withOrg.utf8).write(to: env.claudeJSON)

        // 스냅샷에서도 같은 신원이 나온다(구버전 프로필 조직 채우기·CLI capture가 쓰는 경로)
        let snap = try XCTUnwrap(io.readLiveSnapshot())
        XCTAssertEqual(ClaudeConfigIO.identity(fromSnapshot: snap)?.key, identity.key)
    }

    func testWritePreservesOtherKeys() throws {
        try seedLive()
        var snap = try XCTUnwrap(io.readLiveSnapshot())
        snap.keychainBlob = Data(#"{"tok":"secret-B"}"#.utf8)
        snap.credentialsFileData = Data(#"{"tok":"secret-B"}"#.utf8)
        snap.oauthAccountJSON = Data(#"{"emailAddress":"w@x.com"}"#.utf8)
        try io.writeLiveSnapshot(snap)

        XCTAssertEqual(try kc.read(service: env.claudeKeychainService,
                                   account: env.claudeKeychainAccount),
                       Data(#"{"tok":"secret-B"}"#.utf8))
        XCTAssertEqual(try Data(contentsOf: env.credentialsFile),
                       Data(#"{"tok":"secret-B"}"#.utf8))
        let dict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: env.claudeJSON)) as! [String: Any]
        XCTAssertEqual(dict["otherKey"] as? Int, 42) // 다른 키 보존
        XCTAssertEqual((dict["oauthAccount"] as? [String: Any])?["emailAddress"] as? String,
                       "w@x.com")
        XCTAssertEqual(try io.liveEmail(), "w@x.com")
    }
}
