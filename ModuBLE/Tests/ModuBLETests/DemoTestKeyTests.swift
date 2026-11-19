import XCTest
@testable import ModuBLE

final class DemoTestKeyTests: XCTestCase {
    func testDemoKeysHaveTheDocumentedLengths() {
        XCTAssertEqual(DemoTestKey.aes128GCM.count, AESGCMProvider.keyLength)
        XCTAssertEqual(DemoTestKey.aes128CBCHMAC.count, AESCBCProvider.masterKeyLength)
    }

    func testDemoKeysAreAcceptedByTheirProviders() throws {
        let gcm = try AESGCMProvider(key: DemoTestKey.aes128GCM)
        XCTAssertEqual(try gcm.decrypt(gcm.encrypt(Data("ping".utf8))), Data("ping".utf8))

        let cbc = try AESCBCProvider(key: DemoTestKey.aes128CBCHMAC)
        XCTAssertEqual(try cbc.decrypt(cbc.encrypt(Data("ping".utf8))), Data("ping".utf8))
    }

    /// A receiver can dispatch on the first byte alone, so the two envelope
    /// formats can never be confused by length heuristics.
    func testEnvelopeVersionsAreDistinct() throws {
        XCTAssertNotEqual(AESGCMProvider.envelopeVersion, AESCBCProvider.envelopeVersion)
        XCTAssertEqual(AESGCMProvider.envelopeVersion, 0x01)
        XCTAssertEqual(AESCBCProvider.envelopeVersion, 0x02)

        let gcm = try AESGCMProvider(key: DemoTestKey.aes128GCM)
        let cbc = try AESCBCProvider(key: DemoTestKey.aes128CBCHMAC)
        XCTAssertEqual(try gcm.encrypt(Data()).first, AESGCMProvider.envelopeVersion)
        XCTAssertEqual(try cbc.encrypt(Data()).first, AESCBCProvider.envelopeVersion)
    }
}
