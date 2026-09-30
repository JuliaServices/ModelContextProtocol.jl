using Test, HTTP, JSON, Random, Base64, Dates, Sockets, Logging
using ModelContextProtocol

const EventsMCP = ModelContextProtocol
const EVENT_SECRET = "whsec_" * base64encode(collect(UInt8(0):UInt8(31)))
const EVENT_URL = "https://receiver.example/hooks/one"

function event_fixture(; store=EventsMCP.InMemoryEventSubscriptionStore(), kwargs...)
    now = Ref(1_800_000_000.0)
    calls = NamedTuple[]
    statuses = Int[]
    owners = Dict("alpha" => true, "beta" => true)
    addresses = Ref(IPAddr[ip"8.8.8.8"])
    verification = Ref{Any}(:echo)
    sender = function (url, address, headers, body, timeout)
        parsed = JSON.parse(body)
        push!(calls, (; url, address, headers=copy(headers), body, parsed, timeout))
        # Reject bad signatures like a real receiver. Deliveries run on worker
        # tasks, where a @test here would not reach the enclosing testset.
        EventsMCP.verify_event_webhook(EVENT_SECRET, headers, body; now=now[]) ||
            EventsMCP.verify_event_webhook("whsec_" * base64encode(fill(UInt8(42), 32)), headers, body; now=now[]) ||
            return (status=401, body="")
        if get(parsed, "type", nothing) == "verification"
            verification[] isa Exception && throw(verification[])
            verification[] === :echo && return (status=200, body=JSON.json(Dict("challenge" => parsed["challenge"])))
            return verification[]
        end
        status = isempty(statuses) ? 202 : popfirst!(statuses)
        return (status=status, body="endpoint-controlled secret response")
    end
    server = MCPServer(name="Events", version="1.0")
    EventsMCP.enable_events!(server;
        store=store,
        principal=context -> get(context.http_request.context, :event_owner, nothing),
        authorize=(owner, name, args) -> get(owners, owner, false) &&
            (name != "hidden" || owner == "beta") &&
            (args === nothing || get(args, "resource", "shared") in ("shared", owner)),
        request=sender, resolve=_host -> addresses[], clock=() -> now[],
        wait=delay -> (now[] += delay), kwargs...,
    )
    input = Dict{String,Any}(
        "type" => "object", "properties" => Dict(
            "resource" => Dict("type" => "string"), "metadata" => Dict("type" => "object"),
        ), "required" => ["resource"], "additionalProperties" => false,
    )
    payload = Dict{String,Any}(
        "type" => "object", "properties" => Dict(
            "resource" => Dict("type" => "string"), "text" => Dict("type" => "string"),
        ), "required" => ["resource", "text"], "additionalProperties" => false,
    )
    EventsMCP.register_event!(server; name="comment.created", description="A review comment.",
        input_schema=input, payload_schema=payload,
        matches=(_owner, args, data) -> args["resource"] == data["resource"],
    )
    EventsMCP.register_event!(server; name="hidden", input_schema=input, payload_schema=payload,
        matches=(_owner, args, data) -> args["resource"] == data["resource"],
    )
    return (; server, now, calls, statuses, owners, addresses, verification, sender)
end

function event_params(; name="comment.created", arguments=Dict("resource" => "shared"), url=EVENT_URL, secret=EVENT_SECRET, ttl_ms=missing)
    params = Dict{String,Any}(
        "name" => name, "arguments" => arguments,
        "delivery" => Dict{String,Any}("mode" => "webhook", "url" => url, "secret" => secret),
    )
    ttl_ms === missing || (params["ttlMs"] = ttl_ms)
    return params
end

function event_request(server, method, params=Dict{String,Any}(); owner="alpha", id="events-1", legacy=false, jsonrpc="2.0")
    wire_params = params isa AbstractDict ? Dict{String,Any}(deepcopy(params)) : deepcopy(params)
    if wire_params isa AbstractDict && !legacy
        wire_params["_meta"] = Dict(
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => Dict{String,Any}(),
        )
    end
    envelope = Dict{String,Any}("jsonrpc" => jsonrpc, "method" => method, "params" => wire_params)
    jsonrpc === missing && delete!(envelope, "jsonrpc")
    id === nothing || (envelope["id"] = id)
    headers = [
        "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream",
        "Mcp-Method" => method,
        "MCP-Protocol-Version" => legacy ? "2025-11-25" : "2026-07-28",
    ]
    request = HTTP.Request("POST", "/v1/mcp", headers, Vector{UInt8}(codeunits(JSON.json(envelope))))
    owner === nothing || (request.context[:event_owner] = owner)
    response = EventsMCP.handle_jsonrpc_request(server, request)
    result = isempty(response.body) ? nothing : JSON.parse(String(response.body))
    return response, result
end

event_data(; resource="shared", text="hello") = Dict("resource" => resource, "text" => text)
event_deliveries(fixture) = filter(call -> !haskey(call.parsed, "type"), fixture.calls)
event_records(fixture) = EventsMCP.event_subscriptions(fixture.server.events.store)

