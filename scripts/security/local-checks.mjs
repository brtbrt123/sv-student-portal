// Issue #108: security checks that need NO database, NO credentials and NO node_modules.
// Run from the repository root:   node scripts/security/local-checks.mjs
// (Node 22.18 or newer; it reads next.config.ts directly.) Exit code 1 if any check fails.
// These are static checks of the source tree. They do not replace the live tests in
// scripts/security/live-tests.mjs and the SQL suites; they only catch regressions early.
import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs'
import { join, relative } from 'node:path'
import { pathToFileURL } from 'node:url'

const root = process.cwd()
const results = []
const check = (id, name, ok, detail = '') => {
  results.push({ id, name, ok })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${id}  ${name}${detail ? '  -> ' + detail : ''}`)
}

function walk(dir, out = []) {
  for (const f of readdirSync(dir)) {
    if (['node_modules', '.next', '.git', 'public'].includes(f)) continue
    const p = join(dir, f)
    statSync(p).isDirectory() ? walk(p, out) : out.push(p)
  }
  return out
}
const src = ['app', 'components', 'lib', 'proxy.ts', 'next.config.ts']
  .filter(existsSync)
  .flatMap((p) => (statSync(p).isDirectory() ? walk(p) : [p]))
  .filter((p) => /\.(ts|tsx|mjs|js)$/.test(p))
const text = (p) => readFileSync(p, 'utf8')
const rel = (p) => relative(root, p).replaceAll('\\', '/')

// H-1..H-4: security headers declared in next.config.ts
const mod = await import(pathToFileURL(join(root, 'next.config.ts')).href)
const rules = await mod.default.headers()
const all = rules.flatMap((r) => r.headers)
const val = (k) => all.filter((h) => h.key.toLowerCase() === k.toLowerCase())
check('H-1', 'headers apply to every path', rules.length === 1 && rules[0].source === '/:path*')
check('H-2', 'X-Frame-Options is DENY (once)', val('X-Frame-Options').length === 1 && val('X-Frame-Options')[0].value === 'DENY')
check('H-3', "CSP has frame-ancestors 'none' (once)", val('Content-Security-Policy').length === 1 && /frame-ancestors 'none'/.test(val('Content-Security-Policy')[0].value))
check('H-4', 'Referrer-Policy is set (once) and is not unsafe-url/no-referrer-when-downgrade', val('Referrer-Policy').length === 1 && !/unsafe-url|no-referrer-when-downgrade/.test(val('Referrer-Policy')[0].value))
check('H-5', 'nosniff is set', val('X-Content-Type-Options')[0]?.value === 'nosniff')
check('H-6', 'camera stays allowed for the same origin (QueueScanner needs it)', /camera=\(self\)/.test(val('Permissions-Policy')[0]?.value ?? ''))
check('H-7', 'no duplicate header keys', new Set(all.map((h) => h.key.toLowerCase())).size === all.length)
check('H-8', 'X-Powered-By is switched off', mod.default.poweredByHeader === false)

// S-1..S-6: secrets
const pub = new Set(src.flatMap((p) => [...text(p).matchAll(/NEXT_PUBLIC_[A-Z0-9_]+/g)].map((m) => m[0])))
const okPub = new Set(['NEXT_PUBLIC_SUPABASE_URL', 'NEXT_PUBLIC_SUPABASE_ANON_KEY'])
const badPub = [...pub].filter((n) => !okPub.has(n) || /SERVICE|SECRET|ADMIN|PRIVATE/.test(n))
check('S-1', 'only the Supabase URL and anon key use a NEXT_PUBLIC_ name', badPub.length === 0, badPub.join(', '))
const adminKeyFiles = src.filter((p) => /SUPABASE_ADMIN_KEY|service_role/.test(text(p))).map(rel)
check('S-2', 'the admin key is read only in lib/supabase/admin.ts', adminKeyFiles.length === 1 && adminKeyFiles[0] === 'lib/supabase/admin.ts', adminKeyFiles.join(', '))
check('S-3', "lib/supabase/admin.ts imports 'server-only'", /import 'server-only'/.test(text('lib/supabase/admin.ts')))
const clientFiles = src.filter((p) => /^\s*['"]use client['"]/m.test(text(p)))
// Match real imports and env reads only, not comments that mention a server-only file.
const serverOnly = /from\s+['"][^'"]*(supabase\/admin|queue\/qr-secret|queue\/qr-token)['"]|import\s+['"]server-only['"]|process\.env\.(SUPABASE_ADMIN_KEY|QUEUE_QR_SECRET)/
const leak = clientFiles.filter((p) => serverOnly.test(text(p))).map(rel)
check('S-4', 'no Client Component imports the admin client or reads a server secret', leak.length === 0, leak.join(', '))
check('S-5', '.gitignore ignores .env files', /^\.env\*/m.test(text('.gitignore')))
const secretRe = /eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}|sb_secret_[A-Za-z0-9_]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}/
const hits = [...src, ...walk('docs'), ...walk('tests')].filter((p) => secretRe.test(text(p))).map(rel)
check('S-6', 'no JWT, sb_secret_, private key or AWS key pattern in source, docs or tests', hits.length === 0, hits.join(', '))

// Q-1..Q-4: SQL construction and HTML injection
const rawSql = src.filter((p) => /from\s+['"](pg|postgres|mysql2?|knex|sequelize)['"]|\.raw\(|\bsql`|\$queryRaw/.test(text(p))).map(rel)
check('Q-1', 'no SQL driver, .raw() or sql`` template in application code', rawSql.length === 0, rawSql.join(', '))
const concat = src.filter((p) => /\.(rpc|from)\(\s*(`[^`]*\$\{|[^)]*\+\s*\w)/.test(text(p))).map(rel)
check('Q-2', 'no table or function name is built from a variable', concat.length === 0, concat.join(', '))
const dyn = src.filter((p) => /dangerouslySetInnerHTML/.test(text(p))).map(rel)
check('Q-3', 'dangerouslySetInnerHTML is used only in app/layout.tsx', dyn.length === 1 && dyn[0] === 'app/layout.tsx', dyn.join(', '))
const layout = text('app/layout.tsx')
check('Q-4', 'that HTML comes from a constant string with no interpolation', /const THEME_SCRIPT = `[^`$]*`/.test(layout) && /__html: THEME_SCRIPT/.test(layout))
// Dynamic SQL matters inside stored functions, which run for app users. EXECUTE in one-off DO blocks and
// diagnostics (run by the Project Manager at deploy time, no user input) is not the injection path.
const fnBody = /\$function\$([\s\S]*?)\$function\$/g
const dynSql = walk('docs/database')
  .filter((p) => p.endsWith('.sql'))
  .filter((p) =>
    [...text(p).matchAll(fnBody)].some((m) =>
      m[1].split('\n').some((l) => /\bEXECUTE\s+(?!FUNCTION|PROCEDURE)/i.test(l) && !/^\s*--/.test(l))
    )
  )
  .map(rel)
check('Q-5', 'no stored function body in docs/database builds SQL with EXECUTE', dynSql.length === 0, dynSql.join(', '))

// A-1..A-3: authorization wiring
const adminCalls = src.flatMap((p) => [...text(p).matchAll(/getAdminClientFor\('(\w+)'\)/g)].map((m) => `${rel(p)}:${m[1]}`))
const wrong = adminCalls.filter((c) => !/^lib\/data\/admin-users-actions\.ts:Admin$|^lib\/data\/applications-actions\.ts:Registrar$/.test(c))
check('A-1', 'every admin-client call names the expected role (Admin / Registrar)', adminCalls.length > 0 && wrong.length === 0, wrong.join(', '))
const roles = text('lib/auth/roles.ts')
check('A-2', 'public paths are only /apply and /auth/confirm', /PUBLIC_PATHS = \['\/apply', '\/auth\/confirm'\] as const/.test(roles))
const proxy = text('lib/supabase/proxy.ts')
check('A-3', 'the proxy validates the token with getUser(), never getSession()', /auth\.getUser\(\)/.test(proxy) && !/auth\.getSession\(\)/.test(proxy))
check('A-4', 'the login action checks the lockout before signInWithPassword', text('app/(auth)/login/actions.ts').indexOf('check_login_lockout') < text('app/(auth)/login/actions.ts').indexOf('signInWithPassword'))
check('A-5', 'the login action rejects bad input before any database call', text('app/(auth)/login/actions.ts').indexOf('loginInputIsAcceptable(typed') < text('app/(auth)/login/actions.ts').indexOf('createClient()'))

const failed = results.filter((r) => !r.ok).length
console.log(`\n${results.length - failed} of ${results.length} checks passed`)
process.exit(failed ? 1 : 0)
