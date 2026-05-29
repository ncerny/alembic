import Testing
import AlembicKit

/// Phase 1 smoke test: confirms the package builds and links a test target
/// against the executable target under Swift 6 strict concurrency.
struct AlembicSmokeTests {
    @Test
    func displayNameIsAlembic() {
        #expect(AlembicInfo.displayName == "Alembic")
    }

    @Test
    func bundleIdentifierMatchesInfoPlist() {
        #expect(AlembicInfo.bundleIdentifier == "com.alembic.app")
    }
}
