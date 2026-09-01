const cron = require('node-cron');
const nodemailer = require('nodemailer');
const db = require('./database');

// Function to send Telegram Notification
async function sendTelegramAlert(botToken, chatId, message) {
  if (!botToken || !chatId) return;
  try {
    const url = `https://api.telegram.org/bot${botToken}/sendMessage`;
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        chat_id: chatId,
        text: message,
        parse_mode: 'HTML'
      })
    });
    const result = await response.json();
    console.log('[Scheduler] Telegram Alert Sent:', result.ok);
  } catch (err) {
    console.error('[Scheduler] Telegram Alert Error:', err.message);
  }
}

// Function to send an ntfy Notification.
// Needs no credential, unlike SMTP - which is why the email channel had been
// silently failing while nobody noticed the renewal alerts had stopped.
const NTFY_URL = process.env.NTFY_URL || 'http://192.168.126.101:8080/it-billing-console';

async function sendNtfyAlert(title, body, urgent) {
  // HTTP header values must be ASCII; the title starts with an emoji and node's
  // fetch throws on any character above 255. Strip it for the header only - the
  // body carries the full text.
  const asciiTitle = String(title).replace(/[^ -~]/g, '').replace(/\s+/g, ' ').trim() || 'IT renewal alert';
  try {
    const res = await fetch(NTFY_URL, {
      method: 'POST',
      headers: {
        'Title': asciiTitle,
        'Priority': urgent ? 'high' : 'default',
        'Tags': urgent ? 'rotating_light,calendar' : 'calendar',
        'Content-Type': 'text/plain'
      },
      body
    });
    if (!res.ok) throw new Error('ntfy returned ' + res.status);
    console.log('[Scheduler] ntfy alert sent:', asciiTitle);
  } catch (err) {
    console.error('[Scheduler] ntfy Alert Error:', err.message);
  }
}

// Function to send Email Notification
async function sendEmailAlert(smtpConfig, toEmail, subject, htmlBody) {
  if (!smtpConfig.smtp_host || !toEmail) return;
  try {
    const transporter = nodemailer.createTransport({
      host: smtpConfig.smtp_host,
      port: smtpConfig.smtp_port || 587,
      secure: smtpConfig.smtp_port === 465,
      auth: {
        user: smtpConfig.smtp_user,
        pass: smtpConfig.smtp_pass
      }
    });

    await transporter.sendMail({
      from: `"IT Billing & Renewal System" <${smtpConfig.smtp_user}>`,
      to: toEmail,
      subject: subject,
      html: htmlBody
    });

    console.log('[Scheduler] Email Alert Sent to:', toEmail);
  } catch (err) {
    console.error('[Scheduler] Email Alert Error:', err.message);
  }
}

