import Foundation

/// Typed accessors for values pulled out of `JSONSerialization` output.
///
/// WHY THIS EXISTS (portability, see docs/swift-windows-audit.md §1.3):
/// this codebase reads JSON as `[String: Any]` and casts with `as? Bool` /
/// `as? Int` / `as? Double` / `as? NSNumber`. On Darwin those casts work
/// only because of Objective-C bridging — `JSONSerialization` hands back
/// `__NSCFBoolean` / `__NSCFNumber`, and the runtime conditionally bridges
/// them to Swift scalars. **That bridging does not exist off Darwin.** On
/// swift-corelibs-foundation the same values arrive as plain `NSNumber`, and
/// under the newer swift-foundation JSON implementation as *native* Swift
/// `Bool`/`Int`/`Double` — the two possibilities break opposite halves of a
/// naive cast set. Each failure is a silent wrong default (a `?? false`
/// toggle, a nil percent, a "bad envelope" error), never a crash, which is
/// what makes it dangerous.
///
/// These accessors handle every representation explicitly, so the same source
/// behaves identically whichever JSON core is underneath.
///
/// SEMANTICS ARE DARWIN-PARITY BY DEFAULT. Each function reproduces exactly
/// what the cast it replaces does today on macOS (measured, not assumed —
/// see the notes on each function). The deliberate deviations are documented
/// inline and in the change report:
///   1. `jsonInt`/`jsonDouble` additionally accept *numeric strings*
///      (widening; only turns a previously-nil read into a value).
///   2. `jsonBool` and `jsonNumber` accept **no** string forms at all
///      (strict, unchanged): `jsonBool` gates every API response envelope,
///      and `jsonNumber` feeds a frozen on-disk format.
///   3. `jsonInt` returns nil for NaN/±inf/out-of-Int-range numbers where
///      `NSNumber.intValue` would silently yield 0 or a saturated bound.
///      JSON cannot express those values at all, so nothing real changes.

// MARK: - Boolean identity

/// True boolean detection, independent of bridging.
///
/// On Darwin a JSON `true` is a `__NSCFBoolean` and a JSON `1` is a
/// `__NSCFNumber`, but `as? Bool` succeeds for BOTH (measured: `1 as? Bool`
/// == true, `0 as? Bool` == false, `2 as? Bool` == nil). This helper answers
/// the narrower question "was this actually a JSON boolean" by asking
/// CoreFoundation for the concrete type; off Darwin there is no Int↔Bool
/// bridging, so `as? Bool` is already exact.
private func jsonBooleanValue(_ value: Any) -> Bool? {
    #if canImport(Darwin)
    if let number = value as? NSNumber {
        return CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : nil
    }
    return nil
    #else
    return value as? Bool
    #endif
}

/// Any non-boolean numeric representation, as a Double. Strings are NOT
/// accepted here — callers that want string coercion opt into it.
private func jsonNumericDouble(_ value: Any) -> Double? {
    if jsonBooleanValue(value) != nil { return nil }
    if let n = value as? NSNumber { return n.doubleValue }   // Darwin + corelibs
    if let d = value as? Double { return d }                 // native swift-foundation
    if let i = value as? Int { return Double(i) }
    if let i = value as? Int64 { return Double(i) }
    if let u = value as? UInt64 { return Double(u) }
    if let f = value as? Float { return Double(f) }
    return nil
}

private func jsonUnwrap(_ value: Any?) -> Any? {
    guard let value = value, !(value is NSNull) else { return nil }
    return value
}

// MARK: - Public accessors

/// Bool from a JSON value. Nil for a missing key, `NSNull`, a string, or a
/// number that isn't exactly 0/1 — i.e. exactly what `as? Bool` does on
/// Darwin today, including its acceptance of numeric `0`/`1`.
///
/// DELIBERATELY NOT WIDENED: `"true"` / `"yes"` / `"1"` stay nil. This
/// accessor gates the API response envelope (`ok`, `loggedOut`), and the
/// observed contract (CONTRACT.md) only ever sends real JSON booleans there;
/// accepting string forms would let a garbled payload read as success.
public func jsonBool(_ value: Any?) -> Bool? {
    guard let value = jsonUnwrap(value) else { return nil }
    if let b = jsonBooleanValue(value) { return b }
    // Numeric 0/1 — Darwin's `as? Bool` accepts these, so we do too.
    guard let d = jsonNumericDouble(value) else { return nil }
    if d == 1 { return true }
    if d == 0 { return false }
    return nil
}

