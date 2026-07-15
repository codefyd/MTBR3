(() => {
  'use strict';

  const state = {
    campaigns: [], projects: [], channels: [], currentId: null, detail: null,
    view: 'campaigns', detailTab: 'overview', loading: false, legacyRows: [],
    draft: null, preview: null,
  };

  const labels = {
    nature: { short: 'قصيرة', ongoing: 'مستمرة', seasonal: 'موسمية' },
    status: { draft: 'مسودة', active: 'نشطة', ended: 'منتهية', paused: 'متوقفة' },
  };

  document.addEventListener('DOMContentLoaded', init);

  async function init() {
    const session = await App.initShell('campaign-analysis.html');
    if (!session) return;
    renderPage();
    bindPageEvents();
    await loadReferences();
    await loadCampaigns();
  }

  function renderPage() {
    document.getElementById('mainArea').innerHTML = `
      <div class="topbar">
        <h1><i class="fa-solid fa-chart-simple text-gold"></i> ذكاء الحملات التسويقية</h1>
        <div class="ca-top-actions">
          <button class="btn-x btn-ghost btn-sm" id="refreshCampaignsBtn"><i class="fa-solid fa-rotate"></i> تحديث التحليل</button>
          <button class="btn-x btn-ghost btn-sm" id="exportCampaignsBtn"><i class="fa-solid fa-file-export"></i> تصدير</button>
          <button class="btn-x btn-sm" id="newCampaignBtn"><i class="fa-solid fa-plus"></i> حملة جديدة</button>
        </div>
      </div>
      <main class="content ca-page">
        <section class="ca-hero fade-in">
          <div class="ca-hero-content">
            <div>
              <div class="ca-eyebrow">CAMPAIGN INTELLIGENCE</div>
              <h2>من الإنفاق إلى الأثر… كل حملة قابلة للقياس</h2>
              <p>اربط العوائد بالأكواد والمشاريع والفترة الزمنية، ثم اقرأ أثر الحملة على الإيرادات والمتبرعين والاستجابة من مكان واحد.</p>
            </div>
            <div class="ca-hero-stat"><small>العائد المجمع على التكلفة</small><strong id="heroRoas">—</strong></div>
          </div>
        </section>

        <div class="ca-view-switch" id="viewSwitch">
          <button class="active" data-view="campaigns"><i class="fa-solid fa-layer-group"></i> الحملات</button>
          <button data-view="codes"><i class="fa-solid fa-code-branch"></i> أكواد الإحالة</button>
        </div>

        <div id="schemaNotice"></div>
        <section id="campaignsView">
          <div class="ca-summary-grid" id="campaignSummary"></div>
          <div class="panel ca-filter-panel">
            <div class="ca-filter-grid">
              <div><label class="lbl">بحث</label><div class="ca-search"><i class="fa-solid fa-magnifying-glass"></i><input class="field" id="campaignSearch" placeholder="اسم الحملة أو القناة" /></div></div>
              <div><label class="lbl">طبيعة الحملة</label><select class="field" id="natureFilter"><option value="">الكل</option><option value="short">قصيرة</option><option value="ongoing">مستمرة</option><option value="seasonal">موسمية</option></select></div>
              <div><label class="lbl">الحالة</label><select class="field" id="statusFilter"><option value="">الكل</option><option value="active">نشطة</option><option value="ended">منتهية</option><option value="draft">مسودة</option><option value="paused">متوقفة</option></select></div>
              <div><label class="lbl">القناة</label><select class="field" id="channelFilter"><option value="">كل القنوات</option></select></div>
              <div class="ca-filter-actions"><button class="btn-x btn-ghost" id="resetFiltersBtn" title="مسح الفلاتر"><i class="fa-solid fa-rotate-left"></i></button></div>
            </div>
          </div>
          <div id="campaignList"></div>
        </section>
        <section id="detailView" class="hidden"></section>
        <section id="codesView" class="hidden"></section>
      </main>`;
  }

  function bindPageEvents() {
    document.getElementById('newCampaignBtn').addEventListener('click', () => openBuilder());
    document.getElementById('refreshCampaignsBtn').addEventListener('click', loadCampaigns);
    document.getElementById('exportCampaignsBtn').addEventListener('click', exportCampaigns);
    document.getElementById('resetFiltersBtn').addEventListener('click', resetFilters);
    document.getElementById('viewSwitch').addEventListener('click', e => {
      const btn = e.target.closest('[data-view]'); if (!btn) return;
      switchView(btn.dataset.view);
    });
    let timer;
    document.getElementById('campaignSearch').addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(loadCampaigns, 350); });
    ['natureFilter','statusFilter','channelFilter'].forEach(id => document.getElementById(id).addEventListener('change', loadCampaigns));
    document.getElementById('campaignList').addEventListener('click', e => {
      const card = e.target.closest('[data-campaign-id]');
      if (card) openDetail(card.dataset.campaignId);
    });
  }

  async function loadReferences() {
    const [projectsRes, channelsRes] = await Promise.all([
      App.sb.rpc('operations_projects'),
      App.sb.from('marketing_platforms').select('name,color').eq('is_active', true).order('name'),
    ]);
    if (!projectsRes.error) state.projects = projectsRes.data || [];
    if (!channelsRes.error) state.channels = channelsRes.data || [];
    if (!state.channels.length) state.channels = [
      { name:'واتس اب', color:'#25D366' }, { name:'Google', color:'#4285F4' },
      { name:'منصة X', color:'#1f2d2b' }, { name:'رسائل SMS', color:'#c79a3c' },
    ];
    const channelFilter = document.getElementById('channelFilter');
    channelFilter.innerHTML = '<option value="">كل القنوات</option>' + state.channels.map(c => `<option value="${App.esc(c.name)}">${App.esc(c.name)}</option>`).join('');
  }

  function currentFilters() {
    return {
      p_search: document.getElementById('campaignSearch').value.trim() || null,
      p_nature: document.getElementById('natureFilter').value || null,
      p_status: document.getElementById('statusFilter').value || null,
      p_channel: document.getElementById('channelFilter').value || null,
    };
  }

  async function loadCampaigns() {
    if (state.loading) return;
    state.loading = true;
    document.getElementById('campaignList').innerHTML = loadingBlock('جارٍ تحليل الحملات…');
    try {
      const { data, error } = await App.sb.rpc('marketing_campaign_analysis_list', currentFilters());
      if (error) throw error;
      state.campaigns = (data || []).map(normalizeCampaign);
      document.getElementById('schemaNotice').innerHTML = '';
      renderSummary();
      renderCampaigns();
    } catch (e) {
      if (isSchemaMissing(e)) renderSchemaNotice();
      else if (isStatementTimeout(e)) renderPerformanceNotice();
      document.getElementById('campaignList').innerHTML = emptyBlock('تعذّر تحميل الحملات', e.message || 'تحقق من تثبيت ملف SQL.');
    } finally { state.loading = false; }
  }

  function normalizeCampaign(r) {
    const numeric = ['target_amount','total_amount','donations_count','unique_donors','total_cost','net_return','roas','cost_revenue_percent','new_donors','returning_donors','targeted_count','respondents_count'];
    const out = { ...r }; numeric.forEach(k => out[k] = r[k] == null ? null : Number(r[k])); return out;
  }

  function renderSummary() {
    const rows = state.campaigns;
    const revenue = sum(rows, 'total_amount'), cost = sum(rows, 'total_cost'), net = revenue - cost;
    const active = rows.filter(x => x.status === 'active').length, roas = cost > 0 ? revenue / cost : null;
    document.getElementById('heroRoas').textContent = roas == null ? '—' : `${roas.toFixed(2)}x`;
    document.getElementById('campaignSummary').innerHTML = [
      miniKpi('الحملات الظاهرة', App.fmtNum(rows.length), 'fa-layer-group'),
      miniKpi('العوائد المنسوبة', `${App.fmtMoney(revenue)} ر.س`, 'fa-sack-dollar', true),
      miniKpi('إجمالي التكلفة', `${App.fmtMoney(cost)} ر.س`, 'fa-coins'),
      miniKpi('صافي العائد التسويقي', `${App.fmtMoney(net)} ر.س`, 'fa-arrow-trend-up', true),
      miniKpi('الحملات النشطة', App.fmtNum(active), 'fa-bolt'),
    ].join('');
  }

  function miniKpi(label, value, icon, gold=false) {
    return `<div class="ca-mini-kpi ${gold?'gold':''}"><div class="icon"><i class="fa-solid ${icon}"></i></div><small>${label}</small><strong>${value}</strong></div>`;
  }

  function renderCampaigns() {
    const area = document.getElementById('campaignList');
    if (!state.campaigns.length) {
      area.innerHTML = `<div class="panel ca-empty"><div class="orb"><i class="fa-solid fa-bullhorn"></i></div><h3>ابدأ بأول حملة قابلة للقياس</h3><p>أنشئ حملة وحدد الأكواد أو المشاريع المرتبطة بها، وسيتولى النظام قراءة النتائج.</p><button class="btn-x" onclick="document.getElementById('newCampaignBtn').click()"><i class="fa-solid fa-plus"></i> إنشاء حملة</button></div>`;
      return;
    }
    area.innerHTML = `<div class="ca-campaign-grid">${state.campaigns.map(campaignCard).join('')}</div>`;
  }

  function campaignCard(c) {
    const progress = c.target_amount > 0 ? Math.min(100, c.total_amount / c.target_amount * 100) : 0;
    const roas = c.roas == null ? '—' : `${c.roas.toFixed(2)}x`;
    const date = `${App.fmtDate(c.start_date)} — ${c.end_date ? App.fmtDate(c.end_date) : 'مستمرة'}`;
    return `<article class="ca-campaign-card" data-campaign-id="${c.id}">
      <div class="ca-card-accent"></div><div class="ca-card-body">
        <div class="ca-card-head"><div><h3 class="ca-card-title">${App.esc(c.name)}</h3><div class="ca-card-meta"><span><i class="fa-solid fa-tower-broadcast"></i> ${App.esc(c.channel)}</span><span><i class="fa-regular fa-calendar"></i> ${date}</span></div></div><span class="ca-status ${c.status}">${labels.status[c.status] || c.status}</span></div>
        <div class="ca-card-revenue"><small>العوائد المنسوبة</small><strong>${App.fmtMoney(c.total_amount)} <small>ر.س</small></strong></div>
        <div class="ca-card-stats"><div><span>العمليات</span><b>${App.fmtNum(c.donations_count)}</b></div><div><span>المتبرعون</span><b>${App.fmtNum(c.unique_donors)}</b></div><div><span>ROAS</span><b>${roas}</b></div></div>
        ${c.target_amount > 0 ? `<div class="ca-progress" title="تحقيق الهدف ${progress.toFixed(1)}%"><span style="width:${progress}%"></span></div>` : ''}
      </div></article>`;
  }

  async function openDetail(id) {
    state.currentId = id; state.detail = null; state.detailTab = 'overview';
    document.getElementById('campaignsView').classList.add('hidden');
    document.getElementById('viewSwitch').classList.add('hidden');
    const area = document.getElementById('detailView'); area.classList.remove('hidden'); area.innerHTML = loadingBlock('جارٍ بناء التقرير التفصيلي…');
    try {
      const { data, error } = await App.sb.rpc('marketing_campaign_analysis_detail', { p_campaign_id:id });
      if (error) throw error;
      state.detail = data; renderDetail();
    } catch (e) { area.innerHTML = emptyBlock('تعذّر فتح التقرير', e.message); }
  }

  function renderDetail() {
    const d = state.detail, c = d.campaign, m = numberObject(d.metrics), dm = numberObject(d.donors), t = numberObject(d.targeting);
    const rules = rulePills(c);
    document.getElementById('detailView').innerHTML = `
      <section class="ca-detail-head">
        <div class="ca-detail-head-top"><div>
          <button class="btn-x btn-sm ca-back" id="backToCampaigns"><i class="fa-solid fa-arrow-right"></i> كل الحملات</button>
          <h2>${App.esc(c.name)}</h2><div class="muted-light">${App.esc(c.channel)} · ${labels.nature[c.nature] || c.nature} · ${App.fmtDate(c.start_date)} — ${c.end_date ? App.fmtDate(c.end_date) : 'مستمرة'}</div>
          <div class="ca-rule-summary" style="margin-top:.7rem">${rules}</div>
        </div><div class="ca-card-actions"><button class="btn-x btn-gold btn-sm" id="editCampaignBtn"><i class="fa-solid fa-pen"></i> تعديل</button><button class="btn-x ca-back btn-sm" id="deleteCampaignBtn"><i class="fa-regular fa-trash-can"></i></button></div></div>
      </section>
      <div class="ca-detail-kpis">
        ${detailKpi('إجمالي العوائد المنسوبة', `${App.fmtMoney(m.total_amount)} ر.س`, 'من العمليات المطابقة')}
        ${detailKpi('عدد عمليات التبرع', App.fmtNum(m.donations_count), `متوسط ${App.fmtMoney(m.average_donation)} ر.س`)}
        ${detailKpi('المتبرعون الفريدون', App.fmtNum(m.unique_donors), `تكلفة المتبرع ${moneyOrDash(m.acquisition_cost)}`)}
        ${detailKpi('أكبر تبرع', `${App.fmtMoney(m.largest_donation)} ر.س`, 'ضمن مدة الحملة')}
        ${detailKpi('إجمالي التكلفة', `${App.fmtMoney(m.total_cost)} ر.س`, `${(m.cost_revenue_percent ?? 0).toFixed(1)}% من العوائد`)}
        ${detailKpi('صافي العائد التسويقي', `${App.fmtMoney(m.net_return)} ر.س`, 'العوائد ناقص التكلفة')}
        ${detailKpi('ROAS', m.roas == null ? '—' : `${m.roas.toFixed(2)}x`, 'العوائد ÷ التكلفة')}
        ${detailKpi('تحقيق الهدف', m.target_achievement_percent == null ? '—' : `${m.target_achievement_percent.toFixed(1)}%`, c.target_amount > 0 ? `الهدف ${App.fmtMoney(c.target_amount)} ر.س` : 'لم يحدد هدف')}
      </div>
      <div class="panel">
        <div class="panel-body">
          <div class="ca-tabs" id="detailTabs">
            <button class="active" data-tab="overview"><i class="fa-solid fa-chart-column"></i> الأداء</button>
            <button data-tab="donors"><i class="fa-solid fa-users"></i> المتبرعون</button>
            <button data-tab="targeting"><i class="fa-solid fa-bullseye"></i> الاستهداف</button>
            <button data-tab="rules"><i class="fa-solid fa-code-branch"></i> الربط والتكاليف</button>
          </div>
          <div id="detailTabContent">${renderOverview(d)}</div>
        </div>
      </div>`;
    document.getElementById('backToCampaigns').addEventListener('click', closeDetail);
    document.getElementById('editCampaignBtn').addEventListener('click', () => openBuilder(d));
    document.getElementById('deleteCampaignBtn').addEventListener('click', deleteCurrentCampaign);
    document.getElementById('detailTabs').addEventListener('click', e => {
      const btn = e.target.closest('[data-tab]'); if (!btn) return;
      state.detailTab = btn.dataset.tab;
      document.querySelectorAll('#detailTabs button').forEach(x => x.classList.toggle('active', x === btn));
      renderDetailTab();
    });
  }

  function renderDetailTab() {
    const area = document.getElementById('detailTabContent');
    const d = state.detail;
    area.innerHTML = state.detailTab === 'donors' ? renderDonors(d) : state.detailTab === 'targeting' ? renderTargeting(d) : state.detailTab === 'rules' ? renderRules(d) : renderOverview(d);
  }

  function detailKpi(label,value,hint) { return `<div class="ca-detail-kpi"><small>${label}</small><strong>${value}</strong><em>${hint}</em></div>`; }

  function renderOverview(d) {
    const daily = d.daily || [], projects = d.projects || [], codes = d.codes || [];
    return `<div class="ca-tab-pane active"><div class="ca-two-col">
      <div class="panel"><div class="panel-head"><h2>العوائد اليومية</h2><span class="muted">${App.fmtNum(daily.length)} يوم</span></div><div class="panel-body">${barChart(daily)}</div></div>
      <div class="panel"><div class="panel-head"><h2>المشاريع الأعلى عائدًا</h2></div><div class="panel-body">${rankList(projects)}</div></div>
    </div><div class="panel" style="margin-top:1rem"><div class="panel-head"><h2>أداء أكواد الإحالة</h2></div><div class="panel-body">${rankList(codes, 10)}</div></div></div>`;
  }

  function renderDonors(d) {
    const x = numberObject(d.donors), total = (x.new_donors || 0) + (x.returning_donors || 0);
    const newP = total ? x.new_donors / total * 100 : 0, oldP = total ? x.returning_donors / total * 100 : 0;
    return `<div class="ca-tab-pane active"><div class="ca-metric-sections">
      ${featureCard('متبرعون جدد', App.fmtNum(x.new_donors), `${(x.new_donors_percent || 0).toFixed(1)}% من المتبرعين`, 'fa-user-plus')}
      ${featureCard('متبرعون سابقون عادوا', App.fmtNum(x.returning_donors), 'سبق لهم التبرع قبل الحملة', 'fa-user-clock')}
      ${featureCard('تبرعوا أكثر من مرة', App.fmtNum(x.repeat_donors), 'داخل مدة الحملة', 'fa-repeat')}
      ${featureCard('متوسط تبرع الجديد', `${App.fmtMoney(x.avg_new_donation)} ر.س`, 'متوسط العملية', 'fa-hand-holding-dollar')}
      ${featureCard('متوسط تبرع السابق', `${App.fmtMoney(x.avg_returning_donation)} ر.س`, 'متوسط العملية', 'fa-chart-line')}
      ${featureCard('تبرعات لاحقة للحملة', `${App.fmtMoney(x.subsequent_amount)} ر.س`, `خلال ${App.fmtNum(d.campaign.post_campaign_days)} يومًا`, 'fa-forward')}
    </div><div class="panel" style="margin-top:1rem"><div class="panel-head"><h2>تركيبة المتبرعين</h2></div><div class="panel-body ca-compare">
      ${compareRow('جدد', x.new_donors, newP, false)}${compareRow('سابقون', x.returning_donors, oldP, true)}
    </div></div></div>`;
  }

  function renderTargeting(d) {
    const t = numberObject(d.targeting), cost = numberObject(d.metrics).total_cost;
    return `<div class="ca-tab-pane active"><div class="ca-metric-sections">
      ${featureCard('عدد المستهدفين', App.fmtNum(t.targeted_count), 'أرقام فريدة مرتبطة بالحملة', 'fa-crosshairs')}
      ${featureCard('المتبرعون المستجيبون', App.fmtNum(t.respondents_count), `${(t.response_rate || 0).toFixed(1)}% نسبة الاستجابة`, 'fa-circle-check')}
      ${featureCard('تكلفة الاستجابة', t.response_cost == null ? '—' : `${App.fmtMoney(t.response_cost)} ر.س`, 'التكلفة لكل عملية استجابة', 'fa-coins')}
      ${featureCard('تكلفة المتبرع المستجيب', t.respondent_donor_cost == null ? '—' : `${App.fmtMoney(t.respondent_donor_cost)} ر.س`, `من تكلفة ${App.fmtMoney(cost)} ر.س`, 'fa-user-check')}
      ${featureCard('متوسط زمن الاستجابة', durationHours(t.average_response_hours), 'من الاستهداف إلى أول تبرع', 'fa-clock')}
      ${featureCard('استجابة خلال 24 ساعة', App.fmtNum(t.response_24h), 'الأسرع استجابة', 'fa-bolt')}
      ${featureCard('نافذة الإسناد', `${App.fmtNum(d.campaign.attribution_days)} أيام`, 'المدة المعتمدة للاستجابة', 'fa-calendar-check')}
    </div><div class="panel" style="margin-top:1rem"><div class="panel-head"><h2>سرعة الاستجابة التراكمية</h2><span class="muted">المستهدف ← المتبرع</span></div><div class="panel-body">
      <div class="ca-funnel">${funnelStep('المستهدفون',t.targeted_count,'100%')}${funnelStep('خلال 24 ساعة',t.response_24h,rate(t.response_24h,t.targeted_count))}${funnelStep('خلال 3 أيام',t.response_3d,rate(t.response_3d,t.targeted_count))}${funnelStep('خلال 7 أيام',t.response_7d,rate(t.response_7d,t.targeted_count))}</div>
    </div></div></div>`;
  }

  function renderRules(d) {
    const c = d.campaign, costs = d.costs || [];
    return `<div class="ca-tab-pane active"><div class="ca-definition">
      ${defBox('الأكواد المحددة', c.exact_codes, 'fa-tag')}
      ${defBox('بادئات الأكواد', c.code_prefixes, 'fa-code')}
      ${defBox('المشاريع المشمولة', c.projects, 'fa-folder-open')}
      ${defBox('الاستثناءات', [...(c.excluded_codes||[]), ...(c.excluded_projects||[])], 'fa-filter-circle-xmark', true)}
    </div><div class="panel" style="margin-top:1rem"><div class="panel-head"><h2>بنود التكلفة</h2><strong>${App.fmtMoney(sum(costs,'amount'))} ر.س</strong></div><div class="panel-body">
      ${costs.length ? costs.map(x => `<div class="ca-cost-row-view"><span>${App.esc(x.category)}</span><span class="muted">${App.fmtDate(x.cost_date)}${x.note?` · ${App.esc(x.note)}`:''}</span><b>${App.fmtMoney(x.amount)} ر.س</b></div>`).join('') : '<div class="muted">لا توجد تكاليف مسجلة.</div>'}
    </div></div></div>`;
  }

  function featureCard(label,value,hint,icon) { return `<div class="ca-feature-card"><div class="feature-icon"><i class="fa-solid ${icon}"></i></div><small>${label}</small><strong>${value}</strong><div class="ca-help">${hint}</div></div>`; }
  function compareRow(label,n,p,gold) { return `<div class="ca-compare-row ${gold?'gold':''}"><div class="ca-compare-label"><span>${label}</span><b>${App.fmtNum(n)} · ${p.toFixed(1)}%</b></div><div class="ca-compare-track"><span style="width:${Math.min(100,p)}%"></span></div></div>`; }
  function funnelStep(label,n,hint) { return `<div class="ca-funnel-step"><div class="ca-funnel-block"><strong>${App.fmtNum(n)}</strong></div><small>${label}<br>${hint}</small></div>`; }
  function defBox(title,items,icon,exclude=false) { const list=items||[]; return `<div class="ca-def-box"><h4><i class="fa-solid ${icon} text-gold"></i> ${title}</h4>${list.length?list.map(x=>`<span class="ca-token ${exclude?'exclude':''}">${App.esc(x)}</span>`).join(''):'<span class="muted">لا يوجد</span>'}</div>`; }

  function barChart(rows) {
    if (!rows.length) return '<div class="ca-empty">لا توجد عوائد يومية ضمن قواعد الحملة.</div>';
    const max = Math.max(...rows.map(x => Number(x.amount || 0)), 1);
    return `<div class="ca-chart">${rows.map(x => { const h=Math.max(2,Number(x.amount||0)/max*155); return `<div class="ca-bar-col"><div class="ca-bar" style="height:${h}px" data-value="${App.fmtMoney(x.amount)} ر.س"></div><span class="ca-bar-label">${shortDate(x.day)}</span></div>`; }).join('')}</div>`;
  }

  function rankList(rows,limit=6) {
    if (!rows.length) return '<div class="ca-empty" style="padding:1rem">لا توجد بيانات.</div>';
    const shown=rows.slice(0,limit), max=Math.max(...shown.map(x=>Number(x.amount||0)),1);
    return `<div class="ca-rank-list">${shown.map(x=>`<div class="ca-rank-row"><span class="ca-rank-name" title="${App.esc(x.label)}">${App.esc(x.label)}</span><div class="ca-rank-track"><span style="width:${Number(x.amount||0)/max*100}%"></span></div><span class="ca-rank-value">${App.fmtMoney(x.amount)} ر.س</span></div>`).join('')}</div>`;
  }

  function rulePills(c) {
    const out=[];
    if (c.exact_codes?.length) out.push(`<span class="ca-rule-pill"><i class="fa-solid fa-tag"></i> ${c.exact_codes.length} كود</span>`);
    if (c.code_prefixes?.length) out.push(`<span class="ca-rule-pill"><i class="fa-solid fa-code"></i> ${c.code_prefixes.length} بادئة</span>`);
    if (c.projects?.length) out.push(`<span class="ca-rule-pill"><i class="fa-solid fa-folder"></i> ${c.projects.length} مشروع</span>`);
    out.push(`<span class="ca-rule-pill"><i class="fa-solid fa-link"></i> ${c.match_mode==='all'?'جميع الشروط':'أي شرط'}</span>`);
    return out.join('');
  }

  function closeDetail() {
    state.currentId=null; state.detail=null;
    document.getElementById('detailView').classList.add('hidden');
    document.getElementById('campaignsView').classList.remove('hidden');
    document.getElementById('viewSwitch').classList.remove('hidden');
  }

  async function deleteCurrentCampaign() {
    if (!state.detail || !confirm(`حذف حملة "${state.detail.campaign.name}"؟ لن تُحذف أي عمليات تبرع.`)) return;
    try {
      const { error } = await App.sb.rpc('delete_marketing_campaign', { p_campaign_id:state.currentId });
      if (error) throw error; App.toast('تم حذف الحملة دون المساس بالعمليات.', 'ok'); closeDetail(); await loadCampaigns();
    } catch(e) { App.toast(e.message || 'تعذر حذف الحملة','err'); }
  }

  // -------------------------------------------------------------------
  // منشئ الحملات
  // -------------------------------------------------------------------
  function blankDraft() {
    const now = new Date(), today = now.toISOString().slice(0,10);
    return { id:null,name:'',nature:'short',channel:state.channels[0]?.name||'واتس اب',status:'active',start_date:today,end_date:today,target_amount:0,attribution_days:7,post_campaign_days:30,match_mode:'all',exact_codes:[],code_prefixes:[],projects:[],excluded_codes:[],excluded_projects:[],notes:'',costs:[] };
  }

  function openBuilder(detail=null) {
    const c = detail?.campaign;
    state.draft = c ? { ...blankDraft(), ...c, exact_codes:[...(c.exact_codes||[])],code_prefixes:[...(c.code_prefixes||[])],projects:[...(c.projects||[])],excluded_codes:[...(c.excluded_codes||[])],excluded_projects:[...(c.excluded_projects||[])],costs:(detail.costs||[]).map(x=>({cost_date:x.cost_date,category:x.category,amount:Number(x.amount),note:x.note||''})) } : blankDraft();
    state.preview = null;
    const modal=document.createElement('div'); modal.className='ca-modal'; modal.id='campaignBuilder'; modal.innerHTML=builderHtml(Boolean(c)); document.body.appendChild(modal); bindBuilder(); renderDraftControls();
  }

  function builderHtml(editing) {
    const channelNames = state.channels.map(x => x.name);
    if (state.draft?.channel && !channelNames.includes(state.draft.channel)) channelNames.push(state.draft.channel);
    return `<div class="ca-modal-card">
      <div class="ca-modal-head"><div><div class="ca-eyebrow" style="color:var(--c-gold)">${editing?'EDIT CAMPAIGN':'NEW CAMPAIGN'}</div><h3>${editing?'تعديل الحملة':'بناء حملة قابلة للقياس'}</h3></div><button class="btn-x btn-ghost btn-sm" id="closeBuilder"><i class="fa-solid fa-xmark"></i></button></div>
      <div class="ca-modal-body">
        <section class="ca-step"><div class="ca-step-head"><span class="ca-step-no">1</span><h4>تعريف الحملة</h4></div><div class="ca-step-body"><div class="ca-form-grid">
          <div class="ca-span-2"><label class="lbl">اسم الحملة</label><input class="field" id="dName" placeholder="مثال: رسالة السلة الرمضانية" /></div>
          <div><label class="lbl">القناة التسويقية</label><select class="field" id="dChannel">${channelNames.map(x=>`<option>${App.esc(x)}</option>`).join('')}</select></div>
          <div><label class="lbl">طبيعة الحملة</label><div class="ca-segment" data-segment="nature"><button data-value="short">قصيرة</button><button data-value="ongoing">مستمرة</button><button data-value="seasonal">موسمية</button></div></div>
          <div><label class="lbl">الحالة</label><select class="field" id="dStatus"><option value="active">نشطة</option><option value="draft">مسودة</option><option value="ended">منتهية</option><option value="paused">متوقفة</option></select></div>
          <div><label class="lbl">هدف العوائد</label><input class="field" id="dTarget" type="number" min="0" step="0.01" /></div>
          <div><label class="lbl">تاريخ البداية</label><input class="field" id="dStart" type="date" /></div>
          <div><label class="lbl">تاريخ النهاية</label><input class="field" id="dEnd" type="date" /><div class="ca-help">يمكن تركه فارغًا للحملة المستمرة.</div></div>
          <div><label class="lbl">ملاحظات</label><input class="field" id="dNotes" placeholder="اختياري" /></div>
        </div></div></section>

        <section class="ca-step"><div class="ca-step-head"><span class="ca-step-no">2</span><h4>قواعد ربط التبرعات</h4></div><div class="ca-step-body">
          <div class="ca-form-grid"><div class="ca-span-3"><label class="lbl">طريقة الجمع بين مجموعات الشروط</label><div class="ca-segment" data-segment="match_mode"><button data-value="all">يجب تحقق جميع المجموعات (و)</button><button data-value="any">يكفي تحقق أي مجموعة (أو)</button></div><div class="ca-help">الأكواد داخل المجموعة الواحدة بدائل، وكذلك المشاريع. الفترة الزمنية مطبقة دائمًا.</div></div>
          ${tagField('exact_codes','أكواد محددة','مثال: WHTS-RMD-01','أضف كودًا واحدًا أو عدة أكواد')}
          ${tagField('code_prefixes','بادئات الأكواد','مثال: WHTS','يطابق كل كود يبدأ بهذه القيمة')}
          <div class="ca-span-3"><label class="lbl">المشاريع المشمولة</label>${projectPicker('projects','projectSearch')}</div>
          ${tagField('excluded_codes','أكواد مستبعدة','اكتب الكود المستبعد','تُستبعد حتى لو طابقت البادئة',true)}
          <div class="ca-span-3"><label class="lbl">مشاريع مستبعدة</label>${projectPicker('excluded_projects','excludedProjectSearch',true)}</div>
          </div>
        </div></section>

        <section class="ca-step"><div class="ca-step-head"><span class="ca-step-no">3</span><h4>الاستجابة والتكاليف</h4></div><div class="ca-step-body"><div class="ca-form-grid">
          <div><label class="lbl">نافذة الاستجابة بعد الاستهداف</label><input class="field" id="dAttribution" type="number" min="1" max="365" /><div class="ca-help">عدد الأيام التي يُعد التبرع خلالها استجابة.</div></div>
          <div><label class="lbl">متابعة التبرعات اللاحقة</label><input class="field" id="dPostDays" type="number" min="0" max="730" /><div class="ca-help">بعد نهاية الحملة.</div></div>
          <div class="ca-span-3"><div class="ca-inline" style="justify-content:space-between"><label class="lbl">بنود التكلفة</label><button class="btn-x btn-ghost btn-sm" id="addCostBtn"><i class="fa-solid fa-plus"></i> إضافة تكلفة</button></div><div class="ca-cost-table" id="costRows"></div></div>
        </div></div></section>
      </div>
      <div class="ca-modal-footer"><div id="previewArea" class="muted">عاين المطابقة قبل الحفظ للتأكد من القواعد.</div><div class="ca-modal-actions"><button class="btn-x btn-ghost" id="previewBtn"><i class="fa-solid fa-wand-magic-sparkles"></i> معاينة النتائج</button><button class="btn-x" id="saveCampaignBtn"><i class="fa-solid fa-floppy-disk"></i> حفظ الحملة</button></div></div>
    </div>`;
  }

  function tagField(key,label,placeholder,help,exclude=false) {
    return `<div class="ca-span-3"><label class="lbl">${label}</label><div class="ca-tag-input"><input class="field" id="tagInput_${key}" placeholder="${placeholder}" /><button class="btn-x btn-ghost" data-add-tag="${key}" type="button"><i class="fa-solid fa-plus"></i></button></div><div class="ca-help">${help} — اضغط Enter للإضافة.</div><div class="ca-selected-list" id="tagList_${key}" data-exclude="${exclude?'1':'0'}"></div></div>`;
  }

  function projectPicker(key,searchId,exclude=false) {
    return `<div class="ca-project-picker" data-picker="${key}" data-exclude="${exclude?'1':'0'}"><input class="field picker-search" id="${searchId}" placeholder="ابحث عن مشروع…" /><div class="ca-project-options" id="options_${key}"></div></div><div class="ca-selected-list" id="selected_${key}"></div>`;
  }

  function bindBuilder() {
    const modal=document.getElementById('campaignBuilder');
    document.getElementById('closeBuilder').addEventListener('click',closeBuilder);
    modal.addEventListener('click',e=>{ if(e.target===modal) closeBuilder(); });
    modal.querySelectorAll('[data-segment] button').forEach(b=>b.addEventListener('click',()=>{ state.draft[b.parentElement.dataset.segment]=b.dataset.value; renderDraftControls(); }));
    ['dName','dChannel','dStatus','dTarget','dStart','dEnd','dNotes','dAttribution','dPostDays'].forEach(id=>document.getElementById(id).addEventListener('input',syncDraft));
    modal.querySelectorAll('[data-add-tag]').forEach(b=>b.addEventListener('click',()=>addTags(b.dataset.addTag)));
    ['exact_codes','code_prefixes','excluded_codes'].forEach(k=>document.getElementById(`tagInput_${k}`).addEventListener('keydown',e=>{ if(e.key==='Enter'){e.preventDefault();addTags(k);} }));
    ['projects','excluded_projects'].forEach(k=>document.getElementById(k==='projects'?'projectSearch':'excludedProjectSearch').addEventListener('input',()=>renderProjectOptions(k)));
    document.getElementById('addCostBtn').addEventListener('click',()=>{ syncDraft();state.draft.costs.push({cost_date:state.draft.start_date,category:'إعلانات',amount:0,note:''});renderCosts(); });
    document.getElementById('costRows').addEventListener('input',syncCosts);
    document.getElementById('costRows').addEventListener('click',e=>{const b=e.target.closest('[data-remove-cost]');if(b){state.draft.costs.splice(Number(b.dataset.removeCost),1);renderCosts();}});
    document.getElementById('previewBtn').addEventListener('click',previewCampaign);
    document.getElementById('saveCampaignBtn').addEventListener('click',saveCampaign);
  }

  function renderDraftControls() {
    const d=state.draft;
    setValue('dName',d.name);setValue('dChannel',d.channel);setValue('dStatus',d.status);setValue('dTarget',d.target_amount);setValue('dStart',d.start_date);setValue('dEnd',d.end_date||'');setValue('dNotes',d.notes||'');setValue('dAttribution',d.attribution_days);setValue('dPostDays',d.post_campaign_days);
    document.querySelectorAll('[data-segment]').forEach(s=>s.querySelectorAll('button').forEach(b=>b.classList.toggle('on',b.dataset.value===d[s.dataset.segment])));
    ['exact_codes','code_prefixes','excluded_codes'].forEach(renderTagList);
    ['projects','excluded_projects'].forEach(k=>{renderProjectOptions(k);renderSelectedProjects(k);});
    renderCosts();
  }

  function syncDraft() {
    const d=state.draft; d.name=value('dName');d.channel=value('dChannel');d.status=value('dStatus');d.target_amount=Number(value('dTarget')||0);d.start_date=value('dStart');d.end_date=value('dEnd')||null;d.notes=value('dNotes');d.attribution_days=Number(value('dAttribution')||7);d.post_campaign_days=Number(value('dPostDays')||0);
  }

  function addTags(key) {
    const input=document.getElementById(`tagInput_${key}`),vals=input.value.split(/[،,\n]+/).map(x=>x.trim()).filter(Boolean);
    vals.forEach(v=>{if(!state.draft[key].some(x=>x.toLowerCase()===v.toLowerCase()))state.draft[key].push(v);}); input.value='';renderTagList(key);
  }

  function renderTagList(key) {
    const area=document.getElementById(`tagList_${key}`); if(!area)return;
    area.innerHTML=state.draft[key].map((x,i)=>`<span class="ca-token ${area.dataset.exclude==='1'?'exclude':''}">${App.esc(x)} <button data-remove-tag="${key}" data-index="${i}"><i class="fa-solid fa-xmark"></i></button></span>`).join('');
    area.querySelectorAll('[data-remove-tag]').forEach(b=>b.addEventListener('click',()=>{state.draft[key].splice(Number(b.dataset.index),1);renderTagList(key);}));
  }

  function renderProjectOptions(key) {
    const search=document.getElementById(key==='projects'?'projectSearch':'excludedProjectSearch')?.value.toLowerCase()||'';
    const area=document.getElementById(`options_${key}`);if(!area)return;
    const rows=state.projects.filter(x=>!search||x.toLowerCase().includes(search)).slice(0,120);
    area.innerHTML=rows.length?rows.map((p,i)=>{const checked=state.draft[key].some(x=>x.toLowerCase()===p.toLowerCase());return `<label class="ca-project-option"><input type="checkbox" data-project-key="${key}" data-project-idx="${i}" ${checked?'checked':''}/><span>${App.esc(p)}</span></label>`;}).join(''):'<div class="muted" style="padding:.5rem">لا توجد نتيجة.</div>';
    area.querySelectorAll('[data-project-key]').forEach((box,i)=>box.addEventListener('change',()=>{const p=rows[i]; if(box.checked){if(!state.draft[key].includes(p))state.draft[key].push(p);}else state.draft[key]=state.draft[key].filter(x=>x!==p);renderSelectedProjects(key);}));
  }

  function renderSelectedProjects(key) {
    const area=document.getElementById(`selected_${key}`);if(!area)return;
    area.innerHTML=state.draft[key].map((x,i)=>`<span class="ca-token ${key==='excluded_projects'?'exclude':''}">${App.esc(x)} <button data-rm-project="${i}" style="border:0;background:transparent;color:inherit"><i class="fa-solid fa-xmark"></i></button></span>`).join('');
    area.querySelectorAll('[data-rm-project]').forEach(b=>b.addEventListener('click',()=>{state.draft[key].splice(Number(b.dataset.rmProject),1);renderProjectOptions(key);renderSelectedProjects(key);}));
  }

  function renderCosts() {
    const area=document.getElementById('costRows');if(!area)return;
    area.innerHTML=state.draft.costs.length?state.draft.costs.map((x,i)=>`<div class="ca-cost-edit-row" data-cost-index="${i}"><input class="field" type="date" data-cost-field="cost_date" value="${App.esc(x.cost_date||state.draft.start_date||'')}"/><input class="field" data-cost-field="category" value="${App.esc(x.category||'إعلانات')}" placeholder="نوع التكلفة"/><input class="field cost-amount" type="number" min="0" step="0.01" data-cost-field="amount" value="${Number(x.amount||0)}" placeholder="المبلغ"/><input class="field cost-note" data-cost-field="note" value="${App.esc(x.note||'')}" placeholder="ملاحظة اختيارية"/><button class="btn-x btn-ghost" data-remove-cost="${i}"><i class="fa-regular fa-trash-can"></i></button></div>`).join(''):'<div class="muted">لا توجد تكاليف. يمكن حفظ الحملة ثم إضافة التكلفة لاحقًا.</div>';
  }

  function syncCosts() {
    document.querySelectorAll('[data-cost-index]').forEach(row=>{const x=state.draft.costs[Number(row.dataset.costIndex)];row.querySelectorAll('[data-cost-field]').forEach(el=>x[el.dataset.costField]=el.dataset.costField==='amount'?Number(el.value||0):el.value);});
  }

  async function previewCampaign() {
    syncDraft();syncCosts();
    const err=validateDraft();if(err){App.toast(err,'err');return;}
    const btn=document.getElementById('previewBtn'),old=btn.innerHTML;btn.disabled=true;btn.innerHTML='<span class="spinner-x"></span> تحليل';
    try {
      const d=state.draft,{data,error}=await App.sb.rpc('campaign_match_preview',{p_start_date:d.start_date,p_end_date:d.end_date,p_match_mode:d.match_mode,p_exact_codes:d.exact_codes,p_code_prefixes:d.code_prefixes,p_projects:d.projects,p_excluded_codes:d.excluded_codes,p_excluded_projects:d.excluded_projects});
      if(error)throw error;state.preview=numberObject(data);renderPreview();
    }catch(e){App.toast(e.message||'تعذرت المعاينة','err');}finally{btn.disabled=false;btn.innerHTML=old;}
  }

  function renderPreview() {
    const p=state.preview;document.getElementById('previewArea').innerHTML=`<div class="ca-preview"><div><small>العوائد المطابقة</small><b>${App.fmtMoney(p.total_amount)} ر.س</b></div><div><small>العمليات</small><b>${App.fmtNum(p.donations_count)}</b></div><div><small>المتبرعون</small><b>${App.fmtNum(p.unique_donors)}</b></div></div>`;
  }

  function validateDraft() {
    const d=state.draft;if(!d.name.trim())return'اكتب اسم الحملة.';if(!d.channel.trim())return'اختر القناة التسويقية.';if(!d.start_date)return'حدد تاريخ البداية.';if(d.end_date&&d.end_date<d.start_date)return'تاريخ النهاية يسبق البداية.';if(!d.exact_codes.length&&!d.code_prefixes.length&&!d.projects.length)return'أضف كودًا أو بادئة أو مشروعًا واحدًا على الأقل.';return'';
  }

  async function saveCampaign() {
    syncDraft();syncCosts();const err=validateDraft();if(err){App.toast(err,'err');return;}
    const btn=document.getElementById('saveCampaignBtn'),old=btn.innerHTML;btn.disabled=true;btn.innerHTML='<span class="spinner-x"></span> حفظ';
    try {
      const wasEditing = Boolean(state.draft.id);
      const {data,error}=await App.sb.rpc('save_marketing_campaign',{p_payload:state.draft});if(error)throw error;
      const id=data;closeBuilder();App.toast(wasEditing?'تم تحديث الحملة.':'تم إنشاء الحملة.','ok');await loadCampaigns();await openDetail(id);
    }catch(e){App.toast(e.message||'تعذر حفظ الحملة','err');btn.disabled=false;btn.innerHTML=old;}
  }

  function closeBuilder(){document.getElementById('campaignBuilder')?.remove();state.draft=null;state.preview=null;}

  // -------------------------------------------------------------------
  // التحليل السابق لأكواد الإحالة
  // -------------------------------------------------------------------
  async function switchView(view) {
    state.view=view;document.querySelectorAll('#viewSwitch [data-view]').forEach(b=>b.classList.toggle('active',b.dataset.view===view));
    document.getElementById('campaignsView').classList.toggle('hidden',view!=='campaigns');document.getElementById('codesView').classList.toggle('hidden',view!=='codes');
    if(view==='codes')await loadLegacyCodes();
  }

  async function loadLegacyCodes() {
    const area=document.getElementById('codesView');area.innerHTML=loadingBlock('جارٍ تحليل أكواد الإحالة…');
    const y=new Date().getFullYear();
    try{const{data,error}=await App.sb.rpc('referral_code_analysis',{p_from:`${y}-01-01`,p_to:new Date().toISOString().slice(0,10),p_project:null,p_search:null});if(error)throw error;state.legacyRows=(data||[]).map(x=>({...x,total_amount:Number(x.total_amount||0),cost:Number(x.cost||0),unique_donors:Number(x.unique_donors||0),donations_count:Number(x.donations_count||0)}));renderLegacyCodes();}catch(e){area.innerHTML=emptyBlock('تعذر تحليل الأكواد',e.message);}
  }

  function renderLegacyCodes() {
    const rows=state.legacyRows,amount=sum(rows,'total_amount');document.getElementById('codesView').innerHTML=`<div class="panel"><div class="panel-head"><div><h2>استكشاف أكواد الإحالة</h2><div class="muted">عرض تشغيلي مستقل عن الحملات · السنة الحالية</div></div><strong>${App.fmtMoney(amount)} ر.س</strong></div><div class="panel-body"><div class="table-wrap"><table class="data"><thead><tr><th>الكود</th><th>المشاريع</th><th>العوائد</th><th>العمليات</th><th>متبرعون فريدون</th><th>التكلفة</th><th>ROAS</th></tr></thead><tbody>${rows.map(r=>`<tr><td dir="ltr">${App.esc(r.referral_code)}</td><td>${App.fmtNum((r.projects||[]).length)} مشروع</td><td>${App.fmtMoney(r.total_amount)} ر.س</td><td>${App.fmtNum(r.donations_count)}</td><td>${App.fmtNum(r.unique_donors)}</td><td>${App.fmtMoney(r.cost)} ر.س</td><td>${r.cost>0?(r.total_amount/r.cost).toFixed(2)+'x':'—'}</td></tr>`).join('')}</tbody></table></div></div></div>`;
  }

  function resetFilters(){['campaignSearch','natureFilter','statusFilter','channelFilter'].forEach(id=>document.getElementById(id).value='');loadCampaigns();}
  function exportCampaigns(){if(!state.campaigns.length){App.toast('لا توجد حملات للتصدير.','err');return;}App.downloadCsv('marketing-campaigns-analysis.csv',state.campaigns.map(c=>({'الحملة':c.name,'الطبيعة':labels.nature[c.nature]||c.nature,'القناة':c.channel,'الحالة':labels.status[c.status]||c.status,'البداية':c.start_date,'النهاية':c.end_date||'مستمرة','العوائد المنسوبة':c.total_amount,'عدد العمليات':c.donations_count,'المتبرعون الفريدون':c.unique_donors,'التكلفة':c.total_cost,'صافي العائد':c.net_return,'ROAS':c.roas??'','نسبة التكلفة من العوائد':c.cost_revenue_percent??'','متبرعون جدد':c.new_donors,'متبرعون سابقون':c.returning_donors,'المستهدفون':c.targeted_count,'المستجيبون':c.respondents_count})));}

  function renderSchemaNotice(){document.getElementById('schemaNotice').innerHTML=`<div class="ca-install"><i class="fa-solid fa-screwdriver-wrench"></i><div><b>يلزم تثبيت محرك تحليل الحملات الجديد</b><div>شغّل الملف <span dir="ltr">supabase/campaign_analysis_v2.sql</span> مرة واحدة في SQL Editor، ثم حدّث الصفحة.</div></div></div>`;}
  function renderPerformanceNotice(){document.getElementById('schemaNotice').innerHTML=`<div class="ca-install"><i class="fa-solid fa-gauge-high"></i><div><b>يلزم تثبيت تحسين الأداء v2.2</b><div>شغّل الملف <span dir="ltr">supabase/campaign_analysis_v2_2_cache_fix.sql</span> مرة واحدة في SQL Editor، وانتظر رسالة Success ثم اضغط تحديث التحليل.</div></div></div>`;}
  function isSchemaMissing(e){return ['PGRST202','42883','42P01'].includes(e?.code)||/marketing_campaign|schema cache|function/i.test(e?.message||'');}
  function isStatementTimeout(e){return e?.code==='57014'||/statement timeout|canceling statement/i.test(e?.message||'');}
  function loadingBlock(text){return `<div class="panel center-load"><div class="spinner-x spinner-dark" style="width:32px;height:32px"></div><div class="muted" style="margin-top:.65rem">${text}</div></div>`;}
  function emptyBlock(title,msg=''){return `<div class="panel ca-empty"><div class="orb"><i class="fa-solid fa-triangle-exclamation"></i></div><h3>${App.esc(title)}</h3><p>${App.esc(msg)}</p></div>`;}
  function numberObject(obj){const out={...(obj||{})};Object.keys(out).forEach(k=>{if(out[k]!==null&&out[k]!==''&&!Number.isNaN(Number(out[k])))out[k]=Number(out[k]);});return out;}
  function sum(rows,key){return (rows||[]).reduce((s,x)=>s+Number(x[key]||0),0);}
  function rate(a,b){return b?`${(a/b*100).toFixed(1)}%`:'0%';}
  function durationHours(h){h=Number(h||0);if(!h)return'—';if(h<24)return`${h.toFixed(1)} ساعة`;return`${(h/24).toFixed(1)} يوم`;}
  function moneyOrDash(n){return n==null?'—':`${App.fmtMoney(n)} ر.س`;}
  function shortDate(s){if(!s)return'';const d=new Date(`${s}T00:00:00`);return `${d.getDate()}/${d.getMonth()+1}`;}
  function value(id){return document.getElementById(id)?.value||'';}
  function setValue(id,v){const el=document.getElementById(id);if(el&&document.activeElement!==el)el.value=v??'';}
})();