@testset "MCP Events discovery and opt-in" begin
    fixture = event_fixture()
    server = fixture.server
    _, discovery = event_request(server, "server/discover")
    @test discovery["result"]["capabilities"]["events"] == Dict()
    response, listed = event_request(server, "events/list")
    @test response.status == 200
    @test listed["result"]["resultType"] == "complete"
    @test length(listed["result"]["events"]) == 1
    descriptor = only(listed["result"]["events"])
    @test descriptor["name"] == "comment.created"
    @test descriptor["delivery"] == ["webhook"]
    @test descriptor["inputSchema"]["required"] == ["resource"]
    @test descriptor["payloadSchema"]["required"] == ["resource", "text"]
    @test descriptor["inputSchema"]["\$schema"] == "http://json-schema.org/draft-07/schema#"
    _, page = event_request(server, "events/list", Dict("limit" => 1); owner="beta")
    @test page["result"]["nextCursor"] == "2"
    _, next = event_request(server, "events/list", Dict("cursor" => page["result"]["nextCursor"]); owner="beta")
    @test only(next["result"]["events"])["name"] == "hidden"
    @test !haskey(next["result"], "nextCursor")
    for method in ("events/list", "events/subscribe", "events/unsubscribe")
        _, forbidden = event_request(server, method, method == "events/list" ? Dict() : event_params(); owner=nothing)
        @test forbidden["error"]["code"] == -32012
    end
    @test isempty(fixture.calls)
    @test isempty(event_records(fixture))
    plain = MCPServer(name="No events", version="1")
    response, unsupported = event_request(plain, "events/list")
    @test response.status == 404
    @test unsupported["error"]["code"] == -32601
    @test !haskey(plain.capabilities, "events")
    _, legacy = event_request(server, "initialize", Dict("protocolVersion" => "2025-11-25"); legacy=true)
    @test !haskey(legacy["result"]["capabilities"], "events")
    # The discovery manifest describes the 2025-11-25 endpoint, which has no events.
    @test !haskey(only(EventsMCP.server_manifest(server)["model_context_protocols"])["capabilities"], "events")
    @test haskey(server.capabilities, "events")
    @test_throws ArgumentError EventsMCP.register_event!(server; name="comment.created",
        input_schema=Dict(), payload_schema=Dict(), matches=(_...) -> true)
    @test_throws ArgumentError EventsMCP.register_event!(server; name="new-dialect",
        input_schema=Dict("\$schema" => "https://json-schema.org/draft/2020-12/schema"),
        payload_schema=Dict(), matches=(_...) -> true)
    for ref in ("https://127.0.0.1/private", "file:///private/secret", "relative.json", "#anchor")
        @test_throws ArgumentError EventsMCP.register_event!(server; name="external-reference",
            input_schema=Dict("type" => "object", "properties" => Dict("resource" => Dict("\$ref" => ref))),
            payload_schema=Dict(), matches=(_...) -> true)
    end
    @test_throws ArgumentError EventsMCP.register_event!(server; name="nested-dialect",
        input_schema=Dict("properties" => Dict("resource" => Dict("\$schema" => "https://json-schema.org/draft/2020-12/schema"))),
        payload_schema=Dict(), matches=(_...) -> true)
    local_schema = Dict("type" => "object", "definitions" => Dict("resource" => Dict("type" => "string")),
        "properties" => Dict("resource" => Dict("\$ref" => "#/definitions/resource")), "required" => ["resource"])
    EventsMCP.register_event!(server; name="local-reference", input_schema=local_schema,
        payload_schema=Dict(), matches=(_...) -> true)
    @test isvalid(server.events.definitions["local-reference"].input_validator, Dict("resource" => "shared"))
    @test !isvalid(server.events.definitions["local-reference"].input_validator, Dict("resource" => 1))
    @test !haskey(local_schema, "\$schema")
end

@testset "Webhook lifecycle, isolation, and rotation" begin
    fixture = event_fixture()
    params = event_params(arguments=Dict("resource" => "shared", "metadata" => Dict("z" => 1.0, "a" => [true, nothing, "λ"])))
    _, subscribed = event_request(fixture.server, "events/subscribe", params)
    subscription = subscribed["result"]
    @test startswith(subscription["id"], "sub_")
    @test subscription["cursor"] === nothing
    @test subscription["truncated"] === false
    @test endswith(subscription["refreshBefore"], "Z")
    @test length(fixture.calls) == 1
    @test only(fixture.calls).parsed["type"] == "verification"
    @test startswith(Dict(only(fixture.calls).headers)["webhook-id"], "msg_verification_")
    reordered = event_params(arguments=Dict("metadata" => Dict("a" => [true, nothing, "λ"], "z" => 1), "resource" => "shared"))
    fixture.now[] += 1
    _, refreshed = event_request(fixture.server, "events/subscribe", reordered)
    @test refreshed["result"]["id"] == subscription["id"]
    @test refreshed["result"]["refreshBefore"] != subscription["refreshBefore"]
    @test length(event_records(fixture)) == 1
    @test length(fixture.calls) == 1
    _, other = event_request(fixture.server, "events/subscribe", reordered; owner="beta")
    @test other["result"]["id"] != subscription["id"]
    @test length(event_records(fixture)) == 2
    @test length(fixture.calls) == 2
    _, denied = event_request(fixture.server, "events/subscribe", event_params(arguments=Dict("resource" => "alpha")); owner="beta")
    @test denied["error"]["code"] == -32012
    @test length(fixture.calls) == 2
    @test isempty(EventsMCP.emit_event!(fixture.server, "comment.created", event_data(resource="different")))
    @test isempty(event_deliveries(fixture))
    receipts = EventsMCP.emit_event!(fixture.server, "comment.created", event_data(); event_id="evt_1", timestamp=fixture.now[] - 60)
    @test length(receipts) == 2
    @test all(receipt -> receipt.accepted && receipt.attempts == 1 && receipt.status == 202, receipts)
    @test all(call -> call.parsed["eventId"] == "evt_1" && call.parsed["cursor"] === nothing, event_deliveries(fixture))
    @test all(call -> call.parsed["timestamp"] == EventsMCP.event_iso8601(fixture.now[] - 60), event_deliveries(fixture))
    rotated = deepcopy(reordered)
    rotated["delivery"]["secret"] = "whsec_" * base64encode(fill(UInt8(42), 32))
    _, refresh = event_request(fixture.server, "events/subscribe", rotated)
    @test refresh["result"]["id"] == subscription["id"]
    EventsMCP.emit_event!(fixture.server, "comment.created", event_data())
    alpha_delivery = only(filter(call -> Dict(call.headers)["X-MCP-Subscription-Id"] == subscription["id"], event_deliveries(fixture)[3:end]))
    @test length(split(Dict(alpha_delivery.headers)["webhook-signature"])) == 2
    @test EventsMCP.verify_event_webhook(EVENT_SECRET, alpha_delivery.headers, alpha_delivery.body; now=fixture.now[])
    @test EventsMCP.verify_event_webhook(rotated["delivery"]["secret"], alpha_delivery.headers, alpha_delivery.body; now=fixture.now[])
    fixture.now[] += 301
    EventsMCP.emit_event!(fixture.server, "comment.created", event_data())
    alpha_delivery = only(filter(call -> Dict(call.headers)["X-MCP-Subscription-Id"] == subscription["id"], event_deliveries(fixture)[5:end]))
    @test !EventsMCP.verify_event_webhook(EVENT_SECRET, alpha_delivery.headers, alpha_delivery.body; now=fixture.now[])
    stop = deepcopy(reordered)
    delete!(stop["delivery"], "secret")
    for _ in 1:2
        _, stopped = event_request(fixture.server, "events/unsubscribe", stop)
        @test stopped["result"]["resultType"] == "complete"
    end
    @test length(event_records(fixture)) == 1
    @test only(event_records(fixture)).principal == "beta"
    fixture.owners["beta"] = false
    @test isempty(EventsMCP.emit_event!(fixture.server, "comment.created", event_data()))
    @test isempty(event_records(fixture))
    _, revoked = event_request(fixture.server, "events/subscribe", params; owner="beta")
    @test revoked["error"]["code"] == -32012
