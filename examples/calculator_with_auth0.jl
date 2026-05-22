#!/usr/bin/env julia

using Dates
using HTTP
using JSON
using Logging
using ModelContextProtocol
using OAuth

const MCP = ModelContextProtocol

# === Calculator logic copied from the basic example ===

function pretty_number(value::Real)
    isfinite(value) || return string(value)
    rounded = round(Int, value)
    return isapprox(value, rounded; atol=1e-10) ? string(rounded) : string(round(value, digits=10))
end

function ensure_number_list(value, label; min_items::Int=2)
    value isa AbstractVector || throw(MCP.mcp_error(:invalid_params, "$(label) must be an array of numbers"))
    numbers = Float64[]
    for (idx, item) in enumerate(value)
        item isa Real || throw(MCP.mcp_error(:invalid_params, "$(label)[$idx] must be a real number"))
        push!(numbers, Float64(item))
    end
    length(numbers) >= min_items || throw(MCP.mcp_error(:invalid_params, "$(label) must contain at least $(min_items) numbers"))
    return numbers
end

function require_number(value, label)
    value isa Real || throw(MCP.mcp_error(:invalid_params, "$(label) must be a real number"))
    return Float64(value)
end

function register_calculator_tools!(server::MCPServer)
    register_tool!(
        server;
        name="add",
        title="Add Numbers",
        description="Add two or more numbers together.",
        input_schema=Dict(
            "type" => "object",
            "properties" => Dict(
                "numbers" => Dict(
                    "type" => "array",
                    "minItems" => 2,
                    "items" => Dict("type" => "number"),
                    "description" => "Numbers to add.",
                ),
            ),
            "required" => ["numbers"],
        ),
        output_schema=Dict(
            "type" => "object",
            "properties" => Dict("sum" => Dict("type" => "number")),
            "required" => ["sum"],
        ),
        handler=function (_::MCPRequestContext, args::Dict{String,Any})
            numbers = ensure_number_list(get(args, "numbers", nothing), "numbers")
            result = sum(numbers)
            text = string(join(pretty_number.(numbers), " + "), " = ", pretty_number(result))
            return Dict(
                "content" => [Dict("type" => "text", "text" => text)],
                "structuredContent" => Dict("sum" => result),
                "annotations" => Dict("operation" => "add", "result" => result, "operands" => numbers),
            )
        end,
    )

    register_tool!(
        server;
        name="subtract",
        title="Subtract Numbers",
        description="Subtract one number from another.",
        input_schema=Dict(
            "type" => "object",
            "properties" => Dict(
                "minuend" => Dict("type" => "number", "description" => "The starting value."),
                "subtrahend" => Dict("type" => "number", "description" => "The amount to subtract."),
            ),
            "required" => ["minuend", "subtrahend"],
        ),
        output_schema=Dict(
            "type" => "object",
            "properties" => Dict("difference" => Dict("type" => "number")),
            "required" => ["difference"],
        ),
        handler=function (_::MCPRequestContext, args::Dict{String,Any})
            minuend = require_number(get(args, "minuend", nothing), "minuend")
            subtrahend = require_number(get(args, "subtrahend", nothing), "subtrahend")
            result = minuend - subtrahend
            text = string(pretty_number(minuend), " - ", pretty_number(subtrahend), " = ", pretty_number(result))
            return Dict(
                "content" => [Dict("type" => "text", "text" => text)],
                "structuredContent" => Dict("difference" => result),
                "annotations" => Dict(
                    "operation" => "subtract",
                    "result" => result,
                    "minuend" => minuend,
                    "subtrahend" => subtrahend,
                ),
            )
        end,
    )

    register_tool!(
        server;
        name="multiply",
        title="Multiply Numbers",
        description="Multiply two or more numbers together.",
        input_schema=Dict(
            "type" => "object",
            "properties" => Dict(
                "factors" => Dict(
                    "type" => "array",
                    "minItems" => 2,
                    "items" => Dict("type" => "number"),
                    "description" => "Numbers to multiply in order.",
                ),
            ),
            "required" => ["factors"],
        ),
        output_schema=Dict(
            "type" => "object",
            "properties" => Dict("product" => Dict("type" => "number")),
            "required" => ["product"],
        ),
        handler=function (_::MCPRequestContext, args::Dict{String,Any})
            factors = ensure_number_list(get(args, "factors", nothing), "factors")
            result = prod(factors)
            text = string(join(pretty_number.(factors), " * "), " = ", pretty_number(result))
            return Dict(
                "content" => [Dict("type" => "text", "text" => text)],
                "structuredContent" => Dict("product" => result),
                "annotations" => Dict("operation" => "multiply", "result" => result, "factors" => factors),
            )
        end,
    )

    register_tool!(
        server;
        name="divide",
        title="Divide Numbers",
        description="Divide one number by another.",
        input_schema=Dict(
            "type" => "object",
            "properties" => Dict(
                "dividend" => Dict("type" => "number", "description" => "The numerator."),
                "divisor" => Dict("type" => "number", "description" => "The denominator."),
            ),
            "required" => ["dividend", "divisor"],
        ),
        output_schema=Dict(
            "type" => "object",
            "properties" => Dict("quotient" => Dict("type" => "number")),
            "required" => ["quotient"],
        ),
        handler=function (_::MCPRequestContext, args::Dict{String,Any})
            dividend = require_number(get(args, "dividend", nothing), "dividend")
            divisor = require_number(get(args, "divisor", nothing), "divisor")
            abs(divisor) > 0 || throw(MCP.mcp_error(:invalid_params, "divisor must be non-zero"))
            result = dividend / divisor
            text = string(pretty_number(dividend), " / ", pretty_number(divisor), " = ", pretty_number(result))
            return Dict(
                "content" => [Dict("type" => "text", "text" => text)],
                "structuredContent" => Dict("quotient" => result),
                "annotations" => Dict(
                    "operation" => "divide",
                    "result" => result,
                    "dividend" => dividend,
                    "divisor" => divisor,
                ),
            )
        end,
    )
