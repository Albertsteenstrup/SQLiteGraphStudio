import Foundation
import Testing
@testable import StudioCore

/// Replaying migration DDL must reconstruct the schema those files describe,
/// and must say so when it cannot.
struct MigrationSchemaReplayTests {

    // MARK: - Helpers

    private func makeSet(_ files: [(String, String)], dialect: SQLDialect = .postgreSQL) throws -> (MigrationSet, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var migrations: [MigrationFile] = []
        for (name, sql) in files {
            let url = directory.appendingPathComponent(name)
            try sql.write(to: url, atomically: true, encoding: .utf8)
            guard let parsed = ProjectScanner.migrationVersion(fileName: name) else { continue }
            migrations.append(MigrationFile(url: url, version: parsed.version, sortKey: parsed.sortKey, fileName: name))
        }
        migrations.sort { $0.sortKey < $1.sortKey }
        return (MigrationSet(directoryURL: directory, files: migrations, dialect: dialect), directory)
    }

    private func replay(_ files: [(String, String)], dialect: SQLDialect = .postgreSQL,
                        through version: String? = nil) throws -> MigrationSchemaModel {
        let (set, directory) = try makeSet(files, dialect: dialect)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try MigrationSchemaReplay.buildModel(files: set.files(through: version), dialect: dialect)
    }

    private func descriptor(_ model: MigrationSchemaModel, _ name: String) throws -> TableDescriptor {
        try #require(model.catalog.descriptors.first { $0.name == name })
    }

    // MARK: - CREATE TABLE

    @Test func createTableCapturesColumnsKeysAndDefaults() throws {
        let model = try replay([("0001_init.sql", """
        create table app_user (
            id uuid primary key default gen_random_uuid(),
            email text not null unique,
            display_name character varying(120),
            created_at timestamp with time zone not null default now(),
            login_count integer not null default 0,
            search tsvector generated always as (to_tsvector('simple', email)) stored
        );
        """)])

        let user = try descriptor(model, "public.app_user")
        #expect(user.columns.map(\.name) == ["id", "email", "display_name", "created_at", "login_count", "search"])
        #expect(user.primaryKeyColumns == ["id"])
        #expect(user.displayName == "app_user")
        #expect(user.isEditable == false)
        #expect(user.rowCount == nil)

        let email = try #require(user.columns.first { $0.name == "email" })
        #expect(email.notNull)
        #expect(email.declaredType == "text")

        let displayName = try #require(user.columns.first { $0.name == "display_name" })
        #expect(displayName.declaredType == "character varying(120)")
        #expect(displayName.notNull == false)

        let createdAt = try #require(user.columns.first { $0.name == "created_at" })
        #expect(createdAt.declaredType == "timestamp with time zone")
        #expect(createdAt.defaultValueSQL == "now()")

        let search = try #require(user.columns.first { $0.name == "search" })
        #expect(search.isGenerated)
        #expect(user.generatedColumns.map(\.name) == ["search"])

        // The inline UNIQUE becomes a unique index, as PostgreSQL would create.
        #expect(user.indexes.contains { $0.columns == ["email"] && $0.isUnique })
        #expect(model.diagnostics.isEmpty)
    }

    @Test func inlineAndTableLevelForeignKeysBecomeGraphEdges() throws {
        let model = try replay([("0001_init.sql", """
        create table account (id bigint primary key);
        create table invoice (
            id bigint primary key,
            account_id bigint not null references account(id) on delete cascade
        );
        create table invoice_line (
            invoice_id bigint not null,
            line_no int not null,
            primary key (invoice_id, line_no),
            constraint invoice_line_invoice_fk foreign key (invoice_id) references invoice (id)
        );
        """)])

        let edges = model.catalog.graph.edges
        #expect(edges.contains { $0.sourceID == "public.invoice" && $0.targetID == "public.account" })
        #expect(edges.contains { $0.sourceID == "public.invoice_line" && $0.targetID == "public.invoice" })

        // account_id is not unique on invoice, id is unique on account.
        let invoiceEdge = try #require(edges.first { $0.sourceID == "public.invoice" })
        #expect(invoiceEdge.cardinality == .manyToOne)
        #expect(invoiceEdge.sourceColumn == "account_id")
        #expect(invoiceEdge.targetColumn == "id")
    }

    @Test func aUniqueForeignKeyIsOneToOne() throws {
        let model = try replay([("0001_init.sql", """
        create table account (id bigint primary key);
        create table account_profile (
            account_id bigint primary key references account(id)
        );
        """)])
        let edge = try #require(model.catalog.graph.edges.first)
        #expect(edge.cardinality == .oneToOne)
    }

