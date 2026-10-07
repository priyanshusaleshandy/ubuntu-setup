// Login for the console: password, then a one-time code by email.
//
// Until now this app had no authentication at all, and it is published through a
// Cloudflare tunnel - `https://it.saleshandy.dev/api/vendors` returned the whole
// vendor list to anyone who asked. So the point of this file is specifically to
// close the *public* door.
//
// Two deliberate choices are worth reading before changing anything here:
//
// 1. No new dependencies. Password hashing is scrypt and sessions are signed with
//    HMAC, both from node's own `crypto`. bcrypt/argon2 would be conventional but
//    they are native modules, and this image is built for alpine/arm64 where that
//    is exactly the kind of thing that breaks a deploy at the worst moment.
//
// 2. Machine callers are not locked out. n8n drives this API from 25 different
//    nodes and Hermes uses a dozen more endpoints. Putting a session in front of
//    all of that would have broken every automation the moment it deployed, so
//    `/api/*` also accepts a request that did not arrive through the tunnel, or
//    one carrying the API key. Page loads always need a session, so a browser
//    still gets a login screen wherever it is.

const crypto = require('crypto');
const nodemailer = require('nodemailer');
const db = require('./database');

const SESSION_HOURS = 12;
const OTP_MINUTES = 10;
const OTP_MAX_ATTEMPTS = 5;
const LOGIN_WINDOW_MS = 15 * 60 * 1000;
const LOGIN_MAX_FAILURES = 8;

// ---------------------------------------------------------------- passwords

function hashPassword(password, salt) {
  const useSalt = salt || crypto.randomBytes(16).toString('hex');
  const derived = crypto.scryptSync(String(password), useSalt, 64).toString('hex');
  return `scrypt$${useSalt}$${derived}`;
}

function passwordMatches(password, stored) {
  const parts = String(stored || '').split('$');
  if (parts.length !== 3 || parts[0] !== 'scrypt') return false;
  const candidate = Buffer.from(hashPassword(password, parts[1]));
  const actual = Buffer.from(stored);
  // Lengths are equal by construction, but timingSafeEqual throws if they ever
  // are not, so guard rather than let a malformed row crash the login route.
  if (candidate.length !== actual.length) return false;
  return crypto.timingSafeEqual(candidate, actual);
}

const sha256 = (v) => crypto.createHash('sha256').update(String(v)).digest('hex');

// ------------------------------------------------------------------- setup

// The admin account is seeded from the environment, never from a literal in the
// repo, and only when no user exists yet. Changing ADMIN_PASSWORD later does not
// silently rewrite the stored hash - use the reset route or delete the row.
function initAuth() {
  db.get('SELECT COUNT(*) AS n FROM users', (err, row) => {
    if (err) return console.error('[Auth] Could not read users:', err.message);
    if (row && row.n > 0) return;

    const email = (process.env.ADMIN_EMAIL || '').trim().toLowerCase();
    const password = process.env.ADMIN_PASSWORD || '';
    if (!email || !password) {
      console.error('[Auth] No users and no ADMIN_EMAIL/ADMIN_PASSWORD set - nobody can sign in.');
      return;
    }
    db.run('INSERT INTO users (email, password_hash) VALUES (?, ?)',
      [email, hashPassword(password)],
      (e) => console.log(e ? '[Auth] Seed failed: ' + e.message : '[Auth] Seeded admin user ' + email));
  });
}

// ---------------------------------------------------------------- sessions

function createSession(email, cb) {
  const token = crypto.randomBytes(32).toString('hex');
  const expires = new Date(Date.now() + SESSION_HOURS * 3600 * 1000).toISOString();
  db.run('INSERT INTO auth_sessions (token_hash, email, expires_at) VALUES (?, ?, ?)',
    [sha256(token), email, expires],
    (err) => cb(err, token));
}

function readSession(token, cb) {
  if (!token) return cb(null, null);
  db.get(`SELECT email, expires_at FROM auth_sessions WHERE token_hash = ?`, [sha256(token)], (err, row) => {
    if (err || !row) return cb(err, null);
    if (new Date(row.expires_at) <= new Date()) {
      db.run('DELETE FROM auth_sessions WHERE token_hash = ?', [sha256(token)]);
      return cb(null, null);
    }
    cb(null, row);
  });
}

