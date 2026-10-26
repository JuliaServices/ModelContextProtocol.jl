# JuliaC --trim=safe workload for ModelContextProtocol's statically dispatchable
# server: the StaticMCPServer transport (session lifecycle, stateless mode,
# protocol version negotiation and header policy, strict JSON-RPC scanning,
# tool dispatch, fixed resources, MCP Apps metadata, and raw-JSON result
# serialization) exercised over in-memory HTTP requests. The
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
        meta=JSON.JSONText("{\"trace\":\"trim\"}"),
    )
end

const _TRIM_WIDGET_URI = "ui://trim/card"
const _TRIM_WIDGET_HTML = "<!doctype html><script>const s = \"</script>\";\n\u00e9</script>"

function _trim_server(; stateless::Bool=false, missing_protocol_header::Symbol=:error)
    tool = ModelContextProtocol.StaticMCPTool(
        name="echo",
        title="Echo",
        description="Return the supplied arguments.",
        input_schema=JSON.JSONText(
            "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}},\"required\":[\"message\"]}",
        ),
        annotations=JSON.JSONText("{\"readOnlyHint\":true}"),
        output_schema=JSON.JSONText("{\"type\":\"object\"}"),
        meta=ModelContextProtocol.static_ui_tool_meta(_TRIM_WIDGET_URI),
        handler=TrimEchoHandler(),
    )
    widget = ModelContextProtocol.StaticMCPResource(
        uri=_TRIM_WIDGET_URI,
        name="card",
        mime_type=ModelContextProtocol.MCP_APP_HTML_MIME_TYPE,
        text=_TRIM_WIDGET_HTML,
        meta=JSON.JSONText("{\"ui\":{\"prefersBorder\":true}}"),
    )
    return ModelContextProtocol.StaticMCPServer(
        [tool];
        name="Trim Test",
        version="0.1.0",
        description="Static MCP trim workload server.",
        instructions="Use the echo tool.",
        resources=[widget],
        extensions=ModelContextProtocol.static_ui_extensions(),
        supported_protocol_versions=["2025-06-18"],
        missing_protocol_header=missing_protocol_header,
        stateless=stateless,
    )
end

function _trim_assert(condition::Bool, msg::AbstractString)::Nothing
    condition || error(msg)
    return nothing
end

function _request(
    body::String;
    session_id::String="",
    protocol_version::String=ModelContextProtocol.DEFAULT_PROTOCOL_VERSION,
)::HTTP.Request
    headers = Pair{String,String}["Content-Type" => "application/json"]
    isempty(protocol_version) || push!(headers, "MCP-Protocol-Version" => protocol_version)
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
    _trim_assert(occursin("\"outputSchema\":{\"type\":\"object\"}", listed_body), "tools/list includes outputSchema")
    _trim_assert(occursin("\"ui/resourceUri\":\"ui://trim/card\"", listed_body), "tools/list includes ui _meta")

    called = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"message\":\"hi \\\"trim\\\"\"}}}"; session_id),
    )
    _trim_assert(called.status == 200, "tools/call status")
    called_body = _body(called)
    _trim_assert(occursin("\"text\":\"echoed\"", called_body), "tools/call text content")
    _trim_assert(occursin("\"structuredContent\":{\"message\":\"hi \\\"trim\\\"\"}", called_body), "tools/call structured content")
    _trim_assert(occursin("\"isError\":false", called_body), "tools/call success flag")
    _trim_assert(occursin("\"_meta\":{\"trace\":\"trim\"}", called_body), "tools/call result _meta")

    resources = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/list\"}"; session_id),
    )
    _trim_assert(occursin("\"_meta\":{\"ui\":{\"prefersBorder\":true}}", _body(resources)), "resources/list _meta")

    read = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"resources/read\",\"params\":{\"uri\":\"ui://trim/card\"}}"; session_id),
    )
    _trim_assert(occursin("\"text\":\"<!doctype html><script>const s = \\\"</script>\\\";\\n\u00e9</script>\"", _body(read)), "resources/read escapes text")

    missing_resource = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"resources/read\",\"params\":{\"uri\":\"ui://missing\"}}"; session_id),
    )
    _trim_assert(occursin("\"code\":-32002", _body(missing_resource)), "unknown resource")

    templates = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"resources/templates/list\"}"; session_id),
    )
    _trim_assert(occursin("\"resourceTemplates\":[]", _body(templates)), "resources/templates/list")

    ping = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"ping\"}"; session_id),
    )
    _trim_assert(occursin("\"result\":{}", _body(ping)), "ping")

    missing_header = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"ping\"}"; session_id, protocol_version=""),
    )
    _trim_assert(missing_header.status == 400, "missing header rejected under :error")

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

function run_stateless_trim_sample()::Nothing
    server = _trim_server(; stateless=true, missing_protocol_header=:warn)

    init = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"trim-test\",\"version\":\"0.1.0\"}}}"; protocol_version=""),
    )
    _trim_assert(init.status == 200, "stateless initialize status")
    _trim_assert(isempty(HTTP.header(init, "MCP-Session-Id", "")), "stateless initialize issues no session")
    _trim_assert(HTTP.header(init, "MCP-Protocol-Version", "") == "2025-06-18", "negotiated version header")
    init_body = _body(init)
    _trim_assert(occursin("\"protocolVersion\":\"2025-06-18\"", init_body), "negotiated version echoed")
    _trim_assert(occursin("\"io.modelcontextprotocol/ui\"", init_body), "extensions advertised")
    _trim_assert(occursin("\"resources\":{\"listChanged\":false}", init_body), "resources advertised")

    listed = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"; protocol_version="2025-06-18"),
    )
    _trim_assert(listed.status == 200, "stateless tools/list without session")

    read = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/read\",\"params\":{\"uri\":\"ui://trim/card\"}}"),
    )
    _trim_assert(read.status == 200 && occursin("\"contents\":[", _body(read)), "stateless resources/read")

    called = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"message\":\"hi\"}}}"),
    )
    _trim_assert(occursin("\"structuredContent\":{\"message\":\"hi\"}", _body(called)), "stateless tools/call")

    warned = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"ping\"}"; protocol_version=""),
    )
    _trim_assert(warned.status == 200, "missing header served under :warn")

    notification = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"),
    )
    _trim_assert(notification.status == 202, "stateless notification accepted")

    unsupported = ModelContextProtocol.handle_static_jsonrpc_request(
        server,
        _request("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"ping\"}"; protocol_version="2024-11-05"),
    )
    _trim_assert(unsupported.status == 400, "unsupported version header rejected")

    deleted = ModelContextProtocol.handle_static_session_delete(
        server,
        HTTP.Request("DELETE", "/v1/mcp", Pair{String,String}["MCP-Session-Id" => "anything"]),
    )
    _trim_assert(deleted.status == 405, "stateless delete")
    _trim_assert(isempty(server.sessions), "stateless server keeps no sessions")
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_mcp_trim_sample()
    run_stateless_trim_sample()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
