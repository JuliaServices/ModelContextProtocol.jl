#!/usr/bin/env julia

using Dates
using HTTP
using JSON
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

# === OAuth / authentication setup ===

const AUTH_USERNAME = "bob"
const AUTH_PASSWORD = "bob"
const REQUIRED_SCOPE = "calculator:use"
const CLIENT_ID = "calculator-public-client"
const AUTH_CODE_TTL = Dates.Second(300)
const REGISTRATION_PATH = "/oidc/register"

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

const TOKEN_STORE = InMemoryTokenStore()

random_token(; bytes::Integer=24) = OAuth.random_state(bytes=bytes)

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

function parse_scope(scope_param)
    if scope_param === nothing || isempty(scope_param)
        return [REQUIRED_SCOPE]
    else
        values = split(String(scope_param))
        return isempty(values) ? [REQUIRED_SCOPE] : [String(s) for s in values]
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

function render_login_page(params::Dict{String,String}; error_message::Union{String,Nothing}=nothing)
    hidden_inputs = IOBuffer()
    for (name, value) in params
        sanitized = replace(value, "\"" => "&quot;")
        println(hidden_inputs, """<input type="hidden" name="$(name)" value="$(sanitized)"/>""")
    end
    error_block = error_message === nothing ? "" : """<p style="color: #c00;">$(error_message)</p>"""
    body = """
    <!doctype html>
    <html>
        <head>
            <meta charset="utf-8"/>
            <title>Calculator Login</title>
            <style>
                body { font-family: sans-serif; margin: 2rem auto; max-width: 24rem; }
                form { display: flex; flex-direction: column; gap: 0.75rem; }
                label { display: flex; flex-direction: column; font-weight: 600; }
                input[type="text"], input[type="password"] { padding: 0.5rem; font-size: 1rem; }
                button { padding: 0.5rem; font-size: 1rem; }
            </style>
        </head>
        <body>
            <h1>Calculator Login</h1>
            <p>Sign in with username <code>bob</code> and password <code>bob</code>.</p>
            $(error_block)
            <form method="post" action="/oauth/authorize">
                $(String(take!(hidden_inputs)))
                <label>
                    Username
                    <input type="text" name="username" autocomplete="username" required/>
                </label>
                <label>
                    Password
                    <input type="password" name="password" autocomplete="current-password" required/>
                </label>
                <button type="submit">Continue</button>
            </form>
        </body>
    </html>
    """
    return body
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
    REQUIRED_SCOPE in scope || push!(scope, REQUIRED_SCOPE)
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

function authorization_get_handler(req::HTTP.Request)
    query = parse_query_params(req)
    normalized, error_message = authorization_parameters(query)
    response = if normalized === nothing
        html_response("<h1>Invalid authorization request</h1><p>$(error_message)</p>"; status=400)
    else
        hidden_params = Dict{String,String}()
        for key in ("client_id", "redirect_uri", "scope", "state", "code_challenge", "code_challenge_method")
            value = get(normalized, key, nothing)
            value === nothing || (hidden_params[key] = value)
        end
        html_response(render_login_page(hidden_params))
    end
    return response
end