// Small enough not to justify a dependency; express gives us the raw header.
function readCookie(req, name) {
  const raw = req.headers.cookie || '';
  for (const part of raw.split(';')) {
    const eq = part.indexOf('=');
    if (eq === -1) continue;
    if (part.slice(0, eq).trim() === name) return decodeURIComponent(part.slice(eq + 1).trim());
  }
  return null;
}

// --------------------------------------------------------------------- otp

async function sendOtpEmail(code, cb) {
  db.get('SELECT * FROM alert_settings WHERE id = 1', async (err, cfg) => {
    if (err || !cfg || !cfg.smtp_host || !cfg.smtp_user) {
      return cb(new Error('Email is not configured, so the code cannot be sent.'));
    }
    const to = cfg.notification_email || cfg.smtp_user;
    try {
      // Deliberately not reusing scheduler.sendEmailAlert: that one swallows its
      // errors, which is fine for a renewal reminder and wrong here - a failed
      // send must surface, or the user waits for a code that is never coming.
      const transporter = nodemailer.createTransport({
        host: cfg.smtp_host,
        port: cfg.smtp_port || 587,
        secure: cfg.smtp_port === 465,
        auth: { user: cfg.smtp_user, pass: cfg.smtp_pass },
        // Without these a stalled SMTP server leaves the login request hanging
        // forever and the person just watches a spinner. Found by testing
        // against a server that accepted the connection and then went quiet.
        connectionTimeout: 10000,
        greetingTimeout: 10000,
        socketTimeout: 15000,
      });
      await transporter.sendMail({
        from: `"IT Ops Console" <${cfg.smtp_user}>`,
        to,
        subject: `${code} is your IT Console sign-in code`,
        html: `<p>Your sign-in code is:</p>
               <p style="font-size:28px;font-weight:bold;letter-spacing:4px;">${code}</p>
               <p>It expires in ${OTP_MINUTES} minutes and can be used once.</p>
               <p style="color:#666;font-size:12px;">If you did not try to sign in, someone has the console password — change it.</p>`,
      });
      cb(null, to);
    } catch (e) {
      cb(new Error('Could not send the code: ' + e.message));
    }
  });
}

// ------------------------------------------------------- brute force guard

const failures = new Map();

function tooManyFailures(key) {
  const rec = failures.get(key);
  if (!rec) return false;
  if (Date.now() - rec.first > LOGIN_WINDOW_MS) { failures.delete(key); return false; }
  return rec.count >= LOGIN_MAX_FAILURES;
}

function noteFailure(key) {
  const rec = failures.get(key);
  if (!rec || Date.now() - rec.first > LOGIN_WINDOW_MS) failures.set(key, { count: 1, first: Date.now() });
  else rec.count++;
}

// ------------------------------------------------------------------ routes