end

function register_calculation_prompt!(server::MCPServer)
    register_prompt!(
        server;
        name="calculation_playbook",
        description="Generate a checklist to translate a word problem into calculator-ready steps.",
        handler=function (_::MCPRequestContext, args::Dict{String,Any})
            goal = string(get(args, "goal", "the calculation"))
            context_hint = let values = get(args, "known_values", nothing)
                if values isa AbstractVector && !isempty(values)
                    joined = join(string.(values), ", ")
                    "Known values: $(joined)."
                else
                    "List the quantities you already know."
                end
            end
            body = join((
                "Goal: $(goal).",
                context_hint,
                "Checklist:",
                "1. Translate the goal into one or more equations.",
                "2. Identify which calculator tool (add, subtract, multiply, divide) applies to each equation.",
                "3. Plug in the numbers and record interim results.",
                "4. Verify the final answer and note any units or rounding.",
            ), "\n")
            return Dict(
                "messages" => [
                    Dict(
                        "role" => "system",
                        "content" => [
                            Dict(
                                "type" => "text",
                                "text" => "You help users break down problems into clear calculator operations. Favor concise checklists and highlight when to call each tool.",
                            ),
                        ],
                    ),
                    Dict(
                        "role" => "assistant",
                        "content" => [Dict("type" => "text", "text" => body)],
                    ),
                ],
            )
        end,
        annotations=Dict(
            "goalParameter" => Dict(
                "description" => "Optional plain-language statement of what should be calculated.",
                "example" => "Compute the total cost of a \$24.99 item with 8.5% sales tax.",
            ),
            "knownValuesParameter" => Dict(
                "description" => "Optional array of numbers or short labels that are already known.",
                "example" => ["price: 24.99", "tax_rate: 0.085"],
            ),
        ),
    )
end

# === OAuth / Auth0 integration ===

const REQUIRED_SCOPES = ["openid", "profile", "email"]
const CLIENT_ID = "calculator-public-client"
const AUTH_CODE_TTL = Dates.Second(300)
const REGISTRATION_PATH = "/oidc/register"

const BASE_URL = replace(strip(get(ENV, "PUBLIC_BASE_URL", "http://127.0.0.1:3010")), r"/+$" => "")
const AUTH0_DOMAIN = replace(replace(strip(get(ENV, "AUTH0_DOMAIN", "")), r"^https?://" => ""), r"/+$" => "")
const AUTH0_CLIENT_ID = get(ENV, "AUTH0_CLIENT_ID", "")
const AUTH0_CLIENT_SECRET = get(ENV, "AUTH0_CLIENT_SECRET", "")
const AUTH0_SCOPE = let default_scope = join(REQUIRED_SCOPES, ' ')
    raw = split(get(ENV, "AUTH0_SCOPE", default_scope))
    scopes = String[]
    for item in raw
        trimmed = strip(item)
        isempty(trimmed) || push!(scopes, trimmed)
    end
    isempty(scopes) && push!(scopes, "openid")
    scopes
