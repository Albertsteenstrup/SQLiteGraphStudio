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
                
                -- HR
                CREATE TABLE departments ( id INTEGER PRIMARY KEY, name TEXT NOT NULL );
                CREATE TABLE employees ( id INTEGER PRIMARY KEY, user_id INTEGER UNIQUE REFERENCES users(id), dept_id INTEGER REFERENCES departments(id), title TEXT );
                CREATE TABLE salaries ( id INTEGER PRIMARY KEY, emp_id INTEGER NOT NULL REFERENCES employees(id), amount INTEGER NOT NULL, effective_date TEXT );
                CREATE TABLE time_off ( id INTEGER PRIMARY KEY, emp_id INTEGER NOT NULL REFERENCES employees(id), start_date TEXT, end_date TEXT, status TEXT );
                CREATE TABLE evaluations ( id INTEGER PRIMARY KEY, emp_id INTEGER NOT NULL REFERENCES employees(id), reviewer_id INTEGER REFERENCES employees(id), score INTEGER, created_at TEXT );
                
                -- CRM
                CREATE TABLE customers ( id INTEGER PRIMARY KEY, name TEXT NOT NULL, industry TEXT );
                CREATE TABLE contacts ( id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), name TEXT, email TEXT );
                CREATE TABLE leads ( id INTEGER PRIMARY KEY, email TEXT, source TEXT, status TEXT );
                CREATE TABLE deals ( id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), amount INTEGER, close_date TEXT );
                CREATE TABLE activities ( id INTEGER PRIMARY KEY, deal_id INTEGER NOT NULL REFERENCES deals(id), type TEXT, description TEXT );
                
                -- eCommerce
                CREATE TABLE categories ( id INTEGER PRIMARY KEY, name TEXT );
                CREATE TABLE products ( id INTEGER PRIMARY KEY, name TEXT, price INTEGER );
                CREATE TABLE product_categories ( product_id INTEGER REFERENCES products(id), category_id INTEGER REFERENCES categories(id), PRIMARY KEY(product_id, category_id) );
                CREATE TABLE orders ( id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), placed_at TEXT );
                CREATE TABLE order_lines ( id INTEGER PRIMARY KEY, order_id INTEGER NOT NULL REFERENCES orders(id), product_id INTEGER NOT NULL REFERENCES products(id), quantity INTEGER );
                
                -- Inventory
                CREATE TABLE warehouses ( id INTEGER PRIMARY KEY, location TEXT );
                CREATE TABLE bins ( id INTEGER PRIMARY KEY, warehouse_id INTEGER NOT NULL REFERENCES warehouses(id), label TEXT );
                CREATE TABLE stock_levels ( bin_id INTEGER NOT NULL REFERENCES bins(id), product_id INTEGER NOT NULL REFERENCES products(id), quantity INTEGER, PRIMARY KEY (bin_id, product_id) );
                CREATE TABLE suppliers ( id INTEGER PRIMARY KEY, name TEXT );
                CREATE TABLE stock_movements ( id INTEGER PRIMARY KEY, product_id INTEGER REFERENCES products(id), quantity INTEGER, date TEXT );
                
                -- Billing
                CREATE TABLE invoices ( id INTEGER PRIMARY KEY, order_id INTEGER REFERENCES orders(id), amount INTEGER, due_date TEXT );
                CREATE TABLE invoice_lines ( id INTEGER PRIMARY KEY, invoice_id INTEGER REFERENCES invoices(id), description TEXT, amount INTEGER );
                CREATE TABLE payments ( id INTEGER PRIMARY KEY, invoice_id INTEGER REFERENCES invoices(id), amount INTEGER, paid_at TEXT );
                CREATE TABLE taxes ( id INTEGER PRIMARY KEY, region TEXT, rate REAL );
                CREATE TABLE payment_methods ( id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), type TEXT, last_four TEXT );
                
                -- Support
                CREATE TABLE tickets ( id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), subject TEXT, status TEXT );
                CREATE TABLE ticket_messages ( id INTEGER PRIMARY KEY, ticket_id INTEGER REFERENCES tickets(id), sender_user_id INTEGER REFERENCES users(id), body TEXT );
                CREATE TABLE articles ( id INTEGER PRIMARY KEY, title TEXT, body TEXT );
                CREATE TABLE feedback ( id INTEGER PRIMARY KEY, article_id INTEGER REFERENCES articles(id), helpful BOOLEAN );
                CREATE TABLE tags ( id INTEGER PRIMARY KEY, name TEXT );
            """)
        }
    }
}