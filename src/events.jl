const MCP_EVENT_BODY_LIMIT = 256 * 1024
const MCP_EVENT_ARGUMENT_LIMIT = 16 * 1024
const MCP_EVENT_METHODS = ("events/list", "events/subscribe", "events/unsubscribe")

function redact_event_request_body(body::String)
    isempty(body) && return body
    payload = try
        JSON.parse(body)
    catch
        return "[invalid JSON-RPC body]"
    end
    payload isa AbstractDict && get(payload, "method", nothing) == "events/subscribe" || return body
    params = get(payload, "params", nothing)
    params isa AbstractDict || return body
    delivery = get(params, "delivery", nothing)
    delivery isa AbstractDict && haskey(delivery, "secret") || return body
    delivery["secret"] = "[redacted]"
    return JSON.json(payload)
end

event_error(code, message; data...) = MCPEventError(code, message, JSONDict(String(k) => v for (k, v) in data))

"""
    InMemoryEventSubscriptionStore()

Process-local webhook subscriptions. Use FileEventSubscriptionStore or an
application-backed MCPEventSubscriptionStore for subscriptions that must survive
restarts. Store implementations provide get_event_subscription,
event_subscriptions, save_event_subscription!, and delete_event_subscription!.
Collection reads return snapshots; records and their filters must not be mutated,
and writes must be atomic.
"""
mutable struct InMemoryEventSubscriptionStore <: MCPEventSubscriptionStore
    records::Dict{String,MCPWebhookSubscription}
    lock::ReentrantLock
end

InMemoryEventSubscriptionStore() = InMemoryEventSubscriptionStore(Dict{String,MCPWebhookSubscription}(), ReentrantLock())

"""
    FileEventSubscriptionStore(path)

Load webhook subscriptions from a private JSON file, or create a new store.
Updates replace the file atomically before becoming visible in memory. Signing
secrets are stored in the file; protect its directory and backups.

One process owns each file. For multiple workers, implement
MCPEventSubscriptionStore using a shared transactional database.
"""
struct FileEventSubscriptionStore <: MCPEventSubscriptionStore
    path::String
    state::InMemoryEventSubscriptionStore
end

get_event_subscription(store::InMemoryEventSubscriptionStore, id::String) = @lock store.lock get(store.records, id, nothing)
event_subscriptions(store::InMemoryEventSubscriptionStore) = @lock store.lock collect(values(store.records))
get_event_subscription(store::FileEventSubscriptionStore, id::String) = get_event_subscription(store.state, id)
event_subscriptions(store::FileEventSubscriptionStore) = event_subscriptions(store.state)

function save_event_subscription!(store::InMemoryEventSubscriptionStore, subscription::MCPWebhookSubscription)
    @lock store.lock store.records[subscription.id] = subscription
    return subscription
end

function delete_event_subscription!(store::InMemoryEventSubscriptionStore, id::String)
    @lock store.lock pop!(store.records, id, nothing)
    return nothing
end

function subscription_record(subscription::MCPWebhookSubscription)
    return JSONDict(
        "id" => subscription.id, "principal" => subscription.principal,
        "name" => subscription.name, "arguments" => subscription.arguments,
        "url" => subscription.url, "secret" => subscription.secret,
        "expiresAt" => subscription.expires_at,
        "previousSecret" => subscription.previous_secret,
        "previousSecretUntil" => subscription.previous_secret_until,
        "instance" => subscription.instance,
    )
end

function write_event_store(store::FileEventSubscriptionStore, records)
    document = JSONDict("version" => 1, "subscriptions" => [
        subscription_record(records[id]) for id in sort!(collect(keys(records)))
    ])
    temporary, io = mktemp(dirname(store.path); cleanup=false)
    try
        chmod(temporary, 0o600)
        write(io, JSON.json(document))
        flush(io)
        # Put the bytes on disk before the rename, so a crash leaves the old
        # or the new file rather than an empty one that fails to load.
        Sys.iswindows() || systemerror(:fsync, ccall(:fsync, Cint, (Cint,), fd(io)) != 0)
        close(io)
        # Julia < 1.12's rename helper can fall back to a non-atomic copy.
        # Use the same libuv operation directly, failing without a fallback.
        result = ccall(:jl_fs_rename, Int32, (Cstring, Cstring), temporary, store.path)
        result < 0 && Base.uv_error("rename event subscription store", result)
    finally
        isopen(io) && close(io)
        isfile(temporary) && rm(temporary)
    end
    return nothing
end

function update_event_store!(store::FileEventSubscriptionStore, id::String, subscription)
    @lock store.state.lock begin
        subscription === nothing && !haskey(store.state.records, id) && return nothing
        updated = copy(store.state.records)
        subscription === nothing ? pop!(updated, id, nothing) : (updated[id] = subscription)
        write_event_store(store, updated)
        store.state.records = updated
    end
    return subscription
end

save_event_subscription!(store::FileEventSubscriptionStore, subscription::MCPWebhookSubscription) =
    update_event_store!(store, subscription.id, subscription)
delete_event_subscription!(store::FileEventSubscriptionStore, id::String) = (update_event_store!(store, id, nothing); nothing)

function event_string(value, label; max_bytes=4096)
    value isa AbstractString && isvalid(value) && 0 < ncodeunits(value) <= max_bytes ||
        throw(mcp_error(:invalid_params, "$(label) must be a non-empty string of at most $(max_bytes) bytes"))
    return String(value)
