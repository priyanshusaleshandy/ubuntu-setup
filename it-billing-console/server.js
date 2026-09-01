const express = require('express');
const cors = require('cors');
const path = require('path');
const fs = require('fs');
const multer = require('multer');
const db = require('./database');
const { startScheduler, checkExpiringServices } = require('./scheduler');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());
// Serve index.html ourselves so app.js / style.css can carry a ?v=<mtime> stamp.
// Without it the browser happily reuses a cached app.js after a UI deploy - which it
// did, and the new markup silently never appeared. Must sit BEFORE express.static,
// otherwise static wins for '/'.
function assetVersion(file) {
  try {
    return String(Math.floor(fs.statSync(path.join(__dirname, 'public', file)).mtimeMs));
  } catch (e) {
    return String(Date.now());
  }
}

app.get(['/', '/index.html'], (req, res) => {
  let html = fs.readFileSync(path.join(__dirname, 'public', 'index.html'), 'utf8');
  html = html
    .replace('href="style.css"', 'href="style.css?v=' + assetVersion('style.css') + '"')
    .replace('src="app.js"', 'src="app.js?v=' + assetVersion('app.js') + '"');
  res.set('Cache-Control', 'no-store');
  res.type('html').send(html);
});

app.use(express.static(path.join(__dirname, 'public')));

// Uploaded files are written straight onto the NAS mount (NAS_DOCS_DIR, see
// docker-compose.yml) under Documents/<Vendor or Company Documents>/ - never
// staged on the Mac Mini's own disk, so uploads never eat local storage.
// Viewing/downloading streams live from that same NAS path. Optionally also
// mirrored to GDRIVE_DOCS_DIR once that mount is set up.
// BILL_STAGING_DIR is legacy-only now: it's where files landed before this
// change, kept as a fallback read path for any attachment not yet migrated.
const BILL_STAGING_DIR = path.join(__dirname, 'uploads', 'bills');

function nasDocsRoot() {
  return process.env.NAS_DOCS_DIR || null;
}

function slugify(str) {
  return String(str || 'Unknown')
    .trim()
    .replace(/[^a-zA-Z0-9\- ]/g, '')
    .replace(/\s+/g, '-')
    .slice(0, 60) || 'Unknown';
}

function billFileFilter(req, file, cb) {
  const allowed = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'];
  if (allowed.includes(file.mimetype)) cb(null, true);
  else cb(new Error('Only PDF or image files (jpg, png, webp, heic) are allowed'));
}

// Builds a multer instance that writes directly into NAS_DOCS_DIR/Documents/<folder>/.
// `resolveFolder(req, cb)` figures out the per-upload folder name (vendor slug,
// or a fixed name for company documents) before the file is written.
function makeNasUpload(resolveFolder, filenamePrefix) {
  return multer({
    storage: multer.diskStorage({
      destination: (req, file, cb) => {
        const root = nasDocsRoot();
        if (!root) return cb(new Error('NAS storage is not connected right now — ask admin to check the NAS mount before uploading.'));
        resolveFolder(req, (folder) => {
          req._uploadFolder = folder;
          const destDir = path.join(root, 'Documents', folder);
          try {
            fs.mkdirSync(destDir, { recursive: true });
            cb(null, destDir);
          } catch (err) {
            cb(new Error('Could not write to NAS: ' + err.message));
          }
        });
      },
      filename: (req, file, cb) => {
        const ext = path.extname(file.originalname) || '';
        cb(null, `${filenamePrefix}-${req.params.id}-${Date.now()}${ext}`);
      }
    }),
    limits: { fileSize: 20 * 1024 * 1024 }, // 20MB
    fileFilter: billFileFilter
  });
}

const upload = makeNasUpload((req, cb) => {
  db.get(`SELECT vendor_name FROM work_log WHERE id = ?`, [req.params.id], (err, row) => cb(slugify(row && row.vendor_name)));
}, 'worklog');

const uploadServiceBill = makeNasUpload((req, cb) => {
  db.get(
    `SELECT v.name as vendor_name FROM services_contracts s LEFT JOIN vendors v ON s.vendor_id = v.id WHERE s.id = ?`,
    [req.params.id],
    (err, row) => cb(slugify(row && row.vendor_name))
  );
}, 'service');

const uploadCompanyDoc = makeNasUpload((req, cb) => cb(slugify('Company Documents')), 'doc');

// Rental bills file under the rental vendor's own folder (RAC/), same as any
// other vendor's paperwork.
const uploadRentalBill = makeNasUpload((req, cb) => {
  db.get(`SELECT vendor_name FROM rental_payments WHERE id = ?`, [req.params.id], (err, row) => cb(slugify((row && row.vendor_name) || 'RAC')));
}, 'rental');

// Optional secondary copy into Google Drive (GDRIVE_DOCS_DIR), once that mount
// is set up. NAS is the primary/only required store - this is best-effort.
function mirrorToGDrive(folder, storedFilePath, storedFileName) {
  const root = process.env.GDRIVE_DOCS_DIR;
  if (!root) return;
  try {
    const destDir = path.join(root, 'Documents', folder);
    fs.mkdirSync(destDir, { recursive: true });
    fs.copyFileSync(storedFilePath, path.join(destDir, storedFileName));
  } catch (err) {
    console.error('[GDrive Mirror] Failed to copy:', err.message);
  }
}

function attachmentFilePath(row) {
  if (row.folder) {
    const root = nasDocsRoot();
    return root ? path.join(root, 'Documents', row.folder, row.stored_filename) : null;
  }
  return path.join(BILL_STAGING_DIR, row.stored_filename); // pre-NAS-migration legacy file
}

// Deletes every attachment file + DB row for one service/worklog entry
// (used when that entry itself is deleted).
function deleteEntityAttachments(entityType, entityId) {
  db.all(`SELECT stored_filename, folder FROM attachments WHERE entity_type = ? AND entity_id = ?`, [entityType, entityId], (err, rows) => {
    if (rows) rows.forEach(r => {
      const p = attachmentFilePath(r);
      if (p) fs.unlink(p, () => {});
    });
  });
  db.run(`DELETE FROM attachments WHERE entity_type = ? AND entity_id = ?`, [entityType, entityId]);
}

// One-time startup migration: move any attachment still sitting in the old
// local BILL_STAGING_DIR onto the NAS mount and record its folder, freeing
// Mac Mini disk space. Safe to re-run - only touches rows with folder IS NULL.
function migrateAttachmentsToNas() {
  const root = nasDocsRoot();
  db.all(`SELECT * FROM attachments WHERE folder IS NULL`, (err, rows) => {
    if (err || !rows || rows.length === 0) return;
    console.log(`[NAS Migration] Moving ${rows.length} attachment(s) off local disk onto NAS...`);
    rows.forEach(row => {
      const onFolderResolved = (folder) => {
        db.run(`UPDATE attachments SET folder = ? WHERE id = ?`, [folder, row.id]);
        if (!root) return; // NAS not mounted yet - DB folder recorded, file move deferred
        const nasPath = path.join(root, 'Documents', folder, row.stored_filename);
        const localPath = path.join(BILL_STAGING_DIR, row.stored_filename);
        if (fs.existsSync(nasPath)) {
          if (fs.existsSync(localPath)) fs.unlink(localPath, () => {}); // already mirrored - drop local copy
        } else if (fs.existsSync(localPath)) {
          try {
            fs.mkdirSync(path.join(root, 'Documents', folder), { recursive: true });
            fs.copyFileSync(localPath, nasPath);
            fs.unlink(localPath, () => {});
          } catch (e) {
            console.error('[NAS Migration] Failed to move attachment:', e.message);
          }
        }
      };

      if (row.entity_type === 'service') {
        db.get(`SELECT v.name as vendor_name FROM services_contracts s LEFT JOIN vendors v ON s.vendor_id = v.id WHERE s.id = ?`, [row.entity_id], (e, r) => onFolderResolved(slugify(r && r.vendor_name)));
      } else if (row.entity_type === 'worklog') {
        db.get(`SELECT vendor_name FROM work_log WHERE id = ?`, [row.entity_id], (e, r) => onFolderResolved(slugify(r && r.vendor_name)));
      } else if (row.entity_type === 'rental_payment') {
        db.get(`SELECT vendor_name FROM rental_payments WHERE id = ?`, [row.entity_id], (e, r) => onFolderResolved(slugify((r && r.vendor_name) || 'RAC')));
      } else {
        onFolderResolved(slugify('Company Documents'));
      }
    });
  });
}

// List all attachment metadata (id, entity_type, entity_id, filename, uploaded_at)
// so the frontend can group them per row without one request per entity.
app.get('/api/attachments', (req, res) => {
  db.all(`SELECT id, entity_type, entity_id, original_filename, uploaded_at FROM attachments ORDER BY uploaded_at ASC`, (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(rows);
  });
});

