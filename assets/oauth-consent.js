(() => {
  const params = new URLSearchParams(location.search);
  const authorizationId = params.get('authorization_id');
  const status = document.getElementById('oauthStatus');
  const details = document.getElementById('oauthDetails');
  const errorBox = document.getElementById('oauthError');
  const approve = document.getElementById('approveOAuth');
  const deny = document.getElementById('denyOAuth');

  const fail = message => {
    status.classList.add('hidden');
    details.classList.add('hidden');
    errorBox.textContent = message;
    errorBox.classList.remove('hidden');
  };

  const busy = (button, text) => {
    approve.disabled = true;
    deny.disabled = true;
    button.innerHTML = `<span class="spinner-x"></span><span>${App.esc(text)}</span>`;
  };

  async function decide(allowed) {
    const button = allowed ? approve : deny;
    busy(button, allowed ? 'جارٍ السماح...' : 'جارٍ الرفض...');
    const action = allowed
      ? App.sb.auth.oauth.approveAuthorization(authorizationId, { skipBrowserRedirect: true })
      : App.sb.auth.oauth.denyAuthorization(authorizationId, { skipBrowserRedirect: true });
    const { data, error } = await action;
    if (error || !data?.redirect_url) {
      fail(error?.message || 'تعذر إكمال قرار الربط. أعد المحاولة من التطبيق.');
      return;
    }
    location.replace(data.redirect_url);
  }

  (async () => {
    if (!authorizationId) {
      fail('طلب الربط غير مكتمل: authorization_id غير موجود. ابدأ الربط من ChatGPT أو Claude.');
      return;
    }

    const { data: sessionData } = await App.sb.auth.getSession();
    if (!sessionData.session) {
      const returnPath = `${location.pathname}${location.search}`;
      location.replace(`login.html?return=${encodeURIComponent(returnPath)}`);
      return;
    }

    let context;
    try {
      context = await App.loadAccessContext(true);
    } catch (_) {
      fail('تعذر التحقق من صلاحيات الحساب.');
      return;
    }
    if (!context?.organization || !context?.subscription_valid) {
      fail('الحساب غير مرتبط بجمعية فعّالة أو أن الاشتراك منتهي.');
      return;
    }

    const { data, error } = await App.sb.auth.oauth.getAuthorizationDetails(authorizationId);
    if (error || !data) {
      fail(error?.message || 'طلب الربط غير صالح أو انتهت صلاحيته.');
      return;
    }
    if (!data.authorization_id && data.redirect_url) {
      location.replace(data.redirect_url);
      return;
    }

    document.getElementById('oauthClientName').textContent = data.client?.name || 'تطبيق ذكاء اصطناعي';
    document.getElementById('oauthOrganization').textContent = context.organization.name;
    status.textContent = 'راجع الطلب ثم اختر السماح أو الرفض.';
    details.classList.remove('hidden');
    approve.onclick = () => decide(true);
    deny.onclick = () => decide(false);
  })().catch(error => fail(error?.message || 'حدث خطأ غير متوقع أثناء الربط.'));
})();