end

function event_integer(value, label; minimum=0, maximum=MCP_SAFE_INTEGER_MAX)
    value isa Integer && !(value isa Bool) && minimum <= value <= maximum ||
        throw(mcp_error(:invalid_params, "$(label) must be an integer between $(minimum) and $(maximum)"))
    return Int(value)
end

function event_json(value, depth=0)
    depth <= 32 || throw(mcp_error(:invalid_params, "Event JSON nesting exceeds 32 levels"))
    if value isa AbstractDict
        result = JSONDict()
        for (key, item) in value
            key isa AbstractString && isvalid(key) || throw(mcp_error(:invalid_params, "Event object keys must be valid strings"))
            result[String(key)] = event_json(item, depth + 1)
        end
        return result
    elseif value isa AbstractVector
        return Any[event_json(item, depth + 1) for item in value]
    elseif value === nothing || value isa Bool
        return value
    elseif value isa AbstractString
        isvalid(value) || throw(mcp_error(:invalid_params, "Event strings must contain valid UTF-8"))
        return String(value)
    elseif value isa Integer
        abs(BigInt(value)) <= MCP_SAFE_INTEGER_MAX ||
            throw(mcp_error(:invalid_params, "Event integers must fit the JSON safe integer range"))
        return Int64(value)
    elseif value isa AbstractFloat
        isfinite(value) || throw(mcp_error(:invalid_params, "Event numbers must be finite"))
        # Numerically equal JSON arguments (1, 1.0, -0.0) identify the same
        # subscription. Booleans remain distinct from numbers.
        isinteger(value) && abs(value) <= MCP_SAFE_INTEGER_MAX && return Int64(value)
        converted = Float64(value)
        isfinite(converted) || throw(mcp_error(:invalid_params, "Event numbers must fit Float64"))
        return converted
    end
    throw(mcp_error(:invalid_params, "Event values must be JSON values"))
end

function event_object(value, label)
    value isa AbstractDict || throw(mcp_error(:invalid_params, "$(label) must be an object"))
    return event_json(value)
end

function event_arguments(params)
    arguments = event_object(get(params, "arguments", JSONDict()), "arguments")
    ncodeunits(JSON.json(arguments)) <= MCP_EVENT_ARGUMENT_LIMIT ||
        throw(mcp_error(:invalid_params, "Event arguments exceed 16 KiB"))
    return arguments
end

function event_subscription_id(principal::String, url::String, name::String, arguments)
    key = JSON.json(Any[principal, url, name, event_json(arguments)]; sort_keys=true)
    return "sub_" * bytes2hex(sha256(key))
end

function FileEventSubscriptionStore(path::AbstractString)
    store = FileEventSubscriptionStore(abspath(path), InMemoryEventSubscriptionStore())
    # Fail at startup, not on a client's first subscribe.
    isdir(dirname(store.path)) || throw(ArgumentError("Subscription store directory must already exist"))
    isfile(store.path) || return store
    # Refuse to load a file whose secrets are readable by other Unix users.
    Sys.iswindows() || (filemode(store.path) & 0o077 == 0) ||
        throw(ArgumentError("Subscription store permissions must exclude group and other users"))
    try
        document = JSON.parsefile(store.path)
        document isa AbstractDict && get(document, "version", nothing) === 1 || error("Invalid store version")
        records = document["subscriptions"]
        records isa AbstractVector || error("Invalid subscriptions")
        for record in records
            principal = event_string(record["principal"], "principal")
            name = event_string(record["name"], "name")
            arguments = event_object(record["arguments"], "arguments")
            url = event_string(record["url"], "url")
            callback_uri(url)
            secret = event_string(record["secret"], "secret")
            event_webhook_key(secret)
            id = event_subscription_id(principal, url, name, arguments)
            id == record["id"] && !haskey(store.state.records, id) || error("Invalid subscription identity")
            expires_at = record["expiresAt"]
            previous_until = get(record, "previousSecretUntil", 0.0)
            expires_at isa Real && !(expires_at isa Bool) && isfinite(expires_at) && expires_at > 0 || error("Invalid expiry")
            previous_until isa Real && !(previous_until isa Bool) && isfinite(previous_until) || error("Invalid rotation expiry")
            previous_secret = get(record, "previousSecret", nothing)
            previous_secret === nothing || event_webhook_key(previous_secret)
            instance = event_string(record["instance"], "instance")
            store.state.records[id] = MCPWebhookSubscription(
                id, principal, name, arguments, url, secret, Float64(expires_at),
                previous_secret, Float64(previous_until), instance,
            )
        end
    catch
        throw(ArgumentError("Invalid event subscription store"))
    end
    return store
end

