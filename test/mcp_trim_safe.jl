# JuliaC --trim=safe workload for ModelContextProtocol's statically dispatchable
# server: the StaticMCPServer tools transport (session lifecycle, protocol
# header validation, strict JSON-RPC scanning, tool dispatch,
# and raw-JSON result serialization) exercised over in-memory HTTP requests. The
# dynamic MCPServer (Dict{String,Any}-based dispatch) and live HTTP serving are
# deliberately not part of this workload: released HTTP 1.x socket/TLS init is
# not trim-verifiable.
using ModelContextProtocol
const HTTP = ModelContextProtocol.HTTP
const JSON = ModelContextProtocol.JSON

struct TrimEchoHandler end

function (::TrimEchoHandler)(
    ::ModelContextProtocol.StaticMCPRequestContext,
    arguments::JSON.JSONText,
)
    return ModelContextProtocol.StaticMCPToolResult(
        text="echoed",
        structured_content=arguments,
    )
end

function _trim_server()
    tool = ModelContextProtocol.StaticMCPTool(
        name="echo",
        title="Echo",
        description="Return the supplied arguments.",
        input_schema=JSON.JSONText(
            "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}},\"required\":[\"message\"]}",
        ),
        annotations=JSON.JSONText("{\"readOnlyHint\":true}"),
        handler=TrimEchoHandler(),
    )
    return ModelContextProtocol.StaticMCPServer(
        [tool];
        name="Trim Test",
        version="0.1.0",
        description="Static MCP trim workload server.",
        instructions="Use the echo tool.",
    )
end

function _trim_assert(condition::Bool, msg::AbstractString)::Nothing
    condition || error(msg)
    return nothing
end

function _request(body::String; session_id::String="")::HTTP.Request
    headers = Pair{String,String}[
        "Content-Type" => "application/json",
        "MCP-Protocol-Version" => ModelContextProtocol.DEFAULT_PROTOCOL_VERSION,
    ]
    isempty(session_id) || push!(headers, "MCP-Session-Id" => session_id)
    return HTTP.Request("POST", "/v1/mcp", headers, Vector{UInt8}(codeunits(body)))
end

_body(response::HTTP.Response)::String = String(copy(response.body))

function run_mcp_trim_sample()::Nothing
    server = _trim_server()

    init = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"trim-test\",\"version\":\"0.1.0\"}}}"),
    )
    _trim_assert(init.status == 200, "initialize status")
    session_id = HTTP.header(init, "MCP-Session-Id", "")
    _trim_assert(!isempty(session_id), "session id issued")
    init_body = _body(init)
    _trim_assert(occursin("\"protocolVersion\":", init_body), "initialize advertises protocol version")
    _trim_assert(occursin("\"name\":\"Trim Test\"", init_body), "initialize server info")

    early = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"; session_id),
    )
    _trim_assert(early.status == 400, "tools/list before initialized rejected")

    initialized = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"; session_id),
    )
    _trim_assert(initialized.status == 202, "notifications/initialized accepted")

    listed = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}"; session_id),
    )
    _trim_assert(listed.status == 200, "tools/list status")
    listed_body = _body(listed)
    _trim_assert(occursin("\"name\":\"echo\"", listed_body), "tools/list includes echo")
    _trim_assert(occursin("\"readOnlyHint\":true", listed_body), "tools/list includes annotations")

    called = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"message\":\"hi \\\"trim\\\"\"}}}"; session_id),
    )
    _trim_assert(called.status == 200, "tools/call status")
    called_body = _body(called)
    _trim_assert(occursin("\"text\":\"echoed\"", called_body), "tools/call text content")
    _trim_assert(occursin("\"structuredContent\":{\"message\":\"hi \\\"trim\\\"\"}", called_body), "tools/call structured content")
    _trim_assert(occursin("\"isError\":false", called_body), "tools/call success flag")

    unknown = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"missing\"}}"; session_id),
    )
    _trim_assert(occursin("-32602", _body(unknown)), "unknown tool invalid params")

    missing_session = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/list\"}"),
    )
    _trim_assert(missing_session.status == 400, "missing session rejected")

    stream = ModelContextProtocol.handle_static_stream_request(
        server,
        HTTP.Request("GET", "/v1/mcp"),
    )
    _trim_assert(stream.status == 405, "static server rejects event stream")

    deleted = ModelContextProtocol.handle_static_session_delete(
        server,
        HTTP.Request("DELETE", "/v1/mcp", Pair{String,String}["MCP-Session-Id" => session_id]),
    )
    _trim_assert(deleted.status == 204, "session delete")
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_mcp_trim_sample()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