end

@testset "Subscription TTL, quotas, and durable restart" begin
    fixture = event_fixture(max_subscriptions=2, max_subscriptions_per_principal=1, default_ttl_ms=5000, max_ttl_ms=10_000)
    _, one = event_request(fixture.server, "events/subscribe", event_params(ttl_ms=100_000))
    @test only(event_records(fixture)).expires_at == fixture.now[] + 10
    @test one["result"]["refreshBefore"] == EventsMCP.event_iso8601(fixture.now[] + 10)
    _, limited = event_request(fixture.server, "events/subscribe", event_params(url=EVENT_URL * "/two"))
    @test limited["error"]["code"] == -32013
    @test limited["error"]["data"]["limit"] == "subscriptionsPerPrincipal"
    @test length(fixture.calls) == 1
    fixture.now[] += 11
    @test !only(EventsMCP.emit_event!(fixture.server, "comment.created", event_data())).accepted
    @test isempty(event_records(fixture))
    # null asks for no expiry; the longest finite lifetime is granted instead.
    _, finite = event_request(fixture.server, "events/subscribe", event_params(ttl_ms=nothing))
    @test finite["result"]["refreshBefore"] == EventsMCP.event_iso8601(fixture.now[] + 10)
    _, clamped = event_request(fixture.server, "events/subscribe", event_params(ttl_ms=big(10)^30))
    @test clamped["result"]["refreshBefore"] == EventsMCP.event_iso8601(fixture.now[] + 10)
    _, defaulted = event_request(fixture.server, "events/subscribe", event_params())
    @test only(event_records(fixture)).expires_at == fixture.now[] + 5
    mktempdir() do directory
        path = joinpath(directory, "subscriptions.json")
        stored = event_fixture(store=EventsMCP.FileEventSubscriptionStore(path))
        _, first = event_request(stored.server, "events/subscribe", event_params())
        @test isfile(path)
        Sys.iswindows() || @test filemode(path) & 0o077 == 0
        restarted = event_fixture(store=EventsMCP.FileEventSubscriptionStore(path))
        @test length(event_records(restarted)) == 1
        @test only(EventsMCP.emit_event!(restarted.server, "comment.created", event_data())).accepted
        @test only(restarted.calls).parsed["name"] == "comment.created"
        _, refreshed = event_request(restarted.server, "events/subscribe", event_params())
        @test refreshed["result"]["id"] == first["result"]["id"]
        _, stopped = event_request(restarted.server, "events/unsubscribe", event_params())
        @test !haskey(stopped, "error")
        @test isempty(EventsMCP.event_subscriptions(EventsMCP.FileEventSubscriptionStore(path)))
        @test readdir(directory) == ["subscriptions.json"]
        write(path, "{}")
        @test_throws ArgumentError EventsMCP.FileEventSubscriptionStore(path)
        @test_throws ArgumentError EventsMCP.FileEventSubscriptionStore(joinpath(directory, "missing", "subscriptions.json"))
    end
end

@testset "Callback failures and bounded retries" begin
    for verification in (
        (status=200, body="{\"challenge\":\"wrong\"}"),
        (status=200, body="not JSON"), (status=200, body="[1,2]"),
        (status=302, body="private redirect oracle"), (status=503, body="private error oracle"),
        ErrorException("sensitive transport detail"),
    )
        fixture = event_fixture()
        fixture.verification[] = verification
        _, failed = event_request(fixture.server, "events/subscribe", event_params())
        @test failed["error"]["code"] == -32015
        @test failed["error"]["data"]["reason"] in ("challenge_failed", "http_4xx", "http_5xx", "connection_refused")
        @test !occursin("oracle", JSON.json(failed))
        @test !occursin("sensitive", JSON.json(failed))
        @test isempty(event_records(fixture))
        _, throttled = event_request(fixture.server, "events/subscribe", event_params(arguments=Dict("resource" => "shared", "metadata" => Dict("different" => true))))
        @test throttled["error"]["code"] == -32013
        @test length(fixture.calls) == 1
    end
    fixture = event_fixture(retry_delay=1.25)
    event_request(fixture.server, "events/subscribe", event_params())
    append!(fixture.statuses, [500, 503, 202])
    receipt = only(EventsMCP.emit_event!(fixture.server, "comment.created", event_data(); event_id="retry_id"))
    @test receipt.accepted && receipt.attempts == 3
    deliveries = event_deliveries(fixture)
    @test length(deliveries) == 3
    @test length(unique(call.body for call in deliveries)) == 1
    @test length(unique(Dict(call.headers)["webhook-id"] for call in deliveries)) == 1
    @test length(unique(Dict(call.headers)["webhook-timestamp"] for call in deliveries)) == 3
    append!(fixture.statuses, fill(500, 10))
    receipt = only(EventsMCP.emit_event!(fixture.server, "comment.created", event_data()))
    @test !receipt.accepted && receipt.attempts == 4 && receipt.reason == "http_5xx"
    for status in (410, 413)
        empty!(fixture.statuses)
        push!(fixture.statuses, status)
        receipt = only(EventsMCP.emit_event!(fixture.server, "comment.created", event_data()))
        @test !receipt.accepted && receipt.attempts == 1 && receipt.status == status
        @test length(event_records(fixture)) == 1
    end
    interrupted = Ref{Any}(nothing)
    stopped = event_fixture(wait=_delay -> event_request(interrupted[].server, "events/unsubscribe", event_params()))
    interrupted[] = stopped
    event_request(stopped.server, "events/subscribe", event_params())
    append!(stopped.statuses, [500, 202])
    receipt = only(EventsMCP.emit_event!(stopped.server, "comment.created", event_data()))
    @test !receipt.accepted && receipt.attempts == 1 && receipt.reason == "unsubscribed"
    @test length(event_deliveries(stopped)) == 1