// View/download one attachment's file content (streamed live from NAS)
app.get('/api/attachments/:attId', (req, res) => {
  db.get(`SELECT stored_filename, original_filename, folder FROM attachments WHERE id = ?`, [req.params.attId], (err, row) => {
    if (err || !row) return res.status(404).json({ error: 'Attachment not found' });
    const filePath = attachmentFilePath(row);
    if (!filePath) return res.status(503).json({ error: 'NAS storage is not connected right now.' });
    if (!fs.existsSync(filePath)) return res.status(404).json({ error: 'File not found' });
    res.sendFile(filePath, { headers: { 'Content-Disposition': `inline; filename="${row.original_filename}"` } });
  });
});

// Remove a single attachment
app.delete('/api/attachments/:attId', (req, res) => {
  db.get(`SELECT stored_filename, folder FROM attachments WHERE id = ?`, [req.params.attId], (err, row) => {
    if (err || !row) return res.status(404).json({ error: 'Attachment not found' });
    const filePath = attachmentFilePath(row);
    if (filePath) fs.unlink(filePath, () => {});
    db.run(`DELETE FROM attachments WHERE id = ?`, [req.params.attId], (err2) => {
      if (err2) return res.status(500).json({ error: err2.message });
      res.json({ message: 'Attachment deleted' });
    });
  });
});

// 1. DASHBOARD STATS
app.get('/api/dashboard/stats', (req, res) => {
  const stats = {
    totalVendors: 0,
    totalServices: 0,
    activeServices: 0,
    expiringSoon: 0,
    expired: 0,
    totalMonthlySpend: 0,
    totalYearlySpend: 0,
    expiringItems: []
  };

  db.get(`SELECT COUNT(*) as count FROM vendors`, (err, r1) => {
    stats.totalVendors = r1 ? r1.count : 0;

    db.all(`SELECT * FROM services_contracts`, (err, services) => {
      if (services) {
        stats.totalServices = services.length;
        const today = new Date();

        services.forEach(s => {
          const expiry = new Date(s.expiry_date);
          const diffDays = Math.ceil((expiry - today) / (1000 * 60 * 60 * 24));

          if (s.status === 'Upcoming' || s.status === 'Pending' || s.status === 'Expiring Soon' || (diffDays > 0 && diffDays <= 30)) {
            stats.expiringSoon++;
            stats.expiringItems.push({ ...s, daysLeft: diffDays });
          } else if (diffDays <= 0 && s.status !== 'Upcoming' && s.status !== 'Pending') {
            stats.expired++;
          } else {
            stats.activeServices++;
          }

          // Calculate normalized monthly & yearly spend
          let yearlyCost = s.cost;
          if (s.billing_cycle === 'monthly') yearlyCost = s.cost * 12;
          else if (s.billing_cycle === 'quarterly') yearlyCost = s.cost * 4;

          stats.totalYearlySpend += yearlyCost;
          stats.totalMonthlySpend += (yearlyCost / 12);
        });

        // Sort expiring items by days remaining
        stats.expiringItems.sort((a, b) => a.daysLeft - b.daysLeft);
      }

      res.json(stats);
    });
  });
});

// 2. VENDORS API
app.get('/api/vendors', (req, res) => {
  db.all(`SELECT * FROM vendors ORDER BY name ASC`, (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(rows);
  });
});

