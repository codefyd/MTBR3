(() => {
  const PAGES = [
    ['dashboard','لوحة التحكم'], ['reports','التقارير'], ['targets','المستهدفات اليومية'],
    ['donors','ملفات المتبرعين'], ['operations','العمليات'], ['campaign_analysis','تحليل الحملات'],
    ['campaign_targets','مستهدفو الحملات'], ['marketing_content','المحتوى التسويقي'], ['settings','الإعدادات'],
  ];
  let state = { organizations: [], memberships: [], tokens: [], mcp_url: '' };

  const api = async (action, payload = {}) => {
    const { data, error } = await App.sb.functions.invoke('saas-admin', { body: { action, ...payload } });
    if (error) throw error;
    if (!data?.ok) throw new Error(data?.error || 'تعذر تنفيذ الطلب');
    return data;
  };

  const permissionBoxes = (name, selected = PAGES.map(p => p[0])) => {
    const set = new Set(selected || []);
    return `<div class="permission-grid">${PAGES.map(([key,label]) => `
      <label class="permission-item"><input type="checkbox" name="${name}" value="${key}" ${set.has(key) ? 'checked' : ''}><span>${label}</span></label>
    `).join('')}</div>`;
  };

  const checked = (form, name) => [...form.querySelectorAll(`[name="${name}"]:checked`)].map(x => x.value);
  const memberEmail = id => state.memberships.find(x => x.user_id === id)?.email || id;

  async function withBusy(button, busyLabel, task) {
    if (!button || button.disabled || button.getAttribute('aria-busy') === 'true') return;
    const original = button.innerHTML;
    button.disabled = true;
    button.setAttribute('aria-busy', 'true');
    button.innerHTML = `<span class="spinner-x" aria-hidden="true"></span><span>${App.esc(busyLabel)}</span>`;
    try {
      return await task();
    } finally {
      if (button.isConnected) {
        button.disabled = false;
        button.removeAttribute('aria-busy');
        button.innerHTML = original;
      }
    }
  }

  const submitButton = form => form.querySelector('button[type="submit"],button:not([type])');

  function render() {
    const area = document.getElementById('mainArea');
    area.innerHTML = `<div class="content admin-content">
      <div class="page-head"><div><h1>إدارة منصة ولاء</h1><p>الجمعيات والمستخدمون والاشتراكات وروابط MCP من مكان واحد.</p></div>
        <button class="btn-x btn-outline-x" id="refreshAdmin"><i class="fa-solid fa-rotate"></i> تحديث</button></div>

      <section class="panel" style="padding:1.25rem;margin-bottom:1rem">
        <h2 style="font-size:1.15rem">إضافة جمعية جديدة</h2>
        <form id="createOrgForm">
          <div class="form-grid" style="margin-bottom:1rem">
            <div><label class="lbl">اسم الجمعية</label><input class="field" name="name" required></div>
            <div><label class="lbl">بريد الجمعية</label><input class="field" name="contact_email" type="email" required dir="ltr"></div>
            <div><label class="lbl">نهاية الاشتراك</label><input class="field" name="subscription_ends_at" type="date" required></div>
            <div><label class="lbl">بريد المستخدم الأول</label><input class="field" name="owner_email" type="email" required dir="ltr"></div>
            <div><label class="lbl">كلمة مرور مؤقتة</label><input class="field" name="temporary_password" type="password" minlength="10" required dir="ltr"></div>
          </div>
          <label class="lbl">الصفحات الظاهرة للمستخدم الأول</label>
          ${permissionBoxes('owner_pages')}
          <button class="btn-x" style="margin-top:1rem" type="submit"><i class="fa-solid fa-building-circle-check"></i> إنشاء الجمعية والحساب</button>
        </form>
      </section>

      <div id="organizationsArea">${state.organizations.length ? state.organizations.map(renderOrg).join('') : '<div class="empty-state">لا توجد جمعيات بعد.</div>'}</div>

      <div class="modal-x hidden" id="secretModal"><div class="modal-card" style="max-width:700px">
        <div class="modal-head"><h3>بيانات ربط MCP</h3><button class="icon-btn" data-close-secret><i class="fa-solid fa-xmark"></i></button></div>
        <p class="muted">المفتاح يظهر مرة واحدة فقط. انسخه الآن واحفظه في مدير أسرار.</p>
        <div class="mcp-note"><strong>تنبيه:</strong> فتح الرابط في المتصفح أو لصقه وحده لا يُنشئ اتصالًا. يجب أن يرسل عميل MCP المفتاح داخل ترويسة <span dir="ltr">Authorization: Bearer</span>.</div>
        <label class="lbl">رابط Streamable HTTP</label><div class="secret-box" id="mcpUrl"></div>
        <label class="lbl" style="margin-top:.8rem">مفتاح Bearer</label><div class="secret-box" id="mcpSecret"></div>
        <div class="modal-actions">
          <button class="btn-x" id="copyMcpConfig"><i class="fa-solid fa-copy"></i> نسخ إعداد العميل</button>
          <button class="btn-x btn-outline-x" id="copyMcpCurl"><i class="fa-solid fa-terminal"></i> نسخ أمر الاختبار</button>
          <button class="btn-x btn-outline-x" id="testMcpConnection"><i class="fa-solid fa-plug-circle-check"></i> اختبار الاتصال</button>
        </div>
        <div class="mcp-test-result hidden" id="mcpTestResult" role="status"></div>
        <p class="muted" style="margin:.9rem 0 0">للعملاء الذين لا يسمحون بإضافة ترويسة مخصصة—ومنهم ربط ChatGPT عبر رابط فقط—يلزم مسار OAuth 2.1، ولا ينبغي وضع المفتاح داخل الرابط.</p>
      </div></div>
      <div class="modal-x hidden" id="memberModal"><div class="modal-card" style="max-width:760px">
        <div class="modal-head"><h3>تعديل المستخدم</h3><button class="icon-btn" data-close-member><i class="fa-solid fa-xmark"></i></button></div>
        <form id="memberForm">
          <input type="hidden" name="membership_id">
          <p id="memberEmail" dir="ltr" style="text-align:right"></p>
          <div class="form-grid" style="margin-bottom:1rem">
            <div><label class="lbl">الدور</label><select class="field" name="role"><option value="member">مستخدم</option><option value="admin">مدير جمعية</option><option value="owner">مالك الجمعية</option></select></div>
            <label class="permission-item" style="align-self:end"><input type="checkbox" name="is_active"> الحساب فعّال</label>
          </div>
          <label class="lbl">الصفحات الظاهرة</label>${permissionBoxes('edit_pages', [])}
          <button class="btn-x" style="margin-top:1rem">حفظ صلاحيات المستخدم</button>
        </form>
      </div></div></div>
    `;
    wire();
  }

  function renderOrg(org) {
    const members = state.memberships.filter(m => m.organization_id === org.id);
    const tokens = state.tokens.filter(t => t.organization_id === org.id);
    const expired = !org.is_active || (org.subscription_ends_at && org.subscription_ends_at < new Date().toISOString().slice(0,10));
    return `<section class="panel" style="padding:1.25rem;margin-bottom:1rem" data-org="${org.id}">
      <div class="page-head" style="margin-bottom:1rem"><div><h2 style="font-size:1.2rem">${App.esc(org.name)}</h2>
        <p>${App.esc(org.contact_email || '—')} · <span class="status-pill ${expired ? 'expired' : ''}">${expired ? 'موقوف/منتهي' : 'فعّال'}</span></p></div></div>
      <div class="admin-grid">
        <div class="admin-card"><h3>الاشتراك</h3>
          <form class="update-org-form">
            <input type="hidden" name="organization_id" value="${org.id}">
            <label class="lbl">اسم الجمعية</label><input class="field" name="name" value="${App.esc(org.name)}" required>
            <label class="lbl" style="margin-top:.6rem">البريد</label><input class="field" name="contact_email" type="email" dir="ltr" value="${App.esc(org.contact_email || '')}" required>
            <label class="lbl" style="margin-top:.6rem">نهاية الاشتراك</label><input class="field" name="subscription_ends_at" type="date" value="${App.esc(org.subscription_ends_at || '')}" required>
            <label class="permission-item" style="margin-top:.7rem"><input type="checkbox" name="is_active" ${org.is_active ? 'checked' : ''}> الجهة فعّالة</label>
            <button class="btn-x btn-sm" style="margin-top:.7rem">حفظ الاشتراك</button>
          </form>
        </div>
        <div class="admin-card"><h3>إضافة مستخدم</h3>
          <form class="add-user-form">
            <input type="hidden" name="organization_id" value="${org.id}">
            <label class="lbl">البريد</label><input class="field" name="email" type="email" dir="ltr" required>
            <label class="lbl" style="margin-top:.6rem">كلمة مرور مؤقتة</label><input class="field" name="temporary_password" type="password" minlength="10" dir="ltr" required>
            <label class="lbl" style="margin-top:.6rem">الدور</label><select class="field" name="role"><option value="member">مستخدم</option><option value="admin">مدير جمعية</option><option value="owner">مالك الجمعية</option></select>
            <details style="margin-top:.7rem"><summary>صلاحيات الصفحات</summary>${permissionBoxes('member_pages')}</details>
            <button class="btn-x btn-sm" style="margin-top:.7rem">إضافة المستخدم</button>
          </form>
        </div>
        <div class="admin-card"><h3>إنشاء مفتاح MCP</h3>
          <form class="create-token-form">
            <input type="hidden" name="organization_id" value="${org.id}">
            <label class="lbl">اسم الاتصال</label><input class="field" name="name" placeholder="ChatGPT - التسويق" required>
            <label class="lbl" style="margin-top:.6rem">مرتبط بمستخدم (اختياري)</label><select class="field" name="user_id"><option value="">للجمعية كاملة</option>${members.filter(m=>m.is_active).map(m=>`<option value="${m.user_id}">${App.esc(m.email || m.user_id)}</option>`).join('')}</select>
            <label class="lbl" style="margin-top:.6rem">ينتهي في (اختياري)</label><input class="field" name="expires_at" type="date">
            <button class="btn-x btn-sm" style="margin-top:.7rem"><i class="fa-solid fa-key"></i> إنشاء المفتاح</button>
          </form>
        </div>
      </div>
      <h3 style="font-size:1rem;margin:1.2rem 0 .7rem">المستخدمون (${members.length})</h3>
      <div class="table-wrap"><table><thead><tr><th>البريد</th><th>الدور</th><th>الصفحات</th><th>الحالة</th><th></th></tr></thead><tbody>
        ${members.map(m => `<tr><td dir="ltr">${App.esc(m.email || m.user_id)}</td><td>${App.esc(m.role)}</td><td>${(m.allowed_pages || []).length}</td><td>${m.is_active ? 'فعّال' : 'موقوف'}</td><td><button class="btn-x btn-sm edit-member" data-member='${App.esc(JSON.stringify(m))}'>تعديل</button></td></tr>`).join('') || '<tr><td colspan="5">لا يوجد مستخدمون</td></tr>'}
      </tbody></table></div>
      <h3 style="font-size:1rem;margin:1.2rem 0 .7rem">اتصالات MCP (${tokens.length})</h3>
      <div class="table-wrap"><table><thead><tr><th>الاسم</th><th>النوع</th><th>آخر استخدام</th><th>الحالة</th><th></th></tr></thead><tbody>
        ${tokens.map(t => `<tr><td>${App.esc(t.name)}</td><td>${t.user_id ? App.esc(memberEmail(t.user_id)) : 'الجمعية'}</td><td>${App.fmtDateTime(t.last_used_at)}</td><td>${t.revoked_at ? 'ملغي' : 'فعّال'}</td><td>${t.revoked_at ? '' : `<button class="btn-x btn-sm btn-danger-x revoke-token" data-id="${t.id}">إلغاء</button>`}</td></tr>`).join('') || '<tr><td colspan="5">لا توجد مفاتيح</td></tr>'}
      </tbody></table></div>
    </section>`;
  }

  function wire() {
    document.getElementById('refreshAdmin').onclick = e => withBusy(e.currentTarget, 'جارٍ التحديث', () => load());
    document.getElementById('createOrgForm').onsubmit = async e => {
      e.preventDefault(); const f=e.currentTarget;
      await withBusy(submitButton(f), 'جارٍ إنشاء الجمعية', async () => {
        try { await api('create_organization',{name:f.name.value,contact_email:f.contact_email.value,subscription_ends_at:f.subscription_ends_at.value,owner_email:f.owner_email.value,temporary_password:f.temporary_password.value,allowed_pages:checked(f,'owner_pages')}); App.toast('تم إنشاء الجمعية والمستخدم'); await load(); } catch(err){App.toast(err.message,'err');}
      });
    };
    document.querySelectorAll('.update-org-form').forEach(f => f.onsubmit = async e => {
      e.preventDefault(); await withBusy(submitButton(f), 'جارٍ الحفظ', async () => {
        try { await api('update_organization',{organization_id:f.organization_id.value,name:f.name.value,contact_email:f.contact_email.value,subscription_ends_at:f.subscription_ends_at.value,is_active:f.is_active.checked}); App.toast('تم تحديث الاشتراك'); await load(); } catch(err){App.toast(err.message,'err');}
      });
    });
    document.querySelectorAll('.add-user-form').forEach(f => f.onsubmit = async e => {
      e.preventDefault(); await withBusy(submitButton(f), 'جارٍ إضافة المستخدم', async () => {
        try { await api('add_user',{organization_id:f.organization_id.value,email:f.email.value,temporary_password:f.temporary_password.value,role:f.role.value,allowed_pages:checked(f,'member_pages')}); App.toast('تمت إضافة المستخدم'); await load(); } catch(err){App.toast(err.message,'err');}
      });
    });
    document.querySelectorAll('.create-token-form').forEach(f => f.onsubmit = async e => {
      e.preventDefault(); await withBusy(submitButton(f), 'جارٍ إنشاء المفتاح', async () => {
        try { const out=await api('create_mcp_token',{organization_id:f.organization_id.value,user_id:f.user_id.value||null,name:f.name.value,expires_at:f.expires_at.value||null}); showSecret(out); await load(false); } catch(err){App.toast(err.message,'err');}
      });
    });
    document.querySelectorAll('.revoke-token').forEach(b => b.onclick = async () => {
      if(!confirm('إلغاء هذا المفتاح فورًا؟'))return;
      await withBusy(b, 'جارٍ الإلغاء', async () => { try{await api('revoke_mcp_token',{token_id:b.dataset.id});App.toast('تم إلغاء المفتاح');await load();}catch(err){App.toast(err.message,'err');} });
    });
    document.querySelectorAll('.edit-member').forEach(b => b.onclick = () => editMember(JSON.parse(b.dataset.member)));
    document.querySelectorAll('[data-close-secret]').forEach(b=>b.onclick=()=>render());
    document.querySelectorAll('[data-close-member]').forEach(b=>b.onclick=()=>document.getElementById('memberModal').classList.add('hidden'));
    document.getElementById('memberForm').onsubmit = async e => {
      e.preventDefault(); const f=e.currentTarget;
      await withBusy(submitButton(f), 'جارٍ حفظ الصلاحيات', async () => {
        try { await api('update_member',{membership_id:f.membership_id.value,role:f.role.value,allowed_pages:checked(f,'edit_pages'),is_active:f.is_active.checked}); App.toast('تم تحديث المستخدم'); document.getElementById('memberModal').classList.add('hidden'); await load(); } catch(err){App.toast(err.message,'err');}
      });
    };
  }

  function editMember(member) {
    const modal=document.getElementById('memberModal'); const f=document.getElementById('memberForm');
    f.membership_id.value=member.id; f.role.value=member.role; f.is_active.checked=member.is_active;
    document.getElementById('memberEmail').textContent=member.email || member.user_id;
    const selected=new Set(member.allowed_pages || []);
    f.querySelectorAll('[name="edit_pages"]').forEach(box=>box.checked=selected.has(box.value));
    modal.classList.remove('hidden');
  }

  function showSecret(out) {
    const modal=document.getElementById('secretModal');
    document.getElementById('mcpUrl').textContent=out.mcp_url;
    document.getElementById('mcpSecret').textContent=out.token;
    document.getElementById('copyMcpConfig').onclick=async e=>{
      const config={mcpServers:{walaa:{type:'http',url:out.mcp_url,headers:{Authorization:`Bearer ${out.token}`}}}};
      await withBusy(e.currentTarget, 'جارٍ النسخ', async () => {
        await navigator.clipboard.writeText(JSON.stringify(config,null,2)); App.toast('تم نسخ إعداد MCP');
      });
    };
    document.getElementById('copyMcpCurl').onclick=async e=>{
      const payload=JSON.stringify({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2025-11-25',capabilities:{},clientInfo:{name:'mcp-check',version:'1.0.0'}}});
      const command=`curl -i -X POST '${out.mcp_url}' -H 'Authorization: Bearer ${out.token}' -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2025-11-25' --data '${payload}'`;
      await withBusy(e.currentTarget, 'جارٍ النسخ', async () => {
        await navigator.clipboard.writeText(command); App.toast('تم نسخ أمر الاختبار');
      });
    };
    document.getElementById('testMcpConnection').onclick=async e=>{
      const result=document.getElementById('mcpTestResult');
      result.className='mcp-test-result hidden';
      await withBusy(e.currentTarget, 'جارٍ الاختبار', async () => {
        try {
          const test=await api('test_mcp_connection',{token:out.token});
          result.textContent=`الاتصال ناجح — إصدار البروتوكول ${test.protocol_version || 'متوافق'}، وعدد الأدوات ${test.tools_count ?? '—'}.`;
          result.className='mcp-test-result';
        } catch(err) {
          result.textContent=`فشل الاختبار: ${err.message}`;
          result.className='mcp-test-result error';
        }
      });
    };
    modal.classList.remove('hidden');
  }

  async function load(renderAfter = true) {
    try { const out=await api('list'); state={...state,...out}; if(renderAfter) render(); }
    catch(err){App.toast(err.message,'err');}
  }

  (async()=>{ const session=await App.initShell('admin.html'); if(!session)return; document.getElementById('mainArea').innerHTML='<div class="loading-state"><span class="spinner-x spinner-dark"></span> جارٍ تحميل إدارة المنصة...</div>'; await load(); })();
})();
