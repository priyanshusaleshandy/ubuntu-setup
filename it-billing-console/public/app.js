// State Management
let currentTab = 'overview';
let servicesData = [];
let vendorsData = [];
let paymentsData = [];
let workLogData = [];
let companyDocsData = [];
let mailboxesData = [];
let domainsData = [];
let attachmentsData = [];
let rentalsData = [];
let rentalPaymentsData = [];
let categoryChartInstance = null;
let monthlyChartInstance = null;

// DOM Initialization
document.addEventListener('DOMContentLoaded', () => {
  setupNavigation();
  setupFormListeners();
  loadAllData();
});

// Navigation Setup
function setupNavigation() {
  document.querySelectorAll('.nav-item').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const tab = btn.dataset.tab;
      switchTab(tab);
    });
  });

  // Search Listeners
  document.getElementById('service-search').addEventListener('input', renderServicesTable);
  document.getElementById('service-status-filter').addEventListener('change', renderServicesTable);
  document.getElementById('security-search').addEventListener('input', renderSecurityTable);
  document.getElementById('vendor-search').addEventListener('input', renderVendorsTable);
  document.getElementById('payment-search').addEventListener('input', renderPaymentsTable);
  document.getElementById('worklog-search').addEventListener('input', renderWorkLogTable);
  document.getElementById('worklog-type-filter').addEventListener('change', renderWorkLogTable);
  document.getElementById('worklog-status-filter').addEventListener('change', renderWorkLogTable);
  document.getElementById('worklog-bill-status-filter').addEventListener('change', renderWorkLogTable);
  document.getElementById('company-doc-search').addEventListener('input', renderCompanyDocsTable);
  document.getElementById('rental-search').addEventListener('input', renderRentalsTable);
  document.getElementById('domain-search').addEventListener('input', renderDomainsTable);
  document.getElementById('domain-detail-mailbox-search').addEventListener('input', () => {
    const primary = domainsData.find(x => x.id === currentOpenPrimaryId);
    if (primary) renderMailboxesTable(primary.domain_name, 'domain-detail-mailboxes-body');
  });
}

function switchTab(tabId) {
  currentTab = tabId;
  document.querySelectorAll('.nav-item').forEach(b => b.classList.remove('active'));
  document.querySelectorAll('.tab-page').forEach(p => p.classList.remove('active'));

  const activeNav = document.querySelector(`.nav-item[data-tab="${tabId}"]`);
  const activePage = document.getElementById(`tab-${tabId}`);
  if (activeNav) activeNav.classList.add('active');
  if (activePage) activePage.classList.add('active');

  const titles = {
    overview: 'Dashboard Overview',
    services: 'Renewals & Services',
    security: 'Security & Antivirus Licenses',
    vendors: 'Vendor Directory',
    mailboxes: 'Domains & Mailboxes',
    payments: 'Payment History',
    worklog: 'Repairs & Site Work',
    rentals: 'RAC Laptops \u2014 Rented Hardware',
    'company-docs': 'Company Documents',
    import: 'Import CSV Data',
    settings: 'Alert Credentials & Settings'
  };
  document.getElementById('page-title').innerText = titles[tabId] || 'Dashboard';

  if (tabId === 'overview') loadDashboardStats();
}

// Data Fetching
async function loadAllData() {
  await fetchAttachments(); // must be loaded before services/worklog tables render their bill chips
  await Promise.all([
    loadDashboardStats(),
    fetchServices(),
    fetchVendors(),
    fetchPayments(),
    fetchWorkLog(),
    fetchCompanyDocuments(),
    fetchRentals(),
    fetchRentalPayments(),
    fetchDomains(),
    fetchMailboxes(),
    fetchAlertSettings()
  ]);
}

async function fetchAttachments() {
  try {
    const res = await fetch('/api/attachments');
    attachmentsData = await res.json();
  } catch (err) {
    console.error('Error fetching attachments:', err);
  }
}

function getAttachments(entityType, entityId) {
  return attachmentsData.filter(a => a.entity_type === entityType && a.entity_id === entityId);
}

function attachmentChips(entityType, entityId) {
  return getAttachments(entityType, entityId)
    .map(a => `<a href="/api/attachments/${a.id}" target="_blank" class="btn btn-sm btn-secondary" title="${escapeHtml(a.original_filename)}">📎</a>`)
    .join('');
}

// Renders the editable attachment list (with remove buttons) shown inside a modal
function renderAttachmentList(containerId, entityType, entityId) {
  const atts = getAttachments(entityType, entityId);
  const container = document.getElementById(containerId);
  if (atts.length === 0) { container.innerHTML = ''; return; }
  if (containerId === 'rental-payment-current') {
    container.innerHTML = '📎 Attached: ' + atts.map(a => `
      <span style="display:inline-block;margin:4px 8px 0 0;">
        ${attachmentThumb(a)}
        <button type="button" onclick="deleteAttachment(${a.id}, '${entityType}', ${entityId}, '${containerId}')" style="background:none;border:none;color:var(--danger);cursor:pointer;">✕</button>
      </span>
    `).join('');
    return;
  }
  container.innerHTML = '📎 Uploaded files: ' + atts.map(a => `
    <span style="display:inline-block;margin:4px 8px 0 0;">
      <a href="/api/attachments/${a.id}" target="_blank" style="color:var(--primary)">${escapeHtml(a.original_filename)}</a>
      <button type="button" onclick="deleteAttachment(${a.id}, '${entityType}', ${entityId}, '${containerId}')" style="background:none;border:none;color:var(--danger);cursor:pointer;">✕</button>
    </span>
  `).join('');
}

async function deleteAttachment(attId, entityType, entityId, containerId) {
  if (!confirm('Delete this file?')) return;
  await fetch(`/api/attachments/${attId}`, { method: 'DELETE' });
  await fetchAttachments();
  if (containerId) renderAttachmentList(containerId, entityType, entityId);
  renderServicesTable();
  renderSecurityTable();
  renderWorkLogTable();
  renderCompanyDocsTable();
  renderRentalPaymentsTable();
}

async function loadDashboardStats() {
  try {
    const res = await fetch('/api/dashboard/stats');
    const stats = await res.json();

    document.getElementById('kpi-monthly-spend').innerText = '₹' + Math.round(stats.totalMonthlySpend).toLocaleString('en-IN');
    document.getElementById('kpi-yearly-spend').innerText = '₹' + Math.round(stats.totalYearlySpend).toLocaleString('en-IN');
    document.getElementById('kpi-expiring-soon').innerText = stats.expiringSoon;
    document.getElementById('kpi-expired').innerText = stats.expired;

    // Banner logic
    const banner = document.getElementById('expiry-banner');
    if (stats.expiringSoon > 0 || stats.expired > 0) {
      banner.classList.remove('hidden');
      document.getElementById('banner-title').innerText = `⚠️ Renewal Attention Required`;
      document.getElementById('banner-desc').innerText = `You have ${stats.expiringSoon} service(s) expiring within 30 days and ${stats.expired} expired item(s).`;
    } else {
      banner.classList.add('hidden');
    }

    loadCharts();
  } catch (err) {
    console.error('Error loading stats:', err);
  }
}

async function fetchServices() {
  try {
    const res = await fetch('/api/services');
    servicesData = await res.json();
    populateVendorDropdowns();
    populateServiceDropdowns();
    renderServicesTable();
    renderSecurityTable();
  } catch (err) {
    console.error('Error fetching services:', err);
  }
}

async function fetchVendors() {
  try {
    const res = await fetch('/api/vendors');
    vendorsData = await res.json();
    populateVendorDropdowns();
    renderVendorsTable();
  } catch (err) {
    console.error('Error fetching vendors:', err);
  }
}

async function fetchPayments() {
  try {
    const res = await fetch('/api/payments');
    paymentsData = await res.json();
    renderPaymentsTable();
  } catch (err) {
    console.error('Error fetching payments:', err);
  }
}

async function fetchRentals() {
  try {
    const res = await fetch('/api/rentals');
    rentalsData = await res.json();
    renderRentalsTable();
    renderRentalKpis();
  } catch (err) {
    console.error('Error fetching rented laptops:', err);
  }
}

async function fetchRentalPayments() {
  try {
    const res = await fetch('/api/rental-payments');
    rentalPaymentsData = await res.json();
    renderRentalPaymentsTable();
    renderRentalKpis();
  } catch (err) {
    console.error('Error fetching rental payments:', err);
  }
}

async function fetchWorkLog() {
  try {
    const res = await fetch('/api/worklog');
    workLogData = await res.json();
    renderWorkLogTable();
  } catch (err) {
    console.error('Error fetching work log:', err);
  }
}

async function fetchCompanyDocuments() {
  try {
    const res = await fetch('/api/company-documents');
    companyDocsData = await res.json();
    renderCompanyDocsTable();
  } catch (err) {
    console.error('Error fetching company documents:', err);
  }
}

let currentOpenPrimaryId = null;   // which primary domain's detail modal is open (secondary domains list)
let currentOpenSubdomainId = null; // which secondary domain's mailboxes modal is open

async function fetchMailboxes() {
  try {
    const res = await fetch('/api/mailboxes');
    mailboxesData = await res.json();
    renderDomainsTable();
    if (currentOpenPrimaryId) {
      const primary = domainsData.find(x => x.id === currentOpenPrimaryId);
      if (primary) {
        renderMailboxesTable(primary.domain_name, 'domain-detail-mailboxes-body');
        renderRenewalCard(primary);
      }
      renderSecondaryDomainsTable(currentOpenPrimaryId);
    }
    renderDomainKpis();
    if (currentOpenSubdomainId) {
      const sub = domainsData.find(x => x.id === currentOpenSubdomainId);
      if (sub) {
        renderMailboxesTable(sub.domain_name, 'subdomain-mailboxes-body');
        renderSubdomainChildren(currentOpenSubdomainId);
      }
    }
  } catch (err) {
    console.error('Error fetching mailboxes:', err);
  }
}