app.post('/api/vendors', (req, res) => {
  const { name, category, contact_person, email, phone, portal_url, notes } = req.body;
  if (!name) return res.status(400).json({ error: 'Vendor name is required' });

  db.run(
    `INSERT INTO vendors (name, category, contact_person, email, phone, portal_url, notes) VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [name, category, contact_person, email, phone, portal_url, notes],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ id: this.lastID, message: 'Vendor added successfully' });
    }
  );
});

app.put('/api/vendors/:id', (req, res) => {
  const { name, category, contact_person, email, phone, portal_url, notes } = req.body;
  db.run(
    `UPDATE vendors SET name = ?, category = ?, contact_person = ?, email = ?, phone = ?, portal_url = ?, notes = ? WHERE id = ?`,
    [name, category, contact_person, email, phone, portal_url, notes, req.params.id],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ message: 'Vendor updated successfully' });
    }
  );
});

app.delete('/api/vendors/:id', (req, res) => {
  db.run(`DELETE FROM vendors WHERE id = ?`, [req.params.id], function (err) {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ message: 'Vendor deleted' });
  });
});

// 3. SERVICES & CONTRACTS API
app.get('/api/services', (req, res) => {
  const query = `
    SELECT s.*, v.name as vendor_name, v.email as vendor_email
    FROM services_contracts s
    LEFT JOIN vendors v ON s.vendor_id = v.id
    ORDER BY s.expiry_date ASC
  `;
  db.all(query, (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(rows);
  });
});

app.post('/api/services', (req, res) => {
  const { vendor_id, service_name, category, cost, currency, billing_cycle, start_date, expiry_date, auto_renew, notes } = req.body;
  if (!service_name || !cost || !expiry_date) {
    return res.status(400).json({ error: 'Service name, cost, and expiry date are required' });
  }

  const today = new Date();
  const exp = new Date(expiry_date);
  const diffDays = Math.ceil((exp - today) / (1000 * 60 * 60 * 24));
  let status = 'Upcoming';
  if (diffDays <= 0) status = 'Expired';

  db.run(
    `INSERT INTO services_contracts (vendor_id, service_name, category, cost, currency, billing_cycle, start_date, expiry_date, auto_renew, status, notes)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [vendor_id, service_name, category, cost, currency || 'INR', billing_cycle || 'yearly', start_date, expiry_date, auto_renew ? 1 : 0, status, notes],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ id: this.lastID, message: 'Service contract added successfully' });
    }
  );
});

app.put('/api/services/:id', (req, res) => {
  const { vendor_id, service_name, category, cost, currency, billing_cycle, start_date, expiry_date, auto_renew, notes } = req.body;
  
  const today = new Date();
  const exp = new Date(expiry_date);
  const diffDays = Math.ceil((exp - today) / (1000 * 60 * 60 * 24));
  let status = 'Upcoming';
  if (diffDays <= 0) status = 'Expired';

  db.run(
    `UPDATE services_contracts 
     SET vendor_id = ?, service_name = ?, category = ?, cost = ?, currency = ?, billing_cycle = ?, start_date = ?, expiry_date = ?, auto_renew = ?, status = ?, notes = ?
     WHERE id = ?`,
    [vendor_id, service_name, category, cost, currency || 'INR', billing_cycle, start_date, expiry_date, auto_renew ? 1 : 0, status, notes, req.params.id],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ message: 'Service updated successfully' });
    }
  );
});

// Add a bill/document to a service/contract entry (a service can have several -
// proforma, payment screenshot, final invoice, etc. Each upload adds one, none
// are replaced). Written straight to NAS - see makeNasUpload above.
app.post('/api/services/:id/bill', uploadServiceBill.single('bill'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No bill file uploaded' });

  db.run(
    `INSERT INTO attachments (entity_type, entity_id, original_filename, stored_filename, folder) VALUES ('service', ?, ?, ?, ?)`,
    [req.params.id, req.file.originalname, req.file.filename, req._uploadFolder],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });

      mirrorToGDrive(req._uploadFolder, req.file.path, req.file.filename);

      res.json({ id: this.lastID, message: 'Bill uploaded successfully', filename: req.file.originalname });
    }
  );
});

app.delete('/api/services/:id', (req, res) => {
  deleteEntityAttachments('service', req.params.id);
  db.run(`DELETE FROM services_contracts WHERE id = ?`, [req.params.id], function (err) {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ message: 'Service deleted' });
  });
});

// 4. PAYMENT HISTORY API
app.get('/api/payments', (req, res) => {
  const query = `
    SELECT p.*, s.service_name, v.name as vendor_name
    FROM payment_history p
    LEFT JOIN services_contracts s ON p.service_id = s.id
    LEFT JOIN vendors v ON p.vendor_id = v.id
    ORDER BY p.payment_date DESC
  `;
  db.all(query, (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(rows);
  });
});

