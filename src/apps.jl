# MCP Apps (SEP-1865) server-side helpers.
#
# MCP Apps let a server attach an interactive HTML "app" (a widget rendered in a
# sandboxed iframe) to tool results. Hosts that support the extension
# (Cursor, Claude, ChatGPT-style clients) render the widget inline in chat and feed it
# the tool call's `structuredContent`; hosts that don't simply ignore it and fall
# back to the text content.
#
# Getting a widget to actually render requires several pieces to line up exactly
# (extension capability, ui:// resource, tool `_meta`, embedded resource content,
# and a widget-side postMessage handshake). These helpers encode all of them.
# See MCP-App-playbook.md at the repo root for the full walkthrough.

"""
Extension identifier for MCP Apps (SEP-1865). Advertised under
`capabilities.extensions` in the server's `initialize` response and used by
hosts to decide whether to render `ui://` resources.
"""
const MCP_APPS_EXTENSION_ID = "io.modelcontextprotocol/ui"

"""
MIME type for MCP App HTML resources. The `;profile=mcp-app` parameter is load
bearing: hosts use it to distinguish renderable app widgets from plain HTML
resources, so a bare `text/html` will NOT render in current hosts.
"""
const MCP_APP_HTML_MIME_TYPE = "text/html;profile=mcp-app"

"""
Protocol version of the widget <-> host bridge, sent by the widget in its
`ui/initialize` request. This is distinct from the MCP protocol version
negotiated between client and server over HTTP.
"""
const MCP_APPS_UI_PROTOCOL_VERSION = "2026-01-26"

const MCP_APP_URI_SCHEME = "ui://"

"""
    MCPUIResource

Handle returned by [`register_ui_resource!`](@ref). Bundles the registered
`uri`, `mime_type`, and `html` so tool handlers can embed the widget in results
via [`embedded_ui_resource`](@ref) / [`ui_tool_content`](@ref) and tool
registrations can point at it via [`ui_tool_meta`](@ref).
"""
struct MCPUIResource
    uri::String
    mime_type::String
    html::String
end

"""
    ui_extension_capability(; mime_types=[MCP_APP_HTML_MIME_TYPE]) -> Dict{String,Any}

Build the server `capabilities` fragment that advertises MCP Apps support:

```json
{"extensions": {"io.modelcontextprotocol/ui": {"mimeTypes": ["text/html;profile=mcp-app"]}}}
```

Pass the result as `capabilities` when constructing the server, or merge it into
existing capabilities with [`add_ui_extension_capability!`](@ref). Hosts ignore
`ui://` resources from servers that do not advertise this capability, so this
must appear in the `initialize` response for widgets to render at all.
"""
function ui_extension_capability(; mime_types::Vector{String}=[MCP_APP_HTML_MIME_TYPE])
    return Dict{String,Any}(
        "extensions" => Dict{String,Any}(
            MCP_APPS_EXTENSION_ID => Dict{String,Any}(
                "mimeTypes" => collect(String, mime_types),
            ),
        ),
    )
end

"""
    add_ui_extension_capability!(capabilities::AbstractDict; mime_types=[MCP_APP_HTML_MIME_TYPE])

Merge the MCP Apps extension capability into an existing `capabilities` dict
(preserving any other extensions already declared) and return it.
"""
function add_ui_extension_capability!(capabilities::AbstractDict; mime_types::Vector{String}=[MCP_APP_HTML_MIME_TYPE])
    extensions = get!(capabilities, "extensions") do
        Dict{String,Any}()
    end
    extensions isa AbstractDict || throw(ArgumentError("capabilities[\"extensions\"] must be an object"))
    extensions[MCP_APPS_EXTENSION_ID] = Dict{String,Any}("mimeTypes" => collect(String, mime_types))
    return capabilities
end