function mailboxDomain(email) {
  const parts = (email || '').split('@');
  return (parts[1] || '').toLowerCase();
}

async function fetchDomains() {
  try {
    const res = await fetch('/api/domains');
    domainsData = await res.json();
    renderDomainsTable();
    renderDomainKpis();
  } catch (err) {
    console.error('Error fetching domains:', err);
  }
}

function primaryDomains() {
  return domainsData.filter(d => !d.parent_domain_id);
}

// Dashboard cards for domains and seats. Computed from data already in memory rather
// than another API call, and refreshed whenever domains or mailboxes are refetched.
// Grouping rows ('Product Team', 'Batch-1') are not domains, so they are excluded.
function renderDomainKpis() {
  const el = (id) => document.getElementById(id);
  if (!el('kpi-domains')) return;

  const realDomains = domainsData.filter(d => !isGroupRow(d));
  const accounts = realDomains.filter(d => !d.parent_domain_id).length;
  const groups = domainsData.filter(d => isGroupRow(d) && !d.parent_domain_id).length;
  el('kpi-domains').innerText = realDomains.length;
  el('kpi-domains-sub').innerText =
    accounts + ' mail account' + (accounts === 1 ? '' : 's') +
    (groups ? ' \u00b7 ' + groups + ' group' + (groups === 1 ? '' : 's') : '') +
    ' \u00b7 ' + mailboxesData.length + ' mailboxes';

  // Seats are recorded on the primary domain of each tenant; used = mailboxes sitting
  // anywhere in that tenant's tree.
  let seats = 0, used = 0;
  domainsData.filter(d => d.total_seats).forEach(d => {
    seats += Number(d.total_seats) || 0;
    used += usedSeatsForPrimary(d.id);
  });
  el('kpi-seats').innerText = seats;
  const free = seats - used;
  el('kpi-seats-sub').innerText = used + ' used \u00b7 ' + free + ' available';
  el('kpi-seats').style.color = free < 0 ? 'var(--danger)' : '';
}

function secondaryDomainsOf(primaryId) {
  return domainsData.filter(d => d.parent_domain_id === primaryId);
}

// 'Product Team', 'Batch-1' etc. are grouping rows, not real domains - they have no dot.
// They render as folders showing how many domains sit inside, not a mailbox count.
function isGroupRow(d) {
  return !String(d.domain_name || '').includes('.');
}

function domainRowLabel(d) {
  return (isGroupRow(d) ? '📁 ' : '🌐 ') + escapeHtml(d.domain_name);
}

function domainRowCountBadge(d) {
  if (isGroupRow(d)) {
    const n = secondaryDomainsOf(d.id).length;
    return `<span class="badge" style="background:#1e40af;color:#dbeafe;">${n} domain${n === 1 ? '' : 's'}</span>`;
  }
  const n = mailboxesData.filter(m => mailboxDomain(m.email) === d.domain_name.toLowerCase()).length;
  return `<span class="badge" style="background:#334155;color:#f8fafc;">${n} mailbox${n === 1 ? '' : 'es'}</span>`;
}

function renderDomainsTable() {
  const search = document.getElementById('domain-search').value.toLowerCase();
  const tbody = document.getElementById('domains-table-body');

  const filtered = primaryDomains().filter(d =>
    d.domain_name.toLowerCase().includes(search) ||
    (d.admin_email && d.admin_email.toLowerCase().includes(search))
  );

  if (filtered.length === 0) {
    tbody.innerHTML = `<tr><td colspan="7" class="text-center text-sub">No domains yet. Click "Add Domain" to create one.</td></tr>`;
    return;
  }

  tbody.innerHTML = filtered.map(d => {
    const svc = d.service_id ? servicesData.find(s => s.id === d.service_id) : null;
    const secCount = secondaryDomainsOf(d.id).length;
    const statusBadge = svc ? serviceStatusBadge(svc.status) : null;
    return `
      <tr style="cursor:pointer" onclick="openDomainDetail(${d.id})">
        <td><strong>${domainRowLabel(d)}</strong></td>
        <td>${escapeHtml(d.admin_email || 'N/A')}</td>
        <td>${svc ? escapeHtml(svc.expiry_date) : 'N/A'}</td>
        <td>${svc ? '₹' + Number(svc.cost).toLocaleString('en-IN') : 'N/A'}</td>
        <td>${statusBadge ? `<span class="badge ${statusBadge.badgeClass}">${statusBadge.statusLabel}</span>` : 'N/A'}</td>
        <td><span class="badge" style="background:#334155;color:#f8fafc;">${secCount} domain${secCount === 1 ? '' : 's'}</span></td>
        <td onclick="event.stopPropagation()">
          <button class="btn btn-sm btn-secondary" onclick="editDomain(${d.id})">✏️ Edit</button>
          <button class="btn btn-sm btn-secondary" style="color:var(--danger)" onclick="deleteDomain(${d.id})">🗑️</button>
        </td>
      </tr>
    `;
  }).join('');
}

function populateDomainDropdowns() {
  const parentSelect = document.getElementById('domain-parent');
  // Primaries first, then any secondary that is itself used as a group (the Product
  // Team batches), so a domain can be filed one level deeper.
  const groupers = domainsData.filter(d => d.domain_type === 'Secondary' && secondaryDomainsOf(d.id).length > 0);
  const byName = (a, b) => a.domain_name.localeCompare(b.domain_name);
  parentSelect.innerHTML = `<option value="">Select parent...</option>` +
    primaryDomains().sort(byName).map(d => `<option value="${d.id}">${escapeHtml(d.domain_name)}</option>`).join('') +
    groupers.sort(byName).map(d => `<option value="${d.id}">&nbsp;&nbsp;↳ ${escapeHtml(d.domain_name)}</option>`).join('');

  const serviceSelect = document.getElementById('domain-service');
  serviceSelect.innerHTML = `<option value="">None</option>` +
    servicesData.map(s => `<option value="${s.id}">${escapeHtml(s.service_name)} (₹${Number(s.cost).toLocaleString('en-IN')}, ${s.expiry_date})</option>`).join('');
}

function toggleDomainTypeFields() {
  const isSecondary = document.getElementById('domain-type').value === 'Secondary';
  document.getElementById('domain-parent-group').style.display = isSecondary ? 'block' : 'none';
  document.getElementById('domain-service-group').style.display = isSecondary ? 'none' : 'block';
  document.getElementById('domain-seats-group').style.display = isSecondary ? 'none' : 'block';
}

function openAddDomain() {
  document.getElementById('domain-form').reset();
  document.getElementById('domain-id').value = '';
  document.getElementById('domain-type').value = 'Primary';
  populateDomainDropdowns();
  toggleDomainTypeFields();
  document.getElementById('domain-modal-title').innerText = '🌐 Add Domain';
  openModal('domain-modal');
}

function openAddSecondaryDomain(parentId) {
  openAddDomain();
  document.getElementById('domain-type').value = 'Secondary';
  document.getElementById('domain-parent').value = parentId;
  toggleDomainTypeFields();
}

function editDomain(id) {
  const d = domainsData.find(x => x.id === id);
  if (!d) return;
  populateDomainDropdowns();
  document.getElementById('domain-id').value = d.id;
  document.getElementById('domain-name').value = d.domain_name;
  document.getElementById('domain-type').value = d.parent_domain_id ? 'Secondary' : 'Primary';
  document.getElementById('domain-parent').value = d.parent_domain_id || '';
  document.getElementById('domain-service').value = d.service_id || '';
  document.getElementById('domain-seats').value = d.total_seats || '';
  document.getElementById('domain-admin').value = d.admin_email || '';
  document.getElementById('domain-notes').value = d.notes || '';
  toggleDomainTypeFields();
  document.getElementById('domain-modal-title').innerText = '✏️ Edit Domain';
  openModal('domain-modal');
}

async function deleteDomain(id) {
  if (confirm('Are you sure you want to delete this domain record?')) {
    await fetch(`/api/domains/${id}`, { method: 'DELETE' });
    fetchDomains();
  }
}

function usedSeatsForPrimary(primaryId) {
  const d = domainsData.find(x => x.id === primaryId);
  if (!d) return 0;
  const domainNames = [d.domain_name.toLowerCase(), ...secondaryDomainsOf(primaryId).map(s => s.domain_name.toLowerCase())];
  return mailboxesData.filter(m => domainNames.includes(mailboxDomain(m.email))).length;
}

function seatsKpiHtml(d) {
  if (!d.total_seats) return '';
  const used = usedSeatsForPrimary(d.id);
  const available = d.total_seats - used;
  const color = available <= 0 ? 'var(--danger)' : (available <= 3 ? 'var(--warning)' : 'var(--success)');
  return `
    <div style="margin-top:12px;padding-top:12px;border-top:1px solid var(--border-color);display:flex;gap:24px;">
      <div><div class="kpi-title">Licensed Seats</div><div style="font-weight:600;">${d.total_seats}</div></div>
      <div><div class="kpi-title">Used</div><div style="font-weight:600;">${used}</div></div>
      <div><div class="kpi-title">Available</div><div style="font-weight:700;color:${color};">${available}</div></div>
    </div>
  `;
}