"""
    enable_events!(server; store, principal, authorize, ...)

Enable the draft MCP Events webhook profile on MCP 2026-07-28 requests.
principal(context) must return a stable authenticated subject or nothing.
authorize(principal, name, arguments) must return true to allow access; arguments
is nothing for catalog discovery. It is called again before each delivery.
Neither hook may trust identity supplied in MCP params or unverified headers.

Subscriptions have finite lifetimes, capped by max_ttl_ms (default one day).
Emit-only events do not support replay and always return cursor: null.
request(url, address, headers, body, timeout) is a trusted transport hook; its
default pins the validated address, verifies TLS, and disables redirects and
proxies. A replacement must preserve those guarantees.
"""
function enable_events!(server::MCPServer;
    store::MCPEventSubscriptionStore, principal::Function, authorize::Function,
    request::Function=request_event_webhook, resolve::Function=Sockets.getalladdrinfo,
    clock::Function=time, wait::Function=sleep,
    default_ttl_ms::Integer=1_800_000, max_ttl_ms::Integer=86_400_000,
    max_subscriptions::Integer=1000, max_subscriptions_per_principal::Integer=100,
    verification_cooldown::Real=5, rotation_grace::Real=300, timeout::Real=10,
    max_attempts::Integer=4, retry_delay::Real=0.25,
    allow_private_addresses::Bool=false,
)
    server.events === nothing || throw(ArgumentError("Events are already enabled"))
    1 <= default_ttl_ms <= max_ttl_ms <= MCP_SAFE_INTEGER_MAX || throw(ArgumentError("Invalid event TTL limits"))
    max_subscriptions > 0 && max_subscriptions_per_principal > 0 || throw(ArgumentError("Subscription limits must be positive"))
    1 <= max_attempts <= 10 || throw(ArgumentError("max_attempts must be between 1 and 10"))
    all(x -> isfinite(x) && x > 0, (verification_cooldown, timeout)) ||
        throw(ArgumentError("Verification cooldown and request timeout must be positive and finite"))
    all(x -> isfinite(x) && x >= 0, (rotation_grace, retry_delay)) ||
        throw(ArgumentError("Rotation grace and retry delay must be non-negative and finite"))
    server.events = MCPEvents(
        store, principal, authorize, Dict{String,MCPServerEvent}(), request, resolve, clock, wait,
        Int(default_ttl_ms), Int(max_ttl_ms), Int(max_subscriptions), Int(max_subscriptions_per_principal),
        Float64(verification_cooldown), Float64(rotation_grace), Float64(timeout),
        Int(max_attempts), Float64(retry_delay), allow_private_addresses,
        Dict{Tuple{String,String},Float64}(), Dict{String,Int}(), Threads.Condition(),
    )
    ensure_capability!(server, "events")
    return server
end

function require_events(server::MCPServer)
    server.events === nothing && throw(mcp_error(:method_not_found, "MCP Events are not enabled"))
    return server.events::MCPEvents
end

function check_event_schema_references(schema)
    if schema isa AbstractDict
        dialect = get(schema, "\$schema", nothing)
        if dialect isa AbstractString
            replace(dialect, r"#$" => "") in (
                "http://json-schema.org/draft-04/schema", "https://json-schema.org/draft-04/schema",
                "http://json-schema.org/draft-06/schema", "https://json-schema.org/draft-06/schema",
                "http://json-schema.org/draft-07/schema", "https://json-schema.org/draft-07/schema",
            ) || throw(ArgumentError("Event schemas must use JSON Schema draft 4, 6, or 7"))
        end
        ref = get(schema, "\$ref", nothing)
        ref isa AbstractString && !(ref == "#" || startswith(ref, "#/")) &&
            throw(ArgumentError("Event schemas may only use local JSON Pointer references"))
        for (key, value) in schema
            key in ("const", "enum") || check_event_schema_references(value)
        end
    elseif schema isa AbstractVector
        foreach(check_event_schema_references, schema)
    end
    return nothing
end

"""
    register_event!(server; name, input_schema, payload_schema, matches, ...)

Register an emit-only webhook event. Schemas are validated by JSONSchema.jl
(draft 4, 6, or 7); omitted dialects are explicitly published as draft 7.
External schema references are rejected. matches(principal, arguments, data) applies subscription
filters; transform(principal, arguments, data) may redact the delivered payload.
The catalog is configured at startup. Duplicate names are rejected; publish
breaking schema changes under a new event name.
"""
function register_event!(server::MCPServer; name, input_schema, payload_schema,
    matches::Function, transform::Function=(_principal, _arguments, data) -> data,
    description=nothing, meta=JSONDict(),
)
    events = require_events(server)
    event_name = event_string(name, "name"; max_bytes=256)
    input = event_object(input_schema, "input_schema")
    payload = event_object(payload_schema, "payload_schema")
    for schema in (input, payload)
        get!(schema, "\$schema", "http://json-schema.org/draft-07/schema#")
        schema["\$schema"] isa AbstractString || throw(ArgumentError("Event schema dialect must be a string"))
        check_event_schema_references(schema)
    end
    definition = MCPServerEvent(
        event_name, description === nothing ? nothing : String(description),
        input, payload, JSONSchema.Schema(deepcopy(input)), JSONSchema.Schema(deepcopy(payload)),
        matches, transform, event_object(meta, "meta"),
    )
    @lock events.lock begin
        haskey(events.definitions, event_name) && throw(ArgumentError("Duplicate event name"))
        events.definitions[event_name] = definition
    end
    return server
end

function event_descriptor(event::MCPServerEvent)
    descriptor = JSONDict(
        "name" => event.name, "delivery" => ["webhook"],
        "inputSchema" => deepcopy(event.input_schema), "payloadSchema" => deepcopy(event.payload_schema),
    )
    event.description === nothing || (descriptor["description"] = event.description)
    isempty(event.meta) || (descriptor["_meta"] = deepcopy(event.meta))
    return descriptor
end

function event_principal(events::MCPEvents, context::MCPRequestContext)
    principal = Base.invokelatest(events.principal, context)
    principal isa AbstractString && 0 < ncodeunits(principal) <= 4096 && isvalid(principal) ||
        throw(event_error(-32012, "Forbidden"))
    return String(principal)