end
const AUTH0_CALLBACK_PATH = get(ENV, "AUTH0_CALLBACK_PATH", "/oauth/idp/callback")
const AUTH0_CALLBACK_URL = string(BASE_URL, AUTH0_CALLBACK_PATH)
const AUTH0_AUTHORIZATION_ENDPOINT = string("https://", AUTH0_DOMAIN, "/authorize")
const AUTH0_TOKEN_ENDPOINT = string("https://", AUTH0_DOMAIN, "/oauth/token")
const AUTH0_JWKS_URI = string("https://", AUTH0_DOMAIN, "/.well-known/jwks.json")
const AUTH0_ISSUER = string("https://", AUTH0_DOMAIN, "/")
const AUTH0_AUDIENCE = strip(get(ENV, "AUTH0_AUDIENCE", ""))
const ISSUER_PRIVATE_KEY = """
-----BEGIN PRIVATE KEY-----
MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDBPuiwJuuZQYce
0Ny8zZifG0SPWhQjH3N+a/6b3wIT2EaCQ7+dwrs8YBOaIWdkoX/kvNiBZ+fnb5vm
LBh/f8Igl4QU5x1jxQe58LV8D8cnvSLZe5fw2iobdxGC2MMF4qsHqHDTLcpBzlkJ
oktP0uJnivY/cWeITVUJD2h/mJyBlOwwxwxImCHMyAA42GbpDa9+QVK51LNA1F6H
aPnDOqAK66USdW1Cl5u8yeGZfX358W66BKWeKWX4pc6oFAg2KsbUrv18Zck/9R6D
1k+i1P/Uynb6DwbghINOuA+QX1yRbyORKrvtQZFC49dvApEefI0tEsKtLpctXn+I
Ed1sl7wtAgMBAAECggEBAKRnrPcQZahBA3/IGcPW9l2GiVGcRT2MaGnJ3xclJ1NS
0MnKcZ76KOk4o/ShLqGCdJhZwah2ielwHqY4Ja9zNekcfpZ5+ZsD6YrbqssdcUXx
t1BnweB6+w/awN8dIu5C5VbiivpfHo/VyhJULNaAh3Wn19Ap3vcrM4k9vp2vbJcg
bUraM9tL0tTZHUwCNNukGQuA8lOAAH0t2PlNcW+Qf3ycxd9fYsrMXG6NDgqU52UV
3eVHVpf4uBEQgUVnOa8FHukzjXMWJvKL2A0KgffbQJ+AswCfwH1/QY0rPhT78X+/
1oSptMIlu1ReWYeTxV2NK8eX/0EO7kip3a+nhHF4wAECgYEA35A9zSCyt1cbIjrw
4RX0TVgpPqwyOgn2x2wPtlmvrMh6dYScuqs/OmQ3uLQZWtIMigV5EJSl81UY5sZw
81j6ilOWuVbNJ8LwIumh/EkndkeAbKWeP0EmeRB4G4suNq0EQWfJfOI3IGmwVSZv
T5BEvs+e4MAi9fh85alrIMCZXAECgYEA3UiVvcfc+elOYksdwLcM34iUkj3/05rk
nUzL6HXk34xKIPiVFVoi2QD1pOvqdIssagtfbnjnofpAn0XbSOuqhmEEU8OUge7M
/fxgOWgzFzsdZm2NXr+ZskA/f1wuYbqvNkGMU2SeDs1wfiklPbFSVqdWy+aNYvw9
mkRM1hXikC0CgYBfU9kWY6/w/4KBaRKXV84xQLttju1n1CHXTRuyDLIdAes9uws9
iZHPazZbWuhI0rIoFEdYK5pLlOimVs2I5lMGsrfdVcbrAnN035yDwAnEpJ59NW2x
2Sz3iG8+h21wQPxEi2XeC3OoLYjT9iyWh5TYrB06BpOhwJA5ObGFaLq8AQKBgQCc
1/nrDmK+cHOyj/OCyTxCpJhKH8/YuI0aQXi2R/n1yYYxYICrJbxVe6yhPOZtvMe6
Ul1N/DySPsLXIbiQMxonLVTX2mTEw/JghCXgCs9LxAbOtw/g/IWAJrHbIAdwFdZi
6osAAO1XKJ53jcprs+fcq7eFxuCoLImtcoPTqqdv8QKBgQCPUJfmkBLGw4deBHGF
VGhlZCadeRnOI6FkCKVD11y3vckilrq9/ZGEelaU47xmsEfC0/USU+l8WAR8+bqu
885rOF8GYVV5ya10dr85jGJzYxb6oHEUq36PIvzFMODrcvlJfaxIxvG34lT94+9e
V1NMZkM+1NqXaUfI0rDZp6somg==
-----END PRIVATE KEY-----
"""

struct AuthorizationCode
    code::String
    client_id::String
    redirect_uri::String
    code_challenge::String
    code_challenge_method::String
    scope::Vector{String}
    subject::String
    state::Union{String,Nothing}
    issued_at::DateTime
end

const AUTH_CODE_STORE_LOCK = ReentrantLock()
const AUTH_CODE_STORE = Dict{String,AuthorizationCode}()

random_token(; bytes::Integer=24) = OAuth.random_state(bytes=bytes)