function renderRenewalCard(d) {
  const svc = d.service_id ? servicesData.find(s => s.id === d.service_id) : null;
  const card = document.getElementById('domain-detail-renewal-card');
  if (svc) {
    const { badgeClass, statusLabel } = serviceStatusBadge(svc.status);
    card.innerHTML = `
      <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:16px;flex-wrap:wrap;">
        <div>
          <div class="kpi-title">Admin</div>
          <div style="font-weight:600;margin-bottom:12px;">${escapeHtml(d.admin_email || 'N/A')}</div>
          <div class="kpi-title">Contract</div>
          <div style="font-weight:600;">${escapeHtml(svc.service_name)}</div>
        </div>
        <div style="text-align:right;">
          <div class="kpi-title">Renewal Date</div>
          <div style="font-weight:600;margin-bottom:12px;">${escapeHtml(svc.expiry_date)}</div>
          <div class="kpi-title">Cost / Year</div>
          <div style="font-weight:600;">₹${Number(svc.cost).toLocaleString('en-IN')}</div>
        </div>
        <div>
          <span class="badge ${badgeClass}">${statusLabel}</span>
        </div>
      </div>
      ${seatsKpiHtml(d)}
    `;
  } else {
    card.innerHTML = `
      <div class="kpi-title">Admin</div>
      <div style="font-weight:600;margin-bottom:8px;">${escapeHtml(d.admin_email || 'N/A')}</div>
      <div class="text-sub">No renewal/contract linked yet. Edit this domain to link one from Renewals & Services.</div>
      ${seatsKpiHtml(d)}
    `;
  }
}

function openDomainDetail(id) {
  const d = domainsData.find(x => x.id === id);
  if (!d) return;
  currentOpenPrimaryId = id;
  const grouping = isGroupRow(d);
  document.getElementById('domain-detail-title').innerText = (grouping ? '📁 ' : '🌐 ') + d.domain_name;
  document.getElementById('domain-detail-mailbox-search').value = '';
  // A grouping row ('Product Team') holds domains, never mailboxes of its own.
  document.getElementById('domain-detail-mailboxes-wrap').style.display = grouping ? 'none' : '';
  renderRenewalCard(d);

  document.getElementById('domain-detail-add-mailbox-btn').onclick = () => openAddMailbox(d.domain_name);
  document.getElementById('domain-detail-add-secondary-btn').onclick = () => openAddSecondaryDomain(id);
  renderMailboxesTable(d.domain_name, 'domain-detail-mailboxes-body');
  renderSecondaryDomainsTable(id);
  openModal('domain-detail-modal');
}

function renderSecondaryDomainsTable(primaryId) {
  const tbody = document.getElementById('domain-detail-secondary-body');
  const secondaries = secondaryDomainsOf(primaryId).sort((a, b) => a.domain_name.localeCompare(b.domain_name));

  if (secondaries.length === 0) {
    tbody.innerHTML = `<tr><td colspan="3" class="text-center text-sub">No secondary domains added yet.</td></tr>`;
    return;
  }

  tbody.innerHTML = secondaries.map(d => {
    return `
      <tr style="cursor:pointer" onclick="openSubdomainDetail(${d.id})">
        <td><strong>${domainRowLabel(d)}</strong></td>
        <td>${domainRowCountBadge(d)}</td>
        <td onclick="event.stopPropagation()">
          <button class="btn btn-sm btn-secondary" onclick="editDomain(${d.id})">✏️ Edit</button>
          <button class="btn btn-sm btn-secondary" style="color:var(--danger)" onclick="deleteDomain(${d.id})">🗑️</button>
        </td>
      </tr>
    `;
  }).join('');
}

// A secondary can itself group further domains (the Product Team batches do this).
// Only shown when there actually are children, so ordinary domains look unchanged.
function renderSubdomainChildren(parentId, alwaysShow) {
  const wrap = document.getElementById('subdomain-children-wrap');
  const children = secondaryDomainsOf(parentId).sort((a, b) => a.domain_name.localeCompare(b.domain_name));
  if (children.length === 0 && !alwaysShow) { wrap.style.display = 'none'; return; }
  wrap.style.display = '';
  if (children.length === 0) {
    document.getElementById('subdomain-children-body').innerHTML =
      `<tr><td colspan="3" class="text-center text-sub">No domains in this batch yet.</td></tr>`;
    return;
  }
  document.getElementById('subdomain-children-body').innerHTML = children.map(c => {
    return `
      <tr style="cursor:pointer" onclick="openSubdomainDetail(${c.id})">
        <td><strong>${domainRowLabel(c)}</strong></td>
        <td>${domainRowCountBadge(c)}</td>
        <td onclick="event.stopPropagation()">
          <button class="btn btn-sm btn-secondary" onclick="editDomain(${c.id})">✏️ Edit</button>
          <button class="btn btn-sm btn-secondary" style="color:var(--danger)" onclick="deleteDomain(${c.id})">🗑️</button>
        </td>
      </tr>
    `;
  }).join('');
}

function openSubdomainDetail(id) {
  const d = domainsData.find(x => x.id === id);
  if (!d) return;
  currentOpenSubdomainId = id;
  document.getElementById('subdomain-title').innerText = (isGroupRow(d) ? '📁 ' : '🌐 ') + d.domain_name;
  document.getElementById('subdomain-add-mailbox-btn').onclick = () => openAddMailbox(d.domain_name);
  document.getElementById('subdomain-add-child-btn').onclick = () => openAddSecondaryDomain(id);
  // A grouping row holds domains, never mailboxes - hide the mailbox half entirely.
  const grouping = isGroupRow(d);
  document.getElementById('subdomain-mailboxes-wrap').style.display = grouping ? 'none' : '';
  if (!grouping) renderMailboxesTable(d.domain_name, 'subdomain-mailboxes-body');
  renderSubdomainChildren(id, grouping);
  openModal('subdomain-modal');
}

// Shared by both the primary-domain-direct mailboxes table and the secondary-domain one
function renderMailboxesTable(domainName, tbodyId) {
  const tbody = document.getElementById(tbodyId);
  const searchEl = tbodyId === 'domain-detail-mailboxes-body' ? document.getElementById('domain-detail-mailbox-search') : null;
  const search = searchEl ? searchEl.value.trim().toLowerCase() : '';
  const onDomain = mailboxesData
    .filter(m => mailboxDomain(m.email) === domainName.toLowerCase())
    .sort((a, b) => a.email.localeCompare(b.email));
  const mailboxes = search
    ? onDomain.filter(m => (m.email || '').toLowerCase().includes(search) || (m.current_user || '').toLowerCase().includes(search))
    : onDomain;

  if (onDomain.length === 0) {
    tbody.innerHTML = `<tr><td colspan="6" class="text-center text-sub">No mailboxes recorded under this domain yet.</td></tr>`;
    return;
  }

  if (mailboxes.length === 0) {
    tbody.innerHTML = `<tr><td colspan="6" class="text-center text-sub">No mailbox matches "${escapeHtml(search)}".</td></tr>`;
    return;
  }

  tbody.innerHTML = mailboxes.map(m => `
    <tr>
      <td><strong>${escapeHtml(m.email)}</strong></td>
      <td><span class="badge ${m.status === 'Active' ? 'badge-active' : 'badge-danger'}">${m.status === 'Active' ? '✅ Active' : '❌ Inactive'}</span></td>
      <td>${escapeHtml(m.purpose || '')}</td>
      <td>${escapeHtml(m.current_user || '')}</td>
      <td>${escapeHtml(m.notes || '')}</td>
      <td>
        <button class="btn btn-sm btn-secondary" onclick="editMailbox(${m.id})">✏️ Edit</button>
        <button class="btn btn-sm btn-secondary" style="color:var(--danger)" onclick="deleteMailbox(${m.id})">🗑️</button>
      </td>
    </tr>
  `).join('');
}

function openAddMailbox(prefillDomain) {
  document.getElementById('mailbox-form').reset();
  document.getElementById('mailbox-id').value = '';
  document.getElementById('mailbox-status').value = 'Active';
  document.getElementById('mailbox-email').value = prefillDomain ? '@' + prefillDomain : '';
  document.getElementById('mailbox-modal-title').innerText = '📧 Add Mailbox';
  openModal('mailbox-modal');
}

function editMailbox(id) {
  const m = mailboxesData.find(x => x.id === id);
  if (!m) return;
  document.getElementById('mailbox-id').value = m.id;
  document.getElementById('mailbox-email').value = m.email;
  document.getElementById('mailbox-status').value = m.status || 'Active';
  document.getElementById('mailbox-current-user').value = m.current_user || '';
  document.getElementById('mailbox-purpose').value = m.purpose || '';
  document.getElementById('mailbox-notes').value = m.notes || '';
  document.getElementById('mailbox-modal-title').innerText = '✏️ Edit Mailbox';
  openModal('mailbox-modal');
}

async function deleteMailbox(id) {
  if (confirm('Are you sure you want to delete this mailbox record?')) {
    await fetch(`/api/mailboxes/${id}`, { method: 'DELETE' });
    fetchMailboxes();
  }
}

async function fetchAlertSettings() {
  try {
    const res = await fetch('/api/alerts/settings');
    const data = await res.json();
    if (data) {
      document.getElementById('email_enabled').checked = !!data.email_enabled;
      document.getElementById('smtp_host').value = data.smtp_host || '';
      document.getElementById('smtp_port').value = data.smtp_port || 587;
      document.getElementById('smtp_user').value = data.smtp_user || '';
      document.getElementById('smtp_pass').value = data.smtp_pass || '';
      document.getElementById('notification_email').value = data.notification_email || '';
      document.getElementById('telegram_enabled').checked = !!data.telegram_enabled;
      document.getElementById('telegram_bot_token').value = data.telegram_bot_token || '';
      document.getElementById('telegram_chat_id').value = data.telegram_chat_id || '';
    }
  } catch (err) {
    console.error('Error fetching alert settings:', err);
  }
}