function authorization_post_handler(req::HTTP.Request)
    body = req.body isa Vector{UInt8} ? req.body : Vector{UInt8}(codeunits(String(req.body)))
    params = parse_form_params(body)
    username = get(params, "username", "")
    password = get(params, "password", "")
    hidden_keys = Dict{String,String}()
    for key in ("client_id", "redirect_uri", "scope", "state", "code_challenge", "code_challenge_method")
        value = get(params, key, nothing)
        value === nothing || (hidden_keys[String(key)] = String(value))
    end
    request_body = String(body)
    normalized, error_message = authorization_parameters(merge(copy(hidden_keys), Dict{String,String}("response_type" => "code")))
    response = if normalized === nothing
        html_response("<h1>Invalid authorization request</h1><p>$(error_message)</p>"; status=400)
    elseif username != AUTH_USERNAME || password != AUTH_PASSWORD
        html_response(render_login_page(hidden_keys; error_message="Invalid credentials"))
    else
        auth_code = random_token()
        scope_values = [String(s) for s in split(normalized["scope"])]
        state_value = get(normalized, "state", nothing)
        code = AuthorizationCode(
            auth_code,
            normalized["client_id"],
            normalized["redirect_uri"],
            normalized["code_challenge"],
            normalized["code_challenge_method"],
            scope_values,
            AUTH_USERNAME,
            state_value,
            Dates.now(UTC),
        )
        store_authorization_code!(code)
        redirect_uri = normalized["redirect_uri"]
        parts = ["code=$(HTTP.URIs.escapeuri(auth_code))"]
        state_value !== nothing && push!(parts, "state=$(HTTP.URIs.escapeuri(String(state_value)))")
        separator = occursin('?', redirect_uri) ? "&" : "?"
        location = string(redirect_uri, separator, join(parts, "&"))
        headers = HTTP.Headers([
            "Location" => location,
            "Cache-Control" => "no-store",
        ])
        HTTP.Response(302, headers, "")
    end
    return response
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
            "scope" => REQUIRED_SCOPE,
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
    request_body = String(body_bytes)
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

    issued = issue_access_token(
        issuer;
        subject=code.subject,
        client_id=client_id,
        scope=code.scope,
        store=TOKEN_STORE,
    )
    body = Dict(
        "access_token" => issued.token,
        "token_type" => "Bearer",
        "expires_in" => issuer.expires_in,
        "scope" => join(code.scope, ' '),
    )
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
        required_scopes=[REQUIRED_SCOPE],
        context_key=:oauth_token,
    )
    protected_stream = protected_resource_middleware(
        req -> MCP.handle_stream_request(server, req),
        validator;
        resource_metadata_url=resource_metadata_url,
        required_scopes=[REQUIRED_SCOPE],
        context_key=:oauth_token,
    )

    HTTP.register!(router, "POST", server.transport_path, protected_jsonrpc)
    HTTP.register!(router, "GET", server.transport_path, protected_stream)

    HTTP.register!(router, "GET", "/oauth/authorize", authorization_get_handler)
    HTTP.register!(router, "POST", "/oauth/authorize", authorization_post_handler)
    HTTP.register!(router, "POST", "/oauth/token", req -> token_handler(req, token_issuer))
    registration_handler = dynamic_client_registration_handler()
    HTTP.register!(router, "POST", REGISTRATION_PATH, registration_handler)

    register_protected_resource_metadata!(router, protected_resource_config)
    register_authorization_server_metadata!(router, authorization_server_config)
    register_jwks_endpoint!(router, [jwk])
end

function start_server()
    config = MCPServerConfig(
        name="Calculator MCP Server (OAuth)",
        version="0.1.0",
        description="Example arithmetic tools protected by OAuth access tokens.",
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
    base = "https://f8c4912df2d1.ngrok-free.app" # MCP.base_url(http_server)
    transport_url = string(base, server.transport_path)
    issuer_url = base
    authorization_endpoint = string(base, "/oauth/authorize")
    token_endpoint = string(base, "/oauth/token")
    jwks_uri = string(base, DEFAULT_JWKS_PATH)
    resource_metadata_url = string(base, OAuth.DEFAULT_PRM_PATH)
    registration_endpoint = string(base, REGISTRATION_PATH)

    prm_config = ProtectedResourceConfig(
        resource=transport_url,
        authorization_servers=[issuer_url],
        scopes_supported=[REQUIRED_SCOPE],
    )
    as_config = AuthorizationServerConfig(
        issuer=issuer_url,
        authorization_endpoint=authorization_endpoint,
        token_endpoint=token_endpoint,
        jwks_uri=jwks_uri,
        response_types_supported=["code"],
        grant_types_supported=["authorization_code"],
        code_challenge_methods_supported=["S256"],
        scopes_supported=[REQUIRED_SCOPE],
        extra=Dict("registration_endpoint" => registration_endpoint),
    )
    token_issuer = JWTAccessTokenIssuer(
        issuer=issuer_url,
        audience=[transport_url],
        private_key=ISSUER_PRIVATE_KEY,
        kid="calculator-auth-key",
        expires_in=3600,
    )
    jwk = public_jwk(token_issuer)
    validator = TokenValidationConfig(
        issuer=issuer_url,
        audience=[transport_url],
        jwks=Dict("keys" => [jwk]),
    )

    add_routes!(http_server.router, server, validator, resource_metadata_url, token_issuer, as_config, prm_config, jwk)

    println("Calculator MCP server with OAuth protection ready.")
    println("Transport URL: $(transport_url)")
    println("Protected resource metadata: $(resource_metadata_url)")
    println("Authorization endpoint: $(authorization_endpoint)")
    println("Token endpoint: $(token_endpoint)")
    println("Dynamic client registration: $(registration_endpoint)")
    println("Client ID: $(CLIENT_ID) (public client, PKCE required)")
    println("Credentials: username=$(AUTH_USERNAME) password=$(AUTH_PASSWORD)")

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

start_server()
