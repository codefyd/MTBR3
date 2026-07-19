import { createClient } from 'npm:@supabase/supabase-js@2.45.4'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const ALL_PAGES = [
  'dashboard','reports','targets','donors','operations',
  'campaign_analysis','campaign_targets','marketing_content','settings',
]

const json = (body: unknown, status = 200, origin = '*') => new Response(JSON.stringify(body), {
  status,
  headers: {
    'content-type': 'application/json; charset=utf-8',
    'access-control-allow-origin': origin,
    'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
    'access-control-allow-methods': 'POST, OPTIONS',
    'vary': 'Origin',
  },
})

const cleanPages = (value: unknown) => {
  const pages = Array.isArray(value) ? value.map(String) : []
  return [...new Set(pages.filter(page => ALL_PAGES.includes(page)))]
}

const normalizeEmail = (value: unknown) => String(value ?? '').trim().toLowerCase()
const requireText = (value: unknown, label: string) => {
  const text = String(value ?? '').trim()
  if (!text) throw new Error(`${label} مطلوب`)
  return text
}

const slugify = (name: string) => {
  const base = name.toLowerCase().normalize('NFKD')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 42)
  return `${base || 'org'}-${crypto.randomUUID().slice(0, 8)}`
}

const sha256 = async (value: string) => {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return [...new Uint8Array(bytes)].map(x => x.toString(16).padStart(2, '0')).join('')
}