end

event_authorized(events::MCPEvents, principal, name, arguments) =
    Base.invokelatest(events.authorize, principal, name, deepcopy(arguments)) === true

function list_events(server::MCPServer, context::MCPRequestContext, params::JSONDict)
    events = require_events(server)
    principal = event_principal(events, context)
    definitions = @lock events.lock collect(values(events.definitions))
    sort!(definitions; by=event -> event.name)
    visible = [event_descriptor(event) for event in definitions if event_authorized(events, principal, event.name, nothing)]
    # Reuse the package's pagination, with stricter event wire types.
    cursor = get(params, "cursor", nothing)
    cursor === nothing || event_string(cursor, "cursor")
    limit = get(params, "limit", nothing)
    limit === nothing || event_integer(limit, "limit"; minimum=1)
    return paginate_collection(visible, params, "events")
end

function callback_uri(url::AbstractString)
    ncodeunits(url) <= 4096 && isascii(url) && startswith(url, "https://") &&
        !occursin(r"[\x00-\x20\x7f\\#]|%(?![0-9a-fA-F]{2})", url) ||
        throw(mcp_error(:invalid_params, "Callback URL must be an absolute HTTPS URL without whitespace or fragment"))
    uri = try
        HTTP.URI(url)
    catch
        throw(mcp_error(:invalid_params, "Invalid callback URL"))
    end
    host = String(uri.host)
    isempty(host) && throw(mcp_error(:invalid_params, "Callback URL must have a hostname"))
    isempty(uri.userinfo) && !occursin('@', first(split(url[9:end], r"[/\?]"; limit=2))) ||
        throw(mcp_error(:invalid_params, "Callback URL must not contain user information"))
    host = startswith(host, "[") && endswith(host, "]") ? host[2:end-1] : host
    if occursin(':', host)
        try
            parse(IPv6, host)
        catch
            throw(mcp_error(:invalid_params, "Invalid callback hostname"))
        end
    else
        occursin(r"^[A-Za-z0-9.-]+$", host) || throw(mcp_error(:invalid_params, "Invalid callback hostname"))
    end
    port = isempty(uri.port) ? 443 : tryparse(Int, uri.port)
    port !== nothing && 1 <= port <= 65535 || throw(mcp_error(:invalid_params, "Invalid callback port"))
    return (url=String(url), host=host, port=port)
end

function public_event_address(address::IPv4)
    ip = UInt32(address)
    # Conservative exclusion of IANA special-purpose ranges, including
    # documentation, carrier NAT, benchmarking, multicast, and reserved space.
    ranges = (
        (ip"0.0.0.0", 8), (ip"10.0.0.0", 8), (ip"100.64.0.0", 10),
        (ip"127.0.0.0", 8), (ip"169.254.0.0", 16), (ip"172.16.0.0", 12),
        (ip"192.0.0.0", 24), (ip"192.0.2.0", 24), (ip"192.88.99.0", 24),
        (ip"192.168.0.0", 16), (ip"198.18.0.0", 15), (ip"198.51.100.0", 24),
        (ip"203.0.113.0", 24), (ip"224.0.0.0", 4), (ip"240.0.0.0", 4),
    )
    return !any(ranges) do (base, bits)
        mask = typemax(UInt32) << (32 - bits)
        (ip & mask) == (UInt32(base) & mask)
    end
end

function public_event_address(address::IPv6)
    ip = UInt128(address)
    # IPv4-mapped addresses inherit the IPv4 policy.
    ip >> 32 == 0xffff && return public_event_address(IPv4(UInt32(ip & typemax(UInt32))))
    ip >> 125 == 1 || return false # allocated global unicast 2000::/3
    ranges = ((ip"2001::", 23), (ip"2001:db8::", 32), (ip"2002::", 16), (ip"3ffe::", 16), (ip"3fff::", 20))
    return !any(ranges) do (base, bits)
        mask = typemax(UInt128) << (128 - bits)
        (ip & mask) == (UInt128(base) & mask)
    end
end

function event_webhook_key(secret)
    secret isa AbstractString && 38 <= ncodeunits(secret) <= 94 && startswith(secret, "whsec_") ||
        throw(mcp_error(:invalid_params, "Signing secret must be whsec_ followed by base64 of 24-64 bytes"))
    encoded = String(secret[7:end])
    key = try
        base64decode(encoded)
    catch
        UInt8[]
    end
    24 <= length(key) <= 64 && base64encode(key) == encoded ||
        throw(mcp_error(:invalid_params, "Signing secret must be whsec_ followed by base64 of 24-64 bytes"))
    return key
end

"""Generate a Standard Webhooks signing secret from 32 cryptographically random bytes."""
event_webhook_secret() = "whsec_" * base64encode(rand(RandomDevice(), UInt8, 32))

function event_header_id(id)
    id isa AbstractString && 0 < ncodeunits(id) <= 256 &&
        all(b -> 0x21 <= b <= 0x7e, codeunits(id)) ||
        throw(ArgumentError("Webhook IDs must contain 1-256 visible ASCII bytes"))
    return String(id)
end

function constant_time_equal(left, right)
    ncodeunits(left) == ncodeunits(right) || return false
    mismatch = UInt8(0)
    for (a, b) in zip(codeunits(left), codeunits(right))
        mismatch |= a ⊻ b
    end
    return mismatch == 0
