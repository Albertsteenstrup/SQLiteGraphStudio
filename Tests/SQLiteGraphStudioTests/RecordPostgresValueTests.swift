import Foundation
import PostgresNIO
import Testing
@testable import StudioCore

struct RecordPostgresValueTests {
    @Test func arrayLiteralsRetainScalarTypesAndEscaping() {
        let uuid = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
        let uuidArray = PostgresData(array: [PostgresData(uuid: uuid)], elementType: .uuid)
        #expect(PostgresValueMapper.map(uuidArray) == .array("{\"12345678-1234-1234-1234-123456789ABC\"}"))
        let integers = PostgresData(array: [PostgresData(int64: 42), nil], elementType: .int8)
        #expect(PostgresValueMapper.map(integers) == .array("{\"42\",NULL}"))
        let text = PostgresData(array: [PostgresData(string: "a,b"), PostgresData(string: "a\"b\\c"), PostgresData(string: "NULL"), PostgresData(string: ""), nil], elementType: .text)
        #expect(PostgresValueMapper.map(text) == .array(#"{"a,b","a\"b\\c","NULL","",NULL}"#))
        let bytes = PostgresData(array: [PostgresData(bytes: [0, 255])], elementType: .bytea)
        #expect(PostgresValueMapper.map(bytes) == .array(#"{"\\x00ff"}"#))
    }
    @Test func multidimensionalArrayBoundsAndValuesArePreserved() throws {
        var buffer = try #require(PostgresData(int64: 1).value)
        buffer.clear()
        buffer.writeInteger(Int32(2))
        buffer.writeInteger(Int32(0))
        buffer.writeInteger(PostgresDataType.int8.rawValue)
        buffer.writeInteger(Int32(2)); buffer.writeInteger(Int32(0))
        buffer.writeInteger(Int32(2)); buffer.writeInteger(Int32(1))
        for value: Int64 in [1, 2, 3, 4] {
            buffer.writeInteger(Int32(8)); buffer.writeInteger(value)
        }
        let data = PostgresData(type: .int8Array, value: buffer)
        #expect(PostgresValueMapper.map(data) == .array(#"[0:1][1:2]={{"1","2"},{"3","4"}}"#))
    }

    @Test func temporalKeyValuesRetainMicrosecondsAndTimezones() throws {
        let micros = PostgresData(int64: 42).value
        #expect(PostgresValueMapper.map(PostgresData(type: .timestamp, value: micros)) == .dateTime("2000-01-01 00:00:00.000042"))
        #expect(PostgresValueMapper.map(PostgresData(type: .timestamptz, value: micros)) == .dateTime("2000-01-01 00:00:00.000042+00"))
        #expect(PostgresValueMapper.map(PostgresData(type: .timestamp, value: PostgresData(int64: -1).value)) == .dateTime("1999-12-31 23:59:59.999999"))
        #expect(PostgresValueMapper.map(PostgresData(type: .time, value: micros)) == .dateTime("00:00:00.000042"))
        var timeZone = try #require(micros)
        timeZone.writeInteger(Int32(-7200))
        #expect(PostgresValueMapper.map(PostgresData(type: .timetz, value: timeZone)) == .dateTime("00:00:00.000042+02:00"))
        #expect(PostgresValueMapper.map(PostgresData(type: .date, value: PostgresData(int32: 0).value)) == .dateTime("2000-01-01"))
        #expect(PostgresValueMapper.map(PostgresData(type: .timestamp, value: PostgresData(int64: Int64.max).value)) == .dateTime("infinity"))
    }

    @Test func numericSpecialSignsPreserveScalarAndArrayIdentities() throws {
        let cases: [(UInt16, String)] = [(0xC000, "NaN"), (0xD000, "Infinity"), (0xF000, "-Infinity")]
        var array: [PostgresData?] = []
        for (sign, expected) in cases {
            var buffer = try #require(PostgresData(int64: 0).value)
            buffer.clear()
            buffer.writeInteger(Int16(0)) // ndigits
            buffer.writeInteger(Int16(0)) // weight
            buffer.writeInteger(sign)
            buffer.writeInteger(Int16(0)) // scale
            let data = PostgresData(type: .numeric, value: buffer)
            #expect(PostgresValueMapper.map(data) == .exactNumeric(expected))
            array.append(data)
        }
        #expect(PostgresValueMapper.map(PostgresData(array: array, elementType: .numeric)) == .array(#"{"NaN","Infinity","-Infinity"}"#))
    }
    @Test func finiteNumericScaleSurvivesTrimmedWireDigits() throws {
        for (digits, scale, expected): ([Int16], Int16, String) in [([], 4, "0.0000"), ([1], 4, "1.0000"), ([1, 2000], 8, "1.20000000")] {
            var buffer = try #require(PostgresData(int64: 0).value)
            buffer.clear()
            buffer.writeInteger(Int16(digits.count)); buffer.writeInteger(Int16(0))
            buffer.writeInteger(Int16(0)); buffer.writeInteger(scale)
            for digit in digits { buffer.writeInteger(digit) }
            #expect(PostgresValueMapper.map(PostgresData(type: .numeric, value: buffer)) == .exactNumeric(expected))
        }
    }
    @Test func moneyMinorUnitsUseServerScaleWithoutRounding() {
        for (scale, expected): (Int, [String]) in [
            (0, ["0", "-1", "12345", "-9223372036854775808"]),
            (2, ["0.00", "-0.01", "123.45", "-92233720368547758.08"]),
            (3, ["0.000", "-0.001", "12.345", "-9223372036854775.808"])
        ] {
            PostgresValueMapper.$moneyFractionDigits.withValue(scale) {
                let data = [Int64(0), -1, 12345, Int64.min].map { PostgresData(type: .money, value: PostgresData(int64: $0).value) }
                for (value, text) in zip(data, expected) {
                    #expect(PostgresValueMapper.map(value) == .exactNumeric(text))
                }
                let literal = "{" + expected.map { "\"" + $0 + "\"" }.joined(separator: ",") + "}"
                #expect(PostgresValueMapper.map(PostgresData(array: data.map { Optional($0) }, elementType: .money)) == .array(literal))
            }
        }
        let unknownScale = PostgresData(type: .money, value: PostgresData(int64: 12345).value)
        #expect(PostgresValueMapper.map(unknownScale) == .blob(Data([0, 0, 0, 0, 0, 0, 48, 57])))
    }
    @Test func moneyPredicatesBindThroughLocaleIndependentNumericInput() throws {
        for type in ["money", "money[]"] {
            let catalog = PostgresCatalogMapper.makeSnapshot(
                objects: [.init(schemaName: "public", objectName: "amounts", relkind: "r", rowEstimate: nil)],
                columns: [.init(schemaName: "public", objectName: "amounts", name: "key", declaredType: type, notNull: true, defaultValueSQL: nil, ordinal: 1)],
                indexes: [.init(schemaName: "public", objectName: "amounts", name: "pk", columns: ["key"], isUnique: true, isPrimary: true, isPartial: false)], foreignKeys: [])
            let descriptor = try #require(catalog.descriptors.first)
            let value: SQLiteValue = type == "money" ? .exactNumeric("-0.01") : .array(#"{"-0.01"}"#)
            let plan = try RecordAccess.plan(descriptor: descriptor, predicates: [.init(columnName: "key", value: value)], offset: 0, limit: 5, postgres: true)
            #expect(plan.sql.contains(type == "money" ? "$1::text::numeric::money" : "$1::text::numeric[]::money[]"))
            #expect(plan.parameters == [value])
        }
    }

}