// Charting Logic
async function loadCharts() {
  try {
    const res = await fetch('/api/analytics');
    const analytics = await res.json();

    // 1. Pie Chart - Category Breakdown
    const pieCtx = document.getElementById('categoryPieChart').getContext('2d');
    if (categoryChartInstance) categoryChartInstance.destroy();

    categoryChartInstance = new Chart(pieCtx, {
      type: 'doughnut',
      data: {
        labels: analytics.categories.length > 0 ? analytics.categories : ['No Data'],
        datasets: [{
          data: analytics.categoryValues.length > 0 ? analytics.categoryValues : [1],
          backgroundColor: ['#6366f1', '#8b5cf6', '#10b981', '#f59e0b', '#06b6d4', '#ef4444', '#64748b']
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { position: 'right', labels: { color: '#94a3b8' } }
        }
      }
    });

    // 2. Bar Chart - Monthly Spend Log
    const barCtx = document.getElementById('monthlyBarChart').getContext('2d');
    if (monthlyChartInstance) monthlyChartInstance.destroy();

    monthlyChartInstance = new Chart(barCtx, {
      type: 'bar',
      data: {
        labels: analytics.monthlyLabels.length > 0 ? analytics.monthlyLabels : ['Current Month'],
        datasets: [{
          label: 'Payments Logged (₹)',
          data: analytics.monthlyValues.length > 0 ? analytics.monthlyValues : [0],
          backgroundColor: '#10b981',
          borderRadius: 6
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
          x: { ticks: { color: '#94a3b8' }, grid: { color: '#334155' } },
          y: { ticks: { color: '#94a3b8' }, grid: { color: '#334155' } }
        },
        plugins: {
          legend: { labels: { color: '#94a3b8' } }
        }
      }
    });
  } catch (err) {
    console.error('Error loading charts:', err);
  }
}

// Table Rendering
function serviceStatusBadge(status) {
  if (status === 'Upcoming' || status === 'Upcomming' || status === 'Expiring Soon') {
    return { badgeClass: 'badge-warning', statusLabel: '🚨 Upcoming' }; // Red, matching spreadsheet
  } else if (status === 'Done' || status === 'Completed') {
    return { badgeClass: 'badge-active', statusLabel: '✅ Done' }; // Green, matching spreadsheet
  } else if (status === 'Auto') {
    return { badgeClass: 'badge-info', statusLabel: '🔄 Auto Monthly' }; // Blue
  } else if (status === 'Expired') {
    return { badgeClass: 'badge-danger', statusLabel: '❌ Expired' };
  }
  return { badgeClass: 'badge-active', statusLabel: status };
}

function renderServicesTable() {
  const search = document.getElementById('service-search').value.toLowerCase();
  const filter = document.getElementById('service-status-filter').value;
  const tbody = document.getElementById('services-table-body');

  const filtered = servicesData.filter(s => {
    const matchesSearch = s.service_name.toLowerCase().includes(search) ||
                          (s.vendor_name && s.vendor_name.toLowerCase().includes(search)) ||
                          s.category.toLowerCase().includes(search);
    const matchesFilter = filter === 'ALL' ||
                          s.status === filter ||
                          (filter === 'Upcoming' && (s.status === 'Upcoming' || s.status === 'Upcomming')) ||
                          (filter === 'Done' && (s.status === 'Done' || s.status === 'Completed'));
    return matchesSearch && matchesFilter;
  });

  if (filtered.length === 0) {
    tbody.innerHTML = `<tr><td colspan="9" class="text-center text-sub">No services or contract records found.</td></tr>`;
    return;
  }

  tbody.innerHTML = filtered.map(s => {
    const { badgeClass, statusLabel } = serviceStatusBadge(s.status);
    return `
      <tr>
        <td><strong>${escapeHtml(s.service_name)}</strong></td>
        <td>${escapeHtml(s.vendor_name || 'N/A')}</td>
        <td><span class="badge" style="background:#334155;color:#f8fafc;">${escapeHtml(s.category)}</span></td>
        <td><strong>₹${Number(s.cost).toLocaleString('en-IN')}</strong></td>
        <td style="text-transform:capitalize">${s.billing_cycle}</td>
        <td><strong>${s.expiry_date}</strong></td>
        <td>${s.auto_renew ? '✅ Yes' : '❌ No'}</td>
        <td><span class="badge ${badgeClass}">${statusLabel}</span></td>
        <td>
          <button class="btn btn-sm btn-secondary" onclick="editService(${s.id})">✏️ Edit</button>
          ${attachmentChips('service', s.id)}
          <button class="btn btn-sm btn-secondary" style="color:var(--danger)" onclick="deleteService(${s.id})">🗑️</button>
        </td>
      </tr>
    `;
  }).join('');
}

function renderSecurityTable() {
  const search = document.getElementById('security-search').value.toLowerCase();
  const tbody = document.getElementById('security-table-body');

  const filtered = servicesData.filter(s =>
    s.category === 'Antivirus & Security' &&
    (s.service_name.toLowerCase().includes(search) || (s.vendor_name && s.vendor_name.toLowerCase().includes(search)))
  );

  if (filtered.length === 0) {
    tbody.innerHTML = `<tr><td colspan="9" class="text-center text-sub">No antivirus/security licenses yet. Click "Add License" to create one.</td></tr>`;
    return;
  }

  tbody.innerHTML = filtered.map(s => {
    const { badgeClass, statusLabel } = serviceStatusBadge(s.status);
    return `
      <tr>
        <td><strong>${escapeHtml(s.service_name)}</strong></td>
        <td>${escapeHtml(s.vendor_name || 'N/A')}</td>
        <td><strong>₹${Number(s.cost).toLocaleString('en-IN')}</strong></td>
        <td style="text-transform:capitalize">${s.billing_cycle}</td>
        <td><strong>${s.expiry_date}</strong></td>
        <td>${s.auto_renew ? '✅ Yes' : '❌ No'}</td>
        <td><span class="badge ${badgeClass}">${statusLabel}</span></td>
        <td>${escapeHtml(s.notes || '')}</td>
        <td>
          <button class="btn btn-sm btn-secondary" onclick="editService(${s.id})">✏️ Edit</button>
          ${attachmentChips('service', s.id)}
          <button class="btn btn-sm btn-secondary" style="color:var(--danger)" onclick="deleteService(${s.id})">🗑️</button>
        </td>
      </tr>
    `;
  }).join('');
}

function openAddSecurityLicense() {
  openModal('service-modal');
  document.getElementById('service-category').value = 'Antivirus & Security';
}

function renderVendorsTable() {
  const search = document.getElementById('vendor-search').value.toLowerCase();
  const tbody = document.getElementById('vendors-table-body');

  const filtered = vendorsData.filter(v => 
    v.name.toLowerCase().includes(search) || (v.category && v.category.toLowerCase().includes(search))
  );

  if (filtered.length === 0) {
    tbody.innerHTML = `<tr><td colspan="8" class="text-center text-sub">No vendors found. Click "Add Vendor" to create one.</td></tr>`;
    return;
  }

  tbody.innerHTML = filtered.map(v => `
    <tr>
      <td><strong>${escapeHtml(v.name)}</strong></td>
      <td>${escapeHtml(v.category || 'N/A')}</td>
      <td>${escapeHtml(v.contact_person || 'N/A')}</td>
      <td>${escapeHtml(v.email || 'N/A')}</td>
      <td>${escapeHtml(v.phone || 'N/A')}</td>
      <td>${v.portal_url ? `<a href="${escapeHtml(v.portal_url)}" target="_blank" style="color:var(--primary)">Portal ↗</a>` : 'N/A'}</td>
      <td>${escapeHtml(v.notes || '')}</td>
      <td>
        <button class="btn btn-sm btn-secondary" onclick="editVendor(${v.id})">✏️ Edit</button>
        <button class="btn btn-sm btn-secondary" style="color:var(--danger)" onclick="deleteVendor(${v.id})">🗑️</button>
      </td>
    </tr>
  `).join('');
}

function renderPaymentsTable() {
  const search = document.getElementById('payment-search').value.toLowerCase();
  const tbody = document.getElementById('payments-table-body');

  const filtered = paymentsData.filter(p => 
    (p.service_name && p.service_name.toLowerCase().includes(search)) ||
    (p.vendor_name && p.vendor_name.toLowerCase().includes(search)) ||
    (p.invoice_no && p.invoice_no.toLowerCase().includes(search))
  );

  if (filtered.length === 0) {
    tbody.innerHTML = `<tr><td colspan="8" class="text-center text-sub">No payment logs recorded yet.</td></tr>`;
    return;
  }

  tbody.innerHTML = filtered.map(p => `
    <tr>
      <td>${p.payment_date}</td>
      <td><strong>${escapeHtml(p.service_name || 'N/A')}</strong></td>
      <td>${escapeHtml(p.vendor_name || 'N/A')}</td>
      <td><strong style="color:var(--success)">₹${Number(p.amount).toLocaleString('en-IN')}</strong></td>
      <td>${escapeHtml(p.payment_method || 'N/A')}</td>
      <td><code>${escapeHtml(p.invoice_no || 'N/A')}</code></td>
      <td>${escapeHtml(p.receipt_note || '')}</td>
      <td>
        <button class="btn btn-sm btn-secondary" style="color:var(--danger)" onclick="deletePayment(${p.id})">🗑️ Delete</button>
      </td>
    </tr>
  `).join('');
}

function renderWorkLogTable() {
  const search = document.getElementById('worklog-search').value.toLowerCase();
  const typeFilter = document.getElementById('worklog-type-filter').value;
  const statusFilter = document.getElementById('worklog-status-filter').value;
  const billStatusFilter = document.getElementById('worklog-bill-status-filter').value;
  const tbody = document.getElementById('worklog-table-body');

  const filtered = workLogData.filter(w => {
    const matchesSearch = w.title.toLowerCase().includes(search) ||
                          (w.vendor_name && w.vendor_name.toLowerCase().includes(search)) ||
                          (w.from_location && w.from_location.toLowerCase().includes(search)) ||
                          (w.to_location && w.to_location.toLowerCase().includes(search));
    const matchesType = typeFilter === 'ALL' || w.type === typeFilter;
    const matchesStatus = statusFilter === 'ALL' || w.status === statusFilter;
    const matchesBillStatus = billStatusFilter === 'ALL' || (w.bill_status || 'Pending') === billStatusFilter;
    return matchesSearch && matchesType && matchesStatus && matchesBillStatus;
  });

  if (filtered.length === 0) {
    tbody.innerHTML = `<tr><td colspan="9" class="text-center text-sub">No repair / cable / work log entries found.</td></tr>`;
    return;
  }

  const typeLabels = { Repair: '🔧 Repair', Cable: '🔌 Cable', Other: '📋 Other' };

  tbody.innerHTML = filtered.map(w => {
    const statusBadge = w.status === 'Done'
      ? `<span class="badge badge-active">✅ Done</span>`
      : `<span class="badge badge-warning">🚨 Pending</span>`;

    const billStatusBadge = w.bill_status === 'Paid'
      ? `<span class="badge badge-active">✅ Paid</span>`
      : `<span class="badge badge-warning">💰 Payment Pending</span>`;

    const worklogAtts = getAttachments('worklog', w.id);
    const billLink = worklogAtts.length > 0
      ? '<br>' + worklogAtts.map(a => `<a href="/api/attachments/${a.id}" target="_blank" style="color:var(--primary);font-size:11px;margin-right:6px;">📎 ${escapeHtml(a.original_filename)}</a>`).join('')
      : `<br><span class="text-sub" style="font-size:11px;">No bill uploaded</span>`;

    let titleCell = escapeHtml(w.title);
    let detailsCell = '';
    if (w.type === 'Cable') {
      titleCell = `${escapeHtml(w.from_location || '?')} → ${escapeHtml(w.to_location || '?')}${w.length_meters ? ' (' + w.length_meters + 'm)' : ''}`;
      detailsCell = escapeHtml(w.cable_type || '');
    } else if (w.type === 'Repair') {
      detailsCell = escapeHtml(w.issue || w.condition_notes || '');
    } else {
      detailsCell = escapeHtml(w.notes || '');
    }

    return `
      <tr>
        <td><span class="badge" style="background:#334155;color:#f8fafc;">${typeLabels[w.type] || w.type}</span></td>
        <td>${w.work_date || 'N/A'}</td>
        <td><strong>${titleCell}</strong></td>
        <td>${escapeHtml(w.vendor_name || 'N/A')}</td>
        <td>${detailsCell}</td>
        <td>${w.cost ? '₹' + Number(w.cost).toLocaleString('en-IN') : 'N/A'}</td>
        <td>${statusBadge}</td>
        <td>${billStatusBadge}${billLink}</td>
        <td>
          <button class="btn btn-sm btn-secondary" onclick="editWorkLog(${w.id})">✏️ Edit</button>
          <button class="btn btn-sm btn-secondary" style="color:var(--danger)" onclick="deleteWorkLog(${w.id})">🗑️</button>
        </td>
      </tr>
    `;
  }).join('');
}

// ---------------------------------------------------------------------------
// RAC LAPTOPS (rented hardware)
// ---------------------------------------------------------------------------

// What actually left the bank. RAC deduct 2% TDS, so this is routinely lower
// than the invoice value; unset means the two matched.
// A payment proof is normally a screenshot. Render images as thumbnails so the
// proof is readable at a glance; anything else stays a filename link.
function attachmentThumb(a) {
  const name = escapeHtml(a.original_filename);
  const isImage = /\.(jpe?g|png|webp|heic|gif)$/i.test(a.original_filename);
  if (!isImage) {
    return '<a href="/api/attachments/' + a.id + '" target="_blank" ' +
      'style="color:var(--primary);font-size:11px;display:block;margin:2px 0;">\uD83D\uDCCE ' + name + '</a>';
  }
  return '<a href="/api/attachments/' + a.id + '" target="_blank" title="' + name + '">' +
    '<img src="/api/attachments/' + a.id + '" alt="' + name + '" ' +
    'style="height:46px;max-width:96px;object-fit:cover;border-radius:4px;' +
    'border:1px solid var(--border-color);margin:2px 4px 2px 0;vertical-align:middle;"></a>';
}

function rentalPaidAmount(pmt) {
  return pmt.paid_amount != null ? Number(pmt.paid_amount) : Number(pmt.amount);
}

function rentalAssetName(assetId) {
  const a = rentalsData.find(x => x.id === assetId);
  return a ? a.asset_name : null;
}

function renderRentalKpis() {
  if (!document.getElementById('kpi-rental-count')) return;

  const onRent = rentalsData.filter(r => (r.status || 'On Rent') === 'On Rent');
  const returned = rentalsData.length - onRent.length;
  document.getElementById('kpi-rental-count').innerText = onRent.length;
  document.getElementById('kpi-rental-count-sub').innerText =
    returned ? returned + ' returned \u00b7 ' + rentalsData.length + ' total' : 'All laptops currently held';

  const monthly = onRent.reduce((sum, r) => sum + (Number(r.monthly_rent) || 0), 0);
  const missing = onRent.filter(r => !r.monthly_rent).length;
  document.getElementById('kpi-rental-monthly').innerText = '\u20B9' + Math.round(monthly).toLocaleString('en-IN');
  document.getElementById('kpi-rental-monthly-sub').innerText = missing
    ? missing + ' laptop' + (missing === 1 ? '' : 's') + ' without a rent figure'
    : '\u20B9' + Math.round(monthly * 12).toLocaleString('en-IN') + ' a year';

  // Payments come back newest-first. A bill sitting at Pending is money we still
  // owe, so it must not count as the last payment made.
  // Newest first by the date the money actually went out, falling back to the
  // bill date for rows entered before paid_on existed.
  const paid = rentalPaymentsData.filter(p => (p.status || 'Pending') === 'Paid')
    .sort((a, b) => String(b.paid_on || b.payment_date).localeCompare(String(a.paid_on || a.payment_date)));
  const pending = rentalPaymentsData.filter(p => (p.status || 'Pending') !== 'Paid');
  const last = paid[0];
  document.getElementById('kpi-rental-last').innerText =
    last ? '\u20B9' + Math.round(rentalPaidAmount(last)).toLocaleString('en-IN') : '\u2014';

  const due = pending.reduce((sum, p) => sum + (Number(p.amount) || 0), 0);
  const today = new Date().toISOString().slice(0, 10);
  const overdue = pending.filter(p => p.due_date && p.due_date < today);
  const nextDue = pending.filter(p => p.due_date && p.due_date >= today)
    .sort((a, b) => a.due_date.localeCompare(b.due_date))[0];
  const dueNote = pending.length
    ? '  \u00b7  ' + pending.length + ' unpaid bill' + (pending.length === 1 ? '' : 's') +
      ': \u20B9' + Math.round(due).toLocaleString('en-IN') +
      (overdue.length ? '  \u00b7  ' + overdue.length + ' OVERDUE'
        : nextDue ? '  \u00b7  due ' + nextDue.due_date : '')
    : '';
  document.getElementById('kpi-rental-last-sub').innerText = (last
    ? 'Paid ' + (last.paid_on || last.payment_date) + (last.period_label ? ' \u00b7 for ' + last.period_label : '')
    : 'Nothing marked paid yet') + dueNote;
  document.getElementById('kpi-rental-last').style.color = (!last && pending.length) ? 'var(--warning)' : '';
}

function renderRentalsTable() {
  const tbody = document.getElementById('rentals-table-body');
  if (!tbody) return;
  const search = document.getElementById('rental-search').value.toLowerCase();

  const filtered = rentalsData.filter(r =>
    r.asset_name.toLowerCase().includes(search) ||
    (r.model && r.model.toLowerCase().includes(search)) ||
    (r.serial_no && r.serial_no.toLowerCase().includes(search))
  );

  if (filtered.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="text-center text-sub">No rented laptops recorded yet. Add the RAC machines you are holding.</td></tr>';
    return;
  }

  tbody.innerHTML = filtered.map(r => {
    const status = (r.status || 'On Rent') === 'On Rent'
      ? '<span class="badge badge-active">\uD83D\uDCBB On Rent</span>'
      : '<span class="badge" style="background:#334155;color:#f8fafc;">\u21A9\uFE0F Returned</span>';
    const gmail = r.gmail_link
      ? ' <a href="' + escapeHtml(r.gmail_link) + '" target="_blank" style="color:var(--primary);font-size:11px;">\u2709\uFE0F Gmail</a>'
      : '';
    return '<tr>' +
      '<td><strong>' + escapeHtml(r.asset_name) + '</strong>' + gmail +
        '<div class="text-sub" style="font-size:11px;">' + escapeHtml(r.vendor_name || 'RAC') + '</div></td>' +
      '<td>' + escapeHtml(r.model || 'N/A') +
        (r.serial_no ? '<div class="text-sub" style="font-size:11px;">SN: ' + escapeHtml(r.serial_no) + '</div>' : '') + '</td>' +
      '<td>' + (r.monthly_rent ? '\u20B9' + Number(r.monthly_rent).toLocaleString('en-IN') : '<span class="text-sub">Not set</span>') + '</td>' +
      '<td>' + (r.rent_start || 'N/A') + (r.rent_end ? '<div class="text-sub" style="font-size:11px;">till ' + r.rent_end + '</div>' : '') + '</td>' +
      '<td>' + status + '</td>' +
      '<td>' +
        '<button class="btn btn-sm btn-secondary" onclick="editRental(' + r.id + ')">\u270F\uFE0F Edit</button> ' +
        '<button class="btn btn-sm btn-secondary" style="color:var(--danger)" onclick="deleteRental(' + r.id + ')">\uD83D\uDDD1\uFE0F</button>' +
      '</td>' +
    '</tr>';
  }).join('');
}

function renderRentalPaymentsTable() {
  const tbody = document.getElementById('rental-payments-table-body');
  if (!tbody) return;

  if (rentalPaymentsData.length === 0) {
    tbody.innerHTML = '<tr><td colspan="9" class="text-center text-sub">No bill or payment recorded yet.</td></tr>';
    return;
  }

  tbody.innerHTML = rentalPaymentsData.map(pmt => {
    const isPaid = (pmt.status || 'Pending') === 'Paid';
    const atts = getAttachments('rental_payment', pmt.id);
    let bill = atts.map(attachmentThumb).join('');
    if (pmt.gmail_link) {
      bill += '<a href="' + escapeHtml(pmt.gmail_link) + '" target="_blank" style="color:var(--primary);font-size:11px;">\u2709\uFE0F Gmail thread</a>';
    }
    if (!bill) bill = '<span class="text-sub" style="font-size:11px;">Nothing attached</span>';

    // Overdue only means anything while the bill is still unpaid.
    const today = new Date().toISOString().slice(0, 10);
    const overdue = !isPaid && pmt.due_date && pmt.due_date < today;
    const dueCell = pmt.due_date
      ? (overdue
          ? '<span style="color:var(--danger);font-weight:600;">' + pmt.due_date + '</span><div class="text-sub" style="font-size:11px;color:var(--danger);">overdue</div>'
          : pmt.due_date)
      : '<span class="text-sub">\u2014</span>';

    const statusCell = isPaid
      ? '<span class="badge badge-active">\u2705 Paid</span>' +
        (pmt.paid_on ? '<div class="text-sub" style="font-size:11px;">on ' + pmt.paid_on + '</div>' : '') +
        (pmt.payment_method ? '<div class="text-sub" style="font-size:11px;">' + escapeHtml(pmt.payment_method) + '</div>' : '')
      : '<span class="badge badge-warning">\uD83D\uDCB0 Not paid</span>' +
        '<div><button class="btn btn-sm btn-secondary" style="margin-top:4px;font-size:11px;" onclick="markRentalPaymentPaid(' + pmt.id + ')">Mark paid</button></div>';

    return '<tr>' +
      '<td><strong>' + (pmt.payment_date || 'N/A') + '</strong></td>' +
      '<td>' + escapeHtml(pmt.period_label || '\u2014') + '</td>' +
      '<td>' + escapeHtml(pmt.invoice_no || '\u2014') +
        (pmt.asset_id ? '<div class="text-sub" style="font-size:11px;">for ' +
          escapeHtml(rentalAssetName(pmt.asset_id) || 'a deleted laptop') + '</div>' : '') + '</td>' +
      '<td>' + dueCell + '</td>' +
      '<td><strong>\u20B9' + Number(pmt.amount).toLocaleString('en-IN') + '</strong>' +
        (pmt.paid_amount != null && Number(pmt.paid_amount) !== Number(pmt.amount)
          ? '<div class="text-sub" style="font-size:11px;">paid \u20B9' +
            Number(pmt.paid_amount).toLocaleString('en-IN') + '</div>' : '') + '</td>' +
      '<td>' + statusCell + '</td>' +
      '<td>' + bill + '</td>' +
      '<td>' +
        '<button class="btn btn-sm btn-secondary" onclick="editRentalPayment(' + pmt.id + ')">\u270F\uFE0F Edit</button> ' +
        '<button class="btn btn-sm btn-secondary" style="color:var(--danger)" onclick="deleteRentalPayment(' + pmt.id + ')">\uD83D\uDDD1\uFE0F</button>' +
      '</td>' +
    '</tr>';
  }).join('');
}

// PUT is a full replace here too - every field goes back or it is nulled.
async function markRentalPaymentPaid(id) {
  const pmt = rentalPaymentsData.find(x => x.id === id);
  if (!pmt) return;
  const today = new Date().toISOString().slice(0, 10);
  const when = prompt('Paid on which date? (YYYY-MM-DD)', pmt.paid_on || today);
  if (when === null) return;
  await fetch('/api/rental-payments/' + id, {
    method: 'PUT', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...pmt, status: 'Paid', paid_on: when.trim() || today })
  });
  fetchRentalPayments();
}

