import type { NextConfig } from "next";

// Issue #108 (SEC-02, XSS hardening): response headers sent with every page and Server Action response.
// Content-Type (text/html; charset=utf-8) is set by Next.js itself and is not repeated here.
//   - X-Frame-Options DENY and CSP frame-ancestors 'none': nobody may embed the portal in a frame
//     (clickjacking). Both are sent on purpose; they say the same thing for old and new browsers.
//   - Referrer-Policy: other sites get the origin only, never the path or query of a portal page.
//   - X-Content-Type-Options nosniff: the browser must not guess a different content type.
//   - Permissions-Policy: the Registrar scan desk needs the camera (components/registrar/QueueScanner.tsx),
//     so camera stays allowed for this site only; microphone, location and payment are switched off.
//   - Strict-Transport-Security: HTTPS only (browsers ignore it on http://localhost).
// Not added: a full Content-Security-Policy. The theme script in app/layout.tsx is inline, so a strict
// script-src needs per-request nonces; that is a separate change that must be tested in a browser.
const securityHeaders = [
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Content-Security-Policy", value: "frame-ancestors 'none'" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Permissions-Policy", value: "camera=(self), microphone=(), geolocation=(), payment=()" },
  { key: "Strict-Transport-Security", value: "max-age=31536000" },
];

const nextConfig: NextConfig = {
  // Do not announce the framework and version in every response.
  poweredByHeader: false,
  async headers() {
    return [{ source: "/:path*", headers: securityHeaders }];
  },
};

export default nextConfig;