end

@testset "Callback address policy and DNS rebinding" begin
    blocked = [
        ip"0.0.0.0", ip"10.0.0.1", ip"100.64.0.1", ip"127.0.0.1", ip"169.254.169.254",
        ip"172.16.0.1", ip"192.0.0.1", ip"192.0.2.1", ip"192.168.0.1", ip"198.18.0.1",
        ip"198.51.100.1", ip"203.0.113.1", ip"224.0.0.1", ip"255.255.255.255",
        ip"::", ip"::1", ip"fc00::1", ip"fe80::1", ip"2001:db8::1", ip"2002:7f00:1::",
        ip"::ffff:127.0.0.1", ip"64:ff9b::a00:1", ip"3fff::1",
    ]
    @test all(address -> !EventsMCP.public_event_address(address), blocked)
    @test all(EventsMCP.public_event_address, [ip"8.8.8.8", ip"1.1.1.1", ip"2001:4860:4860::8888", ip"::ffff:8.8.8.8"])
    for address in blocked
        fixture = event_fixture()
        fixture.addresses[] = IPAddr[address]
        _, rejected = event_request(fixture.server, "events/subscribe", event_params())
        @test rejected["error"]["code"] == -32602
        @test isempty(fixture.calls)
        @test isempty(event_records(fixture))
    end
    mixed = event_fixture()
    mixed.addresses[] = [ip"8.8.8.8", ip"10.0.0.1"]
    _, rejected = event_request(mixed.server, "events/subscribe", event_params())
    @test rejected["error"]["code"] == -32602
    @test isempty(mixed.calls)
    fixture = event_fixture()
    event_request(fixture.server, "events/subscribe", event_params())
    fixture.addresses[] = IPAddr[ip"127.0.0.1"]
    receipt = only(EventsMCP.emit_event!(fixture.server, "comment.created", event_data()))
    @test !receipt.accepted && receipt.reason == "invalid_destination"
    @test isempty(event_deliveries(fixture))
    fixture.addresses[] = IPAddr[ip"1.1.1.1"]
    @test only(EventsMCP.emit_event!(fixture.server, "comment.created", event_data())).accepted
    @test only(event_deliveries(fixture)).address == ip"1.1.1.1"
    for url in (
        "http://example.com/hook", "file:///etc/passwd", "https:///hook", "https://user:password@example.com/hook",
        "https://@example.com/hook", "https://example.com/#fragment", "https://example.com/\r\nInjected: yes",
        "https://example.com:0/hook", "https://example.com:65536/hook", "https://example.com:invalid/hook",
        "https://[bad:ip]/hook", "https://[fe80::1%25en0]/hook", "https://ex%61mple.com/hook",
        "https://example.com\\@127.0.0.1/hook", "https://é.example/hook",
    )
        fixture = event_fixture()
        _, rejected = event_request(fixture.server, "events/subscribe", event_params(url=url))
        @test rejected["error"]["code"] == -32602
        @test isempty(fixture.calls)
    end
end

@testset "Independent Standard Webhooks vector and tamper fuzz" begin
    body = "{\"hello\":\"world\"}"
    headers = EventsMCP.event_webhook_headers("evt_test", "sub_test", body, (EVENT_SECRET,); signed_at=1_800_000_000)
    @test Dict(headers)["webhook-signature"] == "v1,qiVMP7Wiw6qjspZJu5jyX1RBQX5KV8VSNdEkcZQyhtc="
    @test EventsMCP.verify_event_webhook(EVENT_SECRET, headers, body; now=1_800_000_000)
    @test EventsMCP.verify_event_webhook(EVENT_SECRET, headers, collect(codeunits(body)); now=1_800_000_000)
    @test !EventsMCP.verify_event_webhook(EVENT_SECRET, headers, body; now=1_800_000_301)
    @test !EventsMCP.verify_event_webhook(EVENT_SECRET, headers, body; now=1_799_999_699)
    @test !EventsMCP.verify_event_webhook(EVENT_SECRET, vcat(headers, ["Webhook-Id" => "evt_test"]), body; now=1_800_000_000)
    @test !EventsMCP.verify_event_webhook(EVENT_SECRET, headers, repeat("x", 262_145); now=1_800_000_000)
    rng = Xoshiro(0x4d43504556454e54)
    for _ in 1:1000
        changed = collect(codeunits(body))
        index = rand(rng, eachindex(changed))
        changed[index] ⊻= rand(rng, UInt8(1):typemax(UInt8))
        @test !EventsMCP.verify_event_webhook(EVENT_SECRET, headers, changed; now=1_800_000_000)
        altered = copy(headers)
        index = rand(rng, 2:4) # ID, signing time, or signature; subscription ID is routing, not signed.
        altered[index] = first(altered[index]) => last(altered[index]) * "x"
        @test !EventsMCP.verify_event_webhook(EVENT_SECRET, altered, body; now=1_800_000_000)
    end
    for size in (0, 1, 23, 65, 128)
        @test_throws MCPError EventsMCP.event_webhook_key("whsec_" * base64encode(fill(UInt8(1), size)))
    end
    for size in (24, 32, 64)
        @test length(EventsMCP.event_webhook_key("whsec_" * base64encode(fill(UInt8(1), size)))) == size
    end
    for secret in ("", "whsec_", "secret", "whsec_!!!!", EVENT_SECRET * "\n")
        @test_throws MCPError EventsMCP.event_webhook_key(secret)
    end
    @test length(EventsMCP.event_webhook_key(EventsMCP.event_webhook_secret())) == 32
    @test_throws ArgumentError EventsMCP.event_webhook_headers("evt\r\n", "sub", body, (EVENT_SECRET,))
end