    @Test func aForeignKeyWithoutColumnListResolvesToThePrimaryKey() throws {
        let model = try replay([("0001_init.sql", """
        create table account (id bigint primary key);
        create table note (id bigint primary key, account_id bigint references account);
        """)])
        let edge = try #require(model.catalog.graph.edges.first)
        #expect(edge.targetColumn == "id")
    }

    // MARK: - ALTER TABLE

    @Test func alterTableAddsDropsAndRenames() throws {
        let model = try replay([
            ("0001_init.sql", "create table widget (id bigint primary key, old_name text, doomed int);"),
            ("0002_change.sql", """
            alter table widget add column colour text not null default 'red';
            alter table widget drop column doomed;
            alter table widget rename column old_name to name;
            alter table widget alter column name set not null;
            alter table public.widget add constraint widget_name_key unique (name);
            """),
        ])

        let widget = try descriptor(model, "public.widget")
        #expect(widget.columns.map(\.name) == ["id", "name", "colour"])
        let name = try #require(widget.columns.first { $0.name == "name" })
        #expect(name.notNull)
        #expect(widget.indexes.contains { $0.name == "widget_name_key" && $0.isUnique })
        let colour = try #require(widget.columns.first { $0.name == "colour" })
        #expect(colour.defaultValueSQL == "'red'")
    }

    @Test func alterTableAcceptsSeveralCommaSeparatedActions() throws {
        let model = try replay([("0001_init.sql", """
        create table t (id int primary key);
        alter table t add column a text, add column b int not null default 0, drop column id;
        """)])
        let table = try descriptor(model, "public.t")
        #expect(table.columns.map(\.name) == ["a", "b"])
        #expect(table.primaryKeyColumns.isEmpty)
    }

    @Test func renamingATableKeepsForeignKeysPointingAtIt() throws {
        let model = try replay([
            ("0001_init.sql", """
            create table supplier (id bigint primary key);
            create table contract (id bigint primary key, supplier_id bigint references supplier(id));
            """),
            ("0002_rename.sql", "alter table supplier rename to vendor;"),
        ])
        #expect(model.catalog.descriptors.map(\.name).contains("public.vendor"))
        let edge = try #require(model.catalog.graph.edges.first)
        #expect(edge.targetID == "public.vendor")
    }

    @Test func droppingAConstraintRemovesItsEdge() throws {
        let model = try replay([
            ("0001_init.sql", """
            create table a (id int primary key);
            create table b (id int primary key, a_id int);
            alter table b add constraint b_a_fk foreign key (a_id) references a(id);
            """),
            ("0002_drop.sql", "alter table b drop constraint if exists b_a_fk;"),
        ])
        #expect(model.catalog.graph.edges.isEmpty)
    }

    @Test func droppingATableRemovesItAndIncomingEdges() throws {
        let model = try replay([
            ("0001_init.sql", """
            create table a (id int primary key);
            create table b (id int primary key, a_id int references a(id));
            """),
            ("0002_drop.sql", "drop table if exists a cascade;"),
        ])
        #expect(model.catalog.descriptors.map(\.name) == ["public.b"])
        #expect(model.catalog.graph.edges.isEmpty)
    }

    // MARK: - Indexes, views and triggers

    @Test func indexesAreReplayedIncludingPartialAndExpressionForms() throws {
        let model = try replay([("0001_init.sql", """
        create table event (id bigint primary key, kind text, payload jsonb, at timestamptz);
        create index event_kind_idx on event (kind);
        create unique index concurrently if not exists event_kind_at_key on public.event using btree (kind, at desc);
        create index event_open_idx on event (kind) where at is null;
        create index event_payload_idx on event ((payload->>'id'));
        drop index event_kind_idx;
        """)])

        let event = try descriptor(model, "public.event")
        let names = event.indexes.map(\.name)
        #expect(!names.contains("event_kind_idx"))
        #expect(names.contains("event_kind_at_key"))
        #expect(names.contains("event_open_idx"))
        let unique = try #require(event.indexes.first { $0.name == "event_kind_at_key" })
        #expect(unique.isUnique)
        #expect(unique.columns == ["kind", "at"])
        let partial = try #require(event.indexes.first { $0.name == "event_open_idx" })
        #expect(partial.isPartial)
    }

    @Test func viewsBecomeNodesWithProjectedColumnNames() throws {
        let model = try replay([("0001_init.sql", """
        create table contract (id bigint primary key, vendor_id bigint, signed_at date);
        create or replace view active_contract as
            select c.id, c.vendor_id as vendor, count(*) as total
            from contract c
            group by c.id, c.vendor_id;
        """)])
        let view = try descriptor(model, "public.active_contract")
        #expect(view.objectType == .view)
        #expect(view.columns.map(\.name) == ["id", "vendor", "total"])
    }

