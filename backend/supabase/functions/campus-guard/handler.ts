type Config = {
  supabaseUrl: string;
  publishableKey: string;
  allowedOrigins?: string[];
};

type RpcResult = {
  status: number;
  body: Record<string, unknown>;
};

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const maxBodyBytes = 4096;

// Read incrementally: Content-Length can be absent or forged.
async function readBody(request: Request): Promise<string> {
  const reader = request.body?.getReader();
  if (!reader) return "";
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let size = 0;
  let value = "";
  try {
    while (true) {
      const { done, value: chunk } = await reader.read();
      if (done) break;
      size += chunk.byteLength;
      if (size > maxBodyBytes) {
        await reader.cancel();
        throw new RangeError("body_too_large");
      }
      value += decoder.decode(chunk, { stream: true });
    }
    return value + decoder.decode();
  } finally {
    reader.releaseLock();
  }
}

export function createHandler(config: Config, fetcher: typeof fetch = fetch) {
  const base = config.supabaseUrl.replace(/\/$/, "");
  const allowedOrigins = new Set(config.allowedOrigins ?? []);

  return async (request: Request): Promise<Response> => {
    const origin = request.headers.get("origin");
    const headers = new Headers({
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "Vary": "Origin",
    });
    if (origin && allowedOrigins.has(origin)) {
      headers.set("Access-Control-Allow-Origin", origin);
      headers.set(
        "Access-Control-Allow-Headers",
        "authorization, apikey, content-type, x-client-info",
      );
      headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
      headers.set("Access-Control-Expose-Headers", "Retry-After");
    }
    const json = (status: number, body: unknown): Response =>
      new Response(JSON.stringify(body), { status, headers });
    const error = (status: number, code: string, message: string): Response =>
      json(status, { error: { code, message } });

    if (origin && !allowedOrigins.has(origin)) {
      return error(
        403,
        "origin_not_allowed",
        "This browser origin is not enabled.",
      );
    }
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers });
    }
    if (!base || !config.publishableKey) {
      return error(503, "unavailable", "Backend configuration is unavailable.");
    }
    const auth = request.headers.get("authorization");
    if (!auth || !/^Bearer [^\s]+$/i.test(auth)) {
      return error(401, "unauthorized", "A verified user session is required.");
    }

    try {
      // Auth validates the signature, expiry, and user. Never trust decoded JWT
      // claims or accept a project API key as a user identity.
      const userResponse = await fetcher(`${base}/auth/v1/user`, {
        headers: { apikey: config.publishableKey, Authorization: auth },
        signal: AbortSignal.timeout(10_000),
      });
      if (!userResponse.ok) {
        if (userResponse.status >= 500 || userResponse.status === 429) {
          return error(
            503,
            "unavailable",
            "Authentication is temporarily unavailable.",
          );
        }
        return error(
          401,
          "unauthorized",
          "A verified user session is required.",
        );
      }
      const user = await userResponse.json();
      if (
        !user?.id || user.is_anonymous === true ||
        !(user.email_confirmed_at || user.phone_confirmed_at)
      ) {
        return error(
          401,
          "unauthorized",
          "A verified user session is required.",
        );
      }

      const url = new URL(request.url);
      // Supabase forwards the function name in the URL path.
      const path = url.pathname.replace(
        /^\/functions\/v1\/campus-guard(?=\/|$)/,
        "",
      )
        .replace(/^\/campus-guard(?=\/|$)/, "");
      let rpc: string;
      let body: unknown;
      const lastSeen = path.match(/^\/devices\/([^/]+)\/last-seen$/);
      if (lastSeen) {
        if (request.method !== "GET") {
          headers.set("Allow", "GET, OPTIONS");
          return error(405, "method_not_allowed", "Use GET for last-seen.");
        }
        const simulated = url.searchParams.get("simulated");
        if (
          !uuid.test(lastSeen[1]) ||
          !["true", "false"].includes(simulated ?? "") ||
          [...url.searchParams.keys()].some((key) => key !== "simulated") ||
          url.searchParams.getAll("simulated").length !== 1
        ) {
          return error(
            400,
            "invalid_request",
            "Supply a canonical device UUID and simulated=true or false.",
          );
        }
        rpc = "cg_last_seen";
        body = { device_id: lastSeen[1], simulated: simulated === "true" };
      } else {
        const routes: Record<string, string> = {
          "/scanner-consent": "cg_set_scanner",
          "/devices": "cg_register_device",
          "/sightings": "cg_submit_sighting",
        };
        rpc = routes[path];
        if (!rpc) return error(404, "not_found", "Endpoint not found.");
        if (request.method !== "POST") {
          headers.set("Allow", "POST, OPTIONS");
          return error(
            405,
            "method_not_allowed",
            "Use POST for this endpoint.",
          );
        }
        if (url.search) {
          return error(
            400,
            "invalid_request",
            "Query parameters are not supported here.",
          );
        }
        if (
          request.headers.get("content-type")?.split(";")[0].trim()
            .toLowerCase() !== "application/json"
        ) {
          return error(415, "unsupported_media_type", "Use application/json.");
        }
        try {
          body = JSON.parse(await readBody(request));
        } catch (cause) {
          if (cause instanceof RangeError) {
            return error(
              413,
              "body_too_large",
              "Request body exceeds 4096 bytes.",
            );
          }
          return error(
            400,
            "invalid_json",
            "Request body must be valid UTF-8 JSON.",
          );
        }
        if (!body || typeof body !== "object" || Array.isArray(body)) {
          return error(
            400,
            "invalid_request",
            "Request body must be a JSON object.",
          );
        }
      }

      // Database routines validate exact keys/types, opt-in, claims and limits.
      // They derive identity from this JWT again. The Edge runtime has no admin key.
      const rpcResponse = await fetcher(`${base}/rest/v1/rpc/${rpc}`, {
        method: "POST",
        headers: {
          apikey: config.publishableKey,
          Authorization: auth,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ p_body: body }),
        signal: AbortSignal.timeout(10_000),
      });
      if (!rpcResponse.ok) {
        if ([401, 403].includes(rpcResponse.status)) {
          return error(
            401,
            "unauthorized",
            "A verified user session is required.",
          );
        }
        return error(
          503,
          "unavailable",
          "Database is temporarily unavailable.",
        );
      }
      const result: RpcResult = await rpcResponse.json();
      if (
        ![200, 201, 202, 400, 401, 403, 404, 409, 429].includes(
          result?.status,
        ) ||
        !result.body || typeof result.body !== "object"
      ) {
        return error(
          503,
          "unavailable",
          "Database returned an unexpected response.",
        );
      }
      if (result.status === 429) {
        const seconds = result.body.retry_after_seconds;
        if (typeof seconds === "number" && seconds > 0) {
          headers.set("Retry-After", String(Math.ceil(seconds)));
        }
      }
      return json(result.status, result.body);
    } catch {
      // No body, coordinates, bearer/claim token, upstream error or user ID logs.
      return error(503, "unavailable", "Backend is temporarily unavailable.");
    }
  };
}