@testset "Event request mutation fuzz and identity properties" begin
    fixture = event_fixture()
    rng = Xoshiro(0x5355425343524942)
    invalid = (
        ("name", Any[nothing, true, 12, [], Dict(), "", repeat("x", 257)]),
        ("arguments", Any[nothing, 42, [], "text", Dict(), Dict("resource" => 1), Dict("resource" => "shared", "extra" => true)]),
        ("delivery", Any[nothing, true, [], "webhook", Dict(), Dict("mode" => "webhook")]),
        ("ttlMs", Any[false, true, 0, -1, 1.5, "1000", [], Dict()]),
    )
    for _ in 1:2000
        params = event_params()
        key, values = rand(rng, invalid)
        params[key] = deepcopy(rand(rng, values))
        response, rejected = event_request(fixture.server, "events/subscribe", params)
        @test response.status == 200
        @test rejected["error"]["code"] == -32602
        @test isempty(event_records(fixture))
        @test isempty(fixture.calls)
    end
    for params in ([], true, 42, "text")
        _, rejected = event_request(fixture.server, "events/subscribe", params)
        @test rejected["error"]["code"] == -32602
    end
    for id in (true, 1.5, [], Dict("guess" => "id"))
        response, rejected = event_request(fixture.server, "events/subscribe", event_params(); id=id)
        @test rejected["error"]["code"] == -32600
        @test rejected["id"] === nothing
        @test response.status == 400
    end
    for version in (missing, nothing, "1.0", "2.1", 2, true, [], Dict())
        _, rejected = event_request(fixture.server, "events/subscribe", event_params(); jsonrpc=version)
        @test rejected["error"]["code"] == -32600
        @test isempty(event_records(fixture))
        @test isempty(fixture.calls)
    end
    response, rejected = event_request(fixture.server, "events/subscribe", event_params(); id=nothing)
    @test response.status == 400
    @test rejected["error"]["code"] == -32600
    @test isempty(event_records(fixture))
    @test isempty(fixture.calls)
    unsupported = event_params()
    unsupported["delivery"]["mode"] = "push"
    _, rejected = event_request(fixture.server, "events/subscribe", unsupported)
    @test rejected["error"]["code"] == -32014
    @test rejected["error"]["data"]["feature"] == "deliveryMode"
    _, rejected = event_request(fixture.server, "events/subscribe", event_params(name="unknown"))
    @test rejected["error"]["code"] == -32011
    @test rejected["error"]["data"]["kind"] == "event"
    cursor = event_params()
    cursor["cursor"] = "old-history"
    _, rejected = event_request(fixture.server, "events/subscribe", cursor)
    @test rejected["error"]["code"] == -32014
    @test rejected["error"]["data"]["feature"] == "cursor"
    spoof = event_params()
    spoof["principal"] = "alpha"
    spoof["_meta"] = Dict("owner" => "alpha")
    _, rejected = event_request(fixture.server, "events/subscribe", spoof; owner=nothing)
    @test rejected["error"]["code"] == -32012
    for _ in 1:1000
        keys = ["a", "z", "λ", "🚀", "escaped\"\\", ""]
        shuffle!(rng, keys)
        first_args = Dict(key => Any[rand(rng, -100:100), rand(rng, Bool), nothing] for key in keys)
        reordered = Dict(key => deepcopy(first_args[key]) for key in reverse(keys))
        id = EventsMCP.event_subscription_id("alpha", EVENT_URL, "comment.created", first_args)
        @test id == EventsMCP.event_subscription_id("alpha", EVENT_URL, "comment.created", reordered)
        @test id != EventsMCP.event_subscription_id("beta", EVENT_URL, "comment.created", reordered)
        @test id != EventsMCP.event_subscription_id("alpha", EVENT_URL * "/other", "comment.created", reordered)
    end
    @test EventsMCP.event_subscription_id("a", EVENT_URL, "n", Dict("x" => 1)) ==
        EventsMCP.event_subscription_id("a", EVENT_URL, "n", Dict("x" => 1.0))
    @test EventsMCP.event_subscription_id("a", EVENT_URL, "n", Dict("x" => true)) !=
        EventsMCP.event_subscription_id("a", EVENT_URL, "n", Dict("x" => 1))
    nested = Dict{String,Any}()
    for _ in 1:34
        nested = Dict("deeper" => nested)
    end
    _, rejected = event_request(fixture.server, "events/subscribe", event_params(arguments=nested))
    @test rejected["error"]["code"] == -32602
    @test_throws ArgumentError EventsMCP.emit_event!(fixture.server, "comment.created", Dict("text" => "missing resource"))
    event_request(fixture.server, "events/subscribe", event_params())
    @test_throws ArgumentError EventsMCP.emit_event!(fixture.server, "comment.created", event_data(text=repeat("x", 262_144)))
    # maxAgeMs only bounds replay, which emit-only events never do.
    for max_age in (nothing, 300_000, "100")
        params = event_params()
        params["maxAgeMs"] = max_age
        _, ignored = event_request(fixture.server, "events/subscribe", params)
        @test haskey(ignored, "result")
    end
end

@testset "Authorization, filtering, and persistence failure boundaries" begin
    holder = Ref{Any}(nothing)
    revoking_sender = function (args...)
        result = holder[].sender(args...)
        holder[].owners["alpha"] = false
        return result
    end
    fixture = event_fixture(request=revoking_sender)
    holder[] = fixture
    _, denied = event_request(fixture.server, "events/subscribe", event_params())
    @test denied["error"]["code"] == -32012
    @test isempty(event_records(fixture))

    fixture = event_fixture()
    definition = fixture.server.events.definitions["comment.created"]
    EventsMCP.register_event!(fixture.server; name="redacted",
        input_schema=definition.input_schema, payload_schema=definition.payload_schema,
        matches=(_owner, args, data) -> (args["resource"] = "mutated"; true),
        transform=(owner, args, data) -> begin
            @test args["resource"] == "shared"
            data["text"] = "visible to " * owner
            data
        end,
    )
    for owner in ("alpha", "beta")
        event_request(fixture.server, "events/subscribe", event_params(name="redacted"); owner=owner)
    end
    data = event_data()
    @test all(receipt -> receipt.accepted, EventsMCP.emit_event!(fixture.server, "redacted", data))
    @test data == event_data()
    @test Set(call.parsed["data"]["text"] for call in event_deliveries(fixture)) == Set(["visible to alpha", "visible to beta"])
    @test all(record -> record.arguments["resource"] == "shared", event_records(fixture))

    broken = Ref("")
    EventsMCP.register_event!(fixture.server; name="broken-transform",
        input_schema=definition.input_schema, payload_schema=definition.payload_schema,
        matches=(_...) -> true, transform=(owner, _args, data) -> owner == broken[] ? Dict("resource" => "shared") : data)
    for owner in ("alpha", "beta")
        event_request(fixture.server, "events/subscribe", event_params(name="broken-transform"); owner=owner)
    end
    # Break the subscriber that sorts last, so a partial emission would be visible.
    broken[] = last(sort(filter(record -> record.name == "broken-transform", event_records(fixture)); by=record -> record.id)).principal
    calls_before = length(fixture.calls)
    @test_throws ArgumentError EventsMCP.emit_event!(fixture.server, "broken-transform", event_data())
    @test length(fixture.calls) == calls_before

    fixture = event_fixture()
    event_request(fixture.server, "events/subscribe", event_params())
    original = only(event_records(fixture))
    changed = EventsMCP.MCPWebhookSubscription(original.id, original.principal, original.name,
        original.arguments, original.url, original.secret, original.expires_at + 60,
        original.previous_secret, original.previous_secret_until)
    mktempdir() do directory
        # Renaming a file over a directory must fail, even when tests run as root.
        broken = EventsMCP.FileEventSubscriptionStore(directory, fixture.server.events.store)
        @test_throws Base.IOError EventsMCP.save_event_subscription!(broken, changed)
        @test only(EventsMCP.event_subscriptions(broken)) === original
        @test isempty(readdir(directory))
    end

    for secret in (nothing, true, [], Dict(), "whsec_" * repeat("a", 1_000_000))
        @test_throws MCPError EventsMCP.event_webhook_key(secret)
    end