struct PendingAuthRequest
    client_id::String
    redirect_uri::String
    code_challenge::String
    code_challenge_method::String
    scope::Vector{String}
    state::Union{String,Nothing}
    nonce::String
    auth0_code_verifier::String
    created_at::DateTime
end

const PENDING_AUTH_TTL = Dates.Second(300)
const PENDING_AUTH_LOCK = ReentrantLock()
const PENDING_AUTH = Dict{String,PendingAuthRequest}()

const AUTH0_JWKS_CACHE_LOCK = ReentrantLock()
const AUTH0_JWKS_CACHE_TTL = Dates.Minute(15)
const AUTH0_JWKS_CACHE = Ref{Union{Nothing,Tuple{DateTime,Any}}}(nothing)
const AUTH0_TOKEN_STORE_LOCK = ReentrantLock()
const AUTH0_TOKEN_RESPONSES = Dict{String,AbstractDict{String,Any}}()

function store_authorization_code!(code::AuthorizationCode)
    lock(AUTH_CODE_STORE_LOCK) do
        AUTH_CODE_STORE[code.code] = code
    end
    return code
end

function consume_authorization_code(code_value::AbstractString)
    lock(AUTH_CODE_STORE_LOCK) do
        code = get(AUTH_CODE_STORE, String(code_value), nothing)
        code === nothing && return nothing
        if Dates.now(UTC) - code.issued_at > AUTH_CODE_TTL
            delete!(AUTH_CODE_STORE, code.code)
            return nothing
        end
        delete!(AUTH_CODE_STORE, code.code)
        return code
    end
end

function store_auth0_token_response!(code_value::AbstractString, payload::AbstractDict{String,Any})
    lock(AUTH0_TOKEN_STORE_LOCK) do
        AUTH0_TOKEN_RESPONSES[String(code_value)] = payload
    end
    return payload
end

function consume_auth0_token_response(code_value::AbstractString)
    lock(AUTH0_TOKEN_STORE_LOCK) do
        return pop!(AUTH0_TOKEN_RESPONSES, String(code_value), nothing)
    end
end

function purge_pending_requests_locked!(now::DateTime)
    expired = String[]
    for (key, pending) in PENDING_AUTH
        if now - pending.created_at > PENDING_AUTH_TTL
            push!(expired, key)
        end
    end
    for key in expired
        delete!(PENDING_AUTH, key)
    end
    return nothing
end

function store_pending_request!(state_key::AbstractString, pending::PendingAuthRequest)
    lock(PENDING_AUTH_LOCK) do
        purge_pending_requests_locked!(Dates.now(UTC))
        PENDING_AUTH[String(state_key)] = pending
    end
end

function consume_pending_request(state_key::AbstractString)
    lock(PENDING_AUTH_LOCK) do
        return pop!(PENDING_AUTH, String(state_key), nothing)
    end
end

function parse_scope(scope_param)
    if scope_param === nothing || isempty(scope_param)
        return REQUIRED_SCOPES
    else
        values = split(String(scope_param))
        return isempty(values) ? REQUIRED_SCOPES : [String(s) for s in values]
    end
end

function parse_query_params(req::HTTP.Request)
    uri = HTTP.URI(req.target)
    params = Dict{String,String}()
    for (k, v) in HTTP.URIs.queryparams(uri)
        params[String(k)] = String(v)
    end
    return params
end

function parse_form_params(body_bytes::Vector{UInt8})
    params = Dict{String,String}()
    for (k, v) in HTTP.URIs.queryparams(HTTP.URI("?" * String(body_bytes)))
        params[String(k)] = String(v)
    end
    return params
end

function html_response(body::AbstractString; status::Integer=200)
    return HTTP.Response(status, HTTP.Headers(["Content-Type" => "text/html; charset=utf-8"]), body)
end

function authorization_parameters(params::Dict{String,String})
    required_keys = ["response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method"]
    missing = String[]
    for key in required_keys
        haskey(params, key) || push!(missing, key)
    end
    isempty(missing) || return nothing, "Missing parameters: $(join(missing, ", "))"
    HTTP.ascii_lc_isequal(params["response_type"], "code") || return nothing, "Unsupported response_type $(params["response_type"])"
    HTTP.ascii_lc_isequal(params["code_challenge_method"], "s256") || HTTP.ascii_lc_isequal(params["code_challenge_method"], "plain") || return nothing, "Unsupported code_challenge_method"
    HTTP.ascii_lc_isequal(params["client_id"], CLIENT_ID) || return nothing, "Unknown client_id"
    scope = parse_scope(get(params, "scope", nothing))
    for sc in REQUIRED_SCOPES
        sc in scope || push!(scope, sc)
    end
    state = get(params, "state", nothing)
    normalized = Dict{String,String}()
    for (k, v) in params
        normalized[String(k)] = String(v)
    end
    normalized["scope"] = join(scope, ' ')
    if state !== nothing
        normalized["state"] = String(state)
    end
    return normalized, nothing
