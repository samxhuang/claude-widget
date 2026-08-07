import Foundation
import Testing
@testable import ClaudeAPI

/// Accessor semantics (audit §1.3). The important assertions are the PARITY
/// ones: for every value `JSONSerialization` can produce, the accessor must
/// agree with the Objective-C-bridged cast it replaced — otherwise this
/// "portability refactor" silently changes macOS behavior.
@Suite("JSON accessors")
struct JSONValueTests {

    /// One JSON document holding every scalar shape the accessors face.
    static let doc: [String: Any] = {
        let json = """
        {"t": true, "f": false, "zero": 0, "one": 1, "two": 2, "big": 404,
         "frac": 1.5, "neg": -7, "pct": 0.404,
         "s": "hello", "sNum": "404", "sFrac": "4.5", "sTrue": "true", "sJunk": "abc",
         "null": null, "obj": {"k": 1}, "arr": [{"k": 1}, {"k": 2}]}
        """
        return try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }()

    private func v(_ key: String) -> Any? { Self.doc[key] }

    /// Keys whose values are non-string scalars/objects — the set where the
    /// accessors must match the old casts exactly (strings are the one
    /// documented widening, so they're excluded here and asserted below).
    private static let parityKeys = ["t", "f", "zero", "one", "two", "big", "frac", "neg", "pct", "null", "obj"]

    // MARK: - Parity with the casts being replaced

    @Test("jsonBool matches `as? Bool` on every JSON value")
    func boolParityWithAsBool() {
        // Includes the Darwin quirk that numeric 0/1 satisfy `as? Bool`.
        for key in Self.parityKeys + ["s", "sTrue"] {
            #expect(jsonBool(v(key)) == (v(key) as? Bool), "parity broken for \(key)")
        }
        #expect(jsonBool(v("missing")) == nil)
    }

    @Test("jsonInt matches `(as? NSNumber)?.intValue`")
    func intParityWithNSNumberIntValue() {
        for key in Self.parityKeys {
            #expect(jsonInt(v(key)) == (v(key) as? NSNumber)?.intValue, "parity broken for \(key)")
        }
    }

    @Test("jsonDouble matches `(as? NSNumber)?.doubleValue`")
    func doubleParityWithNSNumberDoubleValue() {
        for key in Self.parityKeys {
            #expect(jsonDouble(v(key)) == (v(key) as? NSNumber)?.doubleValue, "parity broken for \(key)")
        }
    }

    @Test("jsonString matches `as? String`")
    func stringParityWithAsString() {
        for key in Self.parityKeys + ["s", "sNum"] {
            #expect(jsonString(v(key)) == (v(key) as? String), "parity broken for \(key)")
        }
    }

    // MARK: - Explicit expectations (parity alone can't state intent)

    @Test("jsonBool is strict about strings and odd numbers")
    func boolIsStrict() {
        #expect(jsonBool(v("t")) == true)
        #expect(jsonBool(v("f")) == false)
        #expect(jsonBool(v("one")) == true, "Darwin parity, not a widening")
        #expect(jsonBool(v("zero")) == false)
        #expect(jsonBool(v("two")) == nil)
        #expect(jsonBool(v("sTrue")) == nil, "no string coercion: this gates the response envelope")
        #expect(jsonBool(v("null")) == nil)
        #expect(jsonBool(NSNull()) == nil)
    }

    @Test("jsonInt truncates and accepts numeric strings (documented widening)")
    func intTruncatesAndAcceptsNumericStrings() {
        #expect(jsonInt(v("big")) == 404)
        #expect(jsonInt(v("frac")) == 1, "NSNumber.intValue truncation, not as?Int's nil")
        #expect(jsonInt(v("neg")) == -7)
        #expect(jsonInt(v("sNum")) == 404, "documented widening")
        #expect(jsonInt(v("sFrac")) == 4, "documented widening, truncated")
        #expect(jsonInt(v("sJunk")) == nil)
        #expect(jsonInt(v("obj")) == nil)
    }

    @Test("jsonDouble accepts numeric strings (documented widening)")
    func doubleAcceptsNumericStrings() {
        #expect(abs((jsonDouble(v("pct")) ?? 0) - 0.404) < 1e-9)
        #expect(abs((jsonDouble(v("sFrac")) ?? 0) - 4.5) < 1e-9, "documented widening")
        #expect(jsonDouble(v("sJunk")) == nil)
    }

    /// `Int(Double.nan)` traps; the accessor must return nil instead.
    @Test("non-finite / out-of-range doubles don't trap")
    func nonFiniteDoublesDoNotTrap() {
        #expect(jsonInt(Double.nan) == nil)
        #expect(jsonInt(Double.infinity) == nil)
        #expect(jsonInt(-Double.infinity) == nil)
        #expect(jsonInt(1e300) == nil)
        #expect(jsonDouble(Double.infinity) == Double.infinity)
    }

    @Test("jsonNumber is strict about strings (frozen on-disk format)")
    func numberIsStrictAboutStrings() {
        #expect(jsonNumber(v("big")) == NSNumber(value: 404))
        #expect(jsonNumber(v("t")) == NSNumber(value: true))
        #expect(jsonNumber(v("sNum")) == nil, "frozen on-disk format: no silent re-typing")
        #expect(jsonNumber(v("null")) == nil)
    }

    @Test("object / object-array accessors")
    func objectAndArrayAccessors() {
        #expect(jsonInt(jsonObject(v("obj"))?["k"]) == 1)
        #expect(jsonObjectArray(v("arr"))?.count == 2)
        #expect(jsonObjectArray(v("obj")) == nil)
        #expect(jsonObject(v("arr")) == nil)
        #expect(jsonObjectArray(FakeScriptRunner.parse("[1, 2]")) == nil,
                "a non-object array is not an object array")
    }

    // MARK: - Native Swift scalars (the off-Darwin representation)

    @Test("native Swift scalars behave identically to bridged ones")
    func nativeSwiftScalarsBehaveIdentically() {
        #expect(jsonBool(true) == true)
        #expect(jsonBool(false) == false)
        #expect(jsonBool(1) == true)
        #expect(jsonBool("true") == nil)
        #expect(jsonInt(404) == 404)
        #expect(jsonInt(Int64(404)) == 404)
        #expect(jsonInt(1.5) == 1)
        #expect(jsonInt(true) == 1)
        #expect(abs((jsonDouble(0.404) ?? 0) - 0.404) < 1e-9)
        #expect(jsonDouble(45) == 45.0)
        #expect(jsonString("x") == "x")
        #expect(jsonString(NSString(string: "ns")) == "ns")
        #expect(jsonString(5) == nil)
        #expect(jsonNumber(45) == NSNumber(value: 45))
    }

    /// A true boolean must never be read as an integer percent, and an
    /// integer 1 must never be mistaken for a boolean — the two directions
    /// that make Darwin's bridging so easy to get wrong.
    @Test("booleans and the number 1 stay distinguishable")
    func booleanAndOneAreDistinguishable() {
        #expect(jsonInt(v("t")) == 1, "NSNumber.intValue parity: true is 1")
        #expect(jsonInt(v("one")) == 1)
        #expect(jsonNumber(v("t"))?.boolValue == true)
        #expect(jsonNumber(v("one")) == NSNumber(value: 1))
    }
}
