# MCP Events

On MCP `2026-07-28`, the general server and client support webhooks from
the [SEP-3415 Events extension](https://github.com/modelcontextprotocol/ext-events/blob/main/specification/beta/events/events.mdx)
and the earlier draft used by [ChatGPT plugins](https://developers.openai.com/plugins/build/mcp-events).
Enable Events on the general server with `ModelContextProtocol.enable_events!`.

Clients discover definitions with `events/list`, create or refresh subscriptions
with `events/subscribe`, and stop them with `events/unsubscribe`. These methods
use the existing authenticated MCP endpoint. Each event advertises `delivery: ["webhook"]`.

| Wire behavior | SEP-3415 | Earlier draft |
| --- | --- | --- |
| Capability in `server/discover` | `capabilities.extensions["io.modelcontextprotocol/events"]` | `capabilities.events` |
| HTTP subscribe, refresh, unsubscribe | `Mcp-Name` and any `Mcp-Param-*` headers declared by `x-mcp-header` | May omit those headers |
| `webhook-id` for an occurrence | A fresh message ID per subscription delivery, stable across retries | The body’s `eventId` |
| Access revoked | A signed `terminated` envelope | Delivery stops silently |

By default the server advertises both capabilities. A client selects SEP-3415
by including `{"extensions":{"io.modelcontextprotocol/events":{}}}` in
`params._meta["io.modelcontextprotocol/clientCapabilities"]` on its event
requests. An undeclared client receives the draft profile, even if it supplies
`Mcp-Name`. A supplied routing header must match its body value in either profile.
The Julia client discovers the server automatically and prefers SEP-3415.

The extension makes the client declaration optional. For deployments where
every client should receive SEP-3415 even when it omits that declaration,
set `legacy_compat=false` on `enable_events!`. That server advertises only
the extension. The server saves the webhook profile on each subscription.
Pre-upgrade records load as draft. A SEP-3415 refresh upgrades the same
subscription ID in place.

## Configure a server

`principal(context)` returns the stable subject established by your
authentication middleware. `authorize(subject, name, arguments)` returns
`true` only when that subject has current access to the event and filters.
Discovery calls it with `arguments === nothing`; subscriptions and every
delivery attempt call it with the actual filters. Missing identity is forbidden.

Do not derive identity from MCP arguments, client metadata, or an unverified
bearer token. Deferred delivery stores the subject and rechecks access without
retaining the original request or bearer token.
The principal hook must also reject credentials that lack the required event
scope; the authorization hook checks current access for the saved subject.

```@example events
using ModelContextProtocol
const MCP = ModelContextProtocol

server = MCPServer(name="Review comments", version="1.0")

# Replace this dictionary with your application's current access checks.
documents = Dict("user-1" => Set(["doc-123"]))
authorize = function (subject, name, arguments)
    haskey(documents, subject) || return false
    name == "comment.created" || return false
    arguments === nothing && return true
    get(arguments, "document_id", nothing) in documents[subject]
end

directory = mktempdir() # Use a persistent, private directory in production.
store = MCP.FileEventSubscriptionStore(joinpath(directory, "subscriptions.json"))
MCP.enable_events!(server;
    store=store,
    principal=context -> get(context.http_request.context, :authenticated_subject, nothing),
    authorize=authorize,
)

MCP.register_event!(server;
    name="comment.created",
    description="A review comment was added to a document.",
    input_schema=Dict(
        "type" => "object",
        "properties" => Dict("document_id" => Dict("type" => "string")),
        "required" => ["document_id"],
        "additionalProperties" => false,
    ),
    payload_schema=Dict(
        "type" => "object",
        "properties" => Dict(
            "document_id" => Dict("type" => "string"),
            "comment_id" => Dict("type" => "string"),
            "text" => Dict("type" => "string"),
        ),
        "required" => ["document_id", "comment_id", "text"],
        "additionalProperties" => false,
    ),
    matches=(subject, arguments, data) ->
        arguments["document_id"] == data["document_id"],
)

@assert haskey(server.capabilities["extensions"], "io.modelcontextprotocol/events")
println("Webhook event registered")
```

Your authentication middleware must validate credentials and place the canonical
subject in `request.context[:authenticated_subject]` for this example.
The package does not authenticate incoming requests automatically.

`matches(subject, arguments, data)` implements your filter semantics. Supply
it explicitly; the package cannot infer whether an argument is a filter, glob,
or transformation. Optional `transform(subject, arguments, data)` can redact
each subscriber's payload. Hooks receive independent copies. JSONSchema.jl
validates subscription arguments and delivered payloads using drafts 4, 6,
and 7. When an implicit schema uses only portable keywords, the catalog leaves
out `$schema`, so clients use MCP's default 2020-12 dialect. Local validation
retains the same assertions. This allows ChatGPT's event settings discovery to
accept ordinary object schemas without requiring optional draft-7 support.

Portable schemas include scalar constraints, object properties and required
fields, homogeneous array items, and common composition keywords. Explicit
dialects are always preserved. Implicit schemas with references, tuple items,
`dependencies`, `format`, or unrecognized keywords retain an explicit draft-7
declaration. Such schemas require a client that supports that dialect. This
publication rule does not add general 2020-12 validation: newer explicit
dialects and external schema references are rejected.
Only local JSON Pointer references are resolved. Domain rules remain your
application's responsibility.

Configure the catalog at startup. Duplicate names are rejected. Publish breaking
schema changes under a new name and retain the old contract for existing
subscriptions. Dynamic catalog notifications are not implemented.

## Persistence and lifecycle

`FileEventSubscriptionStore` persists owner, filters, URL, keys, and expiry.
Each update writes a private temporary file and atomically replaces the old
file before changing memory. Loading invalid state fails instead of silently
discarding subscriptions. Protect the directory and backups: the file contains
signing secrets. Windows deployments must apply an appropriate directory ACL.

One process owns each file. Replicas need an application-backed
`MCPEventSubscriptionStore` with these methods:

- `get_event_subscription(store, id)`: return the record or `nothing`.
- `event_subscriptions(store)`: return a snapshot of the records.
- `save_event_subscription!(store, record)`: atomically insert or replace it.
- `delete_event_subscription!(store, id)`: idempotently delete it.

Distributed backends must enforce quotas and coordinate subscription changes
and delivery across workers. Built-in locks coordinate one process. Records are
plain data; callers must not mutate stored records or their filters.
Custom stores should persist and restore the record's `legacy_draft` flag.
Use `true` for rows created before SEP-3415 support.
`InMemoryEventSubscriptionStore` suits tests and temporary subscriptions;
use durable storage for ChatGPT.

Identity includes the authenticated subject, exact URL, event name, and
recursively sorted JSON arguments. Object key order does not create duplicates.
Numeric arguments `1` and `1.0` share an identity; booleans remain distinct.
Changing the subject, URL, name, or filters creates a different subscription.
A guessed `id` cannot address or modify another subscription.

The default lifetime is 30 minutes, capped at one day. Omitted `ttlMs` uses the
default. A finite request is clamped to the configured cap. `ttlMs: null`
requests no expiry; this implementation grants the cap instead.
Refresh before the returned `refreshBefore`. Expired subscriptions stop
delivering. A caller can unsubscribe after its resource access is revoked.
`events/list` then hides the event, so unsubscribe checks any `Mcp-Param-*`
headers the caller sends but does not require them.
For an already absent subscription SEP-3415 returns `NotFound` with
`data.kind == "subscription"`. Draft clients receive an empty success result.

Events are emit-only: `cursor` is always `null` and `truncated` is `false`.
A non-null replay cursor is explicitly unsupported, and `maxAgeMs` is ignored
because it only bounds replay. Subscription persistence does not recover an
occurrence whose emission was interrupted. Your application owns its reliable
queue or outbox.

## Callback verification and delivery

Before accepting a subscription, the server sends a signed challenge and
requires the endpoint to echo it in a `2xx` JSON response. A live subscription
from the same subject to the same URL counts as verified, so refreshes, key
rotation, and new filters send no challenge. Each subject runs one verification
at a time; its other subscribe calls wait, then reuse a verification that just
succeeded or fail on quota without sending one. A failure starts a short
cooldown for that subject and callback host, however the host is spelled.
Other subjects are unaffected, which matters when many users share a hosted
receiver. Subscription quotas bound state growth.

The default HTTPS sender validates every resolved address before each connection
and pins the selected address with libcurl's `CONNECT_TO`. The original hostname
still controls `Host`, TLS server name, and certificate verification. Redirects
and environment proxies are disabled. The conservative address policy blocks
special-purpose IPv4 and IPv6 ranges, including private, loopback, link-local,
documentation, transition, and multicast space.
System DNS resolution may outlast the configured request timeout; the deadline
is checked again before connecting.
Explicit `allow_private_addresses=true` permits private destinations in
controlled deployments and tests.

A replacement `request(url, address, headers, body, timeout)` transport is
trusted code. It must connect to the supplied address, preserve TLS hostname
verification, enforce its timeout, bound response sizes, and reject redirects.
It must not consult a second DNS answer or reinterpret the URL.

Emit an occurrence with a stable upstream ID:

```@example events
receipts = MCP.emit_event!(server, "comment.created",
    Dict("document_id" => "doc-123", "comment_id" => "comment-456", "text" => "Please clarify.");
    event_id="comment-456",
)
@assert isempty(receipts) # No client has subscribed in this example.
println("Occurrence validated")
rm(directory; recursive=true) # hide
```

Occurrences contain `eventId`, `name`, an ISO 8601 UTC `timestamp`, `data`,
and `cursor: null`. Application fields belong inside `data`. Pass `timestamp`
as Unix seconds to preserve the upstream occurrence time; it defaults to now.
SEP-3415 preserves the upstream ID in the body, including Unicode. For draft
receivers, IDs of 1–256 visible ASCII bytes pass through unchanged. Other IDs
become a deterministic `evt_` hash in both the draft body and header.

Every body is built and validated before any is sent, so a failing `matches`,
`transform`, or payload sends nothing. Each owner's subscriptions are delivered
in order and different owners concurrently, up to 16 at a time, so a slow
endpoint delays only its owner. `emit_event!` returns after every delivery
finishes; there is no background task or unbounded queue. Receipts contain
`subscription_id`, `accepted`, `attempts`, `status`, and `reason`. A `2xx`
acknowledges receipt, not completion of a ChatGPT task.
The default is four attempts with exponential backoff. `410` and `413` are not
retried. Access, expiry, and subscription existence are checked before every
attempt. Unsubscribe drains an in-flight request; later retries stop.

Each body is at most 256 KiB. Retries preserve the event ID and exact body,
but generate their signing timestamp and HMAC anew. A refresh with a replacement
`whsec_` secret dual-signs with the immediately previous key for a five-minute
grace period by default. Treat upstream text as untrusted data and keep
instructions to the agent out of event payloads.

## Client and receiver

Use an authenticated MCP `2026-07-28` client:

```julia
events = ModelContextProtocol.list_events(client)
secret = ModelContextProtocol.event_webhook_secret()
subscription = ModelContextProtocol.subscribe_event(client, "comment.created";
    arguments=Dict("document_id" => "doc-123"),
    url="https://receiver.example/hooks/one", secret=secret, ttl_ms=1_800_000,
)

# Refresh with the same identity before subscription["refreshBefore"].
ModelContextProtocol.unsubscribe_event(client, "comment.created";
    arguments=Dict("document_id" => "doc-123"),
    url="https://receiver.example/hooks/one",
)
```

The receiver must know the secret before subscribing. For the initial challenge,
use the pending secret for the callback URL. For subsequent deliveries select
the secret with `X-MCP-Subscription-Id` and call
`verify_event_webhook(secret, headers, raw_body)` before parsing JSON.
Verification checks exact bytes, required header uniqueness, body size,
timestamp freshness, and any matching `v1` signature during rotation.
The subscription ID is routing metadata, not part of the Standard Webhooks
signature; use separate secrets for different routes.

Echo the challenge for verified `type: "verification"` requests. A signed
`type: "terminated"` tells a SEP-3415 receiver to remove its subscription.
For events, validate the name and payload schema and deduplicate retries by
subscription ID and `webhook-id`. To recognize a repeated upstream occurrence,
deduplicate by subscription ID and the body's `eventId`. The same upstream
event can legitimately match multiple subscriptions. Durably accept or enqueue
the event before acknowledging it.

## Limits and errors

This profile provides emit-only webhooks with finite lifetimes. It offers no
polling, push streams, replay, dynamic catalogs, no-expiry grants, asymmetric
signing, full JSON Schema 2020-12 validation, or replay-gap notifications.
On access revocation the server removes the subscription and makes one
best-effort signed termination POST for SEP-3415 receivers.
Existing MCP transport notifications and `subscriptions/listen` are separate.

| SEP-3415 | Draft | Meaning |
| --- | --- | --- |
| `-32602` | `-32602` | Invalid arguments, URL, secret, TTL, or destination address. |
| `-32020` | `-32020` | Routing header mismatch (HTTP 400). |
| `-32023` | `-32011` | Unknown event. SEP-3415 also uses this code for an absent subscription. |
| `-32024` | `-32012` | Missing authenticated owner or denied access. |
| `-32025` | `-32013` | Subscription quota or callback verification cooldown. |
| `-32026` | `-32014` | Unsupported delivery mode or replay cursor. |
| `-32027` | `-32015` | Callback failure, with a safe `data.reason`. |

Endpoint bodies and transport diagnostics are never returned in callback
errors. Event methods sent as JSON-RPC notifications are rejected with HTTP
`400` and do not change state.

```@docs
ModelContextProtocol.enable_events!
ModelContextProtocol.register_event!
ModelContextProtocol.emit_event!
ModelContextProtocol.InMemoryEventSubscriptionStore
ModelContextProtocol.FileEventSubscriptionStore
ModelContextProtocol.list_events
ModelContextProtocol.subscribe_event
ModelContextProtocol.unsubscribe_event
ModelContextProtocol.event_webhook_secret
ModelContextProtocol.verify_event_webhook
```