end

function build_auth0_authorization_url(state_key::AbstractString, code_challenge::AbstractString, nonce::AbstractString)
    AUTH0_CLIENT_ID == "" && error("Set AUTH0_CLIENT_ID in the environment before using the Auth0 example")
    query_parts = [
        "response_type=code",
        "client_id=$(HTTP.URIs.escapeuri(AUTH0_CLIENT_ID))",
        "redirect_uri=$(HTTP.URIs.escapeuri(AUTH0_CALLBACK_URL))",
        "scope=$(HTTP.URIs.escapeuri(join(AUTH0_SCOPE, ' ')))",
        "state=$(HTTP.URIs.escapeuri(String(state_key)))",
        "nonce=$(HTTP.URIs.escapeuri(String(nonce)))",
        "code_challenge=$(HTTP.URIs.escapeuri(String(code_challenge)))",
        "code_challenge_method=S256",
    ]
    if !isempty(AUTH0_AUDIENCE)
        push!(query_parts, "audience=$(HTTP.URIs.escapeuri(AUTH0_AUDIENCE))")
    end
    return string(AUTH0_AUTHORIZATION_ENDPOINT, "?", join(query_parts, "&"))
end

function client_redirect_response(redirect_uri::AbstractString, params::Vector{Pair{String,String}})
    parts = String[]
    for pair in params
        push!(parts, string(first(pair), "=", HTTP.URIs.escapeuri(last(pair))))
    end
    separator = occursin('?', redirect_uri) ? "&" : "?"
    location = string(redirect_uri, separator, join(parts, "&"))
    headers = HTTP.Headers([
        "Location" => location,
        "Cache-Control" => "no-store",
    ])
    return HTTP.Response(302, headers, "")
end

function redirect_authorization_error(pending::PendingAuthRequest, error_code::AbstractString, description::AbstractString)
    entries = Pair{String,String}["error" => String(error_code)]
    if !isempty(description)
        push!(entries, "error_description" => description)
    end
    if pending.state !== nothing
        push!(entries, "state" => String(pending.state))
    end
    return client_redirect_response(pending.redirect_uri, entries)
end

function exchange_auth0_code(code::AbstractString, verifier::AbstractString, verbose::Bool=false)
    payload = Pair{String,String}[
        "grant_type" => "authorization_code",
        "client_id" => AUTH0_CLIENT_ID,
        "code" => String(code),
        "redirect_uri" => AUTH0_CALLBACK_URL,
        "code_verifier" => String(verifier),
    ]
    if AUTH0_CLIENT_SECRET != ""
        push!(payload, "client_secret" => AUTH0_CLIENT_SECRET)
    end
    body = join([string(first(p), "=", HTTP.URIs.escapeuri(last(p))) for p in payload], "&")
    headers = HTTP.Headers([
        "Content-Type" => "application/x-www-form-urlencoded",
        "Accept" => "application/json",
    ])
    req = HTTP.Request("POST", AUTH0_TOKEN_ENDPOINT, headers, body)
    verbose && @info req
    response = HTTP.request("POST", AUTH0_TOKEN_ENDPOINT, headers, body)
    verbose && @info response
    if response.status != 200
        description = try
            data = JSON.parse(String(response.body))
            data isa Dict && haskey(data, "error_description") ? String(data["error_description"]) : sprint(show, response.status)
        catch
            sprint(show, response.status)
        end
        return nothing, ("access_denied", description)
    end
    data = try
        JSON.parse(String(response.body))
    catch err
        return nothing, ("server_error", "Failed to parse Auth0 token response: $(err)")
    end
    data isa AbstractDict || return nothing, ("server_error", "Unexpected Auth0 token response format")
    return data, nothing
end

function fetch_auth0_jwks()
    now = Dates.now(UTC)
    lock(AUTH0_JWKS_CACHE_LOCK) do
        cached = AUTH0_JWKS_CACHE[]
        if cached !== nothing && now - cached[1] < AUTH0_JWKS_CACHE_TTL
            return cached[2]
        end
        response = HTTP.request("GET", AUTH0_JWKS_URI)
        response.status == 200 || error("Failed to fetch Auth0 JWKS (status $(response.status))")
        data = JSON.parse(String(response.body))
        AUTH0_JWKS_CACHE[] = (now, data)
        return data
    end
end

function validate_auth0_id_token(id_token::AbstractString, nonce::AbstractString)
    jwks = fetch_auth0_jwks()
    validator = TokenValidationConfig(
        issuer=AUTH0_ISSUER,
        audience=[AUTH0_CLIENT_ID],
        jwks=jwks,
    )
    claims = OAuth.validate_jwt_access_token(id_token, validator)
    token_nonce = get(claims.claims, "nonce", nothing)
    token_nonce === nothing && error("Auth0 ID token missing nonce claim")
    String(token_nonce) == String(nonce) || error("Auth0 ID token nonce mismatch")
    return claims