function registerAuthRoutes(app) {
  app.post('/api/auth/login', (req, res) => {
    const email = String(req.body.email || '').trim().toLowerCase();
    const password = String(req.body.password || '');
    const who = req.ip || 'unknown';

    if (tooManyFailures(who)) {
      return res.status(429).json({ error: 'Too many attempts. Wait 15 minutes and try again.' });
    }

    db.get('SELECT email, password_hash FROM users WHERE email = ?', [email], (err, user) => {
      if (err) return res.status(500).json({ error: err.message });

      // Same message either way - a wrong address should not be distinguishable
      // from a wrong password.
      if (!user || !passwordMatches(password, user.password_hash)) {
        noteFailure(who);
        return res.status(401).json({ error: 'Email or password is incorrect.' });
      }

      const code = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
      const expires = new Date(Date.now() + OTP_MINUTES * 60000).toISOString();

      // Any earlier code for this user stops working the moment a new one is
      // issued, so two overlapping attempts cannot both be valid.
      db.run('UPDATE login_otps SET consumed = 1 WHERE email = ? AND consumed = 0', [email], () => {
        db.run('INSERT INTO login_otps (email, code_hash, expires_at) VALUES (?, ?, ?)',
          [email, sha256(code), expires], (e) => {
            if (e) return res.status(500).json({ error: e.message });
            sendOtpEmail(code, (sendErr, sentTo) => {
              if (sendErr) return res.status(502).json({ error: sendErr.message });
              const masked = sentTo.replace(/^(.).*(@.*)$/, (m, a, b) => a + '****' + b);
              res.json({ status: 'otp_sent', sent_to: masked, expires_in_minutes: OTP_MINUTES });
            });
          });
      });
    });
  });

  app.post('/api/auth/verify', (req, res) => {
    const email = String(req.body.email || '').trim().toLowerCase();
    const code = String(req.body.code || '').trim();
    const who = req.ip || 'unknown';

    if (tooManyFailures(who)) {
      return res.status(429).json({ error: 'Too many attempts. Wait 15 minutes and try again.' });
    }

    db.get(`SELECT id, code_hash, expires_at, attempts FROM login_otps
             WHERE email = ? AND consumed = 0 ORDER BY id DESC LIMIT 1`, [email], (err, row) => {
      if (err) return res.status(500).json({ error: err.message });
      if (!row) return res.status(401).json({ error: 'Ask for a new code.' });

      if (new Date(row.expires_at) <= new Date()) {
        db.run('UPDATE login_otps SET consumed = 1 WHERE id = ?', [row.id]);
        return res.status(401).json({ error: 'That code expired. Ask for a new one.' });
      }
      if (row.attempts >= OTP_MAX_ATTEMPTS) {
        db.run('UPDATE login_otps SET consumed = 1 WHERE id = ?', [row.id]);
        return res.status(429).json({ error: 'Too many wrong codes. Ask for a new one.' });
      }
      if (sha256(code) !== row.code_hash) {
        noteFailure(who);
        db.run('UPDATE login_otps SET attempts = attempts + 1 WHERE id = ?', [row.id]);
        return res.status(401).json({ error: 'That code is not right.' });
      }

      db.run('UPDATE login_otps SET consumed = 1 WHERE id = ?', [row.id]);
      createSession(email, (sErr, token) => {
        if (sErr) return res.status(500).json({ error: sErr.message });
        const https = req.headers['x-forwarded-proto'] === 'https' || !!req.headers['cf-ray'];
        res.setHeader('Set-Cookie',
          `itc_session=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${SESSION_HOURS * 3600}` +
          (https ? '; Secure' : ''));
        res.json({ status: 'signed_in', email });
      });
    });
  });

  app.post('/api/auth/logout', (req, res) => {
    const token = readCookie(req, 'itc_session');
    if (token) db.run('DELETE FROM auth_sessions WHERE token_hash = ?', [sha256(token)]);
    res.setHeader('Set-Cookie', 'itc_session=; Path=/; HttpOnly; Max-Age=0');
    res.json({ status: 'signed_out' });
  });

  app.get('/api/auth/me', (req, res) => {
    readSession(readCookie(req, 'itc_session'), (err, sess) => {
      if (sess) return res.json({ signed_in: true, email: sess.email });
      res.status(401).json({ signed_in: false });
    });
  });
}

// -------------------------------------------------------------- middleware

// Anything Cloudflare forwards carries these. A request without them did not
// come through the public tunnel, so it is n8n, Hermes or someone already on the
// office LAN - all of which could reach this port before any of this existed.
function cameFromInternet(req) {
  return !!(req.headers['cf-ray'] || req.headers['cf-connecting-ip']);
}

const OPEN_PATHS = new Set(['/login.html', '/login.js', '/style.css', '/favicon.ico']);

function requireAuth(req, res, next) {
  const p = req.path;

  if (p.startsWith('/api/auth/') || OPEN_PATHS.has(p)) return next();

  readSession(readCookie(req, 'itc_session'), (err, sess) => {
    if (sess) { req.user = sess.email; return next(); }

    if (p.startsWith('/api/')) {
      // The automations keep working untouched; the public tunnel does not.
      const apiKey = process.env.API_KEY;
      if (apiKey && req.headers['x-api-key'] === apiKey) return next();
      if (!cameFromInternet(req)) return next();
      return res.status(401).json({ error: 'Sign in required.' });
    }

    // A page request. Send the browser somewhere it can actually do something.
    res.redirect('/login.html');
  });
}

module.exports = { initAuth, registerAuthRoutes, requireAuth, hashPassword };