const randomToken = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(32))
  const secret = btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replaceAll('=','')
  return `wlmcp_${secret}`
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('origin') || '*'
  if (req.method === 'OPTIONS') return json({ ok: true }, 200, origin)
  if (req.method !== 'POST') return json({ ok: false, error: 'Method not allowed' }, 405, origin)

  const service = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  try {
    const authorization = req.headers.get('authorization') || ''
    const jwt = authorization.replace(/^Bearer\s+/i, '')
    if (!jwt) return json({ ok: false, error: 'غير مصرح' }, 401, origin)

    const { data: authData, error: authError } = await service.auth.getUser(jwt)
    if (authError || !authData.user) return json({ ok: false, error: 'جلسة غير صالحة' }, 401, origin)
    const actor = authData.user

    const { data: admin } = await service.from('platform_admins')
      .select('user_id').eq('user_id', actor.id).maybeSingle()
    if (!admin) return json({ ok: false, error: 'هذه الصفحة لمدير المنصة فقط' }, 403, origin)

    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const action = String(body.action || '')

    if (action === 'list') {
      const [orgsResult, membersResult, tokensResult, usersResult] = await Promise.all([
        service.from('organizations').select('*').order('created_at', { ascending: false }),
        service.from('organization_members').select('*').order('created_at'),
        service.from('mcp_access_tokens').select('id,organization_id,user_id,name,token_prefix,allowed_tools,expires_at,last_used_at,revoked_at,created_at').order('created_at', { ascending: false }),
        service.auth.admin.listUsers({ page: 1, perPage: 1000 }),
      ])
      if (orgsResult.error) throw orgsResult.error
      if (membersResult.error) throw membersResult.error
      if (tokensResult.error) throw tokensResult.error
      if (usersResult.error) throw usersResult.error
      const emails = new Map(usersResult.data.users.map(user => [user.id, user.email || '']))
      const memberships = (membersResult.data || []).map(row => ({ ...row, email: emails.get(row.user_id) || '' }))
      return json({
        ok: true,
        organizations: orgsResult.data || [],
        memberships,
        tokens: tokensResult.data || [],
        mcp_url: `${SUPABASE_URL}/functions/v1/mcp`,
      }, 200, origin)
    }

    if (action === 'create_organization') {
      const name = requireText(body.name, 'اسم الجمعية')
      const contactEmail = normalizeEmail(body.contact_email)
      const ownerEmail = normalizeEmail(body.owner_email)
      const password = requireText(body.temporary_password, 'كلمة المرور المؤقتة')
      const subscriptionEndsAt = requireText(body.subscription_ends_at, 'تاريخ نهاية الاشتراك')
      if (password.length < 10) throw new Error('كلمة المرور المؤقتة يجب ألا تقل عن 10 أحرف')

      const existing = await service.auth.admin.listUsers({ page: 1, perPage: 1000 })
      if (existing.error) throw existing.error
      let user = existing.data.users.find(item => item.email?.toLowerCase() === ownerEmail)
      let createdUser = false
      if (!user) {
        const created = await service.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true })
        if (created.error || !created.data.user) throw created.error || new Error('تعذر إنشاء المستخدم')
        user = created.data.user
        createdUser = true
      }

      const orgInsert = await service.from('organizations').insert({
        name, slug: slugify(name), contact_email: contactEmail,
        subscription_ends_at: subscriptionEndsAt, is_active: true,
      }).select('*').single()
      if (orgInsert.error) {
        if (createdUser) await service.auth.admin.deleteUser(user.id)
        throw orgInsert.error
      }

      const memberInsert = await service.from('organization_members').insert({
        organization_id: orgInsert.data.id,
        user_id: user.id,
        role: 'owner',
        allowed_pages: cleanPages(body.allowed_pages),
        is_active: true,
      })
      if (memberInsert.error) {
        await service.from('organizations').delete().eq('id', orgInsert.data.id)
        if (createdUser) await service.auth.admin.deleteUser(user.id)
        throw memberInsert.error
      }
      return json({ ok: true, organization: orgInsert.data, user_id: user.id }, 200, origin)
    }

    if (action === 'update_organization') {
      const organizationId = requireText(body.organization_id, 'معرف الجمعية')
      const update = await service.from('organizations').update({
        name: requireText(body.name, 'اسم الجمعية'),
        contact_email: normalizeEmail(body.contact_email),
        subscription_ends_at: requireText(body.subscription_ends_at, 'تاريخ نهاية الاشتراك'),
        is_active: body.is_active === true,
        updated_at: new Date().toISOString(),
      }).eq('id', organizationId).select('*').single()
      if (update.error) throw update.error
      return json({ ok: true, organization: update.data }, 200, origin)
    }

    if (action === 'add_user') {
      const organizationId = requireText(body.organization_id, 'معرف الجمعية')
      const email = normalizeEmail(body.email)
      const password = requireText(body.temporary_password, 'كلمة المرور المؤقتة')
      const role = ['owner','admin','member'].includes(String(body.role)) ? String(body.role) : 'member'
      if (password.length < 10) throw new Error('كلمة المرور المؤقتة يجب ألا تقل عن 10 أحرف')

      const users = await service.auth.admin.listUsers({ page: 1, perPage: 1000 })
      if (users.error) throw users.error
      let user = users.data.users.find(item => item.email?.toLowerCase() === email)
      let createdUser = false
      if (!user) {
        const created = await service.auth.admin.createUser({ email, password, email_confirm: true })
        if (created.error || !created.data.user) throw created.error || new Error('تعذر إنشاء المستخدم')
        user = created.data.user
        createdUser = true
      }
      const insert = await service.from('organization_members').insert({
        organization_id: organizationId, user_id: user.id, role,
        allowed_pages: cleanPages(body.allowed_pages), is_active: true,
      })
      if (insert.error) {
        if (createdUser) await service.auth.admin.deleteUser(user.id)
        throw insert.error
      }
      return json({ ok: true, user_id: user.id }, 200, origin)
    }

    if (action === 'update_member') {
      const membershipId = requireText(body.membership_id, 'معرف العضوية')
      const role = ['owner','admin','member'].includes(String(body.role)) ? String(body.role) : 'member'
      const update = await service.from('organization_members').update({
        role, allowed_pages: cleanPages(body.allowed_pages),
        is_active: body.is_active === true, updated_at: new Date().toISOString(),
      }).eq('id', membershipId).select('id').single()
      if (update.error) throw update.error
      return json({ ok: true }, 200, origin)
    }

    if (action === 'create_mcp_token') {
      const organizationId = requireText(body.organization_id, 'معرف الجمعية')
      const userId = body.user_id ? String(body.user_id) : null
      if (userId) {
        const membership = await service.from('organization_members').select('id')
          .eq('organization_id', organizationId).eq('user_id', userId).eq('is_active', true).maybeSingle()
        if (membership.error) throw membership.error
        if (!membership.data) throw new Error('المستخدم لا يتبع هذه الجمعية')
      }
      const token = randomToken()
      const tokenHash = await sha256(token)
      const insert = await service.from('mcp_access_tokens').insert({
        organization_id: organizationId,
        user_id: userId,
        name: requireText(body.name, 'اسم الاتصال'),
        token_hash: tokenHash,
        token_prefix: token.slice(0, 14),
        expires_at: body.expires_at ? `${String(body.expires_at)}T23:59:59+03:00` : null,
        created_by: actor.id,
      }).select('id').single()
      if (insert.error) throw insert.error
      return json({ ok: true, id: insert.data.id, token, mcp_url: `${SUPABASE_URL}/functions/v1/mcp` }, 200, origin)
    }

    if (action === 'revoke_mcp_token') {
      const tokenId = requireText(body.token_id, 'معرف المفتاح')
      const update = await service.from('mcp_access_tokens').update({ revoked_at: new Date().toISOString() })
        .eq('id', tokenId).is('revoked_at', null).select('id').maybeSingle()
      if (update.error) throw update.error
      return json({ ok: true }, 200, origin)
    }

    return json({ ok: false, error: 'إجراء غير معروف' }, 400, origin)
  } catch (error) {
    const message = error instanceof Error ? error.message : 'خطأ غير متوقع'
    return json({ ok: false, error: message }, 400, origin)
  }
})