end

function authorization_get_handler(req::HTTP.Request)
    query = parse_query_params(req)
    normalized, error_message = authorization_parameters(query)
    if normalized === nothing
        return html_response("<h1>Invalid authorization request</h1><p>$(error_message)</p>"; status=400)
    end
    auth0_pkce = OAuth.generate_pkce_verifier().verifier
    auth0_challenge = OAuth.pkce_challenge(auth0_pkce)
    state_key = random_token(bytes=24)
    nonce = random_token(bytes=24)
    requested_scope = split(normalized["scope"])
    state_value = get(normalized, "state", nothing)
    pending = PendingAuthRequest(
        normalized["client_id"],
        normalized["redirect_uri"],
        normalized["code_challenge"],
        normalized["code_challenge_method"],
        [String(s) for s in requested_scope],
        state_value,
        nonce,
        auth0_pkce,
        Dates.now(UTC),
    )
    store_pending_request!(state_key, pending)
    location = try
        build_auth0_authorization_url(state_key, auth0_challenge, nonce)
    catch err
        consume_pending_request(state_key)
        return html_response("<h1>Configuration error</h1><p>$(err)</p>"; status=500)
    end
    headers = HTTP.Headers([
        "Location" => location,
        "Cache-Control" => "no-store",
    ])
    return HTTP.Response(302, headers, "")
end

function auth0_callback_handler(req::HTTP.Request)
    params = parse_query_params(req)
    state_key = get(params, "state", nothing)
    state_key === nothing && return html_response("<h1>Missing state</h1><p>Auth0 callback missing state parameter.</p>"; status=400)
    pending = consume_pending_request(state_key)
    pending === nothing && return html_response("<h1>Invalid state</h1><p>The authorization request has expired or is unknown.</p>"; status=400)
    if haskey(params, "error")
        description = get(params, "error_description", "")
        return redirect_authorization_error(pending, params["error"], description)
    end
    code = get(params, "code", nothing)
    code === nothing && return redirect_authorization_error(pending, "invalid_request", "Missing authorization code from Auth0")
    token_response, token_error = try
        exchange_auth0_code(code, pending.auth0_code_verifier, true)
    catch err
        (nothing, ("server_error", sprint(showerror, err)))
    end
    token_response === nothing && return redirect_authorization_error(pending, token_error[1], token_error[2])
    id_token = get(token_response, "id_token", nothing)
    id_token === nothing && return redirect_authorization_error(pending, "server_error", "Auth0 token response missing id_token")
    claims = try
        validate_auth0_id_token(String(id_token), pending.nonce)
    catch err
        return redirect_authorization_error(pending, "access_denied", sprint(showerror, err))
    end
    subject = claims.subject
    subject === nothing && return redirect_authorization_error(pending, "access_denied", "Auth0 did not include a subject claim")
    authorization_code_value = random_token()
    code_record = AuthorizationCode(
        authorization_code_value,
        pending.client_id,
        pending.redirect_uri,
        pending.code_challenge,
        pending.code_challenge_method,
        pending.scope,
        String(subject),
        pending.state,
        Dates.now(UTC),
    )
    store_auth0_token_response!(authorization_code_value, token_response)
    store_authorization_code!(code_record)
    response_params = Pair{String,String}["code" => authorization_code_value]
    if pending.state !== nothing
        push!(response_params, "state" => String(pending.state))
    end
    return client_redirect_response(pending.redirect_uri, response_params)
end

function verify_pkce(code::AuthorizationCode, verifier::AbstractString)
    method = lowercase(code.code_challenge_method)
    if method == "plain"
        return String(verifier) == code.code_challenge
    elseif method == "s256"
        challenge = OAuth.pkce_challenge(verifier)
        return challenge == code.code_challenge
    else
        return false
    end
end

function json_error(status::Integer, error_code::AbstractString, description::AbstractString)
    body = JSON.json(Dict("error" => String(error_code), "error_description" => String(description)))
    headers = HTTP.Headers([
        "Content-Type" => "application/json",
        "Cache-Control" => "no-store",
    ])
    return HTTP.Response(status, headers, body)
end

