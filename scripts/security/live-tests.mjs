// Issue #108: live security tests against a TEST environment. Needs Node 22+, no npm packages.
// NEVER point this at production data. It creates a few document_requests rows (SQL injection round trip).
//
//   BASE_URL=http://localhost:3000 \
//   SUPABASE_URL=https://<test-project>.supabase.co  SUPABASE_ANON_KEY=<anon key> \
//   STUDENT_A_EMAIL=... STUDENT_A_PASSWORD=... STUDENT_B_EMAIL=... STUDENT_B_PASSWORD=... \
//   LOCKOUT_EMAIL=... LOCKOUT_PASSWORD=...        # a dedicated test account, used for the direct Auth probe
//   node scripts/security/live-tests.mjs [headers|anon|idor|sqli|lockout|rate|all]
//
// Only the anon key is used (the same key the browser has). Tokens and keys are never printed.
// Every result line says PASS, FAIL or BLOCKED (missing input); nothing is assumed.
const env = process.env
const only = process.argv[2] ?? 'all'
const want = (g) => only === 'all' || only === g
const rows = []
const log = (id, name, status, detail = '') => {
  rows.push(status)
  console.log(`${status.padEnd(7)} ${id}  ${name}${detail ? '  -> ' + detail : ''}`)
}
const need = (keys) => keys.filter((k) => !env[k])
const blocked = (id, name, keys) => log(id, name, 'BLOCKED', 'missing ' + keys.join(', '))

const REST = () => `${env.SUPABASE_URL}/rest/v1`
const apikey = () => ({ apikey: env.SUPABASE_ANON_KEY })

