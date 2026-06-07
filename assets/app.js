// =====================================================================
// مكتبة مشتركة لكل صفحات اللوحة
// =====================================================================
const { SUPABASE_URL, SUPABASE_KEY, PAGE_SIZE } = window.APP_CONFIG;

// عميل Supabase (مكتبة supabase-js محمّلة من CDN)
const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
window.sb = sb;

// ------- حارس المصادقة -------
// page: 'login' لصفحة الدخول، أو 'app' لصفحات اللوحة
async function guard(page) {
  const { data: { session } } = await sb.auth.getSession();
  if (page === 'app' && !session) {
    location.href = 'login.html';
    return null;
  }
  if (page === 'login' && session) {
    location.href = 'donors.html';
    return null;
  }
  return session;
}

// ------- الشريط الجانبي -------
const NAV = [
  { href: 'operations.html', label: 'العمليات', icon: 'fa-receipt' },
  { href: 'donors.html', label: 'ملفات المتبرعين', icon: 'fa-users' },
  { href: 'campaigns.html', label: 'المستهدفين في الحملات', icon: 'fa-bullhorn' },
  { href: 'settings.html', label: 'الإعدادات', icon: 'fa-gear' },
];

function renderSidebar(activeHref, userEmail) {
  const links = NAV.map(n => `
    <a href="${n.href}" class="nav-link-x ${n.href === activeHref ? 'active' : ''}">
      <i class="fa-solid ${n.icon}"></i><span>${n.label}</span>
    </a>`).join('');

  return `
    <div class="overlay hidden" id="ovl"></div>
    <aside class="sidebar" id="sidebar">
      <div class="brand"><i class="fa-solid fa-hand-holding-heart"></i><span>المتبرعون</span></div>
      <nav style="flex:1">${links}</nav>
      <div class="sidebar-footer">
        <div style="padding:.75rem 1rem;font-size:.85rem;color:#a9c4be;border-top:1px solid rgba(255,255,255,.12);margin-bottom:.5rem;word-break:break-all">
          <i class="fa-solid fa-user-shield"></i> ${userEmail || ''}
        </div>
        <div class="nav-link-x" id="logoutBtn" style="color:#f3c9c2">
          <i class="fa-solid fa-right-from-bracket"></i><span>تسجيل الخروج</span>
        </div>
      </div>
    </aside>
    <button class="btn-x btn-sm menu-toggle" id="menuToggle"><i class="fa-solid fa-bars"></i></button>
  `;
}

function wireSidebar() {
  const toggle = document.getElementById('menuToggle');
  const sidebar = document.getElementById('sidebar');
  const ovl = document.getElementById('ovl');
  toggle?.addEventListener('click', () => { sidebar.classList.add('open'); ovl.classList.remove('hidden'); });
  ovl?.addEventListener('click', () => { sidebar.classList.remove('open'); ovl.classList.add('hidden'); });
  document.getElementById('logoutBtn')?.addEventListener('click', async () => {
    await sb.auth.signOut();
    location.href = 'login.html';
  });
}

// تهيئة هيكل الصفحة (الشريط + منطقة المحتوى) — يُستدعى بعد التحقق من الجلسة
async function initShell(activeHref) {
  const session = await guard('app');
  if (!session) return null;
  const email = session.user?.email || '';
  document.getElementById('shell').innerHTML =
    renderSidebar(activeHref, email) +
    `<div class="main-area" id="mainArea"></div>`;
  wireSidebar();
  return session;
}

// ------- إشعارات -------
let _toastTimer;
function toast(msg, type = 'ok') {
  let el = document.getElementById('toast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'toast';
    document.body.appendChild(el);
  }
  const icon = type === 'ok' ? 'fa-circle-check' : type === 'err' ? 'fa-circle-xmark' : 'fa-circle-info';
  el.className = `toast-x ${type}`;
  el.innerHTML = `<i class="fa-solid ${icon}" style="margin-inline-end:.5rem"></i>${msg}`;
  clearTimeout(_toastTimer);
  _toastTimer = setTimeout(() => el.remove(), 4500);
}