function openRentalModal() {
  openModal('rental-modal');
}

function editRental(id) {
  const r = rentalsData.find(x => x.id === id);
  if (!r) return;
  document.getElementById('rental-id').value = r.id;
  document.getElementById('rental-asset-name').value = r.asset_name || '';
  document.getElementById('rental-vendor').value = r.vendor_name || 'RAC';
  document.getElementById('rental-model').value = r.model || '';
  document.getElementById('rental-serial').value = r.serial_no || '';
  document.getElementById('rental-monthly').value = r.monthly_rent || '';
  document.getElementById('rental-start').value = r.rent_start || '';
  document.getElementById('rental-end').value = r.rent_end || '';
  document.getElementById('rental-status').value = r.status || 'On Rent';
  document.getElementById('rental-gmail').value = r.gmail_link || '';
  document.getElementById('rental-notes').value = r.notes || '';
  document.getElementById('rental-modal-title').innerText = '\u270F\uFE0F Edit Rented Laptop';
  openModal('rental-modal');
}

async function deleteRental(id) {
  const r = rentalsData.find(x => x.id === id);
  if (!confirm('Remove "' + (r ? r.asset_name : 'this laptop') + '" from the rented list? Payments already recorded are kept.')) return;
  await fetch('/api/rentals/' + id, { method: 'DELETE' });
  await fetchRentals();
  fetchRentalPayments();
}

