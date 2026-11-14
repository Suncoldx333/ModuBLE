import Foundation

/// A byte-oriented link to a peripheral.
///
/// `Session` depends on this abstraction, never on CoreBluetooth, so encrypted
/// sessions can be exercised in tests with a fake implementation.
///
/// Byte order and framing are the caller's business: `write` transmits exactly
/// the bytes it is given, and `inbound` delivers exactly the bytes the
/// peripheral notified, with no reordering and no dropping.
public protocol BLELink: AnyObject, Sendable {
    /// Payloads arriving on the TX characteristic.
    ///
    /// **Single consumer.** `AsyncStream` shares one buffer between iterators,
    /// so two readers would steal elements from each other — never drain this
    /// stream from two places. Reading the bytes is `EncryptedSession`'s job;
    /// use `BLEConnection.observeState()` to react to disconnects.
    ///
    /// The stream is unbounded on purpose: dropping a byte would corrupt frame
    /// reassembly. A consumer that stops draining the stream will grow memory,
    /// so pump it continuously.
    var inbound: AsyncStream<Data> { get }

    /// Writes the whole payload, chunking it to the negotiated MTU.
    ///
    /// The call suspends until every chunk has been accepted by the stack.
    /// Concurrent calls are rejected with `BLEError.writeInProgress`.
    func write(_ data: Data) async throws

    /// Stops notifications and tears the connection down.
    func close() async
}
