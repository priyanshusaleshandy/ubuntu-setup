// A contract's status is DERIVED from its payments, never pinned by hand.
//
// The old rule made "Done" permanent: once a row was marked Done the scheduler
// re-pinned it to Done forever, so next year's renewal never reappeared as
// Upcoming and nobody was reminded to pay it. And recording a payment did not
// touch the status at all, so three fully-paid contracts were still showing red.
//
// The rule below fixes both, and needs no extra column: a contract is Done while
// the CURRENT period is paid for. When the period rolls forward, the old
// payments fall before the new start_date, the period reads as unpaid, and the
// row goes back to Upcoming on its own.
//
// A part payment is deliberately NOT Done - the ESET contract sitting at a 50%
// advance still needs chasing.

const db = require('./database');

// Rounding on invoices routinely leaves a rupee on the table, so treat "within
// one rupee of the full amount" as settled.
const TOLERANCE = 1;

const SQL = `
  SELECT s.id, s.cost, s.status, s.start_date, s.expiry_date,
         (SELECT IFNULL(SUM(p.amount), 0) FROM payment_history p
           WHERE p.service_id = s.id AND p.payment_date >= s.start_date) AS paid
  FROM services_contracts s`;

function decide(row, todayStr) {
  const cost = Number(row.cost) || 0;
  const paid = Number(row.paid) || 0;

  // Cost 0 means nobody has filled the amount in yet (or the service is free).
  // There is nothing to settle, so leave whatever a human chose.
  if (cost <= 0) return row.status;

  if (paid >= cost - TOLERANCE) return 'Done';
  if (row.expiry_date && row.expiry_date <= todayStr) return 'Expired';
  return 'Upcoming';
}

function today() {
  return new Date().toISOString().slice(0, 10);
}

// Recompute one service, e.g. straight after a payment is recorded or removed.
function recomputeOne(serviceId, cb) {
  db.get(SQL + ' WHERE s.id = ?', [serviceId], (err, row) => {
    if (err || !row) return cb && cb(err);
    const next = decide(row, today());
    if (next === row.status) return cb && cb(null, row.status);
    db.run(`UPDATE services_contracts SET status = ? WHERE id = ?`, [next, serviceId],
      (e) => cb && cb(e, next));
  });
}

// Sweep every service; used by the daily scheduler.
function recomputeAll(cb) {
  db.all(SQL, [], (err, rows) => {
    if (err || !rows) return cb && cb(err, []);
    const todayStr = today();
    const changed = [];
    let pending = 0;
    rows.forEach(row => {
      const next = decide(row, todayStr);
      if (next === row.status) return;
      pending++;
      changed.push({ id: row.id, from: row.status, to: next });
      db.run(`UPDATE services_contracts SET status = ? WHERE id = ?`, [next, row.id],
        () => { if (--pending === 0 && cb) cb(null, changed); });
    });
    if (pending === 0 && cb) cb(null, changed);
  });
}

module.exports = { recomputeOne, recomputeAll, decide };