    @Test func triggersAreAttachedToTheirTable() throws {
        let model = try replay([("0001_init.sql", """
        create table audit (id bigint primary key);
        create trigger audit_touch after insert or update on audit
            for each row execute function touch();
        """)])
        let audit = try descriptor(model, "public.audit")
        #expect(audit.triggers.map(\.name) == ["audit_touch"])
    }

    // MARK: - Lexing

    @Test func dollarQuotedBodiesDoNotSplitStatements() throws {
        let model = try replay([("0001_init.sql", """
        create table t (id int primary key);
        create or replace function touch() returns trigger language plpgsql as $$
        begin
            -- a semicolon; inside a body must not end the statement
            new.updated_at := now();
            return new;
        end
        $$;
        create table after_function (id int primary key);
        """)])
        #expect(Set(model.catalog.descriptors.map(\.name)) == ["public.t", "public.after_function"])
        #expect(model.diagnostics.isEmpty)
    }

    @Test func commentsAndStringLiteralsNeverTerminateAStatement() throws {
        let model = try replay([("0001_init.sql", """
        -- leading comment; with a semicolon
        /* block ; comment
           spanning lines */
        create table t (
            id int primary key,
            label text not null default 'a;b''c'  -- trailing ; comment
        );
        """)])
        let table = try descriptor(model, "public.t")
        #expect(table.columns.map(\.name) == ["id", "label"])
        let label = try #require(table.columns.first { $0.name == "label" })
        #expect(label.defaultValueSQL == "'a;b''c'")
    }

    @Test func ddlGuardedByAPlPgSQLBlockIsApplied() throws {
        let model = try replay([
            ("0001_init.sql", """
            create table a (id int primary key);
            create table b (id int primary key, a_id int);
            """),
            ("0002_guarded.sql", """
            do $$
            begin
                if not exists (select 1 from pg_constraint where conname = 'b_a_fk') then
                    alter table b
                        add constraint b_a_fk
                        foreign key (a_id)
                        references a(id)
                        on delete set null;
                end if;
            end
            $$;
            """),
        ])
        let edge = try #require(model.catalog.graph.edges.first)
        #expect(edge.sourceID == "public.b")
        #expect(edge.targetID == "public.a")
    }

    @Test func dataStatementsAreIgnoredWithoutDiagnostics() throws {
        let model = try replay([("0001_init.sql", """
        begin;
        set search_path = public;
        create table t (id int primary key);
        insert into t (id) values (1), (2);
        update t set id = id + 1 where id = 1;
        delete from t where id = 99;
        analyze t;
        commit;
        """)])
        #expect(model.catalog.descriptors.map(\.name) == ["public.t"])
        #expect(model.diagnostics.isEmpty)
    }

    // MARK: - Descriptions and diagnostics

    @Test func commentOnBecomesTableAndColumnDescriptions() throws {
        let model = try replay([("0001_init.sql", """
        create table vendor (id bigint primary key, name text);
        comment on table vendor is 'A supplier of services.';
        comment on column vendor.name is 'Legal entity name.';
        """)])
        let description = try #require(model.catalog.sourceDescriptions["public.vendor"])
        #expect(description.description == "A supplier of services.")
        #expect(description.columns["name"] == "Legal entity name.")
        #expect(model.catalog.sourceDescriptions["public.vendor"] != nil)
    }

    // MARK: - Malformed and hostile input

    /// A quoted identifier or literal can spell "(" without being one. Deciding
    /// from the token's text rather than its kind left the view parser unable to
    /// advance, hanging the replay with the whole window disabled behind it.
    @Test func aViewWhoseCTEHoldsParenthesisShapedTokensStillFinishes() throws {
        let model = try replay([("0001_init.sql", """
        create table t (id int primary key, a int);
        create view v1 as with "(" as (select 1 as a) select a from "(";
        create view v2 as with x as (select 1 as a) select a from x where a <> '(';
        """)])
        #expect(model.catalog.descriptors.map(\.name).contains("public.v1"))
        #expect(model.catalog.descriptors.map(\.name).contains("public.v2"))
    }