end

function event_webhook_headers(id, subscription_id, body, secrets; signed_at=time())
    webhook_id = event_header_id(id)
    subscription_id = event_header_id(subscription_id)
    timestamp = string(floor(Int64, signed_at))
    message = webhook_id * "." * timestamp * "." * body
    signatures = ["v1," * base64encode(hmac_sha256(event_webhook_key(secret), message)) for secret in secrets]
    return HeaderPair[
        "Content-Type" => "application/json", "webhook-id" => webhook_id,
        "webhook-timestamp" => timestamp, "webhook-signature" => join(signatures, " "),
        "X-MCP-Subscription-Id" => subscription_id,
    ]
end

"""
    verify_event_webhook(secret, headers, body; now=time(), tolerance=300)

Verify Standard Webhooks signatures over the exact body bytes before parsing
JSON. Accept any valid v1 signature during rotation; reject duplicate required
headers, oversized bodies, and timestamps outside the freshness window.
Receivers must also deduplicate webhook-id and check the event's schema.
"""
function verify_event_webhook(secret, headers, body; now=time(), tolerance=300)
    isfinite(now) && isfinite(tolerance) && tolerance >= 0 || return false
    bytes = body isa AbstractString ? String(body) : String(copy(body))
    ncodeunits(bytes) <= MCP_EVENT_BODY_LIMIT || return false
    required = ("webhook-id", "webhook-timestamp", "webhook-signature", "x-mcp-subscription-id")
    values = Dict{String,String}()
    for (name, value) in headers
        key = lowercase(String(name))
        key in required || continue
        haskey(values, key) && return false
        value isa AbstractString || return false
        values[key] = String(value)
    end
    all(key -> haskey(values, key), required) || return false
    try
        event_header_id(values["webhook-id"])
        event_header_id(values["x-mcp-subscription-id"])
        timestamp_text = values["webhook-timestamp"]
        occursin(r"^[0-9]{1,19}$", timestamp_text) || return false
        timestamp = tryparse(Int64, timestamp_text)
        timestamp !== nothing && abs(now - timestamp) <= tolerance || return false
        signature_text = values["webhook-signature"]
        ncodeunits(signature_text) <= 4096 || return false
        message = values["webhook-id"] * "." * timestamp_text * "." * bytes
        expected = base64encode(hmac_sha256(event_webhook_key(secret), message))
        return any(split(signature_text)) do signature
            startswith(signature, "v1,") && constant_time_equal(signature[4:end], expected)
        end
    catch
        return false
    end
end

function callback_failure(reason)
    return event_error(-32015, "CallbackEndpointError"; reason=reason)
end

function request_event_webhook(url, address::IPAddr, headers, body, timeout)
    uri = callback_uri(url)
    connect_host = address isa IPv6 ? "[$(address)]" : string(address)
    # libcurl's CONNECT_TO pins only the connection address: the original URL
    # still controls Host, TLS SNI, and certificate hostname verification.
    curl = Downloads.Curl
    addresses = curl.curl_slist_append(C_NULL, "::$(connect_host):$(uri.port)")
    addresses == C_NULL && throw(callback_failure("connection_refused"))
    downloader = Downloads.Downloader(; grace=0)
    downloader.easy_hook = function (easy, _info)
        for (option, value) in (
            (curl.CURLOPT_CONNECT_TO, addresses), (curl.CURLOPT_FOLLOWLOCATION, 0),
            (curl.CURLOPT_PROXY, ""), (curl.CURLOPT_SSL_VERIFYPEER, 1), (curl.CURLOPT_SSL_VERIFYHOST, 2),
        )
            curl.setopt(easy, option, value) == 0 || throw(callback_failure("connection_refused"))
        end
    end
    output = IOBuffer(; maxsize=8192)
    try
        response = Downloads.request(
            url; method="POST", input=IOBuffer(body), output=output,
            headers=headers, timeout=timeout, downloader=downloader, throw=false,
        )
        if response isa Downloads.RequestError
            reason = response.code == 28 ? "timeout" : response.code in (35, 51, 58, 60, 77, 83, 90, 91) ? "tls_error" : "connection_refused"
            throw(callback_failure(reason))
        end
        return (status=Int(response.status), body=String(take!(output)))
    finally
        curl.curl_slist_free_all(addresses)
    end
end

function post_event_webhook(events::MCPEvents, url, headers, body; deadline=events.clock() + events.timeout)
    uri = callback_uri(url)
    addresses = try
        Base.invokelatest(events.resolve, uri.host)
    catch
        throw(callback_failure("connection_refused"))
    end
    isempty(addresses) && throw(callback_failure("connection_refused"))
    all(address -> address isa IPAddr && (events.allow_private_addresses || public_event_address(address)), addresses) ||
        throw(mcp_error(:invalid_params, "Callback destination is not a public address"))
    remaining = deadline - events.clock()
    remaining > 0 || throw(callback_failure("timeout"))
    response = try
        Base.invokelatest(events.request, uri.url, first(addresses), headers, body, remaining)
    catch err
        err isa MCPEventError && rethrow()
        # Never expose endpoint-controlled response bodies or transport errors.
        throw(callback_failure("connection_refused"))
    end
    status = Int(response.status)
    status in 300:399 && throw(callback_failure("http_4xx"))
    return response
end

