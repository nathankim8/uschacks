/**
 * Campus Guard gateway (Cloudflare Worker).
 *
 * The phone talks only to this Worker, with a bearer token. The Worker:
 *  - looks like an ntfy server for one alias topic ("tag"), so the iOS app needs no special code:
 *      GET  /<alias>/json?since=…   → streams the tag's pushes (real topic name rewritten to the alias)
 *      POST /<alias>-cmd            → one allow-listed command (ARM, DISARM, …) to the tag
 *  - serves Find My locations that the laptop uploads:
 *      GET  /api/locations          → latest decrypted reports (timestamps + coordinates only)
 *      POST /v1/ingest              → laptop uploader, separate write-only token
 *  - GET /v1/health                 → liveness, no auth, no data
 *
 * Secrets (wrangler secret put): APP_TOKEN, INGEST_TOKEN, NTFY_TOPIC, optional NTFY_TOKEN.
 * The real ntfy topic and the tag's private key never reach the phone; the key never leaves the laptop.
 */

export interface Env {
  LOCATIONS: KVNamespace;
  APP_TOKEN: string;
  INGEST_TOKEN: string;
  NTFY_TOPIC?: string;
  NTFY_TOKEN?: string;
  NTFY_SERVER?: string;
  TAG_ALIAS?: string;
}

const COMMAND = /^(ARM|DISARM|LOSTMODE|LOST|FOUND|PUSHTEST|TEST|STOP|SIREN|CHIRP|PING)( [a-z0-9]{1,8})?$/i;
const SINCE = /^(all|latest|\d{1,12}|\d{1,6}[smhd]|[A-Za-z0-9]{1,32})$/;
const LOCATIONS_KEY = "findmy:latest";
const MAX_REPORTS = 500;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const alias = env.TAG_ALIAS || "tag";
    const path = url.pathname.replace(/\/+$/, "") || "/";

    try {
      if (path === "/" || path === "/v1/health") {
        return json({ ok: true, service: "campus-guard-gateway", time: new Date().toISOString() });
      }
      if ((path === `/${alias}/json` || path === `/${alias}-cmd`) && !env.NTFY_TOPIC) {
        // Off by default: Workers share egress IPs and ntfy.sh rate-limits per IP, so proxying
        // the tag link is only reliable with an ntfy.sh account token (NTFY_TOKEN).
        return json({ error: "tag proxy not enabled" }, 503);
      }
      if (path === `/${alias}/json`) {
        if (request.method !== "GET") return methodNotAllowed("GET");
        return (await authorize(request, env.APP_TOKEN)) ?? (await streamPushes(url, env, alias));
      }
      if (path === `/${alias}-cmd`) {
        if (request.method !== "POST" && request.method !== "PUT") return methodNotAllowed("POST");
        return (await authorize(request, env.APP_TOKEN)) ?? (await sendCommand(request, env, alias));
      }
      if (path === "/api/locations") {
        if (request.method !== "GET") return methodNotAllowed("GET");
        return (await authorize(request, env.APP_TOKEN)) ?? (await readLocations(env));
      }
      if (path === "/v1/ingest") {
        if (request.method !== "POST") return methodNotAllowed("POST");
        return (await authorize(request, env.INGEST_TOKEN)) ?? (await ingest(request, env));
      }
      return json({ error: "not found" }, 404);
    } catch (err) {
      console.error("gateway error", err);
      return json({ error: "internal error" }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

// MARK: auth

async function authorize(request: Request, expected: string | undefined): Promise<Response | null> {
  const header = request.headers.get("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!expected || !token || !(await safeEqual(token, expected))) {
    return json({ error: "unauthorized" }, 401, { "WWW-Authenticate": 'Bearer realm="campus-guard"' });
  }
  return null;
}

/** Constant-time compare (hash both so lengths match). */
async function safeEqual(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  return crypto.subtle.timingSafeEqual(ha, hb);
}

// MARK: ntfy proxy

function upstream(env: Env, suffix: string): string {
  const server = (env.NTFY_SERVER || "https://ntfy.sh").replace(/\/+$/, "");
  return `${server}/${encodeURIComponent(env.NTFY_TOPIC ?? "")}${suffix}`;
}

function upstreamHeaders(env: Env): HeadersInit {
  return env.NTFY_TOKEN ? { Authorization: `Bearer ${env.NTFY_TOKEN}` } : {};
}

/** Streams ntfy's newline-delimited JSON, replacing the real topic name with the alias. */
async function streamPushes(url: URL, env: Env, alias: string): Promise<Response> {
  const query = new URLSearchParams();
  const since = url.searchParams.get("since");
  if (since) {
    if (!SINCE.test(since)) return json({ error: "bad since" }, 400);
    query.set("since", since);
  }
  if (url.searchParams.get("poll") === "1") query.set("poll", "1");
  const qs = query.toString();

  const res = await fetch(upstream(env, `/json${qs ? `?${qs}` : ""}`), { headers: upstreamHeaders(env) });
  if (!res.ok || !res.body) return json({ error: "upstream", status: res.status }, res.status === 429 ? 429 : 502);

  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  let buffer = "";
  const rewrite = (line: string): string | null => {
    if (!line.trim()) return null;
    try {
      const msg = JSON.parse(line);
      if (typeof msg.topic === "string") msg.topic = alias;
      return JSON.stringify(msg) + "\n";
    } catch {
      return null; // never pass through unparsed upstream text
    }
  };
  const body = res.body.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        buffer += decoder.decode(chunk, { stream: true });
        let nl: number;
        while ((nl = buffer.indexOf("\n")) >= 0) {
          const out = rewrite(buffer.slice(0, nl));
          buffer = buffer.slice(nl + 1);
          if (out) controller.enqueue(encoder.encode(out));
        }
      },
      flush(controller) {
        const out = rewrite(buffer);
        if (out) controller.enqueue(encoder.encode(out));
      },
    }),
  );
  return new Response(body, {
    headers: { "Content-Type": "application/x-ndjson; charset=utf-8", "Cache-Control": "no-store", ...security() },
  });
}