function fillRentalAssetOptions(selectedId) {
  const sel = document.getElementById('rental-payment-asset');
  sel.innerHTML = '<option value="">All laptops (single invoice)</option>' +
    rentalsData.map(r => '<option value="' + r.id + '">' + escapeHtml(r.asset_name) + '</option>').join('');
  sel.value = selectedId ? String(selectedId) : '';
}

function openRentalPaymentModal() {
  fillRentalAssetOptions(null);
  openModal('rental-payment-modal');
}

function editRentalPayment(id) {
  const pmt = rentalPaymentsData.find(x => x.id === id);
  if (!pmt) return;
  fillRentalAssetOptions(pmt.asset_id);
  document.getElementById('rental-payment-id').value = pmt.id;
  document.getElementById('rental-payment-amount').value = pmt.amount;
  document.getElementById('rental-payment-date').value = pmt.payment_date || '';
  document.getElementById('rental-payment-period').value = pmt.period_label || '';
  document.getElementById('rental-payment-invoice').value = pmt.invoice_no || '';
  document.getElementById('rental-payment-due').value = pmt.due_date || '';
  document.getElementById('rental-payment-paidon').value = pmt.paid_on || '';
  document.getElementById('rental-payment-paidamt').value = pmt.paid_amount != null ? pmt.paid_amount : '';
  document.getElementById('rental-payment-method').value = pmt.payment_method || '';
  document.getElementById('rental-payment-status').value = pmt.status || 'Pending';
  document.getElementById('rental-payment-gmail').value = pmt.gmail_link || '';
  document.getElementById('rental-payment-notes').value = pmt.notes || '';
  renderAttachmentList('rental-payment-current', 'rental_payment', pmt.id);
  document.getElementById('rental-payment-modal-title').innerText = '\u270F\uFE0F Edit Payment';
  openModal('rental-payment-modal');
}

async function deleteRentalPayment(id) {
  if (!confirm('Delete this payment record and its uploaded bill?')) return;
  await fetch('/api/rental-payments/' + id, { method: 'DELETE' });
  await fetchAttachments();
  fetchRentalPayments();
}

function renderCompanyDocsTable() {
  const search = document.getElementById('company-doc-search').value.toLowerCase();
  const tbody = document.getElementById('company-docs-table-body');

  const filtered = companyDocsData.filter(d =>
    d.title.toLowerCase().includes(search) ||
    (d.category && d.category.toLowerCase().includes(search)) ||
    (d.notes && d.notes.toLowerCase().includes(search))
  );

  if (filtered.length === 0) {
    tbody.innerHTML = `<tr><td colspan="5" class="text-center text-sub">No company documents yet. Click "Add Document" to upload one.</td></tr>`;
    return;
  }

  tbody.innerHTML = filtered.map(d => `
    <tr>
      <td><strong>${escapeHtml(d.title)}</strong></td>
      <td><span class="badge" style="background:#334155;color:#f8fafc;">${escapeHtml(d.category || 'Other')}</span></td>
      <td>${escapeHtml(d.notes || '')}</td>
      <td>${attachmentChips('company_doc', d.id)}</td>
      <td>
        <button class="btn btn-sm btn-secondary" onclick="editCompanyDoc(${d.id})">✏️ Edit</button>
        <button class="btn btn-sm btn-secondary" style="color:var(--danger)" onclick="deleteCompanyDoc(${d.id})">🗑️</button>
      </td>
    </tr>
  `).join('');
}

// Dropdown Populators
function populateVendorDropdowns() {
  const select = document.getElementById('service-vendor-id');
  select.innerHTML = `<option value="">Select Vendor...</option>` + 
    vendorsData.map(v => `<option value="${v.id}">${escapeHtml(v.name)}</option>`).join('');
}

function populateServiceDropdowns() {
  const select = document.getElementById('payment-service-id');
  select.innerHTML = `<option value="">Select Service...</option>` + 
    servicesData.map(s => `<option value="${s.id}">${escapeHtml(s.service_name)} (₹${s.cost})</option>`).join('');
}