function verify_event_callback!(events::MCPEvents, principal, uri, id, secret)
    # Rate limits are per principal so one caller cannot block callbacks that
    # share a host, such as a hosted client's receiver. Each principal runs one
    # verification per host at a time, and a failure starts a cooldown.
    key = (principal, uri.host)
    @lock events.lock begin
        while get(events.verifications, key, 0.0) == Inf
            wait(events.lock)
        end
        now = events.clock()
        filter!(entry -> last(entry) > now, events.verifications)
        haskey(events.verifications, key) &&
            throw(event_error(-32013, "ResourceExhausted"; limit="callbackVerification"))
        events.verifications[key] = Inf
    end
    verified = false
    try
        started = events.clock()
        challenge = base64encode(rand(RandomDevice(), UInt8, 32))
        body = JSON.json(JSONDict("type" => "verification", "challenge" => challenge))
        headers = event_webhook_headers("msg_verification_" * string(uuid4()), id, body, (secret,); signed_at=started)
        response = post_event_webhook(events, uri.url, headers, body)
        response.status in 200:299 ||
            throw(callback_failure(response.status >= 500 ? "http_5xx" : "http_4xx"))
        received = try
            ncodeunits(response.body) <= 8192 || throw(ArgumentError("Oversized verification response"))
            parsed = JSON.parse(response.body)
            parsed isa AbstractDict ? get(parsed, "challenge", nothing) : nothing
        catch
            nothing
        end
        received isa AbstractString && events.clock() - started <= events.timeout &&
            constant_time_equal(received, challenge) || throw(callback_failure("challenge_failed"))
        verified = true
    finally
        @lock events.lock begin
            if verified
                delete!(events.verifications, key)
            else
                events.verifications[key] = events.clock() + events.verification_cooldown
            end
            notify(events.lock)
        end
    end
    return nothing
end

# Delete expired records and return the live ones. Call with events.lock held.
function live_event_subscriptions!(events::MCPEvents)
    now = events.clock()
    live = MCPWebhookSubscription[]
    for record in event_subscriptions(events.store)
        record.expires_at > now ? push!(live, record) : delete_event_subscription!(events.store, record.id)
    end
    return live
end

function check_event_quota(events::MCPEvents, records, principal, id)
    any(record -> record.id == id, records) && return nothing
    length(records) < events.max_subscriptions ||
        throw(event_error(-32013, "ResourceExhausted"; limit="subscriptions", max=events.max_subscriptions))
    count(record -> record.principal == principal, records) < events.max_subscriptions_per_principal ||
        throw(event_error(-32013, "ResourceExhausted"; limit="subscriptionsPerPrincipal", max=events.max_subscriptions_per_principal))
    return nothing
end

function event_subscription_params(events::MCPEvents, context, params; subscribing)
    principal = event_principal(events, context)
    haskey(params, "id") && throw(mcp_error(:invalid_params, "Subscriptions are addressed by name, arguments, and delivery URL"))
    name = event_string(get(params, "name", nothing), "name"; max_bytes=256)
    arguments = event_arguments(params)
    delivery = event_object(get(params, "delivery", nothing), "delivery")
    mode = get(delivery, "mode", subscribing ? nothing : "webhook")
    mode isa AbstractString || throw(mcp_error(:invalid_params, "delivery.mode must be a string"))
    mode == "webhook" || throw(event_error(-32014, "Unsupported"; feature="deliveryMode", value=mode))
    uri = callback_uri(event_string(get(delivery, "url", nothing), "delivery.url"))
    return principal, name, arguments, delivery, uri
end

event_iso8601(timestamp) = Dates.format(Dates.unix2datetime(timestamp), dateformat"yyyy-mm-ddTHH:MM:SS.sss") * "Z"

# Omitted ttlMs gets the default. null asks for no expiry, which is never
# granted, so it gets the longest finite lifetime. Longer requests are clamped.
function event_ttl_ms(events::MCPEvents, params)
    haskey(params, "ttlMs") || return events.default_ttl_ms
    ttl = params["ttlMs"]
    ttl === nothing && return events.max_ttl_ms
    ttl isa Integer && !(ttl isa Bool) && ttl > 0 ||
        throw(mcp_error(:invalid_params, "ttlMs must be a positive integer or null"))
    return ttl > events.max_ttl_ms ? events.max_ttl_ms : Int(ttl)
end