// ------- أدوات التنسيق -------
function fmtMoney(n) {
  if (n === null || n === undefined) return '٠';
  return Number(n).toLocaleString('ar-SA', { maximumFractionDigits: 2 });
}
function fmtDate(s) {
  if (!s) return '—';
  return new Date(s).toLocaleDateString('ar-SA', { year: 'numeric', month: '2-digit', day: '2-digit' });
}
function fmtDateTime(s) {
  if (!s) return '—';
  return new Date(s).toLocaleString('ar-SA', {
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: true,
  });
}
function esc(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// ------- أدوات Excel -------
// تنظيف وتطبيع رقم الجوال (نفس منطق دالة SQL)
// السعودي => 966XXXXXXXXX | الأجنبي => كما هو | المبتور => null
const SA_OPERATORS = ['50','51','53','54','55','56','57','58','59'];
function normalizePhone(raw) {
  if (raw === null || raw === undefined) return { phone: null, reason: 'فارغ' };
  let d = String(raw).replace(/[^0-9]/g, '');
  if (!d) return { phone: null, reason: 'لا يحتوي أرقام' };
  d = d.replace(/^00/, '');

  if (/^9665\d{8}$/.test(d)) {
    return SA_OPERATORS.includes(d.slice(3, 5))
      ? { phone: d, reason: 'سعودي صحيح' }
      : { phone: null, reason: 'مشغّل سعودي غير صحيح' };
  }
  if (/^05\d{8}$/.test(d)) {
    return SA_OPERATORS.includes(d.slice(1, 3))
      ? { phone: '966' + d.slice(1), reason: 'محلي بصفر' }
      : { phone: null, reason: 'مشغّل سعودي غير صحيح' };
  }
  if (/^5\d{8}$/.test(d)) {
    return SA_OPERATORS.includes(d.slice(0, 2))
      ? { phone: '966' + d, reason: 'محلي 9 خانات' }
      : { phone: null, reason: 'مشغّل سعودي غير صحيح (' + d.slice(0, 2) + ')' };
  }
  if (d.startsWith('966')) return { phone: null, reason: 'يبدأ بـ966 لكن غير صالح' };
  if (d.length >= 8 && d.length <= 15) return { phone: d, reason: 'أجنبي' };
  return { phone: null, reason: 'مبتور/غير صالح (' + d.length + ' خانة)' };
}
// واجهة مختصرة ترجع الرقم فقط (للتوافق مع الاستدعاءات السابقة)
function cleanPhone(raw) {
  return normalizePhone(raw).phone;
}
function toNum(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(String(v).replace(/[^\d.-]/g, ''));
  return isNaN(n) ? null : n;
}
function toISO(v) {
  if (v === null || v === undefined || v === '') return null;
  if (typeof v === 'number' && window.XLSX?.SSF) {
    const d = window.XLSX.SSF.parse_date_code(v);
    if (d) return new Date(Date.UTC(d.y, d.m - 1, d.d, d.H || 0, d.M || 0, Math.floor(d.S || 0))).toISOString();
  }
  const p = new Date(String(v).trim());
  return isNaN(p.getTime()) ? null : p.toISOString();
}
// مطابقة أسماء الأعمدة العربية بمرونة (تجاهل المسافات و #)
function pick(row, keys) {
  for (const k of Object.keys(row)) {
    const norm = k.replace(/\s|#/g, '').trim();
    for (const want of keys) {
      if (norm === want.replace(/\s|#/g, '').trim()) return row[k];
    }
  }
  return null;
}
// قراءة ملف Excel/CSV وإرجاع مصفوفة صفوف ككائنات
// raw:false يجعل القيم نصوصاً منسّقة فلا تتحول الأرقام الطويلة (مثل الجوال) لصيغة علمية
async function readExcel(file) {
  const buf = await file.arrayBuffer();
  const wb = window.XLSX.read(buf, { type: 'array', raw: false, codepage: 65001 });
  const ws = wb.Sheets[wb.SheetNames[0]];
  return window.XLSX.utils.sheet_to_json(ws, { defval: null, raw: false });
}

// رفع البيانات على دفعات عبر دالة RPC في قاعدة البيانات
async function rpcInBatches(fnName, rows, batchSize = 500) {
  let total = 0;
  for (let i = 0; i < rows.length; i += batchSize) {
    const slice = rows.slice(i, i + batchSize);
    const { data, error } = await sb.rpc(fnName, { rows: slice });
    if (error) throw error;
    total += (typeof data === 'number' ? data : slice.length);
  }
  return total;
}

window.App = {
  sb, guard, initShell, toast, fmtMoney, fmtDate, fmtDateTime, esc,
  cleanPhone, normalizePhone, toNum, toISO, pick, readExcel, rpcInBatches, PAGE_SIZE,
};