// Form Handlers
function setupFormListeners() {
  // Service Form
  document.getElementById('service-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const id = document.getElementById('service-id').value;
    const payload = {
      service_name: document.getElementById('service-name').value,
      vendor_id: document.getElementById('service-vendor-id').value || null,
      category: document.getElementById('service-category').value,
      cost: parseFloat(document.getElementById('service-cost').value),
      billing_cycle: document.getElementById('service-cycle').value,
      start_date: document.getElementById('service-start-date').value,
      expiry_date: document.getElementById('service-expiry-date').value,
      auto_renew: document.getElementById('service-auto-renew').checked,
      notes: document.getElementById('service-notes').value
    };

    const url = id ? `/api/services/${id}` : '/api/services';
    const method = id ? 'PUT' : 'POST';

    const saveRes = await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    const saveData = await saveRes.json();
    const entryId = id || saveData.id;

    for (const billFile of document.getElementById('service-bill-file').files) {
      const formData = new FormData();
      formData.append('bill', billFile);
      await fetch(`/api/services/${entryId}/bill`, { method: 'POST', body: formData });
    }

    closeModal('service-modal');
    loadAllData();
  });

  // Vendor Form
  document.getElementById('vendor-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const id = document.getElementById('vendor-id').value;
    const payload = {
      name: document.getElementById('vendor-name').value,
      category: document.getElementById('vendor-category').value,
      contact_person: document.getElementById('vendor-contact').value,
      email: document.getElementById('vendor-email').value,
      phone: document.getElementById('vendor-phone').value,
      portal_url: document.getElementById('vendor-portal').value,
      notes: document.getElementById('vendor-notes').value
    };

    const url = id ? `/api/vendors/${id}` : '/api/vendors';
    const method = id ? 'PUT' : 'POST';

    await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    closeModal('vendor-modal');
    loadAllData();
  });

  // Payment Form
  document.getElementById('payment-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const serviceId = document.getElementById('payment-service-id').value;
    const selectedService = servicesData.find(s => s.id == serviceId);

    const payload = {
      service_id: serviceId || null,
      vendor_id: selectedService ? selectedService.vendor_id : null,
      amount: parseFloat(document.getElementById('payment-amount').value),
      payment_date: document.getElementById('payment-date').value,
      payment_method: document.getElementById('payment-method').value,
      invoice_no: document.getElementById('payment-invoice').value,
      receipt_note: document.getElementById('payment-note').value
    };

    await fetch('/api/payments', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    closeModal('payment-modal');
    loadAllData();
  });

  // Work Log Form (Repairs / Cable / Other)
  document.getElementById('worklog-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const id = document.getElementById('worklog-id').value;
    const payload = {
      type: document.getElementById('worklog-type').value,
      title: document.getElementById('worklog-title').value,
      vendor_name: document.getElementById('worklog-vendor').value,
      issue: document.getElementById('worklog-issue').value,
      condition_notes: document.getElementById('worklog-condition').value,
      cable_type: document.getElementById('worklog-cable-type').value,
      from_location: document.getElementById('worklog-from').value,
      to_location: document.getElementById('worklog-to').value,
      length_meters: document.getElementById('worklog-length').value ? parseFloat(document.getElementById('worklog-length').value) : null,
      cost: document.getElementById('worklog-cost').value ? parseFloat(document.getElementById('worklog-cost').value) : null,
      work_date: document.getElementById('worklog-date').value,
      status: document.getElementById('worklog-status').value,
      bill_status: document.getElementById('worklog-bill-status').value,
      notes: document.getElementById('worklog-notes').value
    };

    const url = id ? `/api/worklog/${id}` : '/api/worklog';
    const method = id ? 'PUT' : 'POST';

    const saveRes = await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    const saveData = await saveRes.json();
    const entryId = id || saveData.id;

    for (const billFile of document.getElementById('worklog-bill-file').files) {
      const formData = new FormData();
      formData.append('bill', billFile);
      await fetch(`/api/worklog/${entryId}/bill`, { method: 'POST', body: formData });
    }

    closeModal('worklog-modal');
    await fetchAttachments();
    fetchWorkLog();
  });

  // Domain Form
  document.getElementById('domain-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const id = document.getElementById('domain-id').value;
    const domainType = document.getElementById('domain-type').value;
    const payload = {
      domain_name: document.getElementById('domain-name').value,
      domain_type: domainType,
      parent_domain_id: domainType === 'Secondary' ? (document.getElementById('domain-parent').value || null) : null,
      service_id: domainType === 'Primary' ? (document.getElementById('domain-service').value || null) : null,
      total_seats: domainType === 'Primary' ? (document.getElementById('domain-seats').value || null) : null,
      admin_email: document.getElementById('domain-admin').value,
      notes: document.getElementById('domain-notes').value
    };

    const url = id ? `/api/domains/${id}` : '/api/domains';
    const method = id ? 'PUT' : 'POST';

    await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    closeModal('domain-modal');
    fetchDomains();
    if (currentOpenPrimaryId) renderSecondaryDomainsTable(currentOpenPrimaryId);
  });

  // Mailbox Form
  document.getElementById('mailbox-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const id = document.getElementById('mailbox-id').value;
    const payload = {
      email: document.getElementById('mailbox-email').value,
      status: document.getElementById('mailbox-status').value,
      current_user: document.getElementById('mailbox-current-user').value,
      purpose: document.getElementById('mailbox-purpose').value,
      notes: document.getElementById('mailbox-notes').value
    };

    const url = id ? `/api/mailboxes/${id}` : '/api/mailboxes';
    const method = id ? 'PUT' : 'POST';

    await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    closeModal('mailbox-modal');
    fetchMailboxes();
  });

  // Company Document Form
  document.getElementById('company-doc-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const id = document.getElementById('company-doc-id').value;
    const payload = {
      title: document.getElementById('company-doc-title').value,
      category: document.getElementById('company-doc-category').value,
      notes: document.getElementById('company-doc-notes').value
    };

    const url = id ? `/api/company-documents/${id}` : '/api/company-documents';
    const method = id ? 'PUT' : 'POST';

    const saveRes = await fetch(url, { method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    const saveData = await saveRes.json();
    const entryId = id || saveData.id;

    for (const file of document.getElementById('company-doc-file').files) {
      const formData = new FormData();
      formData.append('bill', file);
      await fetch(`/api/company-documents/${entryId}/bill`, { method: 'POST', body: formData });
    }

    closeModal('company-doc-modal');
    await fetchAttachments();
    fetchCompanyDocuments();
  });

  document.getElementById('rental-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const id = document.getElementById('rental-id').value;
    const payload = {
      asset_name: document.getElementById('rental-asset-name').value,
      vendor_name: document.getElementById('rental-vendor').value,
      model: document.getElementById('rental-model').value,
      serial_no: document.getElementById('rental-serial').value,
      assigned_to: id ? (rentalsData.find(x => x.id === Number(id)) || {}).assigned_to : null,
      monthly_rent: document.getElementById('rental-monthly').value ? parseFloat(document.getElementById('rental-monthly').value) : null,
      rent_start: document.getElementById('rental-start').value,
      rent_end: document.getElementById('rental-end').value,
      status: document.getElementById('rental-status').value,
      gmail_link: document.getElementById('rental-gmail').value,
      notes: document.getElementById('rental-notes').value
    };

    await fetch(id ? '/api/rentals/' + id : '/api/rentals', {
      method: id ? 'PUT' : 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });

    closeModal('rental-modal');
    await fetchRentals();
    renderRentalPaymentsTable();
  });

  document.getElementById('rental-payment-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const id = document.getElementById('rental-payment-id').value;
    const assetId = document.getElementById('rental-payment-asset').value;
    const payload = {
      amount: parseFloat(document.getElementById('rental-payment-amount').value),
      payment_date: document.getElementById('rental-payment-date').value,
      period_label: document.getElementById('rental-payment-period').value,
      invoice_no: document.getElementById('rental-payment-invoice').value,
      due_date: document.getElementById('rental-payment-due').value,
      paid_on: document.getElementById('rental-payment-paidon').value,
      paid_amount: document.getElementById('rental-payment-paidamt').value ? parseFloat(document.getElementById('rental-payment-paidamt').value) : null,
      payment_method: document.getElementById('rental-payment-method').value,
      status: document.getElementById('rental-payment-status').value,
      asset_id: assetId ? parseInt(assetId) : null,
      gmail_link: document.getElementById('rental-payment-gmail').value,
      notes: document.getElementById('rental-payment-notes').value
    };

    const saveRes = await fetch(id ? '/api/rental-payments/' + id : '/api/rental-payments', {
      method: id ? 'PUT' : 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    const saveData = await saveRes.json();
    const entryId = id || saveData.id;

    for (const file of document.getElementById('rental-payment-bill-file').files) {
      const formData = new FormData();
      formData.append('bill', file);
      await fetch('/api/rental-payments/' + entryId + '/bill', { method: 'POST', body: formData });
    }

    closeModal('rental-payment-modal');
    await fetchAttachments();
    fetchRentalPayments();
  });

  // Alert Settings Form
  document.getElementById('alert-settings-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const payload = {
      email_enabled: document.getElementById('email_enabled').checked,
      smtp_host: document.getElementById('smtp_host').value,
      smtp_port: parseInt(document.getElementById('smtp_port').value) || 587,
      smtp_user: document.getElementById('smtp_user').value,
      smtp_pass: document.getElementById('smtp_pass').value,
      notification_email: document.getElementById('notification_email').value,
      telegram_enabled: document.getElementById('telegram_enabled').checked,
      telegram_bot_token: document.getElementById('telegram_bot_token').value,
      telegram_chat_id: document.getElementById('telegram_chat_id').value
    };

    await fetch('/api/alerts/settings', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    alert('✅ Alert notification settings saved!');
  });
}

// Actions & Modals
function openModal(id) {
  document.getElementById(id).classList.add('active');
}