/// Int from a JSON value, mirroring `(x as? NSNumber)?.intValue` — the idiom
/// this replaces. Fractional numbers TRUNCATE toward zero (`.intValue`
/// semantics, not `as? Int`'s nil). A real JSON boolean maps to 1/0, again
/// matching `NSNumber.intValue`.
///
/// WIDENED: a numeric string ("404", "4.5") parses. The observed contract
/// sends numbers, so this only converts a would-be-nil read (blank bar,
/// missing percent) into a usable value if the API ever switches shape; it
/// cannot change any currently-correct result.
public func jsonInt(_ value: Any?) -> Int? {
    guard let value = jsonUnwrap(value) else { return nil }
    if let b = jsonBooleanValue(value) { return b ? 1 : 0 }
    if let n = value as? NSNumber {
        // Third (tiny) deviation from `.intValue`: NaN/±inf and magnitudes
        // outside Int's range yield nil instead of `.intValue`'s silent 0 /
        // saturation. JSON itself cannot express any of these, so this only
        // affects non-JSON callers, where a nil is honest and a 0 is not.
        guard isIntRepresentable(n.doubleValue) else { return nil }
        return n.intValue
    }
    if let i = value as? Int { return i }
    if let i = value as? Int64 { return Int(clamping: i) }
    if let u = value as? UInt64 { return Int(clamping: u) }
    if let d = jsonNumericDouble(value) { return intFromDouble(d) }
    if let s = jsonRawString(value) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let i = Int(t) { return i }
        if let d = Double(t) { return intFromDouble(d) }
    }
    return nil
}

/// Double from a JSON value, mirroring `(x as? NSNumber)?.doubleValue`.
/// A real JSON boolean maps to 1.0/0.0 (`NSNumber.doubleValue` parity).
///
/// WIDENED: numeric strings parse — same rationale as `jsonInt`.
public func jsonDouble(_ value: Any?) -> Double? {
    guard let value = jsonUnwrap(value) else { return nil }
    if let b = jsonBooleanValue(value) { return b ? 1 : 0 }
    if let d = jsonNumericDouble(value) { return d }
    if let s = jsonRawString(value) { return Double(s.trimmingCharacters(in: .whitespaces)) }
    return nil
}

/// String from a JSON value. Strict: numbers and booleans are NOT
/// stringified (parity with `as? String`, which rejects them on Darwin).
public func jsonString(_ value: Any?) -> String? {
    guard let value = jsonUnwrap(value) else { return nil }
    return jsonRawString(value)
}

/// NSNumber from a JSON value, for the one case that must stay an
/// `NSNumber`: `UsageWindow.utilizationRaw`, which SnapshotLogger writes
/// straight back into the widget's frozen snapshots.jsonl format.
///
/// Strict on strings (no coercion) precisely because the on-disk format is
/// frozen: a shape change should surface as a missing value the validator
/// flags, not as a silently re-typed snapshot field.
public func jsonNumber(_ value: Any?) -> NSNumber? {
    guard let value = jsonUnwrap(value) else { return nil }
    if let b = jsonBooleanValue(value) { return NSNumber(value: b) }
    if let n = value as? NSNumber { return n }
    if let i = value as? Int { return NSNumber(value: i) }
    if let d = value as? Double { return NSNumber(value: d) }
    if let i = value as? Int64 { return NSNumber(value: i) }
    if let u = value as? UInt64 { return NSNumber(value: u) }
    if let f = value as? Float { return NSNumber(value: f) }
    return nil
}

/// A JSON object. Present for symmetry/readability at call sites; the cast
/// itself is portable (`JSONSerialization` yields `[String: Any]` on every
/// platform), so this adds no coercion.
public func jsonObject(_ value: Any?) -> [String: Any]? {
    guard let value = jsonUnwrap(value) else { return nil }
    return value as? [String: Any]
}

/// An array of JSON objects. Same note as `jsonObject`.
public func jsonObjectArray(_ value: Any?) -> [[String: Any]]? {
    guard let value = jsonUnwrap(value) else { return nil }
    if let arr = value as? [[String: Any]] { return arr }
    // Off Darwin a heterogeneous `[Any]` won't down-cast wholesale; salvage
    // it element-wise rather than dropping the whole payload.
    if let arr = value as? [Any] {
        let objs = arr.compactMap { $0 as? [String: Any] }
        return objs.count == arr.count ? objs : nil
    }
    return nil
}

// MARK: - Helpers

private func jsonRawString(_ value: Any) -> String? {
    if let s = value as? String { return s }
    if let ns = value as? NSString { return ns as String }
    return nil
}

/// `NSNumber.intValue`-style truncation, minus the trap: `Int(Double.nan)`
/// and out-of-range conversions crash in Swift, so those become nil.
private func intFromDouble(_ d: Double) -> Int? {
    guard isIntRepresentable(d) else { return nil }
    return Int(d)
}

/// Finite and within Int's range. The bound is just past `Int64.max`
/// (9.223…e18) so an exactly-max integer still qualifies, while a genuine
/// out-of-range float does not.
private func isIntRepresentable(_ d: Double) -> Bool {
    d.isFinite && d.magnitude < 9.3e18
}