app.post('/api/payments', (req, res) => {
  const { service_id, vendor_id, amount, currency, payment_date, payment_method, invoice_no, receipt_note } = req.body;
  if (!amount || !payment_date) {
    return res.status(400).json({ error: 'Amount and Payment Date are required' });
  }

  db.run(
    `INSERT INTO payment_history (service_id, vendor_id, amount, currency, payment_date, payment_method, invoice_no, receipt_note)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    [service_id, vendor_id, amount, currency || 'INR', payment_date, payment_method, invoice_no, receipt_note],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ id: this.lastID, message: 'Payment recorded successfully' });
    }
  );
});

app.delete('/api/payments/:id', (req, res) => {
  db.run(`DELETE FROM payment_history WHERE id = ?`, [req.params.id], function (err) {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ message: 'Payment record deleted' });
  });
});

// 5. EXPENSE ANALYTICS (Category breakdown & Monthly spending)
app.get('/api/analytics', (req, res) => {
  db.all(`SELECT category, cost, billing_cycle FROM services_contracts`, (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });

    const categorySums = {};
    rows.forEach(r => {
      let yearlyCost = r.cost;
      if (r.billing_cycle === 'monthly') yearlyCost = r.cost * 12;
      else if (r.billing_cycle === 'quarterly') yearlyCost = r.cost * 4;

      categorySums[r.category] = (categorySums[r.category] || 0) + yearlyCost;
    });

    db.all(`SELECT payment_date, amount FROM payment_history ORDER BY payment_date ASC`, (err, payments) => {
      const monthlyPayments = {};
      if (payments) {
        payments.forEach(p => {
          const month = p.payment_date.substring(0, 7); // YYYY-MM
          monthlyPayments[month] = (monthlyPayments[month] || 0) + p.amount;
        });
      }

      res.json({
        categories: Object.keys(categorySums),
        categoryValues: Object.values(categorySums),
        monthlyLabels: Object.keys(monthlyPayments),
        monthlyValues: Object.values(monthlyPayments)
      });
    });
  });
});

// 6. ALERT SETTINGS API
app.get('/api/alerts/settings', (req, res) => {
  db.get(`SELECT * FROM alert_settings WHERE id = 1`, (err, row) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(row || {});
  });
});

app.post('/api/alerts/settings', (req, res) => {
  const { email_enabled, smtp_host, smtp_port, smtp_user, smtp_pass, notification_email, telegram_enabled, telegram_bot_token, telegram_chat_id } = req.body;

  db.run(
    `UPDATE alert_settings 
     SET email_enabled = ?, smtp_host = ?, smtp_port = ?, smtp_user = ?, smtp_pass = ?, notification_email = ?, telegram_enabled = ?, telegram_bot_token = ?, telegram_chat_id = ?, updated_at = CURRENT_TIMESTAMP
     WHERE id = 1`,
    [email_enabled ? 1 : 0, smtp_host, smtp_port, smtp_user, smtp_pass, notification_email, telegram_enabled ? 1 : 0, telegram_bot_token, telegram_chat_id],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ message: 'Notification settings saved successfully' });
    }
  );
});

// Trigger Manual Expiry Check / Test Notification
app.post('/api/alerts/test', (req, res) => {
  checkExpiringServices();
  res.json({ message: 'Expiry check triggered successfully. Check console logs and Telegram/Email.' });
});

// 7. REPAIRS & SITE WORK LOG API (device repairs, cable runs, misc IT work)
app.get('/api/worklog', (req, res) => {
  db.all(`SELECT * FROM work_log ORDER BY work_date DESC, id DESC`, (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(rows);
  });
});

app.post('/api/worklog', (req, res) => {
  const { type, work_date, title, vendor_name, issue, condition_notes, cable_type, from_location, to_location, length_meters, cost, status, bill_status, notes } = req.body;
  if (!title) return res.status(400).json({ error: 'Title is required' });

  db.run(
    `INSERT INTO work_log (type, work_date, title, vendor_name, issue, condition_notes, cable_type, from_location, to_location, length_meters, cost, status, bill_status, notes)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [type || 'Repair', work_date, title, vendor_name, issue, condition_notes, cable_type, from_location, to_location, length_meters || null, cost || null, status || 'Pending', bill_status || 'Pending', notes],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ id: this.lastID, message: 'Work log entry added successfully' });
    }
  );
});

app.put('/api/worklog/:id', (req, res) => {
  const { type, work_date, title, vendor_name, issue, condition_notes, cable_type, from_location, to_location, length_meters, cost, status, bill_status, notes } = req.body;

  db.run(
    `UPDATE work_log
     SET type = ?, work_date = ?, title = ?, vendor_name = ?, issue = ?, condition_notes = ?, cable_type = ?, from_location = ?, to_location = ?, length_meters = ?, cost = ?, status = ?, bill_status = ?, notes = ?
     WHERE id = ?`,
    [type || 'Repair', work_date, title, vendor_name, issue, condition_notes, cable_type, from_location, to_location, length_meters || null, cost || null, status || 'Pending', bill_status || 'Pending', notes, req.params.id],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ message: 'Work log entry updated successfully' });
    }
  );
});