function subscribe_event(server::MCPServer, context::MCPRequestContext, params::JSONDict)
    events = require_events(server)
    principal, name, arguments, delivery, uri = event_subscription_params(events, context, params; subscribing=true)
    definition = @lock events.lock get(events.definitions, name, nothing)
    definition === nothing && throw(event_error(-32011, "NotFound"; kind="event"))
    event_authorized(events, principal, name, nothing) || throw(event_error(-32012, "Forbidden"))
    JSONSchema.isvalid(definition.input_validator, arguments) || throw(mcp_error(:invalid_params, "Arguments do not match the event inputSchema"))
    event_authorized(events, principal, name, arguments) || throw(event_error(-32012, "Forbidden"))
    secret = get(delivery, "secret", nothing)
    event_webhook_key(secret)
    # Emit-only events cannot replay, so maxAgeMs, which only bounds replay, is ignored.
    get(params, "cursor", nothing) === nothing || throw(event_error(-32014, "Unsupported"; feature="cursor"))
    ttl_ms = event_ttl_ms(events, params)
    id = event_subscription_id(principal, uri.url, name, arguments)
    # Check quotas before sending any callback traffic. A live subscription
    # from this principal to this URL shows the endpoint already consented.
    verified = @lock events.lock begin
        records = live_event_subscriptions!(events)
        check_event_quota(events, records, principal, id)
        any(record -> record.principal == principal && record.url == uri.url, records)
    end
    if !verified
        verify_event_callback!(events, principal, uri, id, secret)
        # Access can change while the endpoint answers.
        event_authorized(events, principal, name, arguments) || throw(event_error(-32012, "Forbidden"))
    end
    return @lock events.lock begin
        records = live_event_subscriptions!(events)
        check_event_quota(events, records, principal, id)
        previous = get_event_subscription(events.store, id)
        now = events.clock()
        rotated = previous !== nothing && previous.secret != secret
        expires_at = now + ttl_ms / 1000
        save_event_subscription!(events.store, MCPWebhookSubscription(
            id, principal, name, deepcopy(arguments), uri.url, String(secret), expires_at,
            previous === nothing ? nothing : rotated ? previous.secret : previous.previous_secret,
            previous === nothing ? 0.0 : rotated ? now + events.rotation_grace : previous.previous_secret_until,
            previous === nothing ? string(uuid4()) : previous.instance,
        ))
        JSONDict("id" => id, "refreshBefore" => event_iso8601(expires_at), "cursor" => nothing, "truncated" => false)
    end
end

function unsubscribe_event(server::MCPServer, context::MCPRequestContext, params::JSONDict)
    events = require_events(server)
    principal, name, arguments, _delivery, uri = event_subscription_params(events, context, params; subscribing=false)
    # The authenticated principal is part of the lookup key. Cleanup remains
    # possible after resource access is revoked or an event is removed.
    id = event_subscription_id(principal, uri.url, name, arguments)
    @lock events.lock begin
        delete_event_subscription!(events.store, id)
        # No new attempt can start now; wait for one that already started.
        while get(events.sending, id, 0) > 0
            wait(events.lock)
        end
    end
    return JSONDict()
end

function dispatch_events(server, context, params)
    return context.method == "events/list" ? list_events(server, context, params) :
        context.method == "events/subscribe" ? subscribe_event(server, context, params) :
        unsubscribe_event(server, context, params)
end

# The access check ran without the lock. Delete only if the record is
# unchanged, so a refresh made after access was restored survives.
function remove_revoked_subscription!(events::MCPEvents, checked::MCPWebhookSubscription)
    @lock events.lock begin
        current = get_event_subscription(events.store, checked.id)
        current !== nothing && subscription_record(current) == subscription_record(checked) &&
            delete_event_subscription!(events.store, checked.id)
    end
    return nothing
end

function deliver_event!(events, subscription, body, event_id)
    status = nothing
    reason = nothing
    attempts = 0
    for attempt in 1:events.max_attempts
        # Reread the record before each attempt, so unsubscribe, refresh, expiry,
        # and secret rotation take effect between retries.
        current = @lock events.lock begin
            record = get_event_subscription(events.store, subscription.id)
            if record === nothing || record.instance != subscription.instance
                reason = "unsubscribed"
                record = nothing
            elseif record.expires_at <= events.clock()
                delete_event_subscription!(events.store, record.id)
                reason = "expired"
                record = nothing
            else
                events.sending[record.id] = get(events.sending, record.id, 0) + 1
            end
            record
        end
        current === nothing && break
        stop = false
        try
            if event_authorized(events, current.principal, current.name, current.arguments)
                now = events.clock()
                secrets = current.previous_secret !== nothing && current.previous_secret_until > now ?
                    (current.secret, current.previous_secret) : (current.secret,)
                headers = event_webhook_headers(event_id, current.id, body, secrets; signed_at=now)
                attempts += 1
                response = post_event_webhook(events, current.url, headers, body; deadline=min(current.expires_at, now + events.timeout))
                status = Int(response.status)
                status in 200:299 &&
                    return (subscription_id=subscription.id, accepted=true, attempts=attempts, status=status, reason=nothing)
                reason = status >= 500 ? "http_5xx" : "http_4xx"
                stop = status in (410, 413)
            else
                remove_revoked_subscription!(events, current)
                reason = "forbidden"
                stop = true
            end
        catch err
            err isa MCPEventError || err isa MCPError || rethrow()
            reason = err isa MCPEventError ? get(err.data, "reason", "connection_refused") : "invalid_destination"
            # A destination that resolves to a non-public address is not retried.
            stop = err isa MCPError
        finally
            @lock events.lock begin
                remaining = events.sending[current.id] - 1
                remaining == 0 ? delete!(events.sending, current.id) : (events.sending[current.id] = remaining)
                notify(events.lock)
            end
        end
        (stop || attempt == events.max_attempts) && break
        events.wait(min(events.retry_delay * 2.0^(attempt - 1), 30.0))
    end
    return (subscription_id=subscription.id, accepted=false, attempts=attempts, status=status, reason=reason)
end

