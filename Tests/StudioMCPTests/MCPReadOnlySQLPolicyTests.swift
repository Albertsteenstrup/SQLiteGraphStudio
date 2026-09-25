import XCTest
@testable import StudioMCP

final class MCPReadOnlySQLPolicyTests: XCTestCase {
    func testAcceptsReadQueriesAndSafeBuiltInFunctions() throws {
        try MCPReadOnlySQLPolicy.validate("SELECT count(*), lower(name), replace(name, 'x', 'y'), json_extract(payload, '$.kind') FROM items WHERE id > 0;")
        try MCPReadOnlySQLPolicy.validate("SELECT regexp_replace(name, 'x', 'y'), date_trunc('day', created_at), array_agg(id) FROM items")
        try MCPReadOnlySQLPolicy.validate("VALUES (1), (2)")
        try MCPReadOnlySQLPolicy.validate("WITH RECURSIVE recent(id) AS (SELECT id FROM items WHERE id > 0) SELECT id FROM recent")
        try MCPReadOnlySQLPolicy.validate("SELECT 'load_extension(''x'')' AS text -- writefile('x')\n FROM items")
        try MCPReadOnlySQLPolicy.validate("SELECT [description] FROM [items]")
    }

    func testRejectsNonReadRootsAndDangerousSQLiteOperations() {
        let rejected = [
            "PRAGMA table_info(items)",
            "EXPLAIN SELECT * FROM items",
            "ATTACH DATABASE '/tmp/other.db' AS other",
            "WITH items AS (SELECT 1) SELECT * FROM items; DELETE FROM items",
            "WITH x AS (DELETE FROM items RETURNING id) SELECT * FROM x",
            "WITH x AS (REPLACE INTO items VALUES (1)) SELECT * FROM x",
            "SELECT load_extension('evil')",
            "SELECT writefile('/tmp/out', 'x')",
            "SELECT readfile('/etc/passwd')",
            "SELECT custom_side_effect() FROM items",
            "SELECT public.lower(name) FROM items",
            "SELECT \"public\".LOWER(name) FROM items",
            "SELECT pg_sleep(10)",
            "SELECT pg_read_file('/etc/passwd')",
            "SELECT nextval('private_sequence')",
            "SELECT set_config('search_path', 'public', false)",
            "SELECT * FROM pragma_table_info('items')",
            "SELECT * FROM items; SELECT * FROM secrets",
            "SELECT randomblob(100000000)",
            "SELECT zeroblob(100000000)",
            "SELECTED 1",
        ]
        for sql in rejected {
            XCTAssertThrowsError(try MCPReadOnlySQLPolicy.validate(sql), "Expected rejection for: \(sql)")
        }
    }

    func testIgnoresForbiddenWordsInsideQuotedValuesAndComments() throws {
        try MCPReadOnlySQLPolicy.validate("SELECT 'ATTACH; UPDATE' AS note /* DELETE; DROP */ FROM items; -- INSERT")
        try MCPReadOnlySQLPolicy.validate("SELECT \"DROP\" FROM items")
    }

    /// Each rejected query hides a disallowed call from a scanner that follows
    /// one dialect while the other dialect would run it.
    func testRejectsLexicalFormsWhereSQLiteAndPostgreSQLDisagree() {
        let rejected = [
            // PostgreSQL nests comments; SQLite ends this one at the first */.
            "SELECT 1 /* /* */, custom_side_effect() -- */",
            // SQLite keeps a CR-only line in the comment; PostgreSQL ends it.
            "SELECT 1 --\r, pg_sleep(10)\n",
            "SELECT 1 --\r'\n, custom_side_effect() --'",
            // PostgreSQL dollar quoting and positional parameters.
            "SELECT $$'$$, pg_sleep(10) --'",
            "SELECT $1",
            // PostgreSQL E-strings end at a different quote than SQLite strings.
            "SELECT E'\\'', pg_sleep(10) --'",
            // PostgreSQL reads [ as a subscript or ARRAY constructor, not an identifier.
            "SELECT ARRAY[pg_read_file('/etc/passwd')]",
            "SELECT [a'], custom_side_effect(), ['] FROM items",
            "SELECT tags[1 --] '\n + length(pg_read_file('/etc/passwd'))] --' FROM posts",
            "SELECT `a'`, custom_side_effect() FROM items",
            // A combining mark must not merge with the closing quote.
            "SELECT 'abc'\u{301}, custom_side_effect() --'",
        ]
        for sql in rejected {
            XCTAssertThrowsError(try MCPReadOnlySQLPolicy.validate(sql), "Expected rejection for: \(sql.debugDescription)")
        }
    }

    func testAcceptsPortableFormsOfTheRejectedLexicalRegions() throws {
        try MCPReadOnlySQLPolicy.validate("SELECT tags[1], tags[1:2], ARRAY[1, 2] FROM posts")
        try MCPReadOnlySQLPolicy.validate("SELECT [order items], `name` FROM [line items]")
        try MCPReadOnlySQLPolicy.validate("-- Windows line ending\r\nSELECT 1 /**/ FROM items")
        try MCPReadOnlySQLPolicy.validate("SELECT E'plain', 'C:\\path', regexp_replace(name, '\\d+', '') FROM items")
        try MCPReadOnlySQLPolicy.validate("SELECT 'café\u{301}' AS name, json_extract(payload, '$.kind') FROM items")
    }

    func testRejectsMalformedSQLLexicalRegionsAndOversizedText() {
        XCTAssertThrowsError(try MCPReadOnlySQLPolicy.validate("SELECT 'unterminated"))
        XCTAssertThrowsError(try MCPReadOnlySQLPolicy.validate("SELECT 1 /* unfinished"))
        XCTAssertThrowsError(try MCPReadOnlySQLPolicy.validate(String(repeating: "a", count: MCPReadOnlySQLPolicy.maximumSQLCharacters + 1)))
    }
}