async function signIn(email, password) {
  const r = await fetch(`${env.SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { ...apikey(), 'content-type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
  const j = await r.json().catch(() => ({}))
  return { status: r.status, token: j.access_token }
}
const as = (token) => ({ ...apikey(), authorization: `Bearer ${token}`, 'content-type': 'application/json' })
const get = async (path, headers) => {
  const r = await fetch(`${REST()}/${path}`, { headers })
  return { status: r.status, body: await r.json().catch(() => null) }
}

// ---- Headers (needs only BASE_URL) -------------------------------------------------------------
if (want('headers')) {
  if (need(['BASE_URL']).length) blocked('LH-1', 'security headers on /login', ['BASE_URL'])
  else {
    const r = await fetch(`${env.BASE_URL}/login`, { redirect: 'manual' })
    const h = (k) => r.headers.get(k) ?? ''
    log('LH-1', 'Content-Type is text/html with utf-8', /text\/html/i.test(h('content-type')) && /utf-8/i.test(h('content-type')) ? 'PASS' : 'FAIL', h('content-type'))
    log('LH-2', 'X-Frame-Options DENY or CSP frame-ancestors present', /deny|sameorigin/i.test(h('x-frame-options')) || /frame-ancestors/i.test(h('content-security-policy')) ? 'PASS' : 'FAIL')
    log('LH-3', 'Referrer-Policy present', h('referrer-policy') ? 'PASS' : 'FAIL', h('referrer-policy'))
    log('LH-4', 'X-Content-Type-Options nosniff', /nosniff/i.test(h('x-content-type-options')) ? 'PASS' : 'FAIL')
    log('LH-5', 'X-Powered-By absent', h('x-powered-by') ? 'FAIL' : 'PASS', h('x-powered-by'))
    const redirected = await fetch(`${env.BASE_URL}/student`, { redirect: 'manual' })
    log('LH-6', 'anonymous GET /student is redirected to /login (not served)', redirected.status >= 300 && redirected.status < 400 && /\/login/.test(redirected.headers.get('location') ?? '') ? 'PASS' : 'FAIL', String(redirected.status))
    log('LH-7', 'headers also on the redirect response', redirected.headers.get('x-frame-options') ? 'PASS' : 'FAIL')
  }
}

// ---- Anonymous access (SEC-02) -------------------------------------------------------------------
if (want('anon')) {
  const miss = need(['SUPABASE_URL', 'SUPABASE_ANON_KEY'])
  if (miss.length) blocked('LA-1', 'anon cannot read exposed tables', miss)
  else {
    const tables = ['profiles', 'students', 'enrollments', 'enrollment_items', 'grades', 'document_requests', 'academic_holds',
      'charges', 'payments', 'clearances', 'clearance_items', 'audit_logs', 'login_attempts', 'v_grades', 'v_clearances', 'v_clearance_items', 'v_active_holds']
    for (const t of tables) {
      const { status, body } = await get(`${t}?select=*&limit=1`, apikey())
      const leaked = status === 200 && Array.isArray(body) && body.length > 0
      log(`LA-${t}`, `anon read of ${t}`, !leaked ? 'PASS' : 'FAIL', `HTTP ${status}${leaked ? ', ROWS RETURNED' : ''}`)
    }
  }
}

// ---- IDOR between two students (SEC-02, ETH-01) ---------------------------------------------------
if (want('idor')) {
  const miss = need(['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'STUDENT_A_EMAIL', 'STUDENT_A_PASSWORD', 'STUDENT_B_EMAIL', 'STUDENT_B_PASSWORD'])
  if (miss.length) blocked('LI-1', 'student A cannot read or change student B', miss)
  else {
    const A = await signIn(env.STUDENT_A_EMAIL, env.STUDENT_A_PASSWORD)
    const B = await signIn(env.STUDENT_B_EMAIL, env.STUDENT_B_PASSWORD)
    if (!A.token || !B.token) log('LI-0', 'both test students can sign in', 'BLOCKED', `A ${A.status}, B ${B.status}`)
    else {
      const bStudent = (await get('students?select=student_id', as(B.token))).body?.[0]?.student_id
      if (!bStudent) log('LI-0', 'student B has a students row', 'BLOCKED')
      else {
        for (const [t, col] of [['students', 'student_id'], ['enrollments', 'student_id'], ['document_requests', 'student_id'],
          ['academic_holds', 'student_id'], ['clearances', 'student_id'], ['v_grades', 'student_id']]) {
          const own = await get(`${t}?select=*&${col}=eq.${bStudent}`, as(B.token)) // control: B sees own
          const other = await get(`${t}?select=*&${col}=eq.${bStudent}`, as(A.token)) // A asks for B's rows by id
          const leaked = other.status === 200 && Array.isArray(other.body) && other.body.length > 0
          log(`LI-read-${t}`, `A reads B's ${t} by student id`, !leaked ? 'PASS' : 'FAIL',
            `A: HTTP ${other.status}, ${leaked ? other.body.length + ' rows' : '0 rows'}; control (B reads own): ${Array.isArray(own.body) ? own.body.length : '?'} rows`)
        }
        const req = (await get('document_requests?select=request_id,purpose', as(B.token))).body?.[0]
        if (req) {
          const r = await fetch(`${REST()}/document_requests?request_id=eq.${req.request_id}`, {
            method: 'PATCH', headers: { ...as(A.token), prefer: 'return=representation' }, body: JSON.stringify({ purpose: 'tampered by A' }),
          })
          const j = await r.json().catch(() => null)
          const changed = r.status < 300 && Array.isArray(j) && j.length > 0
          const after = (await get(`document_requests?select=purpose&request_id=eq.${req.request_id}`, as(B.token))).body?.[0]?.purpose
          log('LI-write-document_requests', "A updates B's document request by id", !changed && after === req.purpose ? 'PASS' : 'FAIL', `HTTP ${r.status}, rows changed ${changed ? 'YES' : 0}`)
          const d = await fetch(`${REST()}/document_requests?request_id=eq.${req.request_id}`, { method: 'DELETE', headers: { ...as(A.token), prefer: 'return=representation' } })
          const dj = await d.json().catch(() => null)
          log('LI-delete-document_requests', "A deletes B's document request by id", !(d.status < 300 && Array.isArray(dj) && dj.length) ? 'PASS' : 'FAIL', `HTTP ${d.status}`)
        } else log('LI-write-document_requests', "A changes B's document request", 'BLOCKED', 'B has no document request; create one first')
        const staff = await get('audit_logs?select=*&limit=1', as(A.token))
        log('LI-staff-audit_logs', 'a student cannot read the audit log', !(staff.status === 200 && staff.body?.length) ? 'PASS' : 'FAIL', `HTTP ${staff.status}`)
      }
    }
  }
}