"""
    emit_event!(server, name, data; event_id=string(uuid4()), timestamp=time())

Validate and synchronously deliver an emit-only occurrence to matching webhook
subscriptions. Filtering and transformation receive the subscription owner,
not the emitting task's identity. Recheck access and expiry before every bounded
retry. One event ID and exact body are preserved; each attempt is signed anew.

Return delivery receipts (subscription_id, accepted, attempts, status, reason).
The caller owns queuing and recovery of failed or interrupted emissions.
No replay is advertised; cursor is always null. Every body is built and
validated before any is sent. Each owner's subscriptions are delivered in
order, and different owners concurrently, so a slow endpoint delays only its
owner. The call returns after every delivery finishes.
"""
function emit_event!(server::MCPServer, name::AbstractString, data; event_id=string(uuid4()), timestamp=time())
    events = require_events(server)
    event_name = event_string(name, "name"; max_bytes=256)
    id = event_header_id(event_id)
    timestamp isa Real && !(timestamp isa Bool) && isfinite(timestamp) || throw(ArgumentError("timestamp must be finite Unix seconds"))
    occurred_at = event_iso8601(timestamp)
    definition = @lock events.lock get(events.definitions, event_name, nothing)
    definition === nothing && throw(ArgumentError("Unknown event name"))
    payload = event_object(data, "data")
    JSONSchema.isvalid(definition.payload_validator, payload) || throw(ArgumentError("Data does not match the event payloadSchema"))
    subscriptions = filter(subscription -> subscription.name == event_name, event_subscriptions(events.store))
    sort!(subscriptions; by=subscription -> subscription.id)
    batches = Dict{String,Vector{Tuple{MCPWebhookSubscription,String}}}()
    for subscription in subscriptions
        if !event_authorized(events, subscription.principal, event_name, subscription.arguments)
            remove_revoked_subscription!(events, subscription)
            continue
        end
        Base.invokelatest(definition.matches, subscription.principal, deepcopy(subscription.arguments), deepcopy(payload)) === true || continue
        transformed = event_object(Base.invokelatest(definition.transform, subscription.principal, deepcopy(subscription.arguments), deepcopy(payload)), "transformed data")
        JSONSchema.isvalid(definition.payload_validator, transformed) || throw(ArgumentError("Transformed data does not match the event payloadSchema"))
        body = JSON.json(JSONDict(
            "eventId" => id, "name" => event_name, "timestamp" => occurred_at,
            "data" => transformed, "cursor" => nothing,
        ))
        ncodeunits(body) <= MCP_EVENT_BODY_LIMIT || throw(ArgumentError("Event body exceeds 256 KiB"))
        push!(get!(() -> Tuple{MCPWebhookSubscription,String}[], batches, subscription.principal), (subscription, body))
    end
    owners = collect(values(batches))
    receipts = Vector{Vector{NamedTuple}}(undef, length(owners))
    queue = Channel{Int}(length(owners))
    foreach(index -> put!(queue, index), eachindex(owners))
    close(queue)
    # ponytail: fixed pool of delivery tasks; make it configurable if a
    # deployment needs more parallel callbacks per emission.
    @sync for _ in 1:min(16, length(owners))
        @async for index in queue
            receipts[index] = NamedTuple[deliver_event!(events, subscription, body, id) for (subscription, body) in owners[index]]
        end
    end
    return sort!(reduce(vcat, receipts; init=NamedTuple[]); by=receipt -> receipt.subscription_id)
end

"""List discoverable event definitions over a client's MCP 2026-07-28 endpoint."""
function list_events(client::MCPClient; cursor=nothing, limit=nothing, headers=nothing, timeout_ms=nothing)
    client_is_modern(client) || throw(ArgumentError("MCP Events requires protocol 2026-07-28"))
    return list_entities(client, "events/list"; cursor=cursor, limit=limit, headers=headers, timeout_ms=timeout_ms)
end

"""
    subscribe_event(client, name; url, secret, arguments=Dict(), ttl_ms=missing, ...)

Create or refresh a webhook subscription. Omitted ttl_ms uses the server's
default; nothing requests no expiry (the server may grant a finite lifetime).
The caller persists the returned cursor and refreshes before refreshBefore.
"""
function subscribe_event(client::MCPClient, name::AbstractString;
    url::AbstractString, secret::AbstractString, arguments=JSONDict(),
    cursor=nothing, ttl_ms=missing, max_age_ms=nothing, headers=nothing, timeout_ms=nothing,
)
    client_is_modern(client) || throw(ArgumentError("MCP Events requires protocol 2026-07-28"))
    event_webhook_key(secret)
    callback_uri(url)
    params = JSONDict(
        "name" => String(name), "arguments" => event_object(arguments, "arguments"),
        "delivery" => JSONDict("mode" => "webhook", "url" => String(url), "secret" => String(secret)),
        "cursor" => cursor,
    )
    ttl_ms === missing || (params["ttlMs"] = ttl_ms)
    max_age_ms === nothing || (params["maxAgeMs"] = max_age_ms)
    return jsonrpc_call(client, "events/subscribe"; params=params, headers=headers, timeout_ms=timeout_ms)
end

"""Idempotently stop a webhook subscription addressed by its original filters and URL."""
function unsubscribe_event(client::MCPClient, name::AbstractString; url::AbstractString, arguments=JSONDict(), headers=nothing, timeout_ms=nothing)
    client_is_modern(client) || throw(ArgumentError("MCP Events requires protocol 2026-07-28"))
    params = JSONDict(
        "name" => String(name), "arguments" => event_object(arguments, "arguments"),
        "delivery" => JSONDict("mode" => "webhook", "url" => String(url)),
    )
    return jsonrpc_call(client, "events/unsubscribe"; params=params, headers=headers, timeout_ms=timeout_ms)
end