"""
    ui_tool_meta(resource_uri; visibility=["model", "app"], extra=nothing) -> Dict{String,Any}

Build the `_meta` payload that links a tool to its MCP App widget. Accepts a
`ui://` uri string or an [`MCPUIResource`](@ref). Pass the result as the `meta`
keyword of [`register_tool!`](@ref).

The resource uri is written under BOTH shapes hosts read in the wild:

- nested: `_meta.ui = {"resourceUri": ..., "visibility": [...]}`
- flat:   `_meta["ui/resourceUri"] = ...`

`visibility` controls who sees the tool: `"model"` (the LLM may call it) and/or
`"app"` (the widget may call it via `tools/call`). App-only tools — e.g. a
select/validate action triggered from inside a widget — should use
`visibility=["app"]` so the model never calls them directly.
"""
function ui_tool_meta(resource_uri::Union{AbstractString,MCPUIResource,Nothing}=nothing;
                      visibility=["model", "app"], extra::Union{AbstractDict,Nothing}=nothing)
    uri = resource_uri isa MCPUIResource ? resource_uri.uri : resource_uri
    ui = Dict{String,Any}("visibility" => collect(String, String.(visibility)))
    meta = Dict{String,Any}("ui" => ui)
    if uri !== nothing
        ui["resourceUri"] = String(uri)
        meta["ui/resourceUri"] = String(uri)
    end
    extra === nothing || merge!(meta, Dict{String,Any}(String(k) => v for (k, v) in extra))
    return meta
end

"""
    ui_resource_meta(; prefers_border=true, display_mode="inline", extra=nothing) -> Dict{String,Any}

Build the `_meta` payload for a MCP App resource registration. `display_mode`
hints how the host should place the widget (`"inline"` in the chat transcript is
the widely supported mode); `prefers_border` asks the host to draw its standard
widget frame around the iframe.
"""
function ui_resource_meta(; prefers_border::Bool=true, display_mode::AbstractString="inline",
                          extra::Union{AbstractDict,Nothing}=nothing)
    ui = Dict{String,Any}(
        "prefersBorder" => prefers_border,
        "displayMode" => String(display_mode),
    )
    meta = Dict{String,Any}("ui" => ui)
    extra === nothing || merge!(meta, Dict{String,Any}(String(k) => v for (k, v) in extra))
    return meta
end

"""
    ui_resource_contents(uri, html; mime_type=MCP_APP_HTML_MIME_TYPE) -> Dict{String,Any}

The single-resource payload used both in `resources/read` responses and inside
embedded resource content blocks: `{"uri": ..., "mimeType": ..., "text": html}`.
"""
function ui_resource_contents(uri::AbstractString, html::AbstractString; mime_type::AbstractString=MCP_APP_HTML_MIME_TYPE)
    return Dict{String,Any}(
        "uri" => String(uri),
        "mimeType" => String(mime_type),
        "text" => String(html),
    )
end

ui_resource_contents(resource::MCPUIResource) = ui_resource_contents(resource.uri, resource.html; mime_type=resource.mime_type)

"""
    embedded_ui_resource(uri, html; mime_type=MCP_APP_HTML_MIME_TYPE) -> Dict{String,Any}

An embedded-resource content block (`{"type": "resource", "resource": {...}}`)
for inclusion in a tool result's `content` array.

Embedding the widget HTML directly in tool results matters in practice: some
hosts (Cursor at the time of writing) render the embedded copy rather than
fetching the registered resource via `resources/read`. Register the resource
AND embed it for maximum compatibility.
"""
function embedded_ui_resource(uri::AbstractString, html::AbstractString; mime_type::AbstractString=MCP_APP_HTML_MIME_TYPE)
    return Dict{String,Any}(
        "type" => "resource",
        "resource" => ui_resource_contents(uri, html; mime_type=mime_type),
    )
end

embedded_ui_resource(resource::MCPUIResource) = embedded_ui_resource(resource.uri, resource.html; mime_type=resource.mime_type)

"""
    ui_tool_content(text, resource::MCPUIResource; embed=true) -> Vector{Any}

Standard content array for a widget-backed tool result: a text block (shown by
hosts without MCP Apps support, and read by the model) followed, when
`embed=true`, by the embedded widget resource. The widget receives the result's
`structuredContent`, so pass that separately via `MCPToolResult`:

```julia
MCPToolResult(
    content=ui_tool_content(markdown_summary, card),
    structured_content=result,
)
```

Set `embed=false` for outcomes that should not render a widget (e.g. lookups
that found nothing).
"""
function ui_tool_content(text::AbstractString, resource::MCPUIResource; embed::Bool=true)
    content = Any[MCPTextContent(text=String(text))]
    embed && push!(content, embedded_ui_resource(resource))
    return content