function dynamic_client_registration_handler()
    function handler(req::HTTP.Request)
        HTTP.method(req) == "POST" || return HTTP.Response(405, HTTP.Headers(["Allow" => "POST"]), "")
        body_bytes = req.body isa Vector{UInt8} ? req.body : Vector{UInt8}(codeunits(String(req.body)))
        request_body = String(body_bytes)
        registration = Dict{String,Any}()
        if !isempty(body_bytes)
            registration = try
                data = JSON.parse(request_body)
                data isa AbstractDict || error("registration payload must be an object")
                Dict{String,Any}(String(k) => v for (k, v) in data)
            catch err
                return json_error(400, "invalid_client_metadata", sprint(showerror, err))
            end
        end
        redirect_values = String[]
        if haskey(registration, "redirect_uris")
            redirects = registration["redirect_uris"]
            if redirects isa AbstractVector
                for item in redirects
                    item isa AbstractString || continue
                    push!(redirect_values, String(item))
                end
            elseif redirects isa AbstractString
                push!(redirect_values, String(redirects))
            end
        end
        issued_at = round(Int, Dates.datetime2unix(Dates.now(UTC)))
        body = Dict{String,Any}(
            "client_id" => CLIENT_ID,
            "client_id_issued_at" => issued_at,
            "token_endpoint_auth_method" => "none",
            "application_type" => "web",
            "grant_types" => ["authorization_code"],
            "response_types" => ["code"],
            "scope" => join(REQUIRED_SCOPES, ' '),
            "redirect_uris" => redirect_values,
            "client_secret_expires_at" => 0,
        )
        headers = HTTP.Headers([
            "Content-Type" => "application/json",
            "Cache-Control" => "no-store",
            "Pragma" => "no-cache",
        ])
        return HTTP.Response(201, headers, JSON.json(body))
    end
    return handler
end

function token_handler(req::HTTP.Request, issuer::JWTAccessTokenIssuer)
    method = HTTP.method(req)
    method == "POST" || return HTTP.Response(405, HTTP.Headers(["Allow" => "POST"]), "")
    body_bytes = req.body isa Vector{UInt8} ? req.body : Vector{UInt8}(codeunits(String(req.body)))
    params = parse_form_params(body_bytes)
    grant_type = get(params, "grant_type", nothing)
    grant_type === nothing && return json_error(400, "invalid_request", "grant_type is required")
    HTTP.ascii_lc_isequal(grant_type, "authorization_code") || return json_error(400, "unsupported_grant_type", "Only authorization_code is supported")
    client_id = get(params, "client_id", nothing)
    client_id === nothing && return json_error(400, "invalid_request", "client_id is required")
    HTTP.ascii_lc_isequal(client_id, CLIENT_ID) || return json_error(400, "unauthorized_client", "Unknown client_id")
    code_value = get(params, "code", nothing)
    code_value === nothing && return json_error(400, "invalid_request", "code is required")
    redirect_uri = get(params, "redirect_uri", nothing)
    redirect_uri === nothing && return json_error(400, "invalid_request", "redirect_uri is required")
    verifier = get(params, "code_verifier", nothing)
    verifier === nothing && return json_error(400, "invalid_request", "code_verifier is required")
    code = consume_authorization_code(code_value)
    code === nothing && return json_error(400, "invalid_grant", "Authorization code is invalid or expired")
    client_id == code.client_id || return json_error(400, "invalid_grant", "client_id mismatch")
    redirect_uri == code.redirect_uri || return json_error(400, "invalid_grant", "redirect_uri mismatch")
    verify_pkce(code, verifier) || return json_error(400, "invalid_grant", "PKCE verification failed")

    token_payload = consume_auth0_token_response(code_value)
    token_payload === nothing && return json_error(400, "invalid_grant", "Authorization code already used or invalid")
    # Ensure scope string reflects what Auth0 issued; if absent, fall back to original scope.
    if !haskey(token_payload, "scope")
        token_payload = copy(token_payload)
        token_payload["scope"] = join(code.scope, ' ')
    end
    body = token_payload
    headers = HTTP.Headers([
        "Content-Type" => "application/json",
        "Cache-Control" => "no-store",
        "Pragma" => "no-cache",
    ])
    return HTTP.Response(200, headers, JSON.json(body))
end

function add_routes!(
    router::HTTP.Router,
    server::MCPServer,
    validator::TokenValidationConfig,
    resource_metadata_url::AbstractString,
    token_issuer::JWTAccessTokenIssuer,
    authorization_server_config::AuthorizationServerConfig,
    protected_resource_config::ProtectedResourceConfig,
    jwk,
)
    protected_jsonrpc = protected_resource_middleware(
        req -> MCP.handle_jsonrpc_request(server, req),
        validator;
        resource_metadata_url=resource_metadata_url,
        required_scopes=REQUIRED_SCOPES,
        context_key=:oauth_token,
        verbose=true,
    )
    protected_stream = protected_resource_middleware(
        req -> MCP.handle_stream_request(server, req),
        validator;
        resource_metadata_url=resource_metadata_url,
        required_scopes=REQUIRED_SCOPES,
        context_key=:oauth_token,
        verbose=true,
    )

    HTTP.register!(router, "POST", server.transport_path, protected_jsonrpc)
    HTTP.register!(router, "GET", server.transport_path, protected_stream)

    HTTP.register!(router, "GET", "/oauth/authorize", authorization_get_handler)
    HTTP.register!(router, "GET", AUTH0_CALLBACK_PATH, auth0_callback_handler)
    HTTP.register!(router, "POST", "/oauth/token", req -> token_handler(req, token_issuer))
    registration_handler = dynamic_client_registration_handler()
    HTTP.register!(router, "POST", REGISTRATION_PATH, registration_handler)

    register_protected_resource_metadata!(router, protected_resource_config)
    register_authorization_server_metadata!(router, authorization_server_config)
    register_jwks_endpoint!(router, [jwk])