function closeModal(id) {
  document.getElementById(id).classList.remove('active');
  // Reset forms if opening new
  if (id === 'service-modal') {
    document.getElementById('service-form').reset();
    document.getElementById('service-id').value = '';
    document.getElementById('service-modal-title').innerText = '➕ Add New Service / Contract';
    document.getElementById('service-bill-current').innerHTML = '';
  }
  if (id === 'vendor-modal') {
    document.getElementById('vendor-form').reset();
    document.getElementById('vendor-id').value = '';
    document.getElementById('vendor-modal-title').innerText = '🏢 Add Vendor Profile';
  }
  if (id === 'worklog-modal') {
    document.getElementById('worklog-form').reset();
    document.getElementById('worklog-id').value = '';
    document.getElementById('worklog-modal-title').innerText = '🛠️ Add Work Entry';
    document.getElementById('worklog-bill-current').innerHTML = '';
  }
  if (id === 'company-doc-modal') {
    document.getElementById('company-doc-form').reset();
    document.getElementById('company-doc-id').value = '';
    document.getElementById('company-doc-modal-title').innerText = '📁 Add Company Document';
    document.getElementById('company-doc-current').innerHTML = '';
  }
  if (id === 'rental-modal') {
    document.getElementById('rental-form').reset();
    document.getElementById('rental-id').value = '';
    document.getElementById('rental-vendor').value = 'RAC';
    document.getElementById('rental-modal-title').innerText = '\uD83D\uDCBB Add Rented Laptop';
  }
  if (id === 'rental-payment-modal') {
    document.getElementById('rental-payment-form').reset();
    document.getElementById('rental-payment-id').value = '';
    document.getElementById('rental-payment-modal-title').innerText = '\uD83D\uDCB3 Record Bill / Payment';
    document.getElementById('rental-payment-status').value = 'Pending';
    document.getElementById('rental-payment-current').innerHTML = '';
  }
  if (id === 'mailbox-modal') {
    document.getElementById('mailbox-form').reset();
    document.getElementById('mailbox-id').value = '';
    document.getElementById('mailbox-modal-title').innerText = '📧 Add Mailbox';
  }
  if (id === 'domain-modal') {
    document.getElementById('domain-form').reset();
    document.getElementById('domain-id').value = '';
    document.getElementById('domain-modal-title').innerText = '🌐 Add Domain';
  }
  if (id === 'domain-detail-modal') {
    currentOpenPrimaryId = null;
  }
  if (id === 'subdomain-modal') {
    currentOpenSubdomainId = null;
  }
}

function openAddCompanyDoc() {
  openModal('company-doc-modal');
}

function editCompanyDoc(id) {
  const d = companyDocsData.find(x => x.id === id);
  if (!d) return;
  document.getElementById('company-doc-id').value = d.id;
  document.getElementById('company-doc-title').value = d.title;
  document.getElementById('company-doc-category').value = d.category || 'Other';
  document.getElementById('company-doc-notes').value = d.notes || '';
  renderAttachmentList('company-doc-current', 'company_doc', d.id);
  document.getElementById('company-doc-modal-title').innerText = '✏️ Edit Company Document';
  openModal('company-doc-modal');
}

async function deleteCompanyDoc(id) {
  if (confirm('Are you sure you want to delete this document (and all its files)?')) {
    await fetch(`/api/company-documents/${id}`, { method: 'DELETE' });
    await fetchAttachments();
    fetchCompanyDocuments();
  }
}

function editService(id) {
  const s = servicesData.find(x => x.id === id);
  if (!s) return;
  document.getElementById('service-id').value = s.id;
  document.getElementById('service-name').value = s.service_name;
  document.getElementById('service-vendor-id').value = s.vendor_id || '';
  document.getElementById('service-category').value = s.category;
  document.getElementById('service-cost').value = s.cost;
  document.getElementById('service-cycle').value = s.billing_cycle;
  document.getElementById('service-start-date').value = s.start_date || '';
  document.getElementById('service-expiry-date').value = s.expiry_date;
  document.getElementById('service-auto-renew').checked = !!s.auto_renew;
  document.getElementById('service-notes').value = s.notes || '';
  renderAttachmentList('service-bill-current', 'service', s.id);
  document.getElementById('service-modal-title').innerText = '✏️ Edit Contract';
  openModal('service-modal');
}

async function deleteService(id) {
  if (confirm('Are you sure you want to delete this contract?')) {
    await fetch(`/api/services/${id}`, { method: 'DELETE' });
    loadAllData();
  }
}

function editVendor(id) {
  const v = vendorsData.find(x => x.id === id);
  if (!v) return;
  document.getElementById('vendor-id').value = v.id;
  document.getElementById('vendor-name').value = v.name;
  document.getElementById('vendor-category').value = v.category || '';
  document.getElementById('vendor-contact').value = v.contact_person || '';
  document.getElementById('vendor-email').value = v.email || '';
  document.getElementById('vendor-phone').value = v.phone || '';
  document.getElementById('vendor-portal').value = v.portal_url || '';
  document.getElementById('vendor-notes').value = v.notes || '';
  document.getElementById('vendor-modal-title').innerText = '✏️ Edit Vendor Profile';
  openModal('vendor-modal');
}

async function deleteVendor(id) {
  if (confirm('Are you sure you want to delete this vendor?')) {
    await fetch(`/api/vendors/${id}`, { method: 'DELETE' });
    loadAllData();
  }
}

async function deletePayment(id) {
  if (confirm('Are you sure you want to delete this payment record?')) {
    await fetch(`/api/payments/${id}`, { method: 'DELETE' });
    loadAllData();
  }
}

function openWorkLogModal() {
  document.getElementById('worklog-form').reset();
  document.getElementById('worklog-id').value = '';
  document.getElementById('worklog-vendor').value = 'Bhawar';
  document.getElementById('worklog-type').value = 'Repair';
  document.getElementById('worklog-bill-status').value = 'Pending';
  document.getElementById('worklog-bill-current').innerHTML = '';
  document.getElementById('worklog-modal-title').innerText = '🛠️ Add Work Entry';
  toggleWorkLogFields();
  openModal('worklog-modal');
}

function toggleWorkLogFields() {
  const type = document.getElementById('worklog-type').value;
  const repairFields = document.getElementById('worklog-repair-fields');
  const cableFields = document.getElementById('worklog-cable-fields');
  const titleLabel = document.getElementById('worklog-title-label');
  const titleInput = document.getElementById('worklog-title');

  repairFields.style.display = type === 'Repair' ? 'block' : 'none';
  cableFields.style.display = type === 'Cable' ? 'block' : 'none';

  if (type === 'Repair') {
    titleLabel.innerText = 'Laptop / Device Name *';
    titleInput.placeholder = 'e.g. Dell Latitude - Accounts Team';
  } else if (type === 'Cable') {
    titleLabel.innerText = 'Task Label *';
    titleInput.placeholder = 'e.g. LAN Run - Server Room to Reception';
  } else {
    titleLabel.innerText = 'Task Title *';
    titleInput.placeholder = 'e.g. Printer Setup - Finance Desk';
  }
}

function editWorkLog(id) {
  const w = workLogData.find(x => x.id === id);
  if (!w) return;
  document.getElementById('worklog-id').value = w.id;
  document.getElementById('worklog-type').value = w.type;
  document.getElementById('worklog-title').value = w.title;
  document.getElementById('worklog-vendor').value = w.vendor_name || 'Bhawar';
  document.getElementById('worklog-issue').value = w.issue || '';
  document.getElementById('worklog-condition').value = w.condition_notes || '';
  document.getElementById('worklog-cable-type').value = w.cable_type || 'Cat6';
  document.getElementById('worklog-from').value = w.from_location || '';
  document.getElementById('worklog-to').value = w.to_location || '';
  document.getElementById('worklog-length').value = w.length_meters || '';
  document.getElementById('worklog-cost').value = w.cost || '';
  document.getElementById('worklog-date').value = w.work_date || '';
  document.getElementById('worklog-status').value = w.status || 'Pending';
  document.getElementById('worklog-bill-status').value = w.bill_status || 'Pending';
  document.getElementById('worklog-notes').value = w.notes || '';
  renderAttachmentList('worklog-bill-current', 'worklog', w.id);
  document.getElementById('worklog-modal-title').innerText = '✏️ Edit Work Entry';
  toggleWorkLogFields();
  openModal('worklog-modal');
}

async function deleteWorkLog(id) {
  if (confirm('Are you sure you want to delete this work log entry?')) {
    await fetch(`/api/worklog/${id}`, { method: 'DELETE' });
    fetchWorkLog();
  }
}

async function triggerTestAlert() {
  const res = await fetch('/api/alerts/test', { method: 'POST' });
  const data = await res.json();
  alert('⚡ Expiry Check Triggered!\nCheck console logs and your Telegram/Email for alerts.');
}

// CSV Importer Engine
async function processCSVImport() {
  const fileInput = document.getElementById('csv-file-input');
  const pasteArea = document.getElementById('csv-paste-area').value;
  const resultDiv = document.getElementById('import-result');

  let csvText = '';
  if (fileInput.files.length > 0) {
    csvText = await fileInput.files[0].text();
  } else if (pasteArea.trim() !== '') {
    csvText = pasteArea;
  } else {
    alert('Please select a CSV file or paste CSV text to import.');
    return;
  }

  const rows = parseCSV(csvText);
  if (rows.length === 0) {
    resultDiv.innerHTML = `<span style="color:var(--danger)">No valid data rows found in CSV.</span>`;
    return;
  }

  try {
    const res = await fetch('/api/import/csv', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rows })
    });
    const result = await res.json();
    resultDiv.innerHTML = `<span style="color:var(--success);font-weight:bold">✅ ${result.message}</span>`;
    loadAllData();
  } catch (err) {
    resultDiv.innerHTML = `<span style="color:var(--danger)">Import failed: ${err.message}</span>`;
  }
}

function parseCSV(text) {
  const lines = text.trim().split(/\r\n|\n/);
  if (lines.length < 2) return [];

  const headers = lines[0].split(',').map(h => h.trim().replace(/^"|"$/g, ''));
  const rows = [];

  for (let i = 1; i < lines.length; i++) {
    if (!lines[i].trim()) continue;
    const values = lines[i].split(',').map(v => v.trim().replace(/^"|"$/g, ''));
    const obj = {};
    headers.forEach((h, idx) => {
      obj[h] = values[idx] || '';
    });
    rows.push(obj);
  }
  return rows;
}

function escapeHtml(str) {
  if (!str) return '';
  return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