// Add a bill/document to a work log entry (a repair/cable job can have several -
// proforma, payment screenshot, final invoice, etc. Each upload adds one, none
// are replaced). Written straight to NAS - see makeNasUpload above.
app.post('/api/worklog/:id/bill', upload.single('bill'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No bill file uploaded' });

  db.run(
    `INSERT INTO attachments (entity_type, entity_id, original_filename, stored_filename, folder) VALUES ('worklog', ?, ?, ?, ?)`,
    [req.params.id, req.file.originalname, req.file.filename, req._uploadFolder],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });

      mirrorToGDrive(req._uploadFolder, req.file.path, req.file.filename);

      res.json({ id: this.lastID, message: 'Bill uploaded successfully', filename: req.file.originalname });
    }
  );
});

app.delete('/api/worklog/:id', (req, res) => {
  deleteEntityAttachments('worklog', req.params.id);
  db.run(`DELETE FROM work_log WHERE id = ?`, [req.params.id], function (err) {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ message: 'Work log entry deleted' });
  });
});

// 8a. DOMAINS API (each company domain - who administers it. Mailboxes under it
// are matched by the part of their email after @)
app.get('/api/domains', (req, res) => {
  db.all(`SELECT * FROM domains ORDER BY domain_name ASC`, (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(rows);
  });
});

app.post('/api/domains', (req, res) => {
  const { domain_name, admin_email, domain_type, parent_domain_id, service_id, total_seats, notes } = req.body;
  if (!domain_name) return res.status(400).json({ error: 'Domain name is required' });

  db.run(
    `INSERT INTO domains (domain_name, admin_email, domain_type, parent_domain_id, service_id, total_seats, notes) VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [domain_name, admin_email, domain_type || 'Primary', parent_domain_id || null, service_id || null, total_seats || null, notes],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ id: this.lastID, message: 'Domain added successfully' });
    }
  );
});

app.put('/api/domains/:id', (req, res) => {
  const { domain_name, admin_email, domain_type, parent_domain_id, service_id, total_seats, notes } = req.body;
  db.run(
    `UPDATE domains SET domain_name = ?, admin_email = ?, domain_type = ?, parent_domain_id = ?, service_id = ?, total_seats = ?, notes = ? WHERE id = ?`,
    [domain_name, admin_email, domain_type || 'Primary', parent_domain_id || null, service_id || null, total_seats || null, notes, req.params.id],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ message: 'Domain updated successfully' });
    }
  );
});

app.delete('/api/domains/:id', (req, res) => {
  db.run(`DELETE FROM domains WHERE id = ?`, [req.params.id], function (err) {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ message: 'Domain deleted' });
  });
});

// 8. MAILBOXES API (every email address in use across all company domains - who
// uses it and why. Frontend groups these by the domain part of the email.)
app.get('/api/mailboxes', (req, res) => {
  db.all(`SELECT * FROM mailboxes ORDER BY email ASC`, (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(rows);
  });
});

app.post('/api/mailboxes', (req, res) => {
  const { email, status, purpose, current_user, notes } = req.body;
  if (!email) return res.status(400).json({ error: 'Email is required' });

  db.run(
    `INSERT INTO mailboxes (email, status, purpose, current_user, notes) VALUES (?, ?, ?, ?, ?)`,
    [email, status || 'Active', purpose, current_user, notes],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ id: this.lastID, message: 'Mailbox added successfully' });
    }
  );
});

app.put('/api/mailboxes/:id', (req, res) => {
  const { email, status, purpose, current_user, notes } = req.body;
  db.run(
    `UPDATE mailboxes SET email = ?, status = ?, purpose = ?, current_user = ?, notes = ? WHERE id = ?`,
    [email, status || 'Active', purpose, current_user, notes, req.params.id],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ message: 'Mailbox updated successfully' });
    }
  );
});

app.delete('/api/mailboxes/:id', (req, res) => {
  db.run(`DELETE FROM mailboxes WHERE id = ?`, [req.params.id], function (err) {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ message: 'Mailbox deleted' });
  });
});

// 9. COMPANY DOCUMENTS API (certificates, registrations, policies - not tied to any vendor/service)
app.get('/api/company-documents', (req, res) => {
  db.all(`SELECT * FROM company_documents ORDER BY title ASC`, (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(rows);
  });
});

app.post('/api/company-documents', (req, res) => {
  const { title, category, notes } = req.body;
  if (!title) return res.status(400).json({ error: 'Title is required' });

  db.run(
    `INSERT INTO company_documents (title, category, notes) VALUES (?, ?, ?)`,
    [title, category || 'Other', notes],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ id: this.lastID, message: 'Document added successfully' });
    }
  );
});

app.put('/api/company-documents/:id', (req, res) => {
  const { title, category, notes } = req.body;
  db.run(
    `UPDATE company_documents SET title = ?, category = ?, notes = ? WHERE id = ?`,
    [title, category || 'Other', notes, req.params.id],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ message: 'Document updated successfully' });
    }
  );
});

// Add a file to a company document entry (each upload adds one, none are replaced)
app.post('/api/company-documents/:id/bill', uploadCompanyDoc.single('bill'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No file uploaded' });

  db.run(
    `INSERT INTO attachments (entity_type, entity_id, original_filename, stored_filename, folder) VALUES ('company_doc', ?, ?, ?, ?)`,
    [req.params.id, req.file.originalname, req.file.filename, req._uploadFolder],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });

      mirrorToGDrive(req._uploadFolder, req.file.path, req.file.filename);

      res.json({ id: this.lastID, message: 'File uploaded successfully', filename: req.file.originalname });
    }
  );
});

app.delete('/api/company-documents/:id', (req, res) => {
  deleteEntityAttachments('company_doc', req.params.id);
  db.run(`DELETE FROM company_documents WHERE id = ?`, [req.params.id], function (err) {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ message: 'Document deleted' });
  });
});

// 9. RENTED ASSETS API (laptops on rent - vendor RAC)
app.get('/api/rentals', (req, res) => {
  db.all(`SELECT * FROM rented_assets ORDER BY status ASC, asset_name ASC`, (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(rows);
  });
});

app.post('/api/rentals', (req, res) => {
  const { vendor_name, asset_name, model, serial_no, assigned_to, monthly_rent, rent_start, rent_end, status, gmail_link, notes } = req.body;
  if (!asset_name) return res.status(400).json({ error: 'Laptop name is required' });

  db.run(
    `INSERT INTO rented_assets (vendor_name, asset_name, model, serial_no, assigned_to, monthly_rent, rent_start, rent_end, status, gmail_link, notes)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [vendor_name || 'RAC', asset_name, model, serial_no, assigned_to, monthly_rent || null, rent_start, rent_end, status || 'On Rent', gmail_link, notes],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ id: this.lastID, message: 'Rented laptop added' });
    }
  );
});