end

@testset "Unsubscribe drains delivery and revocation stops retries" begin
    entered = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    holder = Ref{Any}(nothing)
    sender = function (url, address, headers, body, timeout)
        if !haskey(JSON.parse(body), "type")
            put!(entered, nothing)
            take!(release)
        end
        holder[].sender(url, address, headers, body, timeout)
    end
    fixture = event_fixture(request=sender)
    holder[] = fixture
    event_request(fixture.server, "events/subscribe", event_params())
    delivery = @async EventsMCP.emit_event!(fixture.server, "comment.created", event_data())
    @test timedwait(() -> isready(entered) || istaskdone(delivery), 10) == :ok
    isready(entered) || error("Delivery did not reach the callback")
    take!(entered)
    started = Channel{Nothing}(1)
    stopped = @async begin
        put!(started, nothing)
        event_request(fixture.server, "events/unsubscribe", event_params())
    end
    try
        take!(started)
        # The record is removed at once, but unsubscribe returns only after the POST in flight.
        @test timedwait(() -> isempty(event_records(fixture)), 10) == :ok
        @test !istaskdone(stopped)
    finally
        put!(release, nothing)
    end
    @test timedwait(() -> istaskdone(delivery) && istaskdone(stopped), 10) == :ok
    @test only(fetch(delivery)).accepted
    @test fetch(stopped)[2]["result"]["resultType"] == "complete"
    @test isempty(event_records(fixture))
    @test isempty(EventsMCP.emit_event!(fixture.server, "comment.created", event_data()))

    revoking = event_fixture(wait=_delay -> (holder[].owners["alpha"] = false))
    holder[] = revoking
    event_request(revoking.server, "events/subscribe", event_params())
    append!(revoking.statuses, [500, 202])
    receipt = only(EventsMCP.emit_event!(revoking.server, "comment.created", event_data()))
    @test !receipt.accepted && receipt.attempts == 1 && receipt.reason == "forbidden"
    @test length(event_deliveries(revoking)) == 1
    @test isempty(event_records(revoking))

    resolutions = Ref(0)
    resolver = function (_host)
        resolutions[] += 1
        resolutions[] > 1 && (holder[].now[] += 2)
        holder[].addresses[]
    end
    expired = event_fixture(resolve=resolver, max_attempts=1)
    holder[] = expired
    event_request(expired.server, "events/subscribe", event_params(ttl_ms=1000))
    receipt = only(EventsMCP.emit_event!(expired.server, "comment.created", event_data()))
    @test !receipt.accepted && receipt.reason == "timeout"
    @test isempty(event_deliveries(expired))
end