end

"""
    register_ui_resource!(server; uri, html, name=nothing, title=nothing, description=nothing,
                          mime_type=MCP_APP_HTML_MIME_TYPE, meta=ui_resource_meta(),
                          annotations=Dict{String,Any}()) -> MCPUIResource

Register an MCP App widget as a `ui://` resource. The handler is generated for
you and serves `html` with the correct contents payload for `resources/read`.

Returns an [`MCPUIResource`](@ref) handle; keep it and use it with
[`ui_tool_meta`](@ref) (tool registration) and [`ui_tool_content`](@ref) /
[`embedded_ui_resource`](@ref) (tool results).

The `uri` must use the `ui://` scheme and should be stable across releases —
hosts key caching and tool->widget association on it.
"""
function register_ui_resource!(server::MCPServer; uri::AbstractString, html::AbstractString,
                               name::Union{AbstractString,Nothing}=nothing,
                               title::Union{AbstractString,Nothing}=nothing,
                               description::Union{AbstractString,Nothing}=nothing,
                               mime_type::AbstractString=MCP_APP_HTML_MIME_TYPE,
                               meta::AbstractDict=ui_resource_meta(),
                               annotations::AbstractDict=Dict{String,Any}())
    startswith(String(uri), MCP_APP_URI_SCHEME) ||
        throw(ArgumentError("MCP App resources must use the $(MCP_APP_URI_SCHEME) uri scheme, got $(uri)"))
    resource = MCPUIResource(String(uri), String(mime_type), String(html))
    register_resource!(
        server;
        uri=resource.uri,
        name=name,
        title=title,
        description=description,
        mime_type=resource.mime_type,
        meta=meta,
        annotations=annotations,
        handler=(_context, _args) -> Dict{String,Any}("contents" => [ui_resource_contents(resource)]),
    )
    return resource
end