// Check Expiry Engine
function checkExpiringServices() {
  console.log('[Scheduler] Running daily expiry & renewal check...');

  const todayStr = new Date().toISOString().split('T')[0];

  db.all(`
    SELECT s.*, v.name as vendor_name, v.email as vendor_email, v.contact_person
    FROM services_contracts s
    LEFT JOIN vendors v ON s.vendor_id = v.id
  `, [], (err, services) => {
    if (err) {
      console.error('[Scheduler] DB Error:', err);
      return;
    }

    db.get(`SELECT * FROM alert_settings WHERE id = 1`, [], async (err, settings) => {
      if (err) return;

      for (const service of services) {
        const expiry = new Date(service.expiry_date);
        const today = new Date(todayStr);
        const diffTime = expiry - today;
        const diffDays = Math.ceil(diffTime / (1000 * 60 * 60 * 24));

        let newStatus = service.status;
        if (service.status === 'Completed' || service.status === 'Done') {
          newStatus = 'Completed';
        } else if (diffDays <= 0 && service.status !== 'Upcoming') {
          newStatus = 'Expired';
        } else if (diffDays > 0) {
          newStatus = 'Upcoming';
        }

        // Update status in DB if changed
        if (newStatus !== service.status) {
          db.run(`UPDATE services_contracts SET status = ? WHERE id = ?`, [newStatus, service.id]);
          service.status = newStatus;
        }

        // Trigger Alerts for 30, 15, 7, 3, 1 day thresholds
        if ([30, 15, 7, 3, 1].includes(diffDays) || (diffDays === 0 && service.status !== 'Expired')) {
          const alertTitle = `⚠️ RENEWAL ALERT: ${service.service_name} (${diffDays <= 0 ? 'EXPIRED' : diffDays + ' Days Left'})`;

          const alertMessage = `
📌 <b>IT Service Renewal Notice</b>
━━━━━━━━━━━━━━━━━━━━━━━━━━
• <b>Service:</b> ${service.service_name}
• <b>Vendor:</b> ${service.vendor_name || 'N/A'}
• <b>Category:</b> ${service.category}
• <b>Cost:</b> ₹${service.cost.toLocaleString('en-IN')} (${service.billing_cycle})
• <b>Expiry Date:</b> ${service.expiry_date}
• <b>Status:</b> ${diffDays <= 0 ? '❌ EXPIRED TODAY' : '⚠️ Expiring in ' + diffDays + ' Days'}
• <b>Auto-Renew:</b> ${service.auto_renew ? 'YES' : 'NO (Manual Renewal Needed)'}
━━━━━━━━━━━━━━━━━━━━━━━━━━
<i>Please process payment/renewal to avoid service disruption.</i>
          `;

          // Send ntfy Alert - always on, and the only channel that currently works
          await sendNtfyAlert(
            alertTitle,
            [
              'Service: ' + service.service_name,
              'Vendor: ' + (service.vendor_name || 'N/A'),
              'Category: ' + service.category,
              'Cost: Rs.' + service.cost.toLocaleString('en-IN') + ' (' + service.billing_cycle + ')',
              'Expiry: ' + service.expiry_date,
              diffDays <= 0 ? 'Status: EXPIRED' : 'Status: ' + diffDays + ' day(s) left',
              'Auto-renew: ' + (service.auto_renew ? 'yes' : 'no - renew by hand')
            ].join('\n'),
            diffDays <= 7
          );

          // Send Telegram Alert
          if (settings && settings.telegram_enabled && settings.telegram_bot_token && settings.telegram_chat_id) {
            await sendTelegramAlert(settings.telegram_bot_token, settings.telegram_chat_id, alertMessage);
          }

          // Send Email Alert
          if (settings && settings.email_enabled && settings.notification_email) {
            const emailHtml = `
              <div style="font-family: Arial, sans-serif; padding: 20px; background-color: #f4f6f9; color: #333;">
                <div style="max-width: 600px; margin: 0 auto; background: #ffffff; border-radius: 8px; border: 1px solid #e1e4e8; padding: 24px;">
                  <h2 style="color: ${diffDays <= 7 ? '#d73a49' : '#e36209'}; margin-top: 0;">${alertTitle}</h2>
                  <p>Hello IT Team,</p>
                  <p>This is an automated notification regarding an upcoming IT renewal.</p>
                  <table style="width: 100%; border-collapse: collapse; margin: 20px 0;">
                    <tr><td style="padding: 8px; border-bottom: 1px solid #eee;"><strong>Service Name:</strong></td><td style="padding: 8px; border-bottom: 1px solid #eee;">${service.service_name}</td></tr>
                    <tr><td style="padding: 8px; border-bottom: 1px solid #eee;"><strong>Vendor:</strong></td><td style="padding: 8px; border-bottom: 1px solid #eee;">${service.vendor_name || 'N/A'}</td></tr>
                    <tr><td style="padding: 8px; border-bottom: 1px solid #eee;"><strong>Category:</strong></td><td style="padding: 8px; border-bottom: 1px solid #eee;">${service.category}</td></tr>
                    <tr><td style="padding: 8px; border-bottom: 1px solid #eee;"><strong>Cost:</strong></td><td style="padding: 8px; border-bottom: 1px solid #eee;">₹${service.cost.toLocaleString('en-IN')} (${service.billing_cycle})</td></tr>
                    <tr><td style="padding: 8px; border-bottom: 1px solid #eee;"><strong>Expiry Date:</strong></td><td style="padding: 8px; border-bottom: 1px solid #eee;"><strong>${service.expiry_date}</strong></td></tr>
                    <tr><td style="padding: 8px; border-bottom: 1px solid #eee;"><strong>Days Remaining:</strong></td><td style="padding: 8px; border-bottom: 1px solid #eee;"><span style="background: ${diffDays <= 7 ? '#ffdce0' : '#fff5b1'}; padding: 4px 8px; border-radius: 4px; font-weight: bold;">${diffDays <= 0 ? 'EXPIRED' : diffDays + ' Days'}</span></td></tr>
                    <tr><td style="padding: 8px; border-bottom: 1px solid #eee;"><strong>Auto-Renew:</strong></td><td style="padding: 8px; border-bottom: 1px solid #eee;">${service.auto_renew ? 'Enabled' : 'Disabled (Requires Manual Action)'}</td></tr>
                  </table>
                  <p style="color: #666; font-size: 13px;">System Log ID: SEC-RENEW-${service.id}-${todayStr}</p>
                </div>
              </div>
            `;
            await sendEmailAlert(settings, settings.notification_email, alertTitle, emailHtml);
          }
        }
      }
    });
  });
}

function startScheduler() {
  // 09:00 IST. The container used to run UTC, which made this fire at 14:30 IST
  // while the UI claimed 09:00 - the image now sets TZ=Asia/Kolkata.
  cron.schedule('0 9 * * *', () => {
    checkExpiringServices();
  });
  console.log('[Scheduler] Daily cron initialized (09:00 ' + (process.env.TZ || 'server local') + ')');

  // Run once immediately on server startup
  setTimeout(checkExpiringServices, 3000);
}

module.exports = { startScheduler, checkExpiringServices };
