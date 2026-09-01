const sqlite3 = require('sqlite3').verbose();
const path = require('path');

const dbPath = path.join(__dirname, 'data.sqlite');
const db = new sqlite3.Database(dbPath);

console.log("Seeding exact spreadsheet status tags (Upcoming, Done, Auto)...");

db.serialize(() => {
  db.run("DELETE FROM payment_history");
  db.run("DELETE FROM services_contracts");
  db.run("DELETE FROM vendors");
  db.run("DELETE FROM sqlite_sequence WHERE name IN ('vendors', 'services_contracts', 'payment_history')");

  // 1. Vendors
  const stmtVendor = db.prepare(`
    INSERT INTO vendors (id, name, category, contact_person, email, phone, portal_url, notes)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);

  stmtVendor.run(1, 'DigiSoft', 'SaaS Reseller', 'Vandana (Account), Nikhil, Swapna', 'accounts@digisoft.in', '9311777103 / 9811636306 / 93550 04641', 'https://digisoft.in', 'Google Workspace Reseller');
  stmtVendor.run(2, 'Cloudgeneric', 'SaaS Reseller', 'Sheetal, Piyush Kumar', 'sales@cloudgeneric.com', '9667677191 / 9667668960', '', 'Google Workspace Reseller');
  stmtVendor.run(3, 'Natraj', 'SaaS Reseller', 'Gaurang Patel', '', '9909022626', '', 'O365 Reseller');
  stmtVendor.run(4, 'Google Direct', 'SaaS Software', 'Google India', 'support@google.com', '', 'https://admin.google.com', 'Direct Google Billing');
  stmtVendor.run(5, 'Microsoft Direct', 'SaaS Software', 'Gaurang Patel', '', '9909022627', 'https://admin.microsoft.com', 'O365 Direct');
  stmtVendor.run(6, 'Zoho Direct', 'SaaS Software', 'Zoho India', 'support@zoho.com', '', 'https://mail.zoho.com', 'Free Tier Zoho Mail');
  stmtVendor.run(7, 'Technofirm', 'SaaS Reseller', 'Technofirm Sales', 'support@technofirm.com', '', 'https://technofirm.com', 'Google Workspace, O365 & Zoho Reseller');
  stmtVendor.finalize();

  // 2. Services / Renewals (Exact Spreadsheet Statuses)
  const stmtService = db.prepare(`
    INSERT INTO services_contracts (id, vendor_id, service_name, category, cost, currency, billing_cycle, start_date, expiry_date, auto_renew, status, notes)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);

  // --- SPREADSHEET 1 ---
  // Row 1: Krishnabusiness -> Upcomming (Red)
  stmtService.run(1, 1, 'Krishnabusiness - GW (22 Users)', 'SaaS Software', 78918.4, 'INR', 'yearly', '2025-09-09', '2026-09-09', 0, 'Upcoming', 'Admin: leo@humbersolutions.com | Price/User: ₹3587.2 | Total Users: 22');
  
  // Row 2: Saleshandy -> Upcomming (Red)
  stmtService.run(2, 1, 'Saleshandy - GW (102 Users)', 'SaaS Software', 365894.4, 'INR', 'yearly', '2025-09-12', '2026-09-12', 0, 'Upcoming', 'Admin: ravip@saleshandy.com | Price/User: ₹3587.2 | Total Users: 102');
  
  // Row 3: Saleshandy Solutions -> Upcomming (Red)
  stmtService.run(3, 2, 'Saleshandy Solutions - GW (10 Users)', 'SaaS Software', 35400, 'INR', 'yearly', '2025-09-25', '2026-09-25', 0, 'Upcoming', 'Admin: dhruv@SaleshandySolutions.com | Price/User: ₹3540 | Total Users: 10');
  
  // Row 4: Truly Inbox HQ -> Upcomming (Red)
  stmtService.run(4, 5, 'Truly Inbox HQ - O365 (33 Users)', 'SaaS Software', 44781, 'INR', 'yearly', '2025-09-17', '2026-09-17', 0, 'Upcoming', 'Admin: julie@neverstoptohustle.com | Price/User: ₹1357 | Total Users: 33');
  
  // Row 5: hqsaleshandy -> Upcomming
  stmtService.run(5, 3, 'hqsaleshandy - O365', 'SaaS Software', 0, 'INR', 'yearly', '2025-12-23', '2026-12-23', 0, 'Upcoming', 'Admin: dhruv@hqsaleshandy.com | Contact: Gaurang Patel 9909022626');
  
  // Row 6: saleshandyteam -> Auto (Blue)
  stmtService.run(6, 4, 'saleshandyteam - GW (9 Users)', 'SaaS Software', 29313.45, 'INR', 'monthly', '2026-08-01', '2026-09-01', 1, 'Auto', 'Admin: admin@saleshandyteam.com | Price/User: ₹3257.05 | Total Users: 9 | Auto Monthly');
  
  // Row 7: Truly Inbox -> Done (Green)
  stmtService.run(7, 1, 'Truly Inbox - GW (8 Users)', 'SaaS Software', 16520, 'INR', 'yearly', '2025-06-09', '2026-06-09', 0, 'Done', 'Admin: vatsal@saleshandy.com | Price/User: ₹2065 | Total Users: 8 | Status: Done');
  
  // Row 8: saleshandyemails -> Done (Free)
  stmtService.run(8, 6, 'saleshandyemails - ZOHO Free', 'SaaS Software', 0, 'INR', 'yearly', '2024-01-01', '2030-01-01', 1, 'Done', 'Admin: piyush@saleshandyemails.com | Free Plan');

  // --- SPREADSHEET 2 (TECHNOFIRM - All Payment Status: Done -> Green) ---
  stmtService.run(9, 7, 'deliverabilityradar.org - GW Batch 1 (20 Users)', 'SaaS Software', 71980, 'INR', 'yearly', '2025-06-10', '2026-06-10', 0, 'Done', 'Admin: emily.white@deliverabilityradar.org | Batch 1 | Price/User: ₹3050 | Payment Status: Done');
  stmtService.run(10, 7, 'getinboxradar.net - GW Batch 2 (20 Users)', 'SaaS Software', 41300, 'INR', 'yearly', '2025-06-01', '2026-06-01', 0, 'Done', 'Admin: julian.moss@getinboxradar.net | Batch 2 | Price/User: ₹2065 | Payment Status: Done');
  stmtService.run(11, 7, 'inboxauditor.org - GW Batch 3 (20 Users)', 'SaaS Software', 41300, 'INR', 'yearly', '2025-06-01', '2026-06-01', 0, 'Done', 'Admin: serena.craig@inboxauditor.org | Batch 3 | Price/User: ₹2065 | Payment Status: Done');
  stmtService.run(12, 7, 'inboxauditor.org - GW Batch 4 (20 Users)', 'SaaS Software', 71980, 'INR', 'yearly', '2025-07-22', '2026-07-22', 0, 'Done', 'Admin: lucas.anderson@emailtestengine.com | Batch 4 | Price/User: ₹3050+GST | Bill #: TSLE26-272973 | Payment Status: Done');
  stmtService.run(13, 7, 'inboxhealthcheck.com - GW Batch 5 (20 Users)', 'SaaS Software', 41300, 'INR', 'yearly', '2025-07-10', '2026-07-10', 0, 'Done', 'Admin: madison.king@inboxhealthcheck.com | Batch 5 | Price/User: ₹2065 | Bill #: TSLE26-272535 | Payment Status: Done');
  stmtService.run(14, 7, 'inboxradar.net - O365 All Batches (100 Users)', 'SaaS Software', 114460, 'INR', 'yearly', '2025-06-10', '2026-06-10', 0, 'Done', 'Admin: admin@InboxRadarApp.onmicrosoft.com | All Batches | Price/User: ₹1144.6 | Payment Status: Done');
  stmtService.run(15, 7, 'inboxreachreport.com - ZOHO All Batches (5 Users)', 'SaaS Software', 4130, 'INR', 'yearly', '2025-06-10', '2026-06-10', 0, 'Done', 'Admin: bryan.farley@inboxreachreport.com | All Batches | Price/User: ₹767 | Payment Status: Done');

  stmtService.finalize();

  // 3. Payment Records
  const stmtPayment = db.prepare(`
    INSERT INTO payment_history (service_id, vendor_id, amount, currency, payment_date, payment_method, invoice_no, receipt_note)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);

  stmtPayment.run(1, 1, 78918.4, 'INR', '2025-09-09', 'Bank Transfer', 'INV-DIGI-KB', 'Paid for 22 GW Users');
  stmtPayment.run(2, 1, 365894.4, 'INR', '2025-09-12', 'Bank Transfer', 'INV-DIGI-SH', 'Paid for 102 GW Users');
  stmtPayment.run(3, 2, 35400, 'INR', '2024-09-25', 'Bank Transfer', 'INV-CG-SHS', 'Paid for 10 GW Users');
  stmtPayment.run(4, 5, 44781, 'INR', '2025-09-17', 'Credit Card', 'INV-MS-TIHQ', 'Paid for 33 O365 Users');
  stmtPayment.run(6, 4, 29313.45, 'INR', '2026-08-01', 'Auto Debit', 'INV-GGL-SHT', 'Auto monthly debit');
  stmtPayment.run(7, 1, 16520, 'INR', '2025-06-09', 'Bank Transfer', 'INV-DIGI-TI', 'Paid for 8 GW Users');
  stmtPayment.run(9, 7, 71980, 'INR', '2025-06-10', 'Bank Transfer', 'TSLE26-RADAR', 'Deliverabilityradar Batch 1 (Done)');
  stmtPayment.run(10, 7, 41300, 'INR', '2025-06-01', 'Bank Transfer', 'TSLE26-INBOX', 'Getinboxradar Batch 2 (Done)');
  stmtPayment.run(11, 7, 41300, 'INR', '2025-06-01', 'Bank Transfer', 'TSLE26-AUDIT3', 'Inboxauditor Batch 3 (Done)');
  stmtPayment.run(12, 7, 71980, 'INR', '2025-07-22', 'Bank Transfer', 'TSLE26-272973', 'Inboxauditor Batch 4 (Done)');
  stmtPayment.run(13, 7, 41300, 'INR', '2025-07-10', 'Bank Transfer', 'TSLE26-272535', 'Inboxhealthcheck Batch 5 (Done)');
  stmtPayment.run(14, 7, 114460, 'INR', '2025-06-10', 'Bank Transfer', 'TSLE26-O365-RADAR', 'Inboxradar O365 (Done)');
  stmtPayment.run(15, 7, 4130, 'INR', '2025-06-10', 'Bank Transfer', 'TSLE26-ZOHO-REACH', 'Inboxreachreport ZOHO (Done)');

  stmtPayment.finalize();

  console.log("✅ Exact spreadsheet statuses (Upcoming, Done, Auto) seeded!");
});