@testset "One principal cannot stall or block another" begin
    # Hosted clients use one receiver host for every user, so one principal's
    # failed or repeated verifications must not block another principal.
    fixture = event_fixture(max_subscriptions=3, max_subscriptions_per_principal=3)
    fixture.owners["mallory"] = true
    fixture.verification[] = (status=404, body="")
    _, failed = event_request(fixture.server, "events/subscribe",
        event_params(url="https://receiver.example/hooks/bogus"); owner="mallory")
    @test failed["error"]["code"] == -32015
    _, throttled = event_request(fixture.server, "events/subscribe",
        event_params(url="https://receiver.example/hooks/other"); owner="mallory")
    @test throttled["error"]["data"]["limit"] == "callbackVerification"
    fixture.verification[] = :echo
    _, subscribed = event_request(fixture.server, "events/subscribe", event_params())
    @test haskey(subscribed, "result")
    for index in 1:3
        fixture.now[] += 10
        url = "https://mallory.example/hooks/$(index)"
        event_request(fixture.server, "events/subscribe", event_params(url=url); owner="mallory")
        event_request(fixture.server, "events/unsubscribe", event_params(url=url); owner="mallory")
    end
    _, other = event_request(fixture.server, "events/subscribe", event_params(); owner="beta")
    @test haskey(other, "result")

    # A live subscription to the same URL counts as consent for refreshes and
    # new filters; the challenge returns only after every subscription ends.
    verifications() = count(call -> haskey(call.parsed, "type"), fixture.calls)
    before = verifications()
    fixture.now[] += 600
    _, refreshed = event_request(fixture.server, "events/subscribe", event_params(ttl_ms=1_800_000))
    @test haskey(refreshed, "result")
    _, filtered = event_request(fixture.server, "events/subscribe",
        event_params(arguments=Dict("resource" => "alpha")))
    @test haskey(filtered, "result")
    @test verifications() == before
    for arguments in (Dict("resource" => "shared"), Dict("resource" => "alpha"))
        event_request(fixture.server, "events/unsubscribe", event_params(arguments=arguments))
    end
    event_request(fixture.server, "events/subscribe", event_params())
    @test verifications() == before + 1

    # A slow delivery, and its owner's unsubscribe, must not stall other principals.
    entered = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    holder = Ref{Any}(nothing)
    slow = function (url, address, headers, body, timeout)
        if !haskey(JSON.parse(body), "type") && occursin("mallory", url)
            put!(entered, nothing)
            take!(release)
        end
        holder[].sender(url, address, headers, body, timeout)
    end
    fixture = event_fixture(request=slow)
    holder[] = fixture
    fixture.owners["mallory"] = true
    mallory = event_params(url="https://mallory.example/hooks/slow")
    event_request(fixture.server, "events/subscribe", mallory; owner="mallory")
    delivery = @async EventsMCP.emit_event!(fixture.server, "comment.created", event_data())
    try
        @test timedwait(() -> isready(entered), 10) == :ok
        stopping = @async event_request(fixture.server, "events/unsubscribe", mallory; owner="mallory")
        @test timedwait(() -> isempty(event_records(fixture)), 10) == :ok
        others = @async begin
            event_request(fixture.server, "events/list"; owner="beta")
            event_request(fixture.server, "events/subscribe", event_params(); owner="beta")
        end
        @test timedwait(() -> istaskdone(others), 10) == :ok
        @test istaskdone(others) && haskey(fetch(others)[2], "result")
        @test !istaskdone(stopping)
    finally
        isready(entered) && take!(entered)
        put!(release, nothing)
    end
    @test timedwait(() -> istaskdone(delivery), 10) == :ok

    # A stalled endpoint delays only its owner's deliveries in the same emission.
    # Its subscription sorts first, so one-at-a-time delivery would stall alpha too.
    shared = Dict("resource" => "shared")
    alpha_id = EventsMCP.event_subscription_id("alpha", EVENT_URL, "comment.created", shared)
    stalled = first(url for url in ("https://mallory.example/hooks/$(index)" for index in 1:100)
        if EventsMCP.event_subscription_id("mallory", url, "comment.created", shared) < alpha_id)
    fixture = event_fixture(request=slow)
    holder[] = fixture
    fixture.owners["mallory"] = true
    event_request(fixture.server, "events/subscribe", event_params(url=stalled); owner="mallory")
    event_request(fixture.server, "events/subscribe", event_params(); owner="alpha")
    delivery = @async EventsMCP.emit_event!(fixture.server, "comment.created", event_data())
    try
        @test timedwait(() -> isready(entered), 10) == :ok
        @test timedwait(() -> any(call -> call.url == EVENT_URL, event_deliveries(fixture)), 10) == :ok
        @test !istaskdone(delivery)
    finally
        isready(entered) && take!(entered)
        put!(release, nothing)
    end
    @test timedwait(() -> istaskdone(delivery), 10) == :ok
    @test length(fetch(delivery)) == 2 && all(receipt -> receipt.accepted, fetch(delivery))
end

@testset "Seeded subscription state-machine fuzz" begin
    fixture = event_fixture(default_ttl_ms=5000, max_ttl_ms=10_000)
    model = Dict{Tuple{String,String,String},NamedTuple}()
    rng = Xoshiro(0x4c4946454359434c)
    for _ in 1:1000
        owner = rand(rng, ["alpha", "beta"])
        url = EVENT_URL * string(rand(rng, 1:3))
        resource = rand(rng, ["shared", "alpha", "beta"])
        key = (owner, url, resource)
        action = rand(rng, 1:5)
        if action == 1
            ttl = rand(rng, 1000:5000)
            calls_before = length(fixture.calls)
            _, result = event_request(fixture.server, "events/subscribe",
                event_params(url=url, arguments=Dict("resource" => resource), ttl_ms=ttl); owner=owner)
            if fixture.owners[owner] && resource in ("shared", owner)
                @test haskey(result, "result")
                model[key] = (; id=result["result"]["id"], expires=fixture.now[] + ttl / 1000)
            else
                @test result["error"]["code"] == -32012
                @test length(fixture.calls) == calls_before
            end
        elseif action == 2
            _, result = event_request(fixture.server, "events/unsubscribe",
                event_params(url=url, arguments=Dict("resource" => resource)); owner=owner)
            @test result["result"]["resultType"] == "complete"
            delete!(model, key)
        elseif action == 3
            expected = Set(record.id for ((subject, _url, filter), record) in model
                if fixture.owners[subject] && record.expires > fixture.now[] && filter == resource)
            receipts = EventsMCP.emit_event!(fixture.server, "comment.created", event_data(resource=resource))
            @test Set(receipt.subscription_id for receipt in receipts if receipt.accepted) == expected
            filter!(entry -> fixture.owners[first(entry)[1]], model)
        elseif action == 4
            fixture.now[] += rand(rng, 0:3)
        else
            fixture.owners[owner] = !fixture.owners[owner]
        end
        filter!(entry -> last(entry).expires > fixture.now[], model)
        actual = Set((record.principal, record.url, record.arguments["resource"])
            for record in event_records(fixture) if record.expires_at > fixture.now[])
        @test actual == Set(keys(model))
    end
end

@testset "Event signing secrets are redacted without changing wire bytes" begin
    envelope = Dict("jsonrpc" => "2.0", "id" => "1", "method" => "events/subscribe", "params" => event_params())
    body = JSON.json(envelope)
    for wire in (body, replace(body, "events/subscribe" => "events\\u002fsubscribe"))
        bytes = collect(codeunits(wire))
        expected = copy(bytes)
        redacted = EventsMCP.redact_event_request_body(EventsMCP.client_request_body_text(bytes))
        @test !occursin(EVENT_SECRET, redacted)
        @test JSON.parse(redacted)["params"]["delivery"]["secret"] == "[redacted]"
        @test bytes == expected
    end
    @test !occursin(EVENT_SECRET, EventsMCP.redact_event_request_body(body[1:end-1]))
    @test EventsMCP.redact_event_request_body("") == ""
    fixture = event_fixture()
    malformed = HTTP.Request("POST", "/v1/mcp",
        ["Content-Type" => "application/json", "Accept" => "application/json, text/event-stream",
            "MCP-Protocol-Version" => "2026-07-28"], collect(codeunits(body[1:end-1])))
    response = EventsMCP.handle_jsonrpc_request(fixture.server, malformed)
    response_text = EventsMCP.client_request_body_text(response.body)
    @test JSON.parse(response_text)["error"]["code"] == -32700
    @test !occursin(EVENT_SECRET, response_text)
    @test isempty(fixture.calls)
    output = IOBuffer()
    request = HTTP.Request("POST", "/v1/mcp", Pair{String,String}[], collect(codeunits(body)))
    with_logger(SimpleLogger(output)) do
        handler = EventsMCP.handle_verbose_logging(true) do received
            @test EventsMCP.client_request_body_text(received.body) == body
            HTTP.Response(202)
        end
        handler(request)
    end
    log = String(take!(output))
    @test occursin("[redacted]", log)
    @test !occursin(EVENT_SECRET, log)
