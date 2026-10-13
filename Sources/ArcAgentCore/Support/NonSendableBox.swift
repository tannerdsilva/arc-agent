/// Read-only holder for a value the compiler cannot prove is Sendable (e.g.
/// JSON dictionaries built from primitives). The value is never mutated after
/// init and is only read through this box (which is itself `Sendable`), so
/// transferring the box across concurrency domains is safe by construction.
public final class NonSendableBox<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}
