const sqlite3 = require('sqlite3').verbose();
const path = require('path');

const dbPath = path.join(__dirname, 'data.sqlite');
const db = new sqlite3.Database(dbPath);

db.serialize(() => {
  db.run("PRAGMA foreign_keys = ON");

  db.run(`
    CREATE TABLE IF NOT EXISTS vendors (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      category TEXT,
      contact_person TEXT,
      email TEXT,
      phone TEXT,
      portal_url TEXT,
      notes TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS services_contracts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      vendor_id INTEGER,
      service_name TEXT NOT NULL,
      category TEXT NOT NULL,
      cost REAL NOT NULL,
      currency TEXT DEFAULT 'INR',
      billing_cycle TEXT DEFAULT 'yearly',
      start_date TEXT,
      expiry_date TEXT NOT NULL,
      auto_renew INTEGER DEFAULT 0,
      status TEXT DEFAULT 'Active',
      bill_filename TEXT,
      bill_stored_name TEXT,
      bill_uploaded_at DATETIME,
      notes TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY(vendor_id) REFERENCES vendors(id) ON DELETE SET NULL
    )
  `);

  // Migration: add bill columns to a services_contracts table created before they existed
  db.all("PRAGMA table_info(services_contracts)", (err, columns) => {
    if (err || !columns) return;
    const names = columns.map(c => c.name);
    if (!names.includes('bill_filename')) db.run("ALTER TABLE services_contracts ADD COLUMN bill_filename TEXT");
    if (!names.includes('bill_stored_name')) db.run("ALTER TABLE services_contracts ADD COLUMN bill_stored_name TEXT");
    if (!names.includes('bill_uploaded_at')) db.run("ALTER TABLE services_contracts ADD COLUMN bill_uploaded_at DATETIME");
  });

  db.run(`
    CREATE TABLE IF NOT EXISTS payment_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      service_id INTEGER,
      vendor_id INTEGER,
      amount REAL NOT NULL,
      currency TEXT DEFAULT 'INR',
      payment_date TEXT NOT NULL,
      payment_method TEXT,
      invoice_no TEXT,
      receipt_note TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY(service_id) REFERENCES services_contracts(id) ON DELETE SET NULL,
      FOREIGN KEY(vendor_id) REFERENCES vendors(id) ON DELETE SET NULL
    )
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS alert_settings (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      email_enabled INTEGER DEFAULT 0,
      smtp_host TEXT,
      smtp_port INTEGER DEFAULT 587,
      smtp_user TEXT,
      smtp_pass TEXT,
      notification_email TEXT,
      telegram_enabled INTEGER DEFAULT 0,
      telegram_bot_token TEXT,
      telegram_chat_id TEXT,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);

  db.run(`
    INSERT OR IGNORE INTO alert_settings (id, email_enabled, telegram_enabled)
    VALUES (1, 0, 0)
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS work_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      type TEXT NOT NULL DEFAULT 'Repair',
      work_date TEXT,
      title TEXT NOT NULL,
      vendor_name TEXT,
      issue TEXT,
      condition_notes TEXT,
      cable_type TEXT,
      from_location TEXT,
      to_location TEXT,
      length_meters REAL,
      cost REAL,
      status TEXT DEFAULT 'Pending',
      bill_status TEXT DEFAULT 'Pending',
      bill_filename TEXT,
      bill_stored_name TEXT,
      bill_uploaded_at DATETIME,
      notes TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);

  // Migration: add bill columns to a work_log table created before they existed
  db.all("PRAGMA table_info(work_log)", (err, columns) => {
    if (err || !columns) return;
    const names = columns.map(c => c.name);
    if (!names.includes('bill_status')) db.run("ALTER TABLE work_log ADD COLUMN bill_status TEXT DEFAULT 'Pending'");
    if (!names.includes('bill_filename')) db.run("ALTER TABLE work_log ADD COLUMN bill_filename TEXT");
    if (!names.includes('bill_stored_name')) db.run("ALTER TABLE work_log ADD COLUMN bill_stored_name TEXT");
    if (!names.includes('bill_uploaded_at')) db.run("ALTER TABLE work_log ADD COLUMN bill_uploaded_at DATETIME");
  });

  db.run(`
    CREATE TABLE IF NOT EXISTS domains (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      domain_name TEXT NOT NULL UNIQUE,
      admin_email TEXT,
      domain_type TEXT DEFAULT 'Primary',
      parent_domain_id INTEGER,
      service_id INTEGER,
      total_seats INTEGER,
      notes TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY(parent_domain_id) REFERENCES domains(id) ON DELETE SET NULL,
      FOREIGN KEY(service_id) REFERENCES services_contracts(id) ON DELETE SET NULL
    )
  `);

  // Migration: add hierarchy/renewal-link columns to a domains table created before they existed
  db.all("PRAGMA table_info(domains)", (err, columns) => {
    if (err || !columns) return;
    const names = columns.map(c => c.name);
    if (!names.includes('domain_type')) db.run("ALTER TABLE domains ADD COLUMN domain_type TEXT DEFAULT 'Primary'");
    if (!names.includes('parent_domain_id')) db.run("ALTER TABLE domains ADD COLUMN parent_domain_id INTEGER");
    if (!names.includes('service_id')) db.run("ALTER TABLE domains ADD COLUMN service_id INTEGER");
    if (!names.includes('total_seats')) db.run("ALTER TABLE domains ADD COLUMN total_seats INTEGER");
  });

  db.run(`
    CREATE TABLE IF NOT EXISTS mailboxes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      email TEXT NOT NULL UNIQUE,
      status TEXT DEFAULT 'Active',
      purpose TEXT,
      current_user TEXT,
      notes TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS company_documents (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      category TEXT DEFAULT 'Other',
      notes TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);

  // Laptops (and any other hardware) taken on rent from a vendor - RAC being the
  // first one. Kept apart from services_contracts because a rental is an ongoing
  // monthly payment against a returnable machine, not a licence with an expiry.
  db.run(`
    CREATE TABLE IF NOT EXISTS rented_assets (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      vendor_name TEXT DEFAULT 'RAC',
      asset_name TEXT NOT NULL,
      model TEXT,
      serial_no TEXT,
      assigned_to TEXT,
      monthly_rent REAL,
      rent_start TEXT,
      rent_end TEXT,
      status TEXT DEFAULT 'On Rent',
      gmail_link TEXT,
      notes TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);

  // Payments made to the rental vendor. asset_id NULL = one payment covering the
  // whole fleet (the usual case - RAC bills all laptops on a single invoice).
  db.run(`
    CREATE TABLE IF NOT EXISTS rental_payments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      vendor_name TEXT DEFAULT 'RAC',
      asset_id INTEGER,
      amount REAL NOT NULL,
      payment_date TEXT NOT NULL,
      period_label TEXT,
      payment_method TEXT,
      invoice_no TEXT,
      gmail_link TEXT,
      status TEXT DEFAULT 'Pending',
      due_date TEXT,
      paid_on TEXT,
      paid_amount REAL,
      notes TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY(asset_id) REFERENCES rented_assets(id) ON DELETE SET NULL
    )
  `);

  // Migration: a rental_payments table created before bills were told apart from
  // payments has no status column.
  db.all("PRAGMA table_info(rental_payments)", (err, columns) => {
    if (err || !columns || columns.length === 0) return;
    const names = columns.map(c => c.name);
    if (!names.includes('status')) {
      db.run("ALTER TABLE rental_payments ADD COLUMN status TEXT DEFAULT 'Pending'");
    }
    if (!names.includes('due_date')) db.run("ALTER TABLE rental_payments ADD COLUMN due_date TEXT");
    if (!names.includes('paid_on')) db.run("ALTER TABLE rental_payments ADD COLUMN paid_on TEXT");
    if (!names.includes('paid_amount')) db.run("ALTER TABLE rental_payments ADD COLUMN paid_amount REAL");
  });

  // Multiple bill/document attachments per service, work log, or company
  // document entry (superseral of the old single bill_filename/bill_stored_name
  // columns above, which are kept around unused so no data is lost).
  db.run(`
    CREATE TABLE IF NOT EXISTS attachments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      entity_type TEXT NOT NULL,
      entity_id INTEGER NOT NULL,
      original_filename TEXT NOT NULL,
      stored_filename TEXT NOT NULL,
      folder TEXT,
      uploaded_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(entity_type, entity_id, stored_filename)
    )
  `);

  // Migration: add folder column (files moved from local disk to living on the
  // NAS mount only - folder records which Documents/<folder>/ they're under)
  db.all("PRAGMA table_info(attachments)", (err, columns) => {
    if (err || !columns) return;
    const names = columns.map(c => c.name);
    if (!names.includes('folder')) db.run("ALTER TABLE attachments ADD COLUMN folder TEXT");
  });

  // One-time carry-over: pull any bill already uploaded under the old
  // one-file-per-entry columns into the new multi-attachment table.
  db.all(`SELECT id, bill_filename, bill_stored_name, bill_uploaded_at FROM services_contracts WHERE bill_stored_name IS NOT NULL`, (err, rows) => {
    if (rows) rows.forEach(r => {
      db.run(
        `INSERT OR IGNORE INTO attachments (entity_type, entity_id, original_filename, stored_filename, uploaded_at) VALUES ('service', ?, ?, ?, ?)`,
        [r.id, r.bill_filename, r.bill_stored_name, r.bill_uploaded_at]
      );
    });
  });
  db.all(`SELECT id, bill_filename, bill_stored_name, bill_uploaded_at FROM work_log WHERE bill_stored_name IS NOT NULL`, (err, rows) => {
    if (rows) rows.forEach(r => {
      db.run(
        `INSERT OR IGNORE INTO attachments (entity_type, entity_id, original_filename, stored_filename, uploaded_at) VALUES ('worklog', ?, ?, ?, ?)`,
        [r.id, r.bill_filename, r.bill_stored_name, r.bill_uploaded_at]
      );
    });
  });
});

module.exports = db;