// ---- SQL injection round trip (SEC-05), through PostgREST as student A ------------------------------
if (want('sqli')) {
  const miss = need(['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'STUDENT_A_EMAIL', 'STUDENT_A_PASSWORD'])
  if (miss.length) blocked('LQ-1', 'SQL injection payloads stored as text', miss)
  else {
    const A = await signIn(env.STUDENT_A_EMAIL, env.STUDENT_A_PASSWORD)
    const students = A.token ? (await get('students?select=student_id', as(A.token))).body : null
    const types = A.token ? (await get('document_types?select=document_type_id', as(A.token))).body : null
    if (!students?.[0] || !types?.[0]) log('LQ-0', 'student A, a document type', 'BLOCKED', 'sign-in or catalog read failed')
    else {
      const before = (await get('document_types?select=document_type_id', as(A.token))).body.length
      const profilesBefore = (await get('profiles?select=profile_id', as(A.token))).body.length
      for (const [i, payload] of ["' OR 1=1 --", "'; DROP TABLE x; --", "<script>alert('XSS')</script>"].entries()) {
        const r = await fetch(`${REST()}/document_requests`, {
          method: 'POST', headers: { ...as(A.token), prefer: 'return=representation' },
          body: JSON.stringify({ student_id: students[0].student_id, document_type_id: types[0].document_type_id, purpose: payload, copies: 1 }),
        })
        const j = await r.json().catch(() => null)
        const stored = r.status < 300 && j?.[0]?.purpose === payload
        const rejected = r.status >= 400 && !/syntax|relation|pg_|SELECT|INSERT|stack/i.test(JSON.stringify(j ?? {}))
        log(`LQ-${i + 1}`, `purpose = ${JSON.stringify(payload)}`, stored || rejected ? 'PASS' : 'FAIL',
          stored ? 'stored as literal text' : `HTTP ${r.status}${rejected ? ', rejected without query details' : ', check the error body by hand'}`)
      }
      const after = (await get('document_types?select=document_type_id', as(A.token))).body.length
      const profilesAfter = (await get('profiles?select=profile_id', as(A.token))).body.length
      log('LQ-4', 'tables and unrelated rows intact after the payloads', before === after && profilesBefore === profilesAfter ? 'PASS' : 'FAIL')
    }
  }
  console.log('NOTE  The login, hold reason, remarks and receipt fields go through Server Actions: run them by hand (docs/testing-plan.md, ST-SQL-2).')
}

// ---- Direct Supabase Auth probe: does the lockout cover it? (SEC-03) ---------------------------------
if (want('lockout')) {
  const miss = need(['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'LOCKOUT_EMAIL', 'LOCKOUT_PASSWORD'])
  if (miss.length) blocked('LL-1', 'direct Auth endpoint vs the app lockout', miss)
  else {
    const codes = []
    for (let i = 0; i < 8; i++) codes.push((await signIn(env.LOCKOUT_EMAIL, 'wrong-password-' + i)).status)
    const good = await signIn(env.LOCKOUT_EMAIL, env.LOCKOUT_PASSWORD)
    log('LL-1', '8 wrong passwords direct to Supabase Auth, then the right one', good.token ? 'FAIL' : 'PASS',
      `wrong attempts: ${codes.join(',')}; right password afterwards: HTTP ${good.status}${good.token ? ' (signed in: the app lockout does NOT cover this path)' : ' (refused)'}`)
  }
}

// ---- Rate limit (SEC-04): local or approved target only ----------------------------------------------
if (want('rate')) {
  if (need(['BASE_URL']).length) blocked('LR-1', 'POST flood to /login', ['BASE_URL'])
  else {
    const local = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(env.BASE_URL)
    if (!local && env.ALLOW_REMOTE_FLOOD !== '1') log('LR-1', 'POST flood to /login', 'BLOCKED', 'not localhost; set ALLOW_REMOTE_FLOOD=1 only for an approved preview deployment')
    else {
      const n = Number(env.FLOOD_COUNT ?? 40)
      const counts = {}
      for (let i = 0; i < n; i++) {
        const r = await fetch(`${env.BASE_URL}/login`, { method: 'POST', redirect: 'manual' })
        counts[r.status] = (counts[r.status] ?? 0) + 1
      }
      const limited = counts[429] ?? 0
      log('LR-1', `${n} POST requests to /login in one burst`, limited > 0 ? 'PASS' : 'FAIL', JSON.stringify(counts) + (local ? ' (the limit is a Vercel Firewall rule: expect no 429 on localhost)' : ''))
    }
  }
}

const f = rows.filter((s) => s === 'FAIL').length, b = rows.filter((s) => s === 'BLOCKED').length
console.log(`\n${rows.filter((s) => s === 'PASS').length} pass, ${f} fail, ${b} blocked`)
process.exit(f ? 1 : 0)
