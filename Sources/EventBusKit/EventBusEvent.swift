/// Marker protocol for all events sent through `EventBus`.
///
/// Conform event payload types to `Sendable` to keep cross-task usage safe.
public protocol EventBusEvent: Sendable {}
