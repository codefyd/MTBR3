import { createClient } from 'npm:@supabase/supabase-js@2.45.4'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const ALLOWED_ORIGINS = (Deno.env.get('MCP_ALLOWED_ORIGINS') ?? '')
  .split(',').map(x => x.trim()).filter(Boolean)
const PROTOCOL_VERSION = '2025-11-25'
const SUPPORTED_PROTOCOLS = ['2025-11-25','2025-06-18','2025-03-26']

const service = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
})

type TokenContext = {
  id: string
  organization_id: string
  user_id: string | null
  allowed_tools: string[]
  allowed_pages: string[] | null
}

type JsonRpcRequest = {
  jsonrpc?: string
  id?: string | number | null
  method?: string
  params?: Record<string, unknown>
}

const baseHeaders = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store',
}

const response = (body: unknown, status = 200, extra: Record<string,string> = {}) =>
  new Response(body === null ? null : JSON.stringify(body), { status, headers: { ...baseHeaders, ...extra } })

const rpcResult = (id: JsonRpcRequest['id'], result: unknown) => ({ jsonrpc: '2.0', id: id ?? null, result })
const rpcError = (id: JsonRpcRequest['id'], code: number, message: string, data?: unknown) => ({
  jsonrpc: '2.0', id: id ?? null, error: { code, message, ...(data === undefined ? {} : { data }) },
})

const sha256 = async (value: string) => {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return [...new Uint8Array(bytes)].map(x => x.toString(16).padStart(2, '0')).join('')
}

const numberArg = (value: unknown, fallback: number, min: number, max: number) => {
  const parsed = Number(value)
  return Number.isFinite(parsed) ? Math.min(max, Math.max(min, Math.trunc(parsed))) : fallback
}

