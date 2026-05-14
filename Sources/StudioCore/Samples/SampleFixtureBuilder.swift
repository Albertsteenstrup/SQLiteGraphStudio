@preconcurrency import GRDB
import Foundation

public enum SampleFixtureBuilder {
    public static func buildFixture(at url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let queue = try DatabaseQueue(path: url.path, configuration: configuration)

        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")

            try db.execute(sql: """
            CREATE TABLE authors (
                -- People who can write or edit posts. One row per identity.

                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                email TEXT UNIQUE, -- lowercased, NULL for anonymous-import rows
                bio TEXT,
                -- 0 = soft-deleted, 1 = active. Inactive authors stay referenced from old posts.
                is_active INTEGER NOT NULL DEFAULT 1
            )
            """)

            try db.execute(sql: """
            CREATE TABLE posts (
                -- Content unit. Lifecycle: draft -> published -> archived.

                id INTEGER PRIMARY KEY,
                author_id INTEGER NOT NULL REFERENCES authors(id),
                -- Author who last edited; NULL means the original author is the only editor.
                editor_id INTEGER REFERENCES authors(id),
                title TEXT NOT NULL,
                slug TEXT UNIQUE NOT NULL,
                summary TEXT,
                body TEXT NOT NULL,
                -- draft | published | archived (CHECK-constrained)
                status TEXT NOT NULL CHECK (status IN ('draft', 'published', 'archived')),
                -- NULL for drafts; ISO8601 timestamp once status flips to published.
                published_at TEXT,
                created_at TEXT NOT NULL
            )
            """)

            try db.execute(sql: """
            CREATE TABLE comments (
                -- Reader comments on posts. Threaded via self-FK on parent_id.

                id INTEGER PRIMARY KEY,
                post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
                parent_id INTEGER REFERENCES comments(id), -- NULL for top-level; self-FK for replies
                -- Display name from form; not tied to the authors table
                author_name TEXT NOT NULL,
                author_email TEXT, -- optional; never shown publicly
                body TEXT NOT NULL,
                is_flagged INTEGER NOT NULL DEFAULT 0, -- 1 if moderation flagged this row
                created_at TEXT NOT NULL
            )
            """)

            try db.execute(sql: """
            CREATE TABLE tags (
                -- Flat label vocabulary. One row per unique tag name.

                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE -- lowercase slug, e.g. swift, sqlite
            )
            """)

            try db.execute(sql: """
            CREATE TABLE post_tags (
                -- Many-to-many join between posts and tags.

                post_id INTEGER NOT NULL REFERENCES posts(id),
                tag_id INTEGER NOT NULL REFERENCES tags(id),
                tagged_by INTEGER REFERENCES authors(id), -- author who applied the tag; NULL if imported
                PRIMARY KEY (post_id, tag_id)
            )
            """)

            try db.execute(sql: """
            CREATE TABLE categories (
                -- Two-level taxonomy. slug is PK; parent_slug enables one level of nesting.

                slug TEXT PRIMARY KEY, -- URL-safe identifier, e.g. swift, sqlite
                parent_slug TEXT REFERENCES categories(slug), -- NULL for top-level categories
                name TEXT NOT NULL -- human-readable label
            )
            """)

            try db.execute(sql: """
            CREATE TABLE post_categories (
                -- Assigns posts to taxonomy categories. A post can belong to multiple.

                post_id INTEGER NOT NULL REFERENCES posts(id),
                category_slug TEXT NOT NULL REFERENCES categories(slug),
                PRIMARY KEY (post_id, category_slug)
            )
            """)

            try db.execute(sql: """
            CREATE TABLE attachments (
                -- Files attached to posts. preview stores a small BLOB thumbnail.

                id INTEGER PRIMARY KEY,
                post_id INTEGER REFERENCES posts(id), -- NULL for orphaned uploads
                file_name TEXT NOT NULL,
                mime_type TEXT NOT NULL, -- MIME type string, e.g. image/png
                byte_count INTEGER NOT NULL, -- size of original file in bytes
                preview BLOB -- optional thumbnail; NULL when not generated
            )
            """)

            try db.execute(sql: """
            CREATE TABLE sync_markers (
                -- Key-value store for external-sync cursors. WITHOUT ROWID, composite PK.

                namespace TEXT NOT NULL, -- logical grouping, e.g. feed, jobs
                marker_key TEXT NOT NULL, -- cursor name within the namespace
                marker_value TEXT, -- opaque string cursor; NULL means unset
                PRIMARY KEY (namespace, marker_key)
            ) WITHOUT ROWID
            """)

            try db.execute(sql: """
            CREATE TABLE event_log (
                -- Append-only analytics event log. High volume: 100k rows in sample data.

                id INTEGER PRIMARY KEY,
                post_id INTEGER REFERENCES posts(id), -- NULL for non-post events
                kind TEXT NOT NULL, -- view | share
                payload TEXT, -- opaque string or JSON; format varies by kind
                created_at TEXT NOT NULL
            )
            """)

            try db.execute(sql: """
            CREATE TABLE generated_metrics (
                -- Demo of GENERATED ALWAYS AS columns. One row of synthetic data.

                id INTEGER PRIMARY KEY,
                base_value INTEGER NOT NULL,
                doubled_value INTEGER GENERATED ALWAYS AS (base_value * 2) STORED -- computed; cannot be written
            )
            """)

            try db.execute(sql: "CREATE INDEX idx_posts_status ON posts(status)")

            try db.execute(sql: """
            CREATE TRIGGER posts_touch_updated_at
            AFTER UPDATE ON posts
            BEGIN
                SELECT 1;
            END
            """)

            try db.execute(sql: """
            CREATE VIEW author_profiles AS
              -- Aggregates each author's published post count. Includes authors with zero posts.
              SELECT
                authors.id,
                authors.name,
                authors.email,
                COUNT(posts.id) AS post_count
              FROM authors
              LEFT JOIN posts ON posts.author_id = authors.id
              GROUP BY authors.id, authors.name, authors.email
            """)

            for authorID in 1...8 {
                try db.execute(
                    sql: """
                    INSERT INTO authors (id, name, email, bio, is_active)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        authorID,
                        "Author \(authorID)",
                        authorID % 3 == 0 ? nil : "author\(authorID)@example.com",
                        authorID % 2 == 0 ? String(repeating: "Long bio \(authorID). ", count: 16) : nil,
                        authorID % 5 == 0 ? 0 : 1,
                    ]
                )
            }

            let categories: [(String, String?, String)] = [
                ("tech", nil, "Tech"),
                ("swift", "tech", "Swift"),
                ("sqlite", "tech", "SQLite"),
                ("design", nil, "Design"),
                ("ops", nil, "Ops"),
            ]
            for category in categories {
                try db.execute(
                    sql: "INSERT INTO categories (slug, parent_slug, name) VALUES (?, ?, ?)",
                    arguments: [category.0, category.1, category.2]
                )
            }

            for tagID in 1...12 {
                try db.execute(
                    sql: "INSERT INTO tags (id, name) VALUES (?, ?)",
                    arguments: [tagID, "tag-\(tagID)"]
                )
            }

            for postID in 1...48 {
                let body = String(repeating: "Post \(postID) body paragraph. ", count: postID % 4 == 0 ? 24 : 8)
                try db.execute(
                    sql: """
                    INSERT INTO posts (
                        id, author_id, editor_id, title, slug, summary, body, status, published_at, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        postID,
                        (postID % 8) + 1,
                        postID % 5 == 0 ? nil : ((postID + 3) % 8) + 1,
                        "Post \(postID)",
                        "post-\(postID)",
                        postID % 3 == 0 ? nil : "Summary for post \(postID)",
                        body,
                        postID % 4 == 0 ? "draft" : "published",
                        postID % 4 == 0 ? nil : "2026-03-\(String(format: "%02d", (postID % 28) + 1))",
                        "2026-02-\(String(format: "%02d", (postID % 28) + 1))",
                    ]
                )

                try db.execute(
                    sql: "INSERT INTO post_categories (post_id, category_slug) VALUES (?, ?)",
                    arguments: [postID, postID % 2 == 0 ? "swift" : "sqlite"]
                )

                for tagOffset in 0..<(postID % 3 + 1) {
                    let tagID = ((postID + tagOffset) % 12) + 1
                    try db.execute(
                        sql: "INSERT INTO post_tags (post_id, tag_id, tagged_by) VALUES (?, ?, ?)",
                        arguments: [postID, tagID, ((postID + tagOffset) % 8) + 1]
                    )
                }

                if postID % 6 == 0 {
                    try db.execute(
                        sql: """
                        INSERT INTO attachments (post_id, file_name, mime_type, byte_count, preview)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            postID,
                            "cover-\(postID).png",
                            "image/png",
                            4_096 + postID,
                            Data(repeating: UInt8(postID % 255), count: 32),
                        ]
                    )
                }
            }

            var commentID = 1
            for postID in 1...48 {
                for localIndex in 0..<(postID % 5 + 1) {
                    try db.execute(
                        sql: """
                        INSERT INTO comments (
                            id, post_id, parent_id, author_name, author_email, body, is_flagged, created_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            commentID,
                            postID,
                            localIndex == 0 ? nil : commentID - 1,
                            "Reader \(commentID)",
                            localIndex % 3 == 0 ? nil : "reader\(commentID)@example.com",
                            localIndex == 0 ? "Great post \(postID)." : "Reply \(localIndex) on post \(postID).",
                            localIndex == 4 ? 1 : 0,
                            "2026-04-\(String(format: "%02d", (commentID % 28) + 1))",
                        ]
                    )
                    commentID += 1
                }
            }

            let syncMarkers: [(String, String, String?)] = [
                ("feed", "latest-id", "5001"),
                ("feed", "next-page", nil),
                ("jobs", "last-run", "2026-04-22T10:15:00Z"),
            ]
            for marker in syncMarkers {
                try db.execute(
                    sql: "INSERT INTO sync_markers (namespace, marker_key, marker_value) VALUES (?, ?, ?)",
                    arguments: [marker.0, marker.1, marker.2]
                )
            }

            try db.execute(sql: "INSERT INTO generated_metrics (id, base_value) VALUES (1, 7)")

            try db.inTransaction {
                for eventID in 1...100_000 {
                    try db.execute(
                        sql: """
                        INSERT INTO event_log (id, post_id, kind, payload, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            eventID,
                            eventID % 17 == 0 ? nil : ((eventID % 48) + 1),
                            eventID % 2 == 0 ? "view" : "share",
                            "payload-\(eventID)-\(String(repeating: "x", count: eventID % 20))",
                            "2026-04-\(String(format: "%02d", (eventID % 28) + 1))T12:00:00Z",
                        ]
                    )
                }
                return .commit
            }
        }
    }
}