async function sendCommand(request: Request, env: Env, alias: string): Promise<Response> {
  const text = (await request.text()).slice(0, 64).trim();
  if (!COMMAND.test(text)) return json({ error: "command not allowed" }, 400);
  const [verb, rid] = text.split(" ");
  // The URL is always "<real topic>-cmd", built here, never taken from the client.
  const res = await fetch(upstream(env, "-cmd"), {
    method: "POST",
    body: verb.toUpperCase() + (rid ? ` ${rid.toLowerCase()}` : ""),
    headers: upstreamHeaders(env),
  });
  return res.ok
    ? json({ ok: true, topic: `${alias}-cmd` })
    : json({ error: "upstream", status: res.status }, res.status === 429 ? 429 : 502);
}

// MARK: Find My locations

interface Report {
  ts: number;
  lat: number;
  lon: number;
  accuracy_m?: number;
  confidence?: number;
}

async function readLocations(env: Env): Promise<Response> {
  const stored = await env.LOCATIONS.get(LOCATIONS_KEY);
  if (!stored) return json({ tag: null, fetched_at: null, count: 0, undecryptable: 0, reports: [] });
  return new Response(stored, { headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...security() } });
}

async function ingest(request: Request, env: Env): Promise<Response> {
  const raw = await request.text();
  if (raw.length > 256_000) return json({ error: "too large" }, 413);
  let body: any;
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: "bad json" }, 400);
  }
  if (!body || !Array.isArray(body.reports)) return json({ error: "reports must be an array" }, 400);

  const reports: Report[] = [];
  for (const r of body.reports.slice(0, MAX_REPORTS)) {
    if (!isNum(r?.ts) || !isNum(r?.lat) || !isNum(r?.lon)) continue;
    if (Math.abs(r.lat) > 90 || Math.abs(r.lon) > 180) continue;
    const clean: Report = { ts: Math.trunc(r.ts), lat: r.lat, lon: r.lon };
    if (isNum(r.accuracy_m)) clean.accuracy_m = Math.max(0, Math.trunc(r.accuracy_m));
    if (isNum(r.confidence)) clean.confidence = Math.trunc(r.confidence);
    reports.push(clean);
  }
  reports.sort((a, b) => b.ts - a.ts);

  const record = {
    tag: typeof body.tag === "string" ? body.tag.slice(0, 32) : null,
    fetched_at: isNum(body.fetched_at) ? Math.trunc(body.fetched_at) : Math.trunc(Date.now() / 1000),
    uploaded_at: Math.trunc(Date.now() / 1000),
    count: reports.length,
    undecryptable: isNum(body.undecryptable) ? Math.trunc(body.undecryptable) : 0,
    reports,
  };
  await env.LOCATIONS.put(LOCATIONS_KEY, JSON.stringify(record));
  return json({ ok: true, stored: reports.length });
}

// MARK: helpers

function isNum(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v);
}

function security(): Record<string, string> {
  return { "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer" };
}

function json(data: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...security(), ...extra },
  });
}

function methodNotAllowed(allow: string): Response {
  return json({ error: "method not allowed" }, 405, { Allow: allow });
}