app.put('/api/rentals/:id', (req, res) => {
  const { vendor_name, asset_name, model, serial_no, assigned_to, monthly_rent, rent_start, rent_end, status, gmail_link, notes } = req.body;

  db.run(
    `UPDATE rented_assets
     SET vendor_name = ?, asset_name = ?, model = ?, serial_no = ?, assigned_to = ?, monthly_rent = ?, rent_start = ?, rent_end = ?, status = ?, gmail_link = ?, notes = ?
     WHERE id = ?`,
    [vendor_name || 'RAC', asset_name, model, serial_no, assigned_to, monthly_rent || null, rent_start, rent_end, status || 'On Rent', gmail_link, notes, req.params.id],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ message: 'Rented laptop updated' });
    }
  );
});

app.delete('/api/rentals/:id', (req, res) => {
  db.run(`DELETE FROM rented_assets WHERE id = ?`, [req.params.id], function (err) {
    if (err) return res.status(500).json({ error: err.message });
    // Payments stay - they are money that actually left the account. Their
    // asset_id is cleared by the FK's ON DELETE SET NULL.
    res.json({ message: 'Rented laptop removed' });
  });
});

// 9a. RENTAL PAYMENTS API (what we have actually paid RAC, and the bill for it)
app.get('/api/rental-payments', (req, res) => {
  db.all(`SELECT * FROM rental_payments ORDER BY payment_date DESC, id DESC`, (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(rows);
  });
});