end

@testset "MCP event client and authenticated HTTP endpoint" begin
    fixture = event_fixture()
    set_request_hook!(fixture.server) do request
        token = EventsMCP.http_header_value(request.headers, "Authorization")
        token == "Bearer valid-alpha" && (request.context[:event_owner] = "alpha")
    end
    http = serve_mcp_http(fixture.server; port=0)
    try
        descriptor = MCPTransportDescriptor(kind=:http, url=base_url(http) * "/v1/mcp")
        discovery = MCPDiscovery(manifest=Dict{String,Any}(), transports=[descriptor], default_transport=descriptor)
        client = prepare_manual_client(discovery; config=MCPClientConfig(protocol_version="2026-07-28"))
        legacy_client = prepare_manual_client(discovery; config=MCPClientConfig(protocol_version="2025-11-25"))
        @test_throws ArgumentError EventsMCP.list_events(legacy_client)
        @test_throws ArgumentError EventsMCP.subscribe_event(legacy_client, "comment.created"; url=EVENT_URL, secret=EVENT_SECRET)
        @test_throws ArgumentError EventsMCP.unsubscribe_event(legacy_client, "comment.created"; url=EVENT_URL)
        attach_token!(client, "Bearer valid-alpha")
        @test only(EventsMCP.list_events(client)["events"])["name"] == "comment.created"
        client.verbose = true
        subscribed = mktemp() do path, output
            result = with_logger(SimpleLogger(output)) do
                redirect_stdout(output) do
                    EventsMCP.subscribe_event(client, "comment.created"; url=EVENT_URL, secret=EVENT_SECRET,
                        arguments=Dict("resource" => "shared"), ttl_ms=5000)
                end
            end
            flush(output)
            log = read(path, String)
            @test occursin("[redacted]", log)
            @test !occursin(EVENT_SECRET, log)
            result
        end
        client.verbose = false
        @test subscribed["refreshBefore"] == EventsMCP.event_iso8601(fixture.now[] + 5)
        @test length(event_records(fixture)) == 1
        @test only(EventsMCP.emit_event!(fixture.server, "comment.created", event_data())).accepted
        @test EventsMCP.unsubscribe_event(client, "comment.created"; url=EVENT_URL, arguments=Dict("resource" => "shared"))["resultType"] == "complete"
        @test isempty(event_records(fixture))
    finally
        stop_mcp_server(http)
    end
end

@testset "Pinned HTTPS callback, TLS hostname, and redirect isolation" begin
    certificate = joinpath(@__DIR__, "fixtures", "event-callback.crt")
    authority = joinpath(@__DIR__, "fixtures", "event-ca.crt")
    key = joinpath(@__DIR__, "fixtures", "event-callback.key")
    # Public test-only key: the certificate trusts callback.test, so success
    # proves CONNECT_TO kept the original hostname for TLS verification.
    received = NamedTuple[]
    handler = function (request)
        body = String(copy(request.body))
        parsed = JSON.parse(body)
        push!(received, (; target=String(request.target), headers=copy(request.headers), body, parsed))
        if request.target == "/redirect"
            return HTTP.Response(302, ["Location" => "/private"], "private response oracle")
        end
        if get(parsed, "type", nothing) == "verification"
            return HTTP.Response(200, JSON.json(Dict("challenge" => parsed["challenge"])))
        end
        return HTTP.Response(202)
    end
    http = if isdefined(HTTP, :TLS)
        listener = HTTP.TLS.listen("tcp", "127.0.0.1:0",
            HTTP.TLS.Config(cert_file=certificate, key_file=key, verify_peer=false))
        HTTP.serve!(handler, listener)
    else
        HTTP.serve!(handler, "127.0.0.1", 0; sslconfig=HTTP.MbedTLS.SSLConfig(certificate, key))
    end
    try
        port = EventsMCP.bound_http_port(http)
        url = "https://callback.test:$(port)/hook"
        withenv("JULIA_SSL_CA_ROOTS_PATH" => authority, "https_proxy" => "http://127.0.0.1:1",
            "HTTPS_PROXY" => "http://127.0.0.1:1") do
            fixture = event_fixture(request=EventsMCP.request_event_webhook, allow_private_addresses=true)
            fixture.addresses[] = IPAddr[ip"127.0.0.1"]
            _, subscribed = event_request(fixture.server, "events/subscribe", event_params(url=url))
            @test haskey(subscribed, "result")
            @test length(received) == 1
            @test EventsMCP.http_header_value(only(received).headers, "Host") == "callback.test:$(port)"
            @test EventsMCP.verify_event_webhook(EVENT_SECRET, only(received).headers, only(received).body; now=fixture.now[])
            @test only(EventsMCP.emit_event!(fixture.server, "comment.created", event_data())).accepted
            @test length(received) == 2
            # Each delivery closes its connection instead of idling in a connection cache.
            if !Sys.iswindows() && Sys.which("lsof") !== nothing
                connected() = !isempty(readlines(ignorestatus(
                    `lsof -nP -a -p $(getpid()) -iTCP:$(port) -sTCP:ESTABLISHED -t`)))
                @test timedwait(() -> !connected(), 5) == :ok
            end
            wrong_host = event_params(url="https://wrong.test:$(port)/hook")
            _, rejected = event_request(fixture.server, "events/subscribe", wrong_host)
            @test rejected["error"]["code"] == -32015
            @test rejected["error"]["data"]["reason"] == "tls_error"
            @test length(received) == 2
            _, rejected = event_request(fixture.server, "events/subscribe", event_params(url="https://callback.test:$(port)/redirect"))
            @test rejected["error"]["code"] == -32015
            @test length(received) == 3
            @test last(received).target == "/redirect"
            @test !any(request -> request.target == "/private", received)
        end
    finally
        close(http)
    end
end
