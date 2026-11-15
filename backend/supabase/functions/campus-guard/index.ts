import { createHandler } from "./handler.ts";

Deno.serve(createHandler({
  supabaseUrl: Deno.env.get("SUPABASE_URL") ?? "",
  publishableKey: Deno.env.get("CAMPUS_GUARD_PUBLISHABLE_KEY") ??
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
  allowedOrigins: (Deno.env.get("ALLOWED_ORIGINS") ?? "")
    .split(",").map((origin) => origin.trim()).filter(Boolean),
}));