const textArg = (value: unknown) => String(value ?? '').trim()
const riyadhDate = () => {
  const parts = new Intl.DateTimeFormat('en', { timeZone: 'Asia/Riyadh', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date())
  const value = Object.fromEntries(parts.map(part => [part.type, part.value]))
  return `${value.year}-${value.month}-${value.day}`
}

const toolDefinitions = [
  {
    name: 'get_dashboard_summary',
    description: 'ملخص مؤشرات الجمعية: عدد العمليات والتبرعات والمتبرعين وإجمالي المبالغ والحملات.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    page: 'dashboard',
  },
  {
    name: 'search_donors',
    description: 'البحث في ملفات المتبرعين بالاسم أو رقم الجوال مع فلاتر الحالة والفئة.',
    inputSchema: { type: 'object', properties: {
      search: { type: 'string', description: 'اسم المتبرع أو رقم الجوال' },
      status: { type: 'string', enum: ['مستمر','خامل'] },
      category: { type: 'string' },
      limit: { type: 'integer', minimum: 1, maximum: 100, default: 20 },
    }, additionalProperties: false },
    page: 'donors',
  },
  {
    name: 'get_donor_profile',
    description: 'جلب ملف متبرع واحد برقم الجوال، متضمناً التبرعات والمشاريع والاستجابة للحملات.',
    inputSchema: { type: 'object', properties: { phone: { type: 'string' } }, required: ['phone'], additionalProperties: false },
    page: 'donors',
  },
  {
    name: 'search_operations',
    description: 'البحث في عمليات التبرع حسب الفترة أو المشروع أو كود الإحالة أو الجوال.',
    inputSchema: { type: 'object', properties: {
      from: { type: 'string', format: 'date' }, to: { type: 'string', format: 'date' },
      project: { type: 'string' }, referral_code: { type: 'string' }, phone: { type: 'string' },
      limit: { type: 'integer', minimum: 1, maximum: 100, default: 30 },
    }, additionalProperties: false },
    page: 'operations',
  },
  {
    name: 'list_campaigns',
    description: 'قائمة الحملات التسويقية وتعريفاتها وحالتها والفترة المستهدفة.',
    inputSchema: { type: 'object', properties: {
      status: { type: 'string', enum: ['draft','active','ended','paused'] },
      limit: { type: 'integer', minimum: 1, maximum: 100, default: 30 },
    }, additionalProperties: false },
    page: 'campaign_analysis',
  },
  {
    name: 'get_campaign_analysis',
    description: 'جلب نتيجة التحليل المحفوظة لحملة محددة مع مؤشر ما إذا كانت بحاجة إلى تحديث.',
    inputSchema: { type: 'object', properties: { campaign_id: { type: 'string', format: 'uuid' } }, required: ['campaign_id'], additionalProperties: false },
    page: 'campaign_analysis',
  },
  {
    name: 'list_projects',
    description: 'قائمة المشاريع التسويقية المعرّفة داخل الجمعية وروابطها الأساسية.',
    inputSchema: { type: 'object', properties: { active_only: { type: 'boolean', default: true } }, additionalProperties: false },
    page: 'marketing_content',
  },
]

const availableTools = (ctx: TokenContext) => toolDefinitions.filter(tool =>
  ctx.allowed_tools.includes(tool.name)
  && (!ctx.user_id || (ctx.allowed_pages || []).includes(tool.page))
)

async function authenticate(req: Request): Promise<TokenContext | null> {
  const bearer = (req.headers.get('authorization') || '').match(/^Bearer\s+(.+)$/i)?.[1]
  if (!bearer?.startsWith('wlmcp_')) return null
  const tokenHash = await sha256(bearer)
  const tokenResult = await service.from('mcp_access_tokens')
    .select('id,organization_id,user_id,allowed_tools,expires_at,revoked_at')
    .eq('token_hash', tokenHash).maybeSingle()
  if (tokenResult.error || !tokenResult.data || tokenResult.data.revoked_at) return null
  if (tokenResult.data.expires_at && new Date(tokenResult.data.expires_at).getTime() < Date.now()) return null

  const orgResult = await service.from('organizations')
    .select('id,is_active,subscription_ends_at').eq('id', tokenResult.data.organization_id).maybeSingle()
  if (orgResult.error || !orgResult.data?.is_active) return null
  if (orgResult.data.subscription_ends_at && orgResult.data.subscription_ends_at < riyadhDate()) return null

  let allowedPages: string[] | null = null
  if (tokenResult.data.user_id) {
    const member = await service.from('organization_members').select('allowed_pages,is_active')
      .eq('organization_id', tokenResult.data.organization_id)
      .eq('user_id', tokenResult.data.user_id).maybeSingle()
    if (member.error || !member.data?.is_active) return null
    allowedPages = member.data.allowed_pages || []
  }

  await service.from('mcp_access_tokens').update({ last_used_at: new Date().toISOString() }).eq('id', tokenResult.data.id)
  return {
    id: tokenResult.data.id,
    organization_id: tokenResult.data.organization_id,
    user_id: tokenResult.data.user_id,
    allowed_tools: tokenResult.data.allowed_tools || [],
    allowed_pages: allowedPages,
  }
}

const asToolContent = (value: unknown) => ({
  content: [{ type: 'text', text: JSON.stringify(value, null, 2) }],
  structuredContent: value,
})

async function callTool(ctx: TokenContext, name: string, args: Record<string,unknown>) {
  const org = ctx.organization_id
  if (name === 'get_dashboard_summary') {
    const result = await service.rpc('mcp_organization_summary', { p_organization_id: org })
    if (result.error) throw result.error
    return result.data
  }

  if (name === 'search_donors') {
    const search = textArg(args.search)
    let query = service.from('donors').select(
      'phone,donor_name,first_donation,last_donation,total_amount,donations_count,projects,status,category,targeted_count,last_targeted,responded,response_date'
    ).eq('organization_id', org).order('total_amount', { ascending: false })
    if (search) query = /^\d+$/.test(search) ? query.ilike('phone', `%${search}%`) : query.ilike('donor_name', `%${search}%`)
    if (args.status) query = query.eq('status', textArg(args.status))
    if (args.category) query = query.eq('category', textArg(args.category))
    const result = await query.limit(numberArg(args.limit, 20, 1, 100))
    if (result.error) throw result.error
    return { donors: result.data || [], count: result.data?.length || 0 }
  }

  if (name === 'get_donor_profile') {
    const phone = textArg(args.phone)
    if (!phone) throw new Error('phone مطلوب')
    const donor = await service.from('donors').select('*')
      .eq('organization_id', org).eq('phone', phone).maybeSingle()
    if (donor.error) throw donor.error
    if (!donor.data) throw new Error('لم يوجد متبرع بهذا الرقم')
    const operations = await service.from('operations')
      .select('operation_no,project,referral_code,total,op_datetime')
      .eq('organization_id', org).eq('phone', phone)
      .order('op_datetime', { ascending: false }).limit(50)
    if (operations.error) throw operations.error
    return { donor: donor.data, recent_operations: operations.data || [] }
  }

  if (name === 'search_operations') {
    let query = service.from('operations').select(
      'line_no,operation_no,donor_name,phone,project,referral_code,value,quantity,total,op_datetime'
    ).eq('organization_id', org).order('op_datetime', { ascending: false })
    if (args.from) query = query.gte('op_datetime', `${textArg(args.from)}T00:00:00+03:00`)
    if (args.to) query = query.lt('op_datetime', `${textArg(args.to)}T23:59:59.999+03:00`)
    if (args.project) query = query.eq('project', textArg(args.project))
    if (args.referral_code) query = query.eq('referral_code', textArg(args.referral_code))
    if (args.phone) query = query.eq('phone', textArg(args.phone))
    const result = await query.limit(numberArg(args.limit, 30, 1, 100))
    if (result.error) throw result.error
    return { operations: result.data || [], rows_count: result.data?.length || 0 }
  }

  if (name === 'list_campaigns') {
    let query = service.from('marketing_campaigns').select(
      'id,name,nature,channel,status,start_date,end_date,target_amount,attribution_days,post_campaign_days,exact_codes,code_prefixes,projects,notes,updated_at'
    ).eq('organization_id', org).order('start_date', { ascending: false })
    if (args.status) query = query.eq('status', textArg(args.status))
    const result = await query.limit(numberArg(args.limit, 30, 1, 100))
    if (result.error) throw result.error
    return { campaigns: result.data || [], count: result.data?.length || 0 }
  }

  if (name === 'get_campaign_analysis') {
    const campaignId = textArg(args.campaign_id)
    if (!campaignId) throw new Error('campaign_id مطلوب')
    const campaign = await service.from('marketing_campaigns').select('id,name,status,start_date,end_date')
      .eq('organization_id', org).eq('id', campaignId).maybeSingle()
    if (campaign.error) throw campaign.error
    if (!campaign.data) throw new Error('الحملة غير موجودة داخل الجمعية')
    const cache = await service.from('marketing_campaign_analysis_cache')
      .select('payload,is_stale,refreshed_at,updated_at')
      .eq('organization_id', org).eq('campaign_id', campaignId).maybeSingle()
    if (cache.error) throw cache.error
    return { campaign: campaign.data, analysis: cache.data?.payload || null, is_stale: cache.data?.is_stale ?? true, refreshed_at: cache.data?.refreshed_at || null }
  }

  if (name === 'list_projects') {
    let query = service.from('marketing_projects').select('id,name,base_url,is_active,updated_at')
      .eq('organization_id', org).order('name')
    if (args.active_only !== false) query = query.eq('is_active', true)
    const result = await query.limit(200)
    if (result.error) throw result.error
    return { projects: result.data || [] }
  }

  throw new Error('الأداة غير معروفة')
}

async function audit(ctx: TokenContext, toolName: string | null, requestId: unknown, status: string, started: number, error?: string) {
  await service.from('mcp_audit_logs').insert({
    token_id: ctx.id, organization_id: ctx.organization_id, user_id: ctx.user_id,
    tool_name: toolName, request_id: requestId == null ? null : String(requestId),
    status, duration_ms: Date.now() - started, error_message: error?.slice(0, 500) || null,
  })
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('origin')
  if (origin && !ALLOWED_ORIGINS.includes(origin)) return response(rpcError(null, -32003, 'Origin غير مسموح'), 403)
  const corsHeaders = origin ? {
    'access-control-allow-origin': origin,
    'access-control-expose-headers': 'mcp-session-id',
    'vary': 'Origin',
  } : {}
  const send = (body: unknown, status = 200, extra: Record<string,string> = {}) =>
    response(body, status, { ...corsHeaders, ...extra })
  if (req.method === 'OPTIONS') return send(null, 204, {
    'access-control-allow-headers': 'authorization, content-type, accept, last-event-id, mcp-protocol-version, mcp-session-id',
    'access-control-allow-methods': 'POST, OPTIONS',
  })
  if (req.method === 'GET' || req.method === 'DELETE') return send(null, 405, { allow: 'POST, OPTIONS' })
  if (req.method !== 'POST') return send(rpcError(null, -32600, 'Method not allowed'), 405)

  const ctx = await authenticate(req)
  if (!ctx) return send(rpcError(null, -32001, 'مفتاح MCP غير صالح أو منتهي'), 401, {
    'www-authenticate': 'Bearer realm="Walaa MCP"',
  })

  const started = Date.now()
  let request: JsonRpcRequest = {}
  try {
    request = await req.json() as JsonRpcRequest
    if (request.jsonrpc !== '2.0' || !request.method) return send(rpcError(request.id, -32600, 'Invalid Request'), 400)

    if (request.method.startsWith('notifications/')) return send(null, 202)
    if (request.method === 'initialize') {
      const requestedVersion = textArg(request.params?.protocolVersion)
      const negotiatedVersion = SUPPORTED_PROTOCOLS.includes(requestedVersion) ? requestedVersion : PROTOCOL_VERSION
      return send(rpcResult(request.id, {
      protocolVersion: negotiatedVersion,
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: 'walaa-donor-intelligence', title: 'ولاء لتحليل المتبرعين', version: '3.0.0' },
      instructions: 'بوابة قراءة وتحليل لبيانات الجمعية المرتبطة بالمفتاح. لا توفر أدوات حذف أو تعديل.',
      }))
    }
    if (request.method === 'ping') return send(rpcResult(request.id, {}))
    if (request.method === 'tools/list') return send(rpcResult(request.id, {
      tools: availableTools(ctx).map(({ page: _page, ...tool }) => tool),
    }))
    if (request.method === 'tools/call') {
      const name = textArg(request.params?.name)
      const allowed = availableTools(ctx).some(tool => tool.name === name)
      if (!allowed) {
        await audit(ctx, name, request.id, 'denied', started, 'الأداة غير مسموحة')
        return send(rpcError(request.id, -32601, 'الأداة غير موجودة أو غير مسموحة'), 403)
      }
      const args = (request.params?.arguments && typeof request.params.arguments === 'object')
        ? request.params.arguments as Record<string,unknown> : {}
      try {
        const value = await callTool(ctx, name, args)
        await audit(ctx, name, request.id, 'success', started)
        return send(rpcResult(request.id, asToolContent(value)))
      } catch (error) {
        const message = error instanceof Error ? error.message : 'تعذر تنفيذ الأداة'
        await audit(ctx, name, request.id, 'error', started, message)
        return send(rpcResult(request.id, {
          content: [{ type: 'text', text: message }], isError: true,
        }))
      }
    }
    return send(rpcError(request.id, -32601, 'Method not found'), 404)
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Parse error'
    await audit(ctx, null, request.id, 'error', started, message)
    return send(rpcError(request.id, -32700, message), 400)
  }
})
