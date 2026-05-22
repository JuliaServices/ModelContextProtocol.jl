#!/usr/bin/env julia

using ModelContextProtocol
using OAuth
using JSON

const MCP = ModelContextProtocol

const SERVER_BASE_URL = "http://127.0.0.1:3020"
const PRM_URL = string(SERVER_BASE_URL, OAuth.DEFAULT_PRM_PATH)
const CLIENT_ID = "calculator-public-client"
const REQUIRED_SCOPE = "calculator:use"
const OPEN_BROWSER = lowercase(get(ENV, "MCP_OPEN_BROWSER", "true")) != "false"

function start_pkce_flow()
    println("Launching PKCE flow in your browser. Sign in as bob/bob.")
    if !OPEN_BROWSER
        println("Set MCP_OPEN_BROWSER=true if you prefer automatic browser launch.")
    end
    result = start_public_client_flow(
        PRM_URL;
        client_id=CLIENT_ID,
        scopes=[REQUIRED_SCOPE],
        open_browser=OPEN_BROWSER,
    )
    scope = result.token.scope === nothing ? "(none provided)" : result.token.scope
    println("Received access token scoped to: ", scope)
    return result
end

function print_json(value)
    io = IOBuffer()
    JSON.print(io, value, 2)
    println(String(take!(io)))
end

function with_authenticated_client(f::Function)
    discovery = discover_server(SERVER_BASE_URL)
    flow = start_pkce_flow()
    client = prepare_manual_client(discovery)
    attach_token!(client, flow.token)
    initialize_client!(
        client;
        client_info=Dict("name" => "Authenticated Calculator Example", "version" => "1.0.0"),
    )
    try
        return f(client)
    finally
        terminate_session!(client)
    end
end

function add_numbers(numbers::Vector{<:Real})
    with_authenticated_client() do client
        response = call_tool(client, "add"; arguments=Dict("numbers" => numbers))
        println("Tool call response:")
        print_json(response)
        return response
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    println("Calling the authenticated calculator tool with numbers 1, 3, 4.")
    add_numbers([1, 3, 4])
end