    @Test func unterminatedQuotesAndCommentsDoNotHangOrCorruptEarlierTables() throws {
        let model = try replay([("0001_init.sql", """
        create table kept (id int primary key);
        create table half (id int primary key, label text default 'unterminated
        """)])
        #expect(model.catalog.descriptors.map(\.name).contains("public.kept"))

        let dollar = try replay([("0001_init.sql", """
        create table kept (id int primary key);
        create function f() returns void as $body$ begin
        """)])
        #expect(dollar.catalog.descriptors.map(\.name) == ["public.kept"])

        let comment = try replay([("0001_init.sql", """
        create table kept (id int primary key);
        /* never closed
        create table lost (id int primary key);
        """)])
        #expect(comment.catalog.descriptors.map(\.name) == ["public.kept"])
    }

    @Test func deeplyNestedExpressionsAreBounded() throws {
        let depth = 2_000
        let nested = String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth)
        let clock = ContinuousClock()
        let start = clock.now
        let model = try replay([("0001_init.sql", "create table t (id int primary key, n int default \(nested));")])
        #expect(clock.now - start < .seconds(20))
        #expect(model.catalog.descriptors.map(\.name) == ["public.t"])
    }

    @Test func statementsThatCannotBeReplayedAreReported() throws {
        let model = try replay([("0001_init.sql", """
        create table report as select 1 as n;
        alter table missing_table add column x int;
        """)])
        #expect(model.diagnostics.count == 2)
        #expect(model.diagnostics.contains { $0.message.contains("CREATE TABLE … AS") })
        #expect(model.diagnostics.contains { $0.message.contains("unknown table") })
        #expect(model.diagnostics.allSatisfy { $0.fileName == "0001_init.sql" })
    }

    // MARK: - Version selection

    @Test func replayingThroughAnEarlierVersionStopsThere() throws {
        let files = [
            ("0001_init.sql", "create table a (id int primary key);"),
            ("0002_more.sql", "create table b (id int primary key);"),
            ("0003_even_more.sql", "create table c (id int primary key);"),
        ]
        let latest = try replay(files)
        #expect(latest.catalog.descriptors.count == 3)

        let earlier = try replay(files, through: "0002")
        #expect(earlier.catalog.descriptors.map(\.name) == ["public.a", "public.b"])
        #expect(earlier.fileCount == 2)
    }

    // MARK: - SQLite dialect

    @Test func sqliteSchemasAreUnqualifiedAndKeepTheirDeclaredCase() throws {
        let model = try replay([("0001_init.sql", """
        CREATE TABLE Country (
            code TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            is_eea INTEGER NOT NULL DEFAULT 0 CHECK (is_eea IN (0,1))
        );
        CREATE TABLE Vendor (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            country_code TEXT REFERENCES Country(code)
        ) WITHOUT ROWID;
        """)], dialect: .sqlite)

        #expect(Set(model.catalog.descriptors.map(\.name)) == ["Country", "Vendor"])
        let vendor = try descriptor(model, "Vendor")
        #expect(vendor.schemaName == nil)
        #expect(vendor.isWithoutRowID)
        let edge = try #require(model.catalog.graph.edges.first)
        #expect(edge.sourceID == "Vendor")
        #expect(edge.targetID == "Country")

        let country = try descriptor(model, "Country")
        #expect(country.constraints.contains { $0.kind == .check && $0.columns == ["is_eea"] })
    }

    // MARK: - Backend

    @Test func theBackendServesSchemaAndRefusesRowWork() async throws {
        let (set, directory) = try makeSet([
            ("0001_init.sql", "create table t (id int primary key, name text);"),
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        let backend = MigrationSchemaBackend()
        try await backend.open(set: set, through: nil)
        #expect(backend.capabilities.canBrowseRows == false)
        #expect(backend.capabilities.canRunQueries == false)
        #expect(backend.capabilities.isReadOnly)

        let tables = try await backend.listTables()
        #expect(tables.map(\.name) == ["public.t"])

        let descriptor = try await backend.fetchDescriptor(named: "public.t")
        let chunk = try await backend.fetchChunk(query: TableQueryState(), descriptor: descriptor)
        #expect(chunk.rows.isEmpty)
        #expect(chunk.totalRowCount == 0)

        await #expect(throws: DatabaseUserError.self) {
            _ = try await backend.executeReadOnlyQuery(sql: "select 1", rowLimit: 1, timeoutSeconds: 1)
        }
        await #expect(throws: DatabaseUserError.self) {
            try await backend.createTable(TableCreateDraft(tableName: "x", columns: []))
        }
    }

    @Test func anEmptyMigrationSelectionIsRejected() async throws {
        let backend = MigrationSchemaBackend()
        let set = MigrationSet(directoryURL: URL(fileURLWithPath: "/tmp"), files: [], dialect: .postgreSQL)
        await #expect(throws: DatabaseUserError.self) {
            try await backend.open(set: set, through: nil)
        }
    }
}
