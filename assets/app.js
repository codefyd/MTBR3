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
    location.href = 'dashboard.html';
    return null;
  }
  return session;
}

// ------- الشريط الجانبي -------
const NAV = [
  { href: 'dashboard.html', label: 'لوحة التحكم', icon: 'fa-chart-line' },
  { href: 'donors.html', label: 'ملفات المتبرعين', icon: 'fa-users' },
  { href: 'operations.html', label: 'العمليات', icon: 'fa-receipt' },
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

// ------- أدوات التنسيق ------- (أرقام إنجليزية/لاتينية في كل الواجهة)
function fmtNum(n) {
  if (n === null || n === undefined || n === '') return '0';
  return Number(n).toLocaleString('en-US');
}
function fmtMoney(n) {
  if (n === null || n === undefined) return '0';
  return Number(n).toLocaleString('en-US', { maximumFractionDigits: 2 });
}
function fmtDate(s) {
  if (!s) return '—';
  return new Date(s).toLocaleDateString('en-GB', { year: 'numeric', month: '2-digit', day: '2-digit' });
}
function fmtDateTime(s) {
  if (!s) return '—';
  return new Date(s).toLocaleString('en-GB', {
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
const SA_OPERATORS = ['50','51','52','53','54','55','56','57','58','59'];
function phoneDigits(raw) {
  if (raw === null || raw === undefined) return '';
  return String(raw).replace(/[^0-9]/g, '').replace(/^00/, '');
}
function invalidPhoneKey(d, lineNo, operationNo) {
  // مفتاح محلي للعرض فقط؛ قاعدة البيانات تولّد مفتاحًا ثابتًا مشابهًا.
  // لا يظهر هذا المفتاح للمستخدم النهائي، بل نعرض الرقم كما ورد.
  if (!d) return `EMPTY:${operationNo || lineNo || Date.now()}`;
  return `INVALID:${d}`;
}
function normalizePhone(raw, ctx = {}) {
  const rawText = raw === null || raw === undefined ? '' : String(raw).trim();
  const d0 = phoneDigits(raw);

  if (!rawText) {
    return { phone: invalidPhoneKey('', ctx.lineNo, ctx.operationNo), status: 'فارغ', reason: 'رقم الجوال فارغ', digits: '' };
  }
  if (!d0) {
    return { phone: invalidPhoneKey('', ctx.lineNo, ctx.operationNo), status: 'فارغ', reason: 'لا يحتوي أرقام', digits: '' };
  }

  const d = d0;
  const validOp = op => SA_OPERATORS.includes(op);

  if (/^9665\d{8}$/.test(d)) {
    const op = d.slice(3, 5);
    return validOp(op)
      ? { phone: d, status: 'صحيح', reason: 'سعودي صحيح', digits: d }
      : { phone: invalidPhoneKey(d, ctx.lineNo, ctx.operationNo), status: 'خاطئ', reason: 'مشغّل سعودي غير صحيح', digits: d };
  }

  if (/^05\d{8}$/.test(d)) {
    const op = d.slice(1, 3);
    return validOp(op)
      ? { phone: '966' + d.slice(1), status: 'صحيح', reason: 'محلي بصفر', digits: d }
      : { phone: invalidPhoneKey(d, ctx.lineNo, ctx.operationNo), status: 'خاطئ', reason: 'مشغّل سعودي غير صحيح', digits: d };
  }

  if (/^5\d{8}$/.test(d)) {
    const op = d.slice(0, 2);
    return validOp(op)
      ? { phone: '966' + d, status: 'صحيح', reason: 'محلي 9 خانات', digits: d }
      : { phone: invalidPhoneKey(d, ctx.lineNo, ctx.operationNo), status: 'خاطئ', reason: 'مشغّل سعودي غير صحيح (' + op + ')', digits: d };
  }

  // تصحيح آمن للأرقام الطويلة التي تبدأ بـ966 وفي آخرها رقم سعودي صحيح
  if (d.startsWith('966') && d.length > 12) {
    const tail12 = d.slice(-12);
    const tail10 = d.slice(-10);

    if (/^9665\d{8}$/.test(tail12)) {
      const op = tail12.slice(3, 5);
      if (validOp(op)) return { phone: tail12, status: 'صحيح', reason: 'تصحيح رقم سعودي مكرر', digits: d };
    }

    if (/^05\d{8}$/.test(tail10)) {
      const op = tail10.slice(1, 3);
      if (validOp(op)) return { phone: '966' + tail10.slice(1), status: 'صحيح', reason: 'تصحيح من آخر رقم محلي صحيح', digits: d };
    }
  }

  if (d.startsWith('966')) {
    return { phone: invalidPhoneKey(d, ctx.lineNo, ctx.operationNo), status: 'خاطئ', reason: 'يبدأ بـ966 لكن غير صالح', digits: d };
  }

  if (d.length >= 8 && d.length <= 15) {
    return { phone: d, status: 'صحيح', reason: 'أجنبي', digits: d };
  }

  return { phone: invalidPhoneKey(d, ctx.lineNo, ctx.operationNo), status: 'خاطئ', reason: 'مبتور/غير صالح (' + d.length + ' خانة)', digits: d };
}

// واجهة مختصرة ترجع الرقم فقط (للتوافق مع الاستدعاءات السابقة)
function cleanPhone(raw) {
  const n = normalizePhone(raw);
  return n.status === 'صحيح' ? n.phone : null;
}
function operationPhoneKey(raw, ctx = {}) {
  return normalizePhone(raw, ctx).phone;
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


// إعادة بناء ملفات المتبرعين على دفعات لتجنب timeout في Supabase/PostgREST
async function rebuildDonorsInBatches(onProgress, batchSize = 300) {
  const start = await sb.rpc('donor_rebuild_start');
  if (start.error) throw start.error;
  const total = Number(start.data || 0);
  let remaining = total;
  let processed = 0;
  if (typeof onProgress === 'function') onProgress({ total, processed, remaining });

  // حماية من حلقة لا نهائية لو رجعت الدالة نتيجة غير متوقعة
  let safety = 0;
  while (remaining > 0 && safety < 10000) {
    safety++;
    const { data, error } = await sb.rpc('donor_rebuild_chunk', { p_limit: batchSize });
    if (error) throw error;
    const stepProcessed = Number(data?.processed || 0);
    remaining = Number(data?.remaining || 0);
    processed += stepProcessed;
    if (typeof onProgress === 'function') onProgress({ total, processed, remaining });
    if (stepProcessed === 0 && remaining > 0) {
      throw new Error('توقف احتساب ملفات المتبرعين قبل اكتمال الدفعات.');
    }
  }
  if (remaining > 0) throw new Error('لم يكتمل احتساب ملفات المتبرعين بسبب تجاوز حد الأمان.');
  return { total, processed, remaining };
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
  sb, guard, initShell, toast, fmtMoney, fmtNum, fmtDate, fmtDateTime, esc,
  cleanPhone, operationPhoneKey, normalizePhone, toNum, toISO, pick, readExcel, rpcInBatches, rebuildDonorsInBatches, PAGE_SIZE,
};