end

function start_server()
    isempty(BASE_URL) && error("PUBLIC_BASE_URL must not be empty")
    isempty(AUTH0_DOMAIN) && error("AUTH0_DOMAIN environment variable must be set before running calculator_with_auth0.jl")
    isempty(AUTH0_CLIENT_ID) && error("AUTH0_CLIENT_ID environment variable must be set before running calculator_with_auth0.jl")

    config = MCPServerConfig(
        name="Calculator MCP Server (Auth0)",
        version="0.1.0",
        description="Example arithmetic tools that delegate user auth to Auth0 and return Auth0 access tokens.",
        transport_path="/v1/calculator",
        verbose=true,
    )
    server = MCPServer(config)
    register_calculator_tools!(server)
    register_calculation_prompt!(server)

    host = get(ENV, "MCP_HOST", "127.0.0.1")
    port_str = get(ENV, "MCP_PORT", "3010")
    port = try
        parse(Int, port_str)
    catch err
        error("Invalid MCP_PORT value $(port_str): $(err)")
    end

    http_server = serve_mcp_http(server; host=host, port=port, verbose=true)
    base = BASE_URL
    transport_url = string(base, server.transport_path)
    issuer_url = base
    authorization_endpoint = string(base, "/oauth/authorize")
    token_endpoint = string(base, "/oauth/token")
    jwks_uri = AUTH0_JWKS_URI
    resource_metadata_url = string(base, OAuth.DEFAULT_PRM_PATH)
    registration_endpoint = string(base, REGISTRATION_PATH)

    prm_config = ProtectedResourceConfig(
        resource=transport_url,
        authorization_servers=[issuer_url],
        scopes_supported=REQUIRED_SCOPES,
    )
    as_config = AuthorizationServerConfig(
        issuer=AUTH0_ISSUER,
        authorization_endpoint=authorization_endpoint,
        token_endpoint=token_endpoint,
        jwks_uri=jwks_uri,
        response_types_supported=["code"],
        grant_types_supported=["authorization_code"],
        code_challenge_methods_supported=["S256", "plain"],
        scopes_supported=REQUIRED_SCOPES,
        extra=Dict(
            "registration_endpoint" => registration_endpoint,
            "auth0_issuer" => AUTH0_ISSUER,
            "auth0_authorization_endpoint" => AUTH0_AUTHORIZATION_ENDPOINT,
            "auth0_jwks_uri" => AUTH0_JWKS_URI,
        ),
    )
    auth0_audience_list = isempty(AUTH0_AUDIENCE) ? String[] : [AUTH0_AUDIENCE]
    validator = TokenValidationConfig(
        issuer=AUTH0_ISSUER,
        audience=auth0_audience_list,
        jwks=fetch_auth0_jwks(),
    )

    token_issuer = JWTAccessTokenIssuer(
        issuer=issuer_url,
        audience=[transport_url],
        private_key=ISSUER_PRIVATE_KEY,
        kid="calculator-auth-key",
        expires_in=3600,
    )
    jwk = public_jwk(token_issuer)

    add_routes!(http_server.router, server, validator, resource_metadata_url, token_issuer, as_config, prm_config, jwk)

    println("Calculator MCP server with Auth0 federation ready.")
    println("Transport URL: $(transport_url)")
    println("Protected resource metadata: $(resource_metadata_url)")
    println("Authorization endpoint: $(authorization_endpoint)")
    println("Token endpoint: $(token_endpoint)")
    println("Auth0 callback: $(string(base, AUTH0_CALLBACK_PATH))")
    println("Dynamic client registration: $(registration_endpoint)")
    println("Client ID: $(CLIENT_ID) (public client, PKCE required)")
    println("Auth0 client: $(AUTH0_CLIENT_ID) (PKCE, secret optional)")
    println("Auth0 issuer: $(AUTH0_ISSUER)")
    println("Auth0 audience: $(AUTH0_AUDIENCE)")

    try
        wait(http_server.http)
    catch err
        err isa InterruptException || rethrow(err)
        println("\nInterrupt received, shutting down...")
    finally
        stop_mcp_server(http_server)
        println("Server stopped.")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    start_server()
end
