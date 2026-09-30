# MCP Events

The package implements the **webhook profile** of the
[draft MCP Events proposal](https://github.com/modelcontextprotocol/experimental-ext-triggers-events/blob/main/docs/design-sketch-proposal.md)
on MCP `2026-07-28`, matching the delivery mode supported by
[ChatGPT plugins](https://developers.openai.com/plugins/build/mcp-events).
Enable it explicitly on the general server. The static JuliaC server remains
tools-only. All event APIs stay under the package namespace.

Clients discover definitions with `events/list`, create or refresh subscriptions
with `events/subscribe`, and stop them with `events/unsubscribe`. These methods
use the existing authenticated MCP endpoint. Enabling events adds `events: {}`
to `server/discover`; each event advertises only `delivery: ["webhook"]`.

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

@assert haskey(server.capabilities, "events")
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
and 7. An omitted dialect is explicitly published as draft 7; it never implies
2020-12 validation. Newer dialects and external schema references are rejected.
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
delivering. Unsubscribe is idempotent and remains possible after resource access
is revoked.

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

The receiver must know the secret before subscribing. Select it with
`X-MCP-Subscription-Id` and call
`verify_event_webhook(secret, headers, raw_body)` before parsing JSON.
Verification checks exact bytes, required header uniqueness, body size,
timestamp freshness, and any matching `v1` signature during rotation.
The subscription ID is routing metadata, not part of the Standard Webhooks
signature; use separate secrets for different routes.

Echo the challenge for verified `type: "verification"` requests.
For events, validate the name and payload schema, deduplicate `webhook-id`,
and durably accept or enqueue the event before acknowledging it.

## Limits and errors

Polling, push streams, replay, dynamic catalogs, no-expiry grants, asymmetric
signing, JSON Schema 2020-12 validation, and draft `gap`/`terminated` envelopes are not implemented or
advertised. Access revocation stops delivery and removes the subscription.
Existing MCP transport notifications and `subscriptions/listen` are separate.

| Code | Meaning |
| --- | --- |
| `-32602` | Invalid arguments, URL, secret, TTL, or destination address. |
| `-32011` | Unknown event, with `data.kind: "event"`. |
| `-32012` | Missing authenticated owner or denied access. |
| `-32013` | Subscription quota or callback verification cooldown. |
| `-32014` | Unsupported delivery mode or replay cursor. |
| `-32015` | Callback failure, with a safe `data.reason`. |

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
