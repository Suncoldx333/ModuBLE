import Foundation

/// Test-only key material shared by the demo apps.
///
/// **Never use these keys outside the demo.** They are hard-coded, public, and
/// identical on both ends. A production deployment must provision a real key
/// through a secure channel and never ship it in source.
public enum DemoTestKey {
    /// 16-byte key for AES-128-GCM.
    public static let aes128GCM = Data("ModuBLE-DemoKey!".utf8)

    /// 32-byte master key for AES-128-CBC + HMAC-SHA256.
    public static let aes128CBCHMAC = Data("ModuBLE-DemoKey!ModuBLE-DemoKey!".utf8)
}
