import XCTest
@testable import SyncContract

final class SyncContractTests: XCTestCase {
    func testEnvelopeRoundTrips() throws {
        let envelope = SyncEnvelope(kind: .storedReceipt, memoID: UUID(), scope: .memo, digest: String(repeating: "a", count: 64))
        let decoded = try SyncContractCodec.decode(try SyncContractCodec.encode(envelope))
        XCTAssertEqual(decoded, envelope)
    }

    func testOldSchemaIsRejected() {
        let envelope = SyncEnvelope(kind: .manifest, memoID: UUID(), transferAttemptID: UUID(), digest: String(repeating: "a", count: 64), schemaVersion: 1)
        XCTAssertThrowsError(try SyncContractCodec.encode(envelope))
    }
}
