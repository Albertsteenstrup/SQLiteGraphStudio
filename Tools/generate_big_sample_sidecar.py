#!/usr/bin/env python3
"""Generate Samples/big_sample.sqlite.studio.json for the 70-table big sample."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIDECAR = ROOT / "Samples" / "big_sample.sqlite.studio.json"

TABLES: dict[str, dict] = {
    # Auth
    "roles": {
        "description": "auth.roles -- Role catalog, one row per named access role.",
        "columns": {"name": "Unique role name."},
    },
    "users": {
        "description": "auth.users -- Login accounts, one row per authenticated user.",
        "columns": {"email": "Unique login email.", "password_hash": "Stored password hash."},
    },
    "user_roles": {
        "description": "auth.user_roles -- Join rows assigning roles to users.",
        "columns": {"user_id": "FK -> users.id.", "role_id": "FK -> roles.id."},
    },
    "sessions": {
        "description": "auth.sessions -- Active login sessions keyed by session token.",
        "columns": {
            "id": "Session token primary key.",
            "user_id": "FK -> users.id.",
            "expires_at": "Session expiry timestamp.",
        },
    },
    "permissions": {
        "description": "auth.permissions -- Action catalog for permission checks.",
        "columns": {"action": "Permission action name."},
    },
    "role_permissions": {
        "description": "auth.role_permissions -- Join rows granting permissions to roles.",
        "columns": {
            "role_id": "FK -> roles.id.",
            "permission_id": "FK -> permissions.id.",
        },
    },
    "api_keys": {
        "description": "auth.api_keys -- Programmatic access keys owned by users.",
        "columns": {
            "user_id": "FK -> users.id.",
            "key_hash": "Hashed API key value.",
            "expires_at": "Optional key expiry timestamp.",
        },
    },
    "oauth_clients": {
        "description": "auth.oauth_clients -- Registered OAuth client applications.",
        "columns": {"name": "Client display name.", "client_id": "Public client identifier."},
    },
    "oauth_tokens": {
        "description": "auth.oauth_tokens -- Issued OAuth access tokens for clients and users.",
        "columns": {
            "client_id": "FK -> oauth_clients.id.",
            "user_id": "Optional FK -> users.id.",
            "token": "Opaque access token.",
            "expires_at": "Token expiry timestamp.",
        },
    },
    "login_attempts": {
        "description": "auth.login_attempts -- Audit log of sign-in attempts by email.",
        "columns": {
            "email": "Attempted login email.",
            "ip": "Source IP address.",
            "success": "Whether credentials matched.",
            "attempted_at": "Attempt timestamp.",
        },
    },
    # HR
    "departments": {
        "description": "hr.departments -- Company departments for employee assignment.",
        "columns": {"name": "Department display name."},
    },
    "employees": {
        "description": "hr.employees -- Employee records linked optionally to user accounts.",
        "columns": {
            "user_id": "Unique FK -> users.id.",
            "dept_id": "FK -> departments.id.",
            "title": "Employee job title.",
        },
    },
    "salaries": {
        "description": "hr.salaries -- Salary history rows for employees.",
        "columns": {
            "emp_id": "FK -> employees.id.",
            "amount": "Salary amount in sample units.",
            "effective_date": "Date salary became effective.",
        },
    },
    "time_off": {
        "description": "hr.time_off -- Employee leave requests by date range.",
        "columns": {
            "emp_id": "FK -> employees.id.",
            "start_date": "Leave start date.",
            "end_date": "Leave end date.",
            "status": "Request workflow status.",
        },
    },
    "evaluations": {
        "description": "hr.evaluations -- Employee performance reviews by reviewer.",
        "columns": {
            "emp_id": "FK -> reviewed employee.",
            "reviewer_id": "FK -> reviewing employee.",
            "score": "Review score.",
            "created_at": "Review creation timestamp.",
        },
    },
    "job_postings": {
        "description": "hr.job_postings -- Open requisitions tied to departments.",
        "columns": {
            "dept_id": "FK -> departments.id.",
            "title": "Job title being hired.",
            "status": "open | closed | draft",
        },
    },
    "candidates": {
        "description": "hr.candidates -- Applicants linked to job postings.",
        "columns": {
            "posting_id": "FK -> job_postings.id.",
            "name": "Candidate display name.",
            "email": "Candidate contact email.",
        },
    },
    "interviews": {
        "description": "hr.interviews -- Scheduled interviews for candidates.",
        "columns": {
            "candidate_id": "FK -> candidates.id.",
            "interviewer_id": "FK -> employees.id.",
            "scheduled_at": "Interview start timestamp.",
        },
    },
    "benefits": {
        "description": "hr.benefits -- Benefit plan catalog offered to employees.",
        "columns": {"name": "Benefit plan name.", "description": "Short plan summary."},
    },
    "employee_benefits": {
        "description": "hr.employee_benefits -- Join rows enrolling employees in benefits.",
        "columns": {
            "emp_id": "FK -> employees.id.",
            "benefit_id": "FK -> benefits.id.",
        },
    },
    # CRM
    "customers": {
        "description": "crm.customers -- Customer organizations, one row per account.",
        "columns": {"name": "Customer organization name.", "industry": "Customer industry segment."},
    },
    "contacts": {
        "description": "crm.contacts -- People attached to customer accounts.",
        "columns": {
            "customer_id": "FK -> customers.id.",
            "name": "Contact display name.",
            "email": "Contact email address.",
        },
    },
    "leads": {
        "description": "crm.leads -- Prospective customers before account conversion.",
        "columns": {
            "email": "Lead contact email.",
            "source": "Acquisition source.",
            "status": "Lead pipeline status.",
        },
    },
    "deals": {
        "description": "crm.deals -- Sales opportunities tied to customers.",
        "columns": {
            "customer_id": "FK -> customers.id.",
            "amount": "Deal value in sample units.",
            "close_date": "Expected or actual close date.",
        },
    },
    "activities": {
        "description": "crm.activities -- Logged sales activities for deals.",
        "columns": {
            "deal_id": "FK -> deals.id.",
            "type": "Activity type.",
            "description": "Activity detail text.",
        },
    },
    "territories": {
        "description": "crm.territories -- Sales territories for account coverage.",
        "columns": {"name": "Territory name.", "region": "Geographic region label."},
    },
    "customer_territories": {
        "description": "crm.customer_territories -- Join rows assigning customers to territories.",
        "columns": {
            "customer_id": "FK -> customers.id.",
            "territory_id": "FK -> territories.id.",
        },
    },
    "campaigns": {
        "description": "crm.campaigns -- Marketing campaigns with date ranges.",
        "columns": {
            "name": "Campaign name.",
            "start_date": "Campaign start date.",
            "end_date": "Campaign end date.",
        },
    },
    "campaign_leads": {
        "description": "crm.campaign_leads -- Join rows attaching leads to campaigns.",
        "columns": {
            "campaign_id": "FK -> campaigns.id.",
            "lead_id": "FK -> leads.id.",
        },
    },
    "notes": {
        "description": "crm.notes -- Account notes authored by internal users.",
        "columns": {
            "customer_id": "FK -> customers.id.",
            "author_user_id": "FK -> users.id.",
            "body": "Note body text.",
            "created_at": "Note creation timestamp.",
        },
    },
    # Catalog
    "categories": {
        "description": "catalog.categories -- Product category vocabulary.",
        "columns": {"name": "Category display name."},
    },
    "products": {
        "description": "catalog.products -- Sellable product catalog entries.",
        "columns": {"name": "Product display name.", "price": "Unit price in sample units."},
    },
    "product_categories": {
        "description": "catalog.product_categories -- Join rows assigning products to categories.",
        "columns": {
            "product_id": "FK -> products.id.",
            "category_id": "FK -> categories.id.",
        },
    },
    "suppliers": {
        "description": "catalog.suppliers -- Supplier organizations for procurement demos.",
        "columns": {"name": "Supplier organization name."},
    },
    "tags": {
        "description": "catalog.tags -- Standalone tag vocabulary for sample metadata.",
        "columns": {"name": "Tag display name."},
    },
    "brands": {
        "description": "catalog.brands -- Product brand catalog.",
        "columns": {"name": "Brand display name."},
    },
    "product_images": {
        "description": "catalog.product_images -- Image URLs attached to products.",
        "columns": {
            "product_id": "FK -> products.id.",
            "url": "Image asset URL.",
            "sort_order": "Display ordering index.",
        },
    },
    "price_lists": {
        "description": "catalog.price_lists -- Named price lists by currency.",
        "columns": {"name": "Price list name.", "currency": "ISO currency code."},
    },
    "price_list_items": {
        "description": "catalog.price_list_items -- Product prices within a price list.",
        "columns": {
            "price_list_id": "FK -> price_lists.id.",
            "product_id": "FK -> products.id.",
            "price": "List price in sample units.",
        },
    },
    "promotions": {
        "description": "catalog.promotions -- Time-bound discount promotions.",
        "columns": {
            "name": "Promotion name.",
            "discount_pct": "Discount percentage as decimal.",
            "starts_at": "Promotion start timestamp.",
            "ends_at": "Promotion end timestamp.",
        },
    },
    # Fulfillment
    "orders": {
        "description": "fulfillment.orders -- Customer purchase orders by placement time.",
        "columns": {
            "customer_id": "FK -> customers.id.",
            "placed_at": "Order placement timestamp.",
        },
    },
    "order_lines": {
        "description": "fulfillment.order_lines -- Product line items within orders.",
        "columns": {
            "order_id": "FK -> orders.id.",
            "product_id": "FK -> products.id.",
            "quantity": "Ordered unit count.",
        },
    },
    "warehouses": {
        "description": "fulfillment.warehouses -- Warehouse locations for inventory storage.",
        "columns": {"location": "Warehouse location label."},
    },
    "bins": {
        "description": "fulfillment.bins -- Physical storage bins inside warehouses.",
        "columns": {"warehouse_id": "FK -> warehouses.id.", "label": "Bin location label."},
    },
    "stock_levels": {
        "description": "fulfillment.stock_levels -- Current product quantities by bin.",
        "columns": {
            "bin_id": "FK -> bins.id.",
            "product_id": "FK -> products.id.",
            "quantity": "On-hand unit count.",
        },
    },
    "stock_movements": {
        "description": "fulfillment.stock_movements -- Inventory adjustments for products over time.",
        "columns": {
            "product_id": "FK -> products.id.",
            "quantity": "Signed movement quantity.",
            "date": "Movement date.",
        },
    },
    "carriers": {
        "description": "fulfillment.carriers -- Shipping carrier catalog.",
        "columns": {"name": "Carrier display name."},
    },
    "shipments": {
        "description": "fulfillment.shipments -- Outbound shipments for customer orders.",
        "columns": {
            "order_id": "FK -> orders.id.",
            "carrier_id": "FK -> carriers.id.",
            "shipped_at": "Ship timestamp.",
            "tracking_number": "Carrier tracking identifier.",
        },
    },
    "shipment_lines": {
        "description": "fulfillment.shipment_lines -- Order line quantities included in a shipment.",
        "columns": {
            "shipment_id": "FK -> shipments.id.",
            "order_line_id": "FK -> order_lines.id.",
            "quantity": "Shipped unit count.",
        },
    },
    "returns": {
        "description": "fulfillment.returns -- Customer return requests against orders.",
        "columns": {
            "order_id": "FK -> orders.id.",
            "reason": "Return reason text.",
            "status": "Return workflow status.",
        },
    },
    "return_lines": {
        "description": "fulfillment.return_lines -- Product quantities being returned.",
        "columns": {
            "return_id": "FK -> returns.id.",
            "product_id": "FK -> products.id.",
            "quantity": "Returned unit count.",
        },
    },
    # Billing
    "invoices": {
        "description": "billing.invoices -- Customer invoices generated from orders.",
        "columns": {
            "order_id": "FK -> orders.id.",
            "amount": "Invoice total in sample units.",
            "due_date": "Payment due date.",
        },
    },
    "invoice_lines": {
        "description": "billing.invoice_lines -- Line-level invoice charges.",
        "columns": {
            "invoice_id": "FK -> invoices.id.",
            "description": "Charge description.",
            "amount": "Line amount in sample units.",
        },
    },
    "payments": {
        "description": "billing.payments -- Payments recorded against invoices.",
        "columns": {
            "invoice_id": "FK -> invoices.id.",
            "amount": "Payment amount in sample units.",
            "paid_at": "Payment timestamp.",
        },
    },
    "taxes": {
        "description": "billing.taxes -- Regional tax rates for billing demos.",
        "columns": {"region": "Tax region code or label.", "rate": "Tax rate as decimal."},
    },
    "payment_methods": {
        "description": "billing.payment_methods -- Stored customer payment instruments.",
        "columns": {
            "customer_id": "FK -> customers.id.",
            "type": "Payment method type.",
            "last_four": "Last four visible digits.",
        },
    },
    "credit_notes": {
        "description": "billing.credit_notes -- Credits issued against invoices.",
        "columns": {
            "invoice_id": "FK -> invoices.id.",
            "amount": "Credit amount in sample units.",
            "issued_at": "Credit issue timestamp.",
        },
    },
    "subscriptions": {
        "description": "billing.subscriptions -- Recurring billing agreements for customers.",
        "columns": {
            "customer_id": "FK -> customers.id.",
            "status": "active | paused | canceled",
            "started_at": "Subscription start timestamp.",
        },
    },
    "subscription_items": {
        "description": "billing.subscription_items -- Products billed on a subscription.",
        "columns": {
            "subscription_id": "FK -> subscriptions.id.",
            "product_id": "FK -> products.id.",
            "quantity": "Billed unit count.",
        },
    },
    "refunds": {
        "description": "billing.refunds -- Refunds recorded against payments.",
        "columns": {
            "payment_id": "FK -> payments.id.",
            "amount": "Refund amount in sample units.",
            "refunded_at": "Refund timestamp.",
        },
    },
    "dunning_events": {
        "description": "billing.dunning_events -- Payment reminder events for overdue invoices.",
        "columns": {
            "invoice_id": "FK -> invoices.id.",
            "sent_at": "Reminder sent timestamp.",
            "channel": "email | sms | letter",
        },
    },
    # Support
    "tickets": {
        "description": "support.tickets -- Customer support cases by subject and status.",
        "columns": {
            "customer_id": "FK -> customers.id.",
            "subject": "Ticket subject line.",
            "status": "Support workflow status.",
        },
    },
    "ticket_messages": {
        "description": "support.ticket_messages -- Conversation messages inside support tickets.",
        "columns": {
            "ticket_id": "FK -> tickets.id.",
            "sender_user_id": "FK -> users.id.",
            "body": "Message body text.",
        },
    },
    "articles": {
        "description": "support.articles -- Knowledge base articles for self-service help.",
        "columns": {"title": "Article title.", "body": "Article content."},
    },
    "feedback": {
        "description": "support.feedback -- Helpfulness votes for knowledge base articles.",
        "columns": {"article_id": "FK -> articles.id.", "helpful": "Boolean helpfulness vote."},
    },
    "sla_policies": {
        "description": "support.sla_policies -- Response-time targets for support queues.",
        "columns": {"name": "Policy name.", "response_hours": "Target first-response hours."},
    },
    "ticket_assignments": {
        "description": "support.ticket_assignments -- Agent ownership rows for tickets.",
        "columns": {
            "ticket_id": "FK -> tickets.id.",
            "assignee_user_id": "FK -> users.id.",
            "assigned_at": "Assignment timestamp.",
        },
    },
    "knowledge_sections": {
        "description": "support.knowledge_sections -- Top-level help center sections.",
        "columns": {"name": "Section title.", "sort_order": "Display ordering index."},
    },
    "article_sections": {
        "description": "support.article_sections -- Join rows placing articles in sections.",
        "columns": {
            "article_id": "FK -> articles.id.",
            "section_id": "FK -> knowledge_sections.id.",
        },
    },
    "escalations": {
        "description": "support.escalations -- Escalation events for overdue tickets.",
        "columns": {
            "ticket_id": "FK -> tickets.id.",
            "escalated_at": "Escalation timestamp.",
            "reason": "Escalation reason text.",
        },
    },
}

CLUSTERS = [
    {
        "id": "auth",
        "label": "Auth & Access",
        "tables": [
            "roles",
            "users",
            "user_roles",
            "sessions",
            "permissions",
            "role_permissions",
            "api_keys",
            "oauth_clients",
            "oauth_tokens",
            "login_attempts",
        ],
        "color": "#7CC3FF",
    },
    {
        "id": "hr",
        "label": "HR",
        "tables": [
            "departments",
            "employees",
            "salaries",
            "time_off",
            "evaluations",
            "job_postings",
            "candidates",
            "interviews",
            "benefits",
            "employee_benefits",
        ],
        "color": "#B8A7FF",
    },
    {
        "id": "crm",
        "label": "CRM",
        "tables": [
            "customers",
            "contacts",
            "leads",
            "deals",
            "activities",
            "territories",
            "customer_territories",
            "campaigns",
            "campaign_leads",
            "notes",
        ],
        "color": "#A8E6A3",
    },
    {
        "id": "catalog",
        "label": "Catalog",
        "tables": [
            "categories",
            "products",
            "product_categories",
            "suppliers",
            "tags",
            "brands",
            "product_images",
            "price_lists",
            "price_list_items",
            "promotions",
        ],
        "color": "#FFD166",
    },
    {
        "id": "fulfillment",
        "label": "Fulfillment",
        "tables": [
            "orders",
            "order_lines",
            "warehouses",
            "bins",
            "stock_levels",
            "stock_movements",
            "carriers",
            "shipments",
            "shipment_lines",
            "returns",
            "return_lines",
        ],
        "color": "#5EC7C2",
    },
    {
        "id": "billing",
        "label": "Billing",
        "tables": [
            "invoices",
            "invoice_lines",
            "payments",
            "taxes",
            "payment_methods",
            "credit_notes",
            "subscriptions",
            "subscription_items",
            "refunds",
            "dunning_events",
        ],
        "color": "#F8B26A",
    },
    {
        "id": "support",
        "label": "Support",
        "tables": [
            "tickets",
            "ticket_messages",
            "articles",
            "feedback",
            "sla_policies",
            "ticket_assignments",
            "knowledge_sections",
            "article_sections",
            "escalations",
        ],
        "color": "#F497B8",
    },
]

NEW_STORIES = [
    {
        "id": "developer-uses-api-key-2026-05-20T18-00-00Z",
        "title": "Developer Uses API Key",
        "created_at": "2026-05-20T18:00:00Z",
        "prompt": "How does programmatic API access work for a user?",
        "actor": "a developer",
        "goal": "to call the API on behalf of their account",
        "benefit": "integrations can authenticate without an interactive sign-in session",
        "clusters": ["auth"],
        "related_stories": [
            {"story_id": "user-signs-in-2026-05-18T07-41-42Z", "kind": "related"},
            {"story_id": "admin-assigns-user-role-2026-05-20T16-00-00Z", "kind": "depends_on"},
        ],
        "conversation": [
            "API keys belong to users rows; OAuth flows use separate client and token tables.",
        ],
        "acceptance_criteria": [
            {"id": "AC1", "given": "a users row exists", "when": "a key is issued", "then": "api_keys stores a hashed key for that user"},
            {"id": "AC2", "given": "the key is presented", "when": "access is granted", "then": "the request resolves to the same users.id as interactive sign-in"},
        ],
        "playback": [
            {"text": "API access still anchors on users as the identity record.", "tables": ["users"], "focus": "users", "expand": "users"},
            {
                "text": "api_keys attaches a long-lived credential to users.id for automation.",
                "tables": ["users", "api_keys"],
                "focus": "api_keys",
                "expand": "api_keys",
                "relation": {"table": "api_keys", "column": "user_id"},
            },
        ],
    },
    {
        "id": "recruiter-schedules-interview-2026-05-20T18-01-00Z",
        "title": "Recruiter Schedules Interview",
        "created_at": "2026-05-20T18:01:00Z",
        "prompt": "What happens when HR schedules a candidate interview?",
        "actor": "a recruiter",
        "goal": "to move a candidate forward in hiring",
        "benefit": "the hiring team knows who to meet and when",
        "clusters": ["hr"],
        "related_stories": [{"story_id": "hr-onboards-new-employee-2026-05-20T16-01-00Z", "kind": "precedes"}],
        "acceptance_criteria": [
            {"id": "AC1", "given": "a job_postings row is open", "when": "a candidate applies", "then": "candidates links to that posting"},
            {"id": "AC2", "given": "a candidate exists", "when": "an interview is booked", "then": "interviews references candidates.id and an employees interviewer"},
        ],
        "playback": [
            {"text": "Hiring starts from job_postings tied to departments.", "tables": ["job_postings", "departments"], "focus": "job_postings", "expand": "job_postings"},
            {"text": "candidates captures the applicant against the posting.", "tables": ["candidates", "job_postings"], "focus": "candidates", "expand": "candidates", "relation": {"table": "candidates", "column": "posting_id"}},
            {"text": "interviews schedules the meeting with an employee interviewer.", "tables": ["interviews", "candidates", "employees"], "focus": "interviews", "expand": "interviews", "relation": {"table": "interviews", "column": "candidate_id"}},
        ],
    },
    {
        "id": "marketer-launches-campaign-2026-05-20T18-02-00Z",
        "title": "Marketer Launches Campaign",
        "created_at": "2026-05-20T18:02:00Z",
        "prompt": "How are leads attached to a marketing campaign?",
        "actor": "a marketer",
        "goal": "to track which leads came from a campaign",
        "benefit": "pipeline reporting can attribute conversions to marketing spend",
        "clusters": ["crm"],
        "related_stories": [{"story_id": "sales-rep-converts-lead-2026-05-20T15-02-00Z", "kind": "follows"}],
        "acceptance_criteria": [
            {"id": "AC1", "given": "a campaigns row exists", "when": "leads are imported", "then": "campaign_leads links campaign and lead ids"},
        ],
        "playback": [
            {"text": "campaigns defines the marketing program and active date range.", "tables": ["campaigns"], "focus": "campaigns", "expand": "campaigns"},
            {"text": "campaign_leads attaches leads to the campaign for attribution.", "tables": ["campaigns", "campaign_leads", "leads"], "focus": "campaign_leads", "expand": "campaign_leads", "relation": {"table": "campaign_leads", "column": "campaign_id"}},
        ],
    },
    {
        "id": "merchandiser-sets-promotional-price-2026-05-20T18-03-00Z",
        "title": "Merchandiser Sets Promotional Price",
        "created_at": "2026-05-20T18:03:00Z",
        "prompt": "How do price lists and promotions relate to products?",
        "actor": "a merchandiser",
        "goal": "to publish promotional pricing",
        "benefit": "checkout can show discounted prices during the promotion window",
        "clusters": ["catalog"],
        "related_stories": [{"story_id": "merchandiser-categorizes-product-2026-05-20T15-03-00Z", "kind": "related"}],
        "acceptance_criteria": [
            {"id": "AC1", "given": "products exist", "when": "a price list is maintained", "then": "price_list_items stores list prices per product"},
            {"id": "AC2", "given": "a promotion is active", "when": "pricing is resolved", "then": "promotions supplies the discount window"},
        ],
        "playback": [
            {"text": "products remains the sellable item anchor.", "tables": ["products"], "focus": "products", "expand": "products"},
            {"text": "price_list_items overrides catalog price inside a named price_lists row.", "tables": ["products", "price_lists", "price_list_items"], "focus": "price_list_items", "expand": "price_list_items", "relation": {"table": "price_list_items", "column": "product_id"}},
            {"text": "promotions adds a time-bound discount layer on top of list pricing.", "tables": ["promotions", "products"], "focus": "promotions", "expand": "promotions"},
        ],
    },
    {
        "id": "warehouse-ships-order-2026-05-20T18-04-00Z",
        "title": "Warehouse Ships Order",
        "created_at": "2026-05-20T18:04:00Z",
        "prompt": "What happens when an order leaves the warehouse?",
        "actor": "a warehouse clerk",
        "goal": "to record shipment with carrier tracking",
        "benefit": "customers and support can trace delivery status",
        "clusters": ["fulfillment"],
        "related_stories": [{"story_id": "warehouse-fulfills-order-2026-05-20T14-31-00Z", "kind": "follows"}],
        "acceptance_criteria": [
            {"id": "AC1", "given": "order_lines exist", "when": "a shipment is created", "then": "shipments references orders and carriers"},
            {"id": "AC2", "given": "a shipment exists", "when": "quantities are picked", "then": "shipment_lines links each order_line quantity shipped"},
        ],
        "playback": [
            {"text": "Shipping starts from orders already placed by the customer.", "tables": ["orders"], "focus": "orders", "expand": "orders"},
            {"text": "shipments records the carrier handoff and tracking number.", "tables": ["orders", "shipments", "carriers"], "focus": "shipments", "expand": "shipments", "relation": {"table": "shipments", "column": "order_id"}},
            {"text": "shipment_lines ties each shipped quantity back to order_lines.", "tables": ["shipments", "shipment_lines", "order_lines"], "focus": "shipment_lines", "expand": "shipment_lines", "relation": {"table": "shipment_lines", "column": "shipment_id"}},
        ],
    },
    {
        "id": "customer-initiates-return-2026-05-20T18-05-00Z",
        "title": "Customer Initiates Return",
        "created_at": "2026-05-20T18:05:00Z",
        "prompt": "How is a product return captured against an order?",
        "actor": "a customer",
        "goal": "to return items from a prior purchase",
        "benefit": "inventory and billing can reverse the sale cleanly",
        "clusters": ["fulfillment"],
        "related_stories": [{"story_id": "customer-places-order-2026-05-19T20-40-57Z", "kind": "depends_on"}],
        "acceptance_criteria": [
            {"id": "AC1", "given": "an orders row exists", "when": "a return is opened", "then": "returns references that order with a reason"},
            {"id": "AC2", "given": "a return exists", "when": "items are listed", "then": "return_lines captures product quantities"},
        ],
        "playback": [
            {"text": "returns anchors on the original orders row.", "tables": ["orders", "returns"], "focus": "returns", "expand": "returns", "relation": {"table": "returns", "column": "order_id"}},
            {"text": "return_lines lists each product quantity being sent back.", "tables": ["returns", "return_lines", "products"], "focus": "return_lines", "expand": "return_lines", "relation": {"table": "return_lines", "column": "return_id"}},
        ],
    },
    {
        "id": "finance-starts-subscription-2026-05-20T18-06-00Z",
        "title": "Finance Starts Subscription",
        "created_at": "2026-05-20T18:06:00Z",
        "prompt": "How is recurring billing set up for a customer?",
        "actor": "a finance analyst",
        "goal": "to bill products on a recurring schedule",
        "benefit": "revenue becomes predictable without manual re-invoicing",
        "clusters": ["billing"],
        "related_stories": [{"story_id": "customer-saves-payment-method-2026-05-20T16-03-00Z", "kind": "depends_on"}],
        "acceptance_criteria": [
            {"id": "AC1", "given": "a customers row exists", "when": "a subscription is opened", "then": "subscriptions links to customers.id with status active"},
            {"id": "AC2", "given": "a subscription exists", "when": "items are added", "then": "subscription_items lists billed products"},
        ],
        "playback": [
            {"text": "subscriptions attaches a recurring agreement to customers.", "tables": ["customers", "subscriptions"], "focus": "subscriptions", "expand": "subscriptions", "relation": {"table": "subscriptions", "column": "customer_id"}},
            {"text": "subscription_items defines which products bill each cycle.", "tables": ["subscriptions", "subscription_items", "products"], "focus": "subscription_items", "expand": "subscription_items", "relation": {"table": "subscription_items", "column": "subscription_id"}},
        ],
    },
    {
        "id": "support-escalates-overdue-ticket-2026-05-20T18-07-00Z",
        "title": "Support Escalates Overdue Ticket",
        "created_at": "2026-05-20T18:07:00Z",
        "prompt": "What happens when a ticket breaches SLA?",
        "actor": "a support lead",
        "goal": "to escalate an overdue case",
        "benefit": "critical customers get senior attention before churn",
        "clusters": ["support"],
        "related_stories": [{"story_id": "customer-opens-support-ticket-2026-05-20T10-00-52Z", "kind": "follows"}],
        "acceptance_criteria": [
            {"id": "AC1", "given": "sla_policies defines response_hours", "when": "a ticket ages past SLA", "then": "escalations records the breach event"},
            {"id": "AC2", "given": "a ticket is escalated", "when": "ownership changes", "then": "ticket_assignments can reassign assignee_user_id"},
        ],
        "playback": [
            {"text": "sla_policies sets the response target for the queue.", "tables": ["sla_policies"], "focus": "sla_policies", "expand": "sla_policies"},
            {"text": "escalations logs the overdue event against tickets.", "tables": ["tickets", "escalations"], "focus": "escalations", "expand": "escalations", "relation": {"table": "escalations", "column": "ticket_id"}},
            {"text": "ticket_assignments moves ownership to a senior agent.", "tables": ["tickets", "ticket_assignments", "users"], "focus": "ticket_assignments", "expand": "ticket_assignments", "relation": {"table": "ticket_assignments", "column": "ticket_id"}},
        ],
    },
    {
        "id": "admin-grants-role-permission-2026-05-20T18-08-00Z",
        "title": "Admin Grants Role Permission",
        "created_at": "2026-05-20T18:08:00Z",
        "prompt": "How are permissions attached to roles?",
        "actor": "an administrator",
        "goal": "to define what a role can do",
        "benefit": "authorization checks use a clear role-to-permission map",
        "clusters": ["auth"],
        "related_stories": [{"story_id": "admin-assigns-user-role-2026-05-20T16-00-00Z", "kind": "follows"}],
        "acceptance_criteria": [
            {"id": "AC1", "given": "roles and permissions rows exist", "when": "a grant is saved", "then": "role_permissions links both ids"},
        ],
        "playback": [
            {"text": "permissions catalogs atomic actions the app can check.", "tables": ["permissions"], "focus": "permissions", "expand": "permissions"},
            {"text": "role_permissions connects roles to permissions.", "tables": ["roles", "permissions", "role_permissions"], "focus": "role_permissions", "expand": "role_permissions", "relation": {"table": "role_permissions", "column": "role_id"}},
        ],
    },
    {
        "id": "account-manager-logs-customer-note-2026-05-20T18-09-00Z",
        "title": "Account Manager Logs Customer Note",
        "created_at": "2026-05-20T18:09:00Z",
        "prompt": "How are internal notes stored on a customer account?",
        "actor": "an account manager",
        "goal": "to capture context from a customer conversation",
        "benefit": "the team shares account history without repeating discovery",
        "clusters": ["crm"],
        "related_stories": [{"story_id": "account-manager-adds-contact-2026-05-20T16-02-00Z", "kind": "related"}],
        "acceptance_criteria": [
            {"id": "AC1", "given": "a customers row exists", "when": "a note is saved", "then": "notes stores body text and author_user_id"},
        ],
        "playback": [
            {"text": "notes anchors on customers as the account being documented.", "tables": ["customers", "notes"], "focus": "notes", "expand": "notes", "relation": {"table": "notes", "column": "customer_id"}},
            {"text": "author_user_id ties the note back to users for attribution.", "tables": ["notes", "users"], "focus": "users", "expand": "users", "relation": {"table": "notes", "column": "author_user_id"}},
        ],
    },
]


def patch_stories(stories: list[dict]) -> list[dict]:
    patches = {
        "user-signs-in-2026-05-18T07-41-42Z": {
            "conversation": [
                "Sign-in starts from an existing users row; account creation and password reset are outside this story.",
                "The schema stores the active login in sessions and derives access context from user_roles, roles, and role_permissions.",
                "login_attempts records each attempt for security monitoring.",
            ],
            "playback_append": [
                {
                    "text": "login_attempts records whether the attempt succeeded before the session is issued.",
                    "spoken_text": "Each sign-in attempt is logged before the session is created.",
                    "tables": ["users", "login_attempts"],
                    "focus": "login_attempts",
                    "expand": "login_attempts",
                }
            ],
        },
        "admin-assigns-user-role-2026-05-20T16-00-00Z": {
            "conversation": [
                "This story covers role assignment after the account exists; account creation and credential setup are outside the flow.",
                "role_permissions defines what each role can do once assigned.",
                "Sign-in reads user_roles on each session; this story writes the assignment that sign-in later consumes.",
            ],
            "playback_replace_last": {
                "text": "role_permissions maps the assigned role to concrete permissions checked at runtime.",
                "spoken_text": "Role permissions define what actions the assigned role may perform.",
                "tables": ["roles", "role_permissions", "permissions"],
                "focus": "role_permissions",
                "expand": "role_permissions",
                "relation": {"table": "role_permissions", "column": "role_id"},
            },
        },
        "warehouse-fulfills-order-2026-05-20T14-31-00Z": {
            "playback_append": [
                {
                    "text": "After picking, shipments and shipment_lines record the carrier handoff from the fulfilled order.",
                    "spoken_text": "Once picked, the shipment and its line items record carrier tracking.",
                    "tables": ["orders", "shipments", "shipment_lines"],
                    "focus": "shipments",
                    "expand": "shipments",
                    "relation": {"table": "shipments", "column": "order_id"},
                }
            ],
        },
        "customer-places-order-2026-05-19T20-40-57Z": {
            "playback_append": [
                {
                    "text": "Active promotions and price_list_items can adjust line pricing before the order total is finalized.",
                    "spoken_text": "Promotions or price list overrides may adjust line pricing before checkout completes.",
                    "tables": ["products", "promotions", "price_list_items", "order_lines"],
                    "focus": "promotions",
                    "expand": "promotions",
                }
            ],
        },
        "finance-records-partial-payment-2026-05-20T15-04-00Z": {
            "playback_append": [
                {
                    "text": "If the remaining balance stays overdue, dunning_events records reminder outreach on the invoice.",
                    "spoken_text": "Overdue balances can trigger dunning reminder events on the invoice.",
                    "tables": ["invoices", "dunning_events"],
                    "focus": "dunning_events",
                    "expand": "dunning_events",
                    "relation": {"table": "dunning_events", "column": "invoice_id"},
                }
            ],
        },
        "customer-opens-support-ticket-2026-05-20T10-00-52Z": {
            "playback_append": [
                {
                    "text": "ticket_assignments can route the new ticket to a support agent via users.",
                    "spoken_text": "The ticket can immediately be assigned to a support agent.",
                    "tables": ["tickets", "ticket_assignments", "users"],
                    "focus": "ticket_assignments",
                    "expand": "ticket_assignments",
                    "relation": {"table": "ticket_assignments", "column": "ticket_id"},
                }
            ],
        },
        "merchandiser-categorizes-product-2026-05-20T15-03-00Z": {
            "playback_append": [
                {
                    "text": "product_images and brands enrich the catalog presentation around the categorized product.",
                    "spoken_text": "Images and brand metadata enrich the categorized product record.",
                    "tables": ["products", "product_images", "brands"],
                    "focus": "product_images",
                    "expand": "product_images",
                    "relation": {"table": "product_images", "column": "product_id"},
                }
            ],
        },
        "hr-onboards-new-employee-2026-05-20T16-01-00Z": {
            "playback_append": [
                {
                    "text": "employee_benefits enrolls the new hire in selected benefits plans.",
                    "spoken_text": "Benefit enrollment links the employee to chosen plans.",
                    "tables": ["employees", "employee_benefits", "benefits"],
                    "focus": "employee_benefits",
                    "expand": "employee_benefits",
                    "relation": {"table": "employee_benefits", "column": "emp_id"},
                }
            ],
        },
    }

    patched: list[dict] = []
    for story in stories:
        story = json.loads(json.dumps(story))
        patch = patches.get(story["id"])
        if not patch:
            patched.append(story)
            continue
        if "conversation" in patch:
            story["conversation"] = patch["conversation"]
        if "playback_append" in patch:
            story.setdefault("playback", []).extend(patch["playback_append"])
        if "playback_replace_last" in patch:
            if story.get("playback"):
                story["playback"][-1] = patch["playback_replace_last"]
        patched.append(story)
    return patched


def main() -> None:
    existing = json.loads(SIDECAR.read_text(encoding="utf-8"))
    stories = patch_stories(existing.get("stories", []))
    stories.extend(NEW_STORIES)

    sidecar = {
        "version": 1,
        "tables": TABLES,
        "clusters": CLUSTERS,
        "stories": stories,
    }
    SIDECAR.write_text(json.dumps(sidecar, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {SIDECAR} with {len(TABLES)} tables, {len(CLUSTERS)} clusters, {len(stories)} stories")


if __name__ == "__main__":
    main()