app.post('/api/rental-payments', (req, res) => {
  const { vendor_name, asset_id, amount, payment_date, period_label, payment_method, invoice_no, gmail_link, status, due_date, paid_on, paid_amount, notes } = req.body;
  if (!amount || !payment_date) return res.status(400).json({ error: 'Amount and payment date are required' });

  db.run(
    `INSERT INTO rental_payments (vendor_name, asset_id, amount, payment_date, period_label, payment_method, invoice_no, gmail_link, status, due_date, paid_on, paid_amount, notes)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [vendor_name || 'RAC', asset_id || null, amount, payment_date, period_label, payment_method, invoice_no, gmail_link, status || 'Pending', due_date, paid_on, paid_amount || null, notes],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ id: this.lastID, message: 'Payment recorded' });
    }
  );
});

app.put('/api/rental-payments/:id', (req, res) => {
  const { vendor_name, asset_id, amount, payment_date, period_label, payment_method, invoice_no, gmail_link, status, due_date, paid_on, paid_amount, notes } = req.body;

  db.run(
    `UPDATE rental_payments
     SET vendor_name = ?, asset_id = ?, amount = ?, payment_date = ?, period_label = ?, payment_method = ?, invoice_no = ?, gmail_link = ?, status = ?, due_date = ?, paid_on = ?, paid_amount = ?, notes = ?
     WHERE id = ?`,
    [vendor_name || 'RAC', asset_id || null, amount, payment_date, period_label, payment_method, invoice_no, gmail_link, status || 'Pending', due_date, paid_on, paid_amount || null, notes, req.params.id],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      res.json({ message: 'Payment updated' });
    }
  );
});

// Attach the bill for a payment. Same multi-file behaviour as work log bills.
app.post('/api/rental-payments/:id/bill', uploadRentalBill.single('bill'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No bill file uploaded' });

  db.run(
    `INSERT INTO attachments (entity_type, entity_id, original_filename, stored_filename, folder) VALUES ('rental_payment', ?, ?, ?, ?)`,
    [req.params.id, req.file.originalname, req.file.filename, req._uploadFolder],
    function (err) {
      if (err) return res.status(500).json({ error: err.message });
      mirrorToGDrive(req._uploadFolder, req.file.path, req.file.filename);
      res.json({ id: this.lastID, message: 'Bill uploaded successfully', filename: req.file.originalname });
    }
  );
});

app.delete('/api/rental-payments/:id', (req, res) => {
  deleteEntityAttachments('rental_payment', req.params.id);
  db.run(`DELETE FROM rental_payments WHERE id = ?`, [req.params.id], function (err) {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ message: 'Payment deleted' });
  });
});

// 10. CSV IMPORT API
app.post('/api/import/csv', (req, res) => {
  const { rows } = req.body; // Expects array of objects
  if (!Array.isArray(rows) || rows.length === 0) {
    return res.status(400).json({ error: 'Invalid or empty CSV rows provided' });
  }

  let importedCount = 0;
  const stmt = db.prepare(`
    INSERT INTO services_contracts (service_name, category, cost, billing_cycle, start_date, expiry_date, notes, status)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);

  rows.forEach(r => {
    const serviceName = r['Service Name'] || r['Item'] || r['Name'] || 'Imported Service';
    const category = r['Category'] || 'Office Insurance';
    const cost = parseFloat(r['Cost'] || r['Amount'] || r['Premium'] || 0);
    const billingCycle = r['Billing Cycle'] || 'yearly';
    const startDate = r['Start Date'] || r['Issue Date'] || '';
    const expiryDate = r['Expiry Date'] || r['Renewal Date'] || new Date().toISOString().split('T')[0];
    const notes = r['Notes'] || r['Policy No'] || r['Vendor'] || '';

    const today = new Date();
    const exp = new Date(expiryDate);
    const diffDays = Math.ceil((exp - today) / (1000 * 60 * 60 * 24));
    let status = 'Active';
    if (diffDays <= 0) status = 'Expired';
    else if (diffDays <= 30) status = 'Expiring Soon';

    stmt.run([serviceName, category, cost, billingCycle, startDate, expiryDate, notes, status]);
    importedCount++;
  });

  stmt.finalize(() => {
    res.json({ message: `Successfully imported ${importedCount} records into database` });
  });
});

// Multer / bill-upload errors -> JSON instead of Express's default HTML error page
app.use((err, req, res, next) => {
  if (err instanceof multer.MulterError || err) {
    return res.status(400).json({ error: err.message });
  }
  next();
});

// Serve frontend SPA fallback
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Start Server and Cron Scheduler
app.listen(PORT, () => {
  console.log(`====================================================`);
  console.log(`🚀 IT Billing Console running on http://localhost:${PORT}`);
  console.log(`====================================================`);
  startScheduler();
  setTimeout(migrateAttachmentsToNas, 2000);
});