"""
Widget-side bootstrap script implementing the MCP Apps host bridge. Injected by
[`mcp_app_html`](@ref); exposed for widgets built outside that helper.

Exposes `window.mcpApp` with:

- `onRender(cb)` — `cb(structuredContent, rawParams)` runs whenever render data
  arrives (from the `ui/initialize` response or `ui/notifications/tool-result`).
  Registering after data already arrived replays the latest data immediately.
- `callTool(name, args)` — proxy a `tools/call` through the host; resolves with
  the tool result.
- `request(method, params)` / `notify(method, params)` — raw JSON-RPC to the host.
- `reportSize()` — manually push a `ui/notifications/size-changed` (automatic
  reporting via ResizeObserver is already on).
- `ready` — Promise resolving after the `ui/initialize` handshake (resolves
  `false` on handshake timeout rather than rejecting; render data is still
  delivered if the host sends it).

The handshake it performs (each step required by hosts in the wild):

1. request `ui/initialize` with `{protocolVersion, appInfo, appCapabilities}`
2. on response, notify `ui/notifications/initialized`
3. report size via `ui/notifications/size-changed` (ResizeObserver + load), so
   the host can size the iframe — without this Cursor renders a 0-height frame
4. listen for `ui/notifications/tool-result` and surface `structuredContent`
"""
const MCP_APP_BOOTSTRAP_JS = raw"""
window.mcpApp = (function () {
  "use strict";
  var config = window.__MCP_APP_CONFIG__ || {};
  var appInfo = { name: config.name || "mcp-app", version: config.version || "1.0.0" };
  var protocolVersion = config.protocolVersion || "2026-01-26";
  var initTimeoutMs = config.initTimeoutMs || 4000;

  var nextId = 1;
  var pending = new Map();
  var renderCallbacks = [];
  var latestData;
  var latestParams;
  var hasData = false;
  var lastSize = { width: -1, height: -1 };
  var sizeScheduled = false;

  function post(message) {
    try { window.parent.postMessage(message, "*"); } catch (_err) { /* detached host */ }
  }
  function notify(method, params) {
    post({ jsonrpc: "2.0", method: method, params: params || {} });
  }
  function request(method, params) {
    var id = nextId++;
    post({ jsonrpc: "2.0", id: id, method: method, params: params || {} });
    return new Promise(function (resolve, reject) {
      pending.set(id, { resolve: resolve, reject: reject });
    });
  }

  function measure() {
    var doc = document.documentElement;
    var body = document.body;
    return {
      width: Math.ceil(Math.max(doc ? doc.scrollWidth : 0, body ? body.scrollWidth : 0)),
      height: Math.ceil(Math.max(doc ? doc.scrollHeight : 0, body ? body.scrollHeight : 0))
    };
  }
  function sendSize(force) {
    var size = measure();
    if (!force && size.width === lastSize.width && size.height === lastSize.height) return;
    lastSize = size;
    notify("ui/notifications/size-changed", size);
  }
  function reportSize() {
    if (sizeScheduled) return;
    sizeScheduled = true;
    requestAnimationFrame(function () {
      sizeScheduled = false;
      sendSize(false);
    });
  }

  function deliver(data, params) {
    latestData = data;
    latestParams = params;
    hasData = true;
    for (var i = 0; i < renderCallbacks.length; i++) {
      try { renderCallbacks[i](data, params); } catch (err) { console.error("mcpApp render callback failed", err); }
    }
    reportSize();
  }
  function extractRenderData(value) {
    if (!value || typeof value !== "object") return undefined;
    if (value.structuredContent !== undefined) return value.structuredContent;
    if (value.toolResult && value.toolResult.structuredContent !== undefined) return value.toolResult.structuredContent;
    if (value.result && value.result.structuredContent !== undefined) return value.result.structuredContent;
    if (value.renderData !== undefined) return value.renderData;
    return undefined;
  }

  window.addEventListener("message", function (ev) {
    if (ev.source !== window.parent) return;
    var message = ev.data;
    if (!message || typeof message !== "object") return;
    if (message.id !== undefined && message.method === undefined && pending.has(message.id)) {
      var entry = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) entry.reject(Object.assign(new Error(message.error.message || "Request failed"), { code: message.error.code, data: message.error.data }));
      else entry.resolve(message.result || {});
      return;
    }
    if (message.method === "ui/notifications/tool-result" && message.params) {
      var data = extractRenderData(message.params);
      deliver(data === undefined ? message.params : data, message.params);
    }
  });

  // ui/initialize is retried: if the host attaches its message listener after the
  // iframe's scripts run (observed in real hosts and test harnesses), the first
  // request is silently dropped and a single-shot handshake would hang forever.
  var INIT_RETRY_DELAYS = [800, 2400];
  var ready = new Promise(function (resolve) {
    var settled = false;
    function finish(ok) {
      if (settled) return;
      settled = true;
      resolve(ok);
    }
    function attempt(round) {
      if (settled) return;
      request("ui/initialize", { protocolVersion: protocolVersion, appInfo: appInfo, appCapabilities: {} })
        .then(function (result) {
          if (settled) return;
          notify("ui/notifications/initialized", {});
          sendSize(true);
          var data = extractRenderData(result);
          if (data !== undefined) deliver(data, result);
          finish(true);
        })
        .catch(function (err) {
          console.warn("mcpApp: ui/initialize failed", err);
          finish(false);
        });
      if (round < INIT_RETRY_DELAYS.length) {
        setTimeout(function () { attempt(round + 1); }, INIT_RETRY_DELAYS[round]);
      } else {
        setTimeout(function () {
          if (settled) return;
          console.warn("mcpApp: ui/initialize timed out after " + initTimeoutMs + "ms; continuing without handshake");
          finish(false);
        }, initTimeoutMs);
      }
    }
    attempt(0);
  });

  if (typeof ResizeObserver !== "undefined") {
    var observer = new ResizeObserver(function () { reportSize(); });
    observer.observe(document.documentElement);
    if (document.body) observer.observe(document.body);
    else document.addEventListener("DOMContentLoaded", function () { observer.observe(document.body); });
  }
  window.addEventListener("load", function () { sendSize(true); });
  if (document.fonts && document.fonts.ready && document.fonts.ready.then) {
    document.fonts.ready.then(function () { reportSize(); });
  }

  return {
    ready: ready,
    request: request,
    notify: notify,
    reportSize: reportSize,
    callTool: function (name, args) {
      return request("tools/call", { name: name, arguments: args || {} });
    },
    onRender: function (callback) {
      renderCallbacks.push(callback);
      if (hasData) {
        try { callback(latestData, latestParams); } catch (err) { console.error("mcpApp render callback failed", err); }
      }
    }
  };
})();
"""

