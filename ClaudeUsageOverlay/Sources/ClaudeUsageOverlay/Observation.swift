#if canImport(Combine)
import Combine
#endif
import Foundation

// Windows-port seam (docs/swift-windows-audit.md §1.7, §3).
//
// Combine is Apple-only and has no Swift-for-Windows equivalent, so the model
// layer can't keep spelling its change notifications as `ObservableObject` +
// `@Published`. This file is the ~90-line replacement the audit specified: an
// `Observable` base class plus an `@Observed` property wrapper built on the
// enclosing-instance static subscript — the same mechanism `@Published` itself
// uses to reach its owning object from a value-type wrapper.
//
// The two properties that make it a drop-in, and that any future edit here
// MUST preserve:
//
//  1. On Apple platforms `Observable` still conforms to `ObservableObject` and
//     still vends an `ObservableObjectPublisher`, so every
//     `@ObservedObject var model: UsageModel` in the SwiftUI layer keeps
//     compiling and re-rendering untouched. No view file changed for this.
//  2. Notifications fire on **willSet**, not didSet: `objectWillChange.send()`
//     and the `$property` publisher both run while the old value is still
//     readable, exactly as `@Published` does. `AppDelegate.swift:322`
//     documents a dependence on that ordering ("@Published emits on willSet;
//     hop a beat so the resize runs after the value has actually changed") and
//     compensates with `.receive(on: DispatchQueue.main)`. Flipping this to
//     did-change would silently break that workaround.
//
// Off Darwin (no Combine), the same models expose plain callback registration
// via `onChange` — one coarse "something changed, re-pull the state" signal,
// which is what the FFI host wants anyway.

/// Opaque registration handle for `Observable.onChange`. Deregisters on
/// `deinit`, so a caller that drops the token can't leak an observer.
public final class ObservationToken {
    private let cancel: () -> Void
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
    /// Silences "result unused" at call sites that intentionally keep the
    /// observer alive for the process lifetime.
    public func keepAlive() {}
}

/// Base class for every shared-core model. On Apple platforms it IS an
/// `ObservableObject`, so SwiftUI views keep working verbatim; everywhere else
/// it exposes plain callback registration.
open class Observable {
    private var observers: [ObjectIdentifier: () -> Void] = [:]
    /// Foundation's `NSLock` is available on every platform the core targets;
    /// `os_unfair_lock`/pthread primitives are not.
    private let lock = NSLock()

    public init() {}

    /// Register a change callback. Fires AFTER the property has changed, and
    /// on whatever thread performed the mutation — the callback must not
    /// assume the main thread (see audit §3.4).
    @discardableResult
    public func onChange(_ body: @escaping () -> Void) -> ObservationToken {
        let box = Box()
        let key = ObjectIdentifier(box)
        lock.lock(); observers[key] = body; lock.unlock()
        return ObservationToken { [weak self] in
            self?.lock.lock()
            self?.observers[key] = nil
            self?.lock.unlock()
            _ = box
        }
    }
    private final class Box {}

    /// Called by `@Observed` BEFORE the stored value changes.
    public func coreWillChange() {
        #if canImport(Combine)
        objectWillChange.send()
        #endif
    }

    /// Called by `@Observed` AFTER the stored value changes.
    public func coreDidChange() {
        lock.lock(); let fns = Array(observers.values); lock.unlock()
        fns.forEach { $0() }
    }

    #if canImport(Combine)
    /// Explicit rather than synthesized: these classes have no `@Published`
    /// properties anymore, so nothing would synthesize one for them.
    public let objectWillChange = ObservableObjectPublisher()
    #endif
}

#if canImport(Combine)
extension Observable: ObservableObject {}
#endif

/// Drop-in replacement for `@Published` on an `Observable` subclass.
///
/// Deliberately mirrors `@Published`'s shape, including the unavailable
/// instance `wrappedValue` (a class-property-only wrapper) and an available
/// `projectedValue`, so `$property` publisher chains outside the core —
/// `AppDelegate.swift:320-385`'s four `.removeDuplicates().receive(on:).sink`
/// subscriptions — compile and behave unchanged. The audit called this the
/// "full fidelity" variant of §3.3 and preferred dropping `$`; the brief's
/// zero-diff-outside-the-core constraint makes it the required variant.
@propertyWrapper
public struct Observed<Value> {
    private var stored: Value

    #if canImport(Combine)
    /// `CurrentValueSubject`, not `PassthroughSubject`, on purpose:
    /// `@Published`'s projected publisher replays the current value to each
    /// new subscriber. `AppDelegate` relies on that initial emission — its
    /// `$sessionsExpanded` sink is what seeds the "Show Sessions" menu-item
    /// check state at launch. A passthrough subject would silently drop it.
    private let subject: CurrentValueSubject<Value, Never>
    #endif

    public init(wrappedValue: Value) {
        self.stored = wrappedValue
        #if canImport(Combine)
        self.subject = CurrentValueSubject(wrappedValue)
        #endif
    }

    // The enclosing-instance subscript is what lets a value-type wrapper reach
    // its owning object — the same mechanism `@Published` uses. `didSet`
    // observers on the wrapped property compose with it normally (the compiler
    // emits willSet → this setter → didSet), so the `UserDefaults`-persisting
    // `didSet` blocks on `SessionsModel.sessionsExpanded` and
    // `GraphModel.selectedTab`/`period` keep working as written.
    public static subscript<T: Observable>(
        _enclosingInstance instance: T,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<T, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<T, Self>
    ) -> Value {
        get { instance[keyPath: storageKeyPath].stored }
        set {
            // Order matters and matches @Published exactly: both notifications
            // go out while `stored` still holds the OLD value.
            instance.coreWillChange()
            #if canImport(Combine)
            instance[keyPath: storageKeyPath].subject.send(newValue)
            #endif
            instance[keyPath: storageKeyPath].stored = newValue
            instance.coreDidChange()
        }
    }

    @available(*, unavailable, message: "@Observed is only usable on a property of an Observable subclass")
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    #if canImport(Combine)
    /// `$property`, matching `@Published`'s projected publisher: replays the
    /// current value on subscribe, then emits each new value at will-set time
    /// (before the stored value changes).
    public var projectedValue: AnyPublisher<Value, Never> {
        subject.eraseToAnyPublisher()
    }
    #endif
}
