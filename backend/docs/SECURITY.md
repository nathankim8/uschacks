# Campus Guard demo security and retention

The backend is scoped to consenting participants and explicitly enrolled test tags. It is not ready for public tracking. It restricts who may submit and retrieve reports, but does not cryptographically prove that a phone heard a particular ESP32 or that the phone supplied an honest GPS position.

## Trust and authorization

Supabase Auth is the user identity source. The Edge Function verifies the user session through Supabase Auth and passes the caller's JWT to PostgreSQL. It does not use a service role to perform normal mobile requests. Database RPCs independently check the authenticated user, confirmed email or phone, and non-anonymous account status. Identity never comes from a client-supplied `user_id`.

Application tables live in a private schema, with RLS enabled and no direct grants for anonymous or authenticated client roles. That schema is not exposed by the Data API. The narrowly scoped public RPCs are the allowed interface. Their `SECURITY DEFINER` bodies use a pinned empty `search_path` and qualified table references; execute grants are explicitly restricted. Because such functions run with their owner's privileges, their internal authorization is essential even when table RLS is enabled. This follows Supabase's guidance on [database function security](https://supabase.com/docs/guides/database/functions) and [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security).

The operator-only provisioning RPC is executable only by the service role. It pre-enrolls a UUID, binds the expected owner, and stores a hash of the private claim token. Public registration requires both that bound account and the token; hearing the public UUID cannot claim ownership. The operator must verify physical control and consent before enrolling a tag. That human verification is part of the controlled-demo trust model.

Location retrieval checks the device's verified owner and enabled registry entry. Missing, disabled, and unauthorized devices return the same `404`. Reporting does not imply permission to retrieve. A reporter must explicitly opt in, but an owner may retrieve their device without opting into reporting.

## Validation and abuse controls

Strict database validation protects both Edge Function calls and direct RPC calls. Unknown fields, invalid types, invalid coordinates, unacceptable accuracy, stale/future timestamps, and identifiers outside the enabled registered test set are rejected. Coordinates are rounded before storage. Client consent and owner checks run in the database, including for callers that bypass the Edge Function.

PostgreSQL maintains per-account fixed-window quotas: consent 10/minute, registration 5/minute, lookup 60/minute, and sightings 30/minute plus 500/day. A valid opt-out by an eligible authenticated account bypasses the consent quota. The quota operation is atomic and counts rejected operations that reach it; returning an application error must not roll back that counter. Duplicate suppression is per reporting account, device, and simulation stream for 30 seconds. Newest-observation checks prevent a delayed report from moving a location backward. Simulated and real reports occupy separate latest records and must be selected explicitly on lookup.

These are limited abuse controls. Multiple accounts can evade per-account limits; a verified account can lie about detection or location; an attacker can copy an advertised UUID; and HTTP requests rejected before a database operation do not consume the database quota. Public use needs account-abuse controls, network-level throttling, anomaly detection, and a reviewed approach to report authenticity. A claim token protects ownership, not sighting authenticity.

## Stored information

| Data | Purpose and retention |
|---|---|
| Supabase Auth user | Login and account verification; handled by Supabase Auth |
| Application user and scanner record | Account linkage, explicit reporting consent; retained until account deletion |
| Registry and registered device | Enabled test identifier, bound owner, hash of claim token, name, verification time; retained until operator/account deletion |
| Sighting | Latest per device and simulation stream only; rounded coordinates, accuracy, observation/receipt times, source flag, and reporter reference |
| Duplicate record | Suppress repeated reports; delete after 24 hours |
| Rate bucket | Quota count and window; delete after 48 hours |

Sighting lookup hides rows once `observed_at` is more than 24 hours old. A PostgreSQL cron job physically removes expired sightings every 15 minutes, so healthy scheduled cleanup gives approximately 24 hours 15 minutes maximum table retention. Only the current newest location per stream is stored; replacement does not retain a history row. The returned accuracy floor of 150 meters avoids presenting rounded coordinates with unjustified precision.

Opt-out removes the account's currently retained reports and duplicate records, in addition to disabling future reporting. It cannot resurrect an older location overwritten by the deleted latest report. Account deletion cascades through linked records. Disabling an identifier through the operator RPC prevents further claims, reports, and retrieval and deletes its retained sightings and duplicate records. These changes do not automatically erase infrastructure backups.

## Deployment checks

- Keep the private schema out of the exposed schema list. Do not add broad table grants or public read policies for debugging.
- Confirm the cron extension, cleanup schedule, and successful recent executions. A missed job must alert the operator; lookup expiry does not by itself erase database rows.
- Keep secret/service keys and database credentials only in operator environments. Mobile and simulator reporting use normal user sessions plus a publishable key.
- Avoid logging request bodies, location responses, access tokens, claim tokens, or secrets. Check Supabase gateway/function logs and any mobile analytics, error reporting, or reverse proxy logging configuration.
- Define retention for database backups, point-in-time recovery, exported fixtures, and support logs. The application TTL does not automatically shorten those systems' retention or promise instantaneous erasure from backups.
- Disable unused identifiers and stop scanner participation after the controlled demonstration. Avoid leaving reusable claim secrets in shell history or shared notes.
- Re-run owner/unrelated-user and direct-RPC authorization tests after any grant, schema, Auth, or function changes.

## Required design work before public deployment

1. Replace static public tag identifiers with rotating ephemeral identifiers and a reviewed cryptographic mapping available only to authorized owners. Address BLE address rotation and other stable fields that could link rotations.
2. Design unwanted-tracking detection, meaningful alerts, audible or other accessible tag identification, a safe disable process, and abuse reporting/response. Validate protections with the mobile and hardware teams, including people without the participating app.
3. Strengthen registration and ownership transfer beyond operator enrollment. Define revocation, lost/stolen devices, account recovery, and disputes without allowing arbitrary users to bind nearby tags.
4. Assess report poisoning, replay, fabricated locations, compromised clients, and account farms. Add appropriate device/app attestation and anomaly controls while acknowledging their limits; do not equate an authenticated request with a true sighting.
5. Review consent, coarse location precision, account deletion, retention across backups/logs, operational access, and access auditing. Ensure alerts and logs themselves do not create a location history.
6. Validate phone foreground/background behavior on supported OS versions, permissions, battery modes, and network failures. Document tested behavior and degraded operation.

Static UUIDs, explicit test enrollment, owner checks, and opt-in reporting are a bounded demo design. They do not by themselves provide the unwanted-tracking protections needed for general deployment.
