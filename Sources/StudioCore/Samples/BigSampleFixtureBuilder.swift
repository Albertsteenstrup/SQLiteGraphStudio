@preconcurrency import GRDB
import Foundation

public enum BigSampleFixtureBuilder {
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
                -- Auth
                CREATE TABLE roles ( id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL );
                CREATE TABLE users ( id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL );
                CREATE TABLE user_roles ( user_id INTEGER NOT NULL REFERENCES users(id), role_id INTEGER NOT NULL REFERENCES roles(id), PRIMARY KEY(user_id, role_id) );
                CREATE TABLE sessions ( id TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), expires_at TEXT NOT NULL );
                CREATE TABLE permissions ( id INTEGER PRIMARY KEY, action TEXT NOT NULL );
                CREATE TABLE role_permissions ( role_id INTEGER NOT NULL REFERENCES roles(id), permission_id INTEGER NOT NULL REFERENCES permissions(id), PRIMARY KEY(role_id, permission_id) );
                CREATE TABLE api_keys ( id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), key_hash TEXT NOT NULL, expires_at TEXT );
                CREATE TABLE oauth_clients ( id INTEGER PRIMARY KEY, name TEXT NOT NULL, client_id TEXT UNIQUE NOT NULL );
                CREATE TABLE oauth_tokens ( id INTEGER PRIMARY KEY, client_id INTEGER NOT NULL REFERENCES oauth_clients(id), user_id INTEGER REFERENCES users(id), token TEXT NOT NULL, expires_at TEXT );
                CREATE TABLE login_attempts ( id INTEGER PRIMARY KEY, email TEXT NOT NULL, ip TEXT, success BOOLEAN, attempted_at TEXT );

                -- HR
                CREATE TABLE departments ( id INTEGER PRIMARY KEY, name TEXT NOT NULL );
                CREATE TABLE employees ( id INTEGER PRIMARY KEY, user_id INTEGER UNIQUE REFERENCES users(id), dept_id INTEGER REFERENCES departments(id), title TEXT );
                CREATE TABLE salaries ( id INTEGER PRIMARY KEY, emp_id INTEGER NOT NULL REFERENCES employees(id), amount INTEGER NOT NULL, effective_date TEXT );
                CREATE TABLE time_off ( id INTEGER PRIMARY KEY, emp_id INTEGER NOT NULL REFERENCES employees(id), start_date TEXT, end_date TEXT, status TEXT );
                CREATE TABLE evaluations ( id INTEGER PRIMARY KEY, emp_id INTEGER NOT NULL REFERENCES employees(id), reviewer_id INTEGER REFERENCES employees(id), score INTEGER, created_at TEXT );
                CREATE TABLE job_postings ( id INTEGER PRIMARY KEY, dept_id INTEGER REFERENCES departments(id), title TEXT NOT NULL, status TEXT );
                CREATE TABLE candidates ( id INTEGER PRIMARY KEY, posting_id INTEGER REFERENCES job_postings(id), name TEXT NOT NULL, email TEXT );
                CREATE TABLE interviews ( id INTEGER PRIMARY KEY, candidate_id INTEGER NOT NULL REFERENCES candidates(id), interviewer_id INTEGER REFERENCES employees(id), scheduled_at TEXT );
                CREATE TABLE benefits ( id INTEGER PRIMARY KEY, name TEXT NOT NULL, description TEXT );
                CREATE TABLE employee_benefits ( emp_id INTEGER NOT NULL REFERENCES employees(id), benefit_id INTEGER NOT NULL REFERENCES benefits(id), PRIMARY KEY(emp_id, benefit_id) );

                -- CRM
                CREATE TABLE customers ( id INTEGER PRIMARY KEY, name TEXT NOT NULL, industry TEXT );
                CREATE TABLE contacts ( id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), name TEXT, email TEXT );
                CREATE TABLE leads ( id INTEGER PRIMARY KEY, email TEXT, source TEXT, status TEXT );
                CREATE TABLE deals ( id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), amount INTEGER, close_date TEXT );
                CREATE TABLE activities ( id INTEGER PRIMARY KEY, deal_id INTEGER NOT NULL REFERENCES deals(id), type TEXT, description TEXT );
                CREATE TABLE territories ( id INTEGER PRIMARY KEY, name TEXT NOT NULL, region TEXT );
                CREATE TABLE customer_territories ( customer_id INTEGER NOT NULL REFERENCES customers(id), territory_id INTEGER NOT NULL REFERENCES territories(id), PRIMARY KEY(customer_id, territory_id) );
                CREATE TABLE campaigns ( id INTEGER PRIMARY KEY, name TEXT NOT NULL, start_date TEXT, end_date TEXT );
                CREATE TABLE campaign_leads ( campaign_id INTEGER NOT NULL REFERENCES campaigns(id), lead_id INTEGER NOT NULL REFERENCES leads(id), PRIMARY KEY(campaign_id, lead_id) );
                CREATE TABLE notes ( id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), author_user_id INTEGER REFERENCES users(id), body TEXT, created_at TEXT );

                -- Catalog
                CREATE TABLE categories ( id INTEGER PRIMARY KEY, name TEXT );
                CREATE TABLE products ( id INTEGER PRIMARY KEY, name TEXT, price INTEGER );
                CREATE TABLE product_categories ( product_id INTEGER REFERENCES products(id), category_id INTEGER REFERENCES categories(id), PRIMARY KEY(product_id, category_id) );
                CREATE TABLE suppliers ( id INTEGER PRIMARY KEY, name TEXT );
                CREATE TABLE tags ( id INTEGER PRIMARY KEY, name TEXT );
                CREATE TABLE brands ( id INTEGER PRIMARY KEY, name TEXT NOT NULL );
                CREATE TABLE product_images ( id INTEGER PRIMARY KEY, product_id INTEGER NOT NULL REFERENCES products(id), url TEXT, sort_order INTEGER );
                CREATE TABLE price_lists ( id INTEGER PRIMARY KEY, name TEXT NOT NULL, currency TEXT );
                CREATE TABLE price_list_items ( price_list_id INTEGER NOT NULL REFERENCES price_lists(id), product_id INTEGER NOT NULL REFERENCES products(id), price INTEGER, PRIMARY KEY(price_list_id, product_id) );
                CREATE TABLE promotions ( id INTEGER PRIMARY KEY, name TEXT NOT NULL, discount_pct REAL, starts_at TEXT, ends_at TEXT );

                -- Fulfillment
                CREATE TABLE orders ( id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), placed_at TEXT );
                CREATE TABLE order_lines ( id INTEGER PRIMARY KEY, order_id INTEGER NOT NULL REFERENCES orders(id), product_id INTEGER NOT NULL REFERENCES products(id), quantity INTEGER );
                CREATE TABLE warehouses ( id INTEGER PRIMARY KEY, location TEXT );
                CREATE TABLE bins ( id INTEGER PRIMARY KEY, warehouse_id INTEGER NOT NULL REFERENCES warehouses(id), label TEXT );
                CREATE TABLE stock_levels ( bin_id INTEGER NOT NULL REFERENCES bins(id), product_id INTEGER NOT NULL REFERENCES products(id), quantity INTEGER, PRIMARY KEY (bin_id, product_id) );
                CREATE TABLE stock_movements ( id INTEGER PRIMARY KEY, product_id INTEGER REFERENCES products(id), quantity INTEGER, date TEXT );
                CREATE TABLE carriers ( id INTEGER PRIMARY KEY, name TEXT NOT NULL );
                CREATE TABLE shipments ( id INTEGER PRIMARY KEY, order_id INTEGER NOT NULL REFERENCES orders(id), carrier_id INTEGER REFERENCES carriers(id), shipped_at TEXT, tracking_number TEXT );
                CREATE TABLE shipment_lines ( id INTEGER PRIMARY KEY, shipment_id INTEGER NOT NULL REFERENCES shipments(id), order_line_id INTEGER NOT NULL REFERENCES order_lines(id), quantity INTEGER );
                CREATE TABLE returns ( id INTEGER PRIMARY KEY, order_id INTEGER NOT NULL REFERENCES orders(id), reason TEXT, status TEXT );
                CREATE TABLE return_lines ( id INTEGER PRIMARY KEY, return_id INTEGER NOT NULL REFERENCES returns(id), product_id INTEGER NOT NULL REFERENCES products(id), quantity INTEGER );

                -- Billing
                CREATE TABLE invoices ( id INTEGER PRIMARY KEY, order_id INTEGER REFERENCES orders(id), amount INTEGER, due_date TEXT );
                CREATE TABLE invoice_lines ( id INTEGER PRIMARY KEY, invoice_id INTEGER REFERENCES invoices(id), description TEXT, amount INTEGER );
                CREATE TABLE payments ( id INTEGER PRIMARY KEY, invoice_id INTEGER REFERENCES invoices(id), amount INTEGER, paid_at TEXT );
                CREATE TABLE taxes ( id INTEGER PRIMARY KEY, region TEXT, rate REAL );
                CREATE TABLE payment_methods ( id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), type TEXT, last_four TEXT );
                CREATE TABLE credit_notes ( id INTEGER PRIMARY KEY, invoice_id INTEGER REFERENCES invoices(id), amount INTEGER, issued_at TEXT );
                CREATE TABLE subscriptions ( id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), status TEXT, started_at TEXT );
                CREATE TABLE subscription_items ( id INTEGER PRIMARY KEY, subscription_id INTEGER NOT NULL REFERENCES subscriptions(id), product_id INTEGER NOT NULL REFERENCES products(id), quantity INTEGER );
                CREATE TABLE refunds ( id INTEGER PRIMARY KEY, payment_id INTEGER REFERENCES payments(id), amount INTEGER, refunded_at TEXT );
                CREATE TABLE dunning_events ( id INTEGER PRIMARY KEY, invoice_id INTEGER REFERENCES invoices(id), sent_at TEXT, channel TEXT );

                -- Support
                CREATE TABLE tickets ( id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), subject TEXT, status TEXT );
                CREATE TABLE ticket_messages ( id INTEGER PRIMARY KEY, ticket_id INTEGER REFERENCES tickets(id), sender_user_id INTEGER REFERENCES users(id), body TEXT );
                CREATE TABLE articles ( id INTEGER PRIMARY KEY, title TEXT, body TEXT );
                CREATE TABLE feedback ( id INTEGER PRIMARY KEY, article_id INTEGER REFERENCES articles(id), helpful BOOLEAN );
                CREATE TABLE sla_policies ( id INTEGER PRIMARY KEY, name TEXT NOT NULL, response_hours INTEGER );
                CREATE TABLE ticket_assignments ( id INTEGER PRIMARY KEY, ticket_id INTEGER NOT NULL REFERENCES tickets(id), assignee_user_id INTEGER REFERENCES users(id), assigned_at TEXT );
                CREATE TABLE knowledge_sections ( id INTEGER PRIMARY KEY, name TEXT NOT NULL, sort_order INTEGER );
                CREATE TABLE article_sections ( article_id INTEGER NOT NULL REFERENCES articles(id), section_id INTEGER NOT NULL REFERENCES knowledge_sections(id), PRIMARY KEY(article_id, section_id) );
                CREATE TABLE escalations ( id INTEGER PRIMARY KEY, ticket_id INTEGER NOT NULL REFERENCES tickets(id), escalated_at TEXT, reason TEXT );
            """)
        }
    }
}