"""
    mcp_app_html(; app_name, body, css="", script="", head="", app_version="1.0.0", title=app_name,
                 lang="en", color_scheme="light dark", init_timeout_ms=4000) -> String

Assemble a complete, handshake-correct MCP App HTML document:

- `app_name` / `app_version` identify the widget in its `ui/initialize` handshake.
- `body` is the widget's inner HTML (placed directly inside `<body>`).
- `css` is inlined into a `<style>` tag in `<head>`. It is the first stylesheet
  content in the document, so leading `@import` rules (e.g. web fonts as
  progressive enhancement) remain valid.
- `head` is optional extra raw head markup (e.g. font `<link>` tags).
- `script` is the widget's own JavaScript, run AFTER the bootstrap so
  `window.mcpApp` is available. A typical widget is just:

```julia
mcp_app_html(
    app_name="acme-report-card",
    body="<main id=\\"app\\"></main>",
    css=CARD_CSS,
    script="mcpApp.onRender(function(data){ document.getElementById('app').innerHTML = render(data); });",
)
```

The document embeds [`MCP_APP_BOOTSTRAP_JS`](@ref), which performs the
`ui/initialize` handshake, subscribes to tool results, and auto-reports size.
Serve the returned string via [`register_ui_resource!`](@ref).

`css`/`script`/`body` must not contain a closing `</style>`/`</script>` tag
sequence (use `<\\/script>` inside JS strings); an `ArgumentError` is thrown if
one is found since it would truncate the document in the host iframe.
"""
function mcp_app_html(; app_name::AbstractString, body::AbstractString,
                      css::AbstractString="", script::AbstractString="",
                      head::AbstractString="",
                      app_version::AbstractString="1.0.0",
                      title::AbstractString=app_name, lang::AbstractString="en",
                      color_scheme::AbstractString="light dark",
                      init_timeout_ms::Integer=4000)
    occursin(r"</style"i, css) && throw(ArgumentError("css must not contain a </style> sequence"))
    for (label, text) in ("script" => script, "body html" => body)
        occursin(r"</script"i, text) && throw(ArgumentError("$label must not contain a </script> sequence; escape it as <\\/script>"))
    end
    config = JSON.json(Dict{String,Any}(
        "name" => String(app_name),
        "version" => String(app_version),
        "protocolVersion" => MCP_APPS_UI_PROTOCOL_VERSION,
        "initTimeoutMs" => Int(init_timeout_ms),
    ))
    io = IOBuffer()
    print(io, "<!doctype html>\n<html lang=\"", lang, "\">\n<head>\n")
    print(io, "<meta charset=\"utf-8\">\n")
    print(io, "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n")
    print(io, "<meta name=\"color-scheme\" content=\"", html_escape(color_scheme), "\">\n")
    print(io, "<title>", html_escape(title), "</title>\n")
    isempty(head) || print(io, head, "\n")
    print(io, "<style>\n", css, "\n</style>\n")
    print(io, "</head>\n<body>\n", body, "\n")
    print(io, "<script>\nwindow.__MCP_APP_CONFIG__=", config, ";\n", MCP_APP_BOOTSTRAP_JS, "\n</script>\n")
    isempty(script) || print(io, "<script>\n", script, "\n</script>\n")
    print(io, "</body>\n</html>\n")
    return String(take!(io))
end

function html_escape(text::AbstractString)
    return replace(String(text),
        "&" => "&amp;",
        "<" => "&lt;",
        ">" => "&gt;",
        "\"" => "&quot;",
        "'" => "&#39;",
    )
end
