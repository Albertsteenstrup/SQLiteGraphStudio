import Foundation
import PostgresNIO
import Testing
@testable import StudioCore

struct PostgresValueFidelityTests {
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

}
