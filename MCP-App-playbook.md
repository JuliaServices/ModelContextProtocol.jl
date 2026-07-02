# MCP App Playbook

How to ship an MCP server whose tools render **interactive HTML widgets** ("MCP
Apps", [SEP-1865](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/1865),
extension id `io.modelcontextprotocol/ui`) in hosts like Cursor, Claude, and other
MCP clients that support the extension — using the helpers in this package.

Everything in this document was extracted from a production integration that was
debugged host-by-host. The hard-won lesson: **five independent pieces must all be
exactly right or the host silently falls back to plain text** (or worse, renders a
blank/zero-height frame). This playbook lists all five, the helpers that produce
them, a verification runbook, and a troubleshooting table mapping each observed
failure mode to its cause.

---

## 1. How MCP Apps work (30 seconds)

Three parties:

```
┌────────────┐   MCP over HTTP    ┌────────────┐
│  MCP host  │ ◄────────────────► │ your server│   (this package)
│ (Cursor,   │                    └────────────┘
│  Claude…)  │   postMessage JSON-RPC
│  ┌───────┐ │
│  │ widget│ │   the widget is YOUR html, rendered by the host in a
│  │ iframe│ │   sandboxed iframe, talking to the host via postMessage
│  └───────┘ │
└────────────┘
```

1. The **server** declares the MCP Apps extension capability, registers a
   `ui://` HTML resource (the widget), and tags tools with `_meta` pointing at it.
2. When a tagged tool is called, the **host** loads the widget HTML into a
   sandboxed iframe and delivers the tool result's `structuredContent` to it.
3. The **widget** performs a `ui/initialize` handshake with the host over
   `postMessage`, then renders whatever `structuredContent` it receives. It may
   also call server tools back through the host (`tools/call`).

## 2. The non-negotiable checklist

| # | Requirement | Helper | What happens if you miss it |
|---|-------------|--------|------------------------------|
| 1 | Server speaks MCP protocol `2025-11-25` (or newer) and negotiates the client's requested version | `MCPServerConfig(protocol_version=…, supported_protocol_versions=[…])` | Host treats the server as pre-Apps; widgets never render |
| 2 | `initialize` response advertises `capabilities.extensions["io.modelcontextprotocol/ui"]` | `ui_extension_capability()` | Host ignores all `ui://` resources — tool results show as plain text |
| 3 | Widget registered as a `ui://` resource with mime type **exactly** `text/html;profile=mcp-app` | `register_ui_resource!` | Bare `text/html` is not treated as a renderable app |
| 4 | Tool `_meta` carries the widget uri under **both** `ui.resourceUri` (nested) and `ui/resourceUri` (flat) | `ui_tool_meta(resource)` | Some host builds read one shape, some the other; missing one → text fallback in that host |
| 5 | Tool results **embed** the widget resource in `content` *and* put the widget's data in `structuredContent` | `ui_tool_content(text, resource)` + `MCPToolResult(structured_content=…)` | Cursor renders the embedded copy, not the registered resource — without it: no widget. Without `structuredContent`: an empty widget |
| 6 | Widget performs the `ui/initialize` handshake, sends `ui/notifications/initialized`, and reports its size | `mcp_app_html` (bundles `MCP_APP_BOOTSTRAP_JS`) | No handshake → host never activates the frame. No size reports → 0-height (blank-looking) widget in Cursor |

Item 6 lives inside your HTML, which is why "the server looks right but nothing
renders" is so common: the bug can be on either side of the iframe boundary.
`mcp_app_html` makes the widget side turnkey.

## 3. Quickstart: a complete widget-backed server

```julia
using ModelContextProtocol
const MCP = ModelContextProtocol

server = MCPServer(
    name="Acme Reports",
    version="1.0.0",
    # Requirement 1: modern protocol + negotiation for older clients
    supported_protocol_versions=["2025-06-18", "2025-03-26"],
    # Cursor omits the MCP-Protocol-Version header on some requests; don't 400 on it
    missing_protocol_header=:warn,
    # Requirement 2: advertise the Apps extension
    capabilities=ui_extension_capability(),
)

# Requirement 3 + 6: register the widget (mcp_app_html handles the handshake JS)
card = register_ui_resource!(
    server;
    uri="ui://acme/report-card",
    name="acme-report-card",
    title="Acme Report Card",
    description="Inline report card for report-lookup results.",
    html=mcp_app_html(
        app_name="acme-report-card",
        body="""<main id="app" class="card">Loading…</main>""",
        css=""".card{font-family:system-ui;padding:16px;border-radius:8px}""",
        script="""
        mcpApp.onRender(function (data) {
          document.getElementById("app").textContent =
            data && data.title ? data.title : "No data";
        });
        """,
    ),
)

# Requirement 4 + 5: tag the tool and embed the widget in its results
register_tool!(
    server;
    name="report-lookup",
    description="Look up a report by id.",
    input_schema=Dict("type" => "object",
                      "properties" => Dict("id" => Dict("type" => "string"))),
    meta=ui_tool_meta(card),
    handler=(ctx, args) -> begin
        report = Dict("title" => "Q3 revenue", "id" => get(args, "id", ""))
        MCPToolResult(
            content=ui_tool_content("Found report: Q3 revenue", card),
            structured_content=report,   # ← this is what the widget receives
        )
    end,
)

http = serve_mcp_http(server; host="127.0.0.1", port=8765)
```

That's the entire surface area. Every requirement from §2 is satisfied by
construction.

## 4. The requirements in depth

### 4.1 Protocol version (requirement 1)

- The default `protocol_version` in this package is `2025-11-25`, the first
  revision with extension capabilities. Don't lower it for an Apps server.
- Clients send *their* `protocolVersion` in the `initialize` request. Per spec
  the server must echo it when supported, otherwise answer with its own. This
  package handles that via `supported_protocol_versions` — list every older
  revision you're willing to serve:

  ```julia
  MCPServer(; protocol_version="2025-11-25",
              supported_protocol_versions=["2025-06-18", "2025-03-26"], …)
  ```

- After `initialize`, spec-compliant clients send an `MCP-Protocol-Version`
  header on every HTTP request. **Cursor does not always do this.** With the
  default `missing_protocol_header=:error` those requests get a 400 and the
  integration looks "randomly broken". Use `:warn` (log it) or `:ignore`.

### 4.2 Capability advertisement (requirement 2)

The `initialize` response must contain:

```json
{
  "capabilities": {
    "extensions": {
      "io.modelcontextprotocol/ui": { "mimeTypes": ["text/html;profile=mcp-app"] }
    }
  }
}
```

`ui_extension_capability()` builds exactly this; `add_ui_extension_capability!(caps)`
merges it into capabilities you already have. Hosts check this **before** looking
at any resource or tool metadata — it is the master switch.

### 4.3 The `ui://` resource (requirement 3)

```julia
card = register_ui_resource!(server; uri="ui://acme/report-card", html=…, …)
```

- The uri **must** use the `ui://` scheme (enforced by the helper).
- The mime type **must** be `text/html;profile=mcp-app`
  (`MCP_APP_HTML_MIME_TYPE`). The `;profile=mcp-app` parameter is how hosts
  distinguish an app widget from an ordinary HTML resource.
- Keep uris stable across releases: hosts key caching and the tool→widget
  association on them.
- Resource `_meta` defaults to `{"ui": {"prefersBorder": true, "displayMode": "inline"}}`
  (`ui_resource_meta()`); `inline` is the widely supported display mode.
- One widget can serve many tools, or each tool can have its own widget —
  a tool points at exactly one widget uri.

### 4.4 Tool `_meta` (requirement 4)

```julia
register_tool!(server; …, meta=ui_tool_meta(card))
```

produces

```json
{
  "ui": { "resourceUri": "ui://acme/report-card", "visibility": ["model", "app"] },
  "ui/resourceUri": "ui://acme/report-card"
}
```

The uri is deliberately **dual-written**: host builds in the wild disagree on
whether they read the nested or the flat key. Writing both is harmless and makes
the tool render everywhere.

`visibility` controls exposure: `"model"` lets the LLM call the tool, `"app"`
lets the widget call it via `tools/call`. For actions that only make sense from
inside a widget (e.g. a "validate this selection" button), register an app-only
tool with `ui_tool_meta(card; visibility=["app"])` so the model never calls it.

### 4.5 Tool results: embed + structuredContent (requirement 5)

```julia
MCPToolResult(
    content=ui_tool_content("Readable text summary", card),  # text + embedded widget
    structured_content=data,                                  # the widget's render data
)
```

Two independent things happen here:

1. **Embedding.** `ui_tool_content` appends
   `{"type": "resource", "resource": {"uri", "mimeType", "text"}}` — a full
   inline copy of the widget HTML — after the text content. Cursor renders this
   embedded copy and does **not** reliably fetch the registered resource via
   `resources/read`. Register the resource *and* embed it; other hosts use the
   registration, Cursor uses the embed.
2. **Render data.** The host feeds the result's `structuredContent` to the
   widget (via the `ui/initialize` response and/or a
   `ui/notifications/tool-result` message). `content` text is for humans/the
   model; `structuredContent` is for the widget. A missing `structuredContent`
   yields a rendered-but-empty widget.

Skip the embed for outcomes that shouldn't render a widget (e.g. "not found"):
`ui_tool_content(text, card; embed=false)`.

### 4.6 The widget-side handshake (requirement 6)

The wire sequence the widget must perform (all messages are JSON-RPC 2.0 over
`window.parent.postMessage(msg, "*")`):

```
widget → host   {"jsonrpc":"2.0","id":1,"method":"ui/initialize",
                 "params":{"protocolVersion":"2026-01-26",
                           "appInfo":{"name":"acme-report-card","version":"1.0.0"},
                           "appCapabilities":{}}}
host   → widget {"id":1,"result":{ …may include render data… }}
widget → host   {"jsonrpc":"2.0","method":"ui/notifications/initialized","params":{}}
widget → host   {"jsonrpc":"2.0","method":"ui/notifications/size-changed",
                 "params":{"width":…,"height":…}}          (initially + on every resize)
host   → widget {"jsonrpc":"2.0","method":"ui/notifications/tool-result",
                 "params":{ …structuredContent… }}          (per tool call)
```

Empirically discovered constraints, all handled by `MCP_APP_BOOTSTRAP_JS`
(injected by `mcp_app_html`):

- `ui/initialize` **must** carry `protocolVersion` + `appInfo` + `appCapabilities`.
  An earlier shape (`{"name": …, "version": …}`) left Cursor's frame inactive.
- `ui/notifications/initialized` must follow the initialize **response** —
  fire-and-forgetting it earlier is not equivalent.
- Without `ui/notifications/size-changed`, Cursor sizes the iframe to 0 height:
  the widget "renders" but looks blank. The bootstrap wires a `ResizeObserver`
  (plus load/fonts-ready hooks) so sizing is automatic and continuous.
- Only accept messages where `event.source === window.parent`, and never throw
  from the message handler.
- Render data can arrive in the `ui/initialize` **result**, in
  `ui/notifications/tool-result` `params.structuredContent`, or nested under
  `params.result.structuredContent` depending on host/version. The bootstrap
  checks all of them and replays the latest data to `onRender` callbacks that
  register late — eliminating the startup race where data arrives before the
  widget's own script has subscribed.

Widget authors only see this API:

```js
mcpApp.onRender(function (data, raw) { /* re-render; called on every update */ });
mcpApp.callTool("select-offer", {offerId: "…"}).then(r => render(r.structuredContent));
mcpApp.reportSize();      // manual nudge; automatic reporting is already on
mcpApp.ready.then(ok => …); // resolves false (not rejects) on handshake timeout
```

### 4.7 Widget HTML constraints

The iframe is sandboxed and hosts apply restrictive CSPs. Author widgets as if
**no network access exists**:

- Inline all CSS and JS (`mcp_app_html` does this by construction).
- No CDN scripts, no external stylesheets, no `fetch`/XHR to your own API — go
  through `mcpApp.callTool` instead, which the host proxies and authenticates.
- External images *may* load in some hosts; don't depend on them. Prefer data
  URIs or inline SVG. Web fonts (e.g. Google Fonts `@import`) are progressive
  enhancement only — always specify a system-font fallback stack, and expect the
  fallback to be what renders in stricter hosts.
- Support both themes cheaply: `:root{color-scheme:light dark}` (set by
  `mcp_app_html`) + `@media (prefers-color-scheme: dark)` overrides.
- Escape every interpolated value (the sample widgets use a tiny `esc()`); the
  data you render came from tool output and can contain anything.
- `mcp_app_html` rejects `</script>`/`</style>` sequences inside `script`/`css`
  — write `<\/script>` inside JS strings if you genuinely need the text.

## 5. Sessions, auth, and deployment notes

- **Streamable HTTP:** this package implements the 2025-11 transport — `POST`
  (JSON-RPC), `GET` (SSE stream), `DELETE` (session teardown) on one path. The
  `initialize` response sets an `MCP-Session-Id` header; clients echo it on every
  subsequent request. Register all three verbs (plus `OPTIONS` if you do CORS)
  when mounting into an existing HTTP router.
- **Multiple replicas:** the default session store is in-memory. Behind a load
  balancer, provide a shared `session_store` (see `MCPSessionStore`; a Redis
  implementation is straightforward) or hosts will get `session not found`
  errors mid-conversation.
- **Auth:** respond `401` with a `WWW-Authenticate: Bearer resource_metadata="…"`
  challenge for missing/invalid tokens; hosts drive the OAuth flow from that.
  Nothing about MCP Apps changes auth — but remember `tools/call` issued *by the
  widget* arrives as a normal MCP request under the host's session/token.

## 6. Verification runbook

### 6.1 Wire-level (curl) — do this before touching any host

```bash
BASE=http://127.0.0.1:8765/v1/mcp

# 1) initialize: capture the session id header, check version + capability
curl -si "$BASE" -X POST -H 'Content-Type: application/json' -d '{
  "jsonrpc":"2.0","id":1,"method":"initialize",
  "params":{"protocolVersion":"2025-06-18","capabilities":{},
            "clientInfo":{"name":"curl","version":"0"}}}' | tee /tmp/init.txt
SESSION=$(grep -i '^mcp-session-id:' /tmp/init.txt | tr -d '\r' | awk '{print $2}')

# CHECK: body .result.protocolVersion == "2025-06-18" (echoed, not overridden)
# CHECK: .result.capabilities.extensions["io.modelcontextprotocol/ui"].mimeTypes
#        == ["text/html;profile=mcp-app"]

H=(-H "Content-Type: application/json" -H "MCP-Session-Id: $SESSION" \
   -H "MCP-Protocol-Version: 2025-06-18")

# 2) tools/list — CHECK each widget tool has BOTH _meta.ui.resourceUri and _meta["ui/resourceUri"]
curl -s "$BASE" -X POST "${H[@]}" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | jq '.result.tools[] | {name, meta: ._meta}'

# 3) resources/read — CHECK mimeType and that the html contains "ui/initialize"
curl -s "$BASE" -X POST "${H[@]}" -d '{
  "jsonrpc":"2.0","id":3,"method":"resources/read",
  "params":{"uri":"ui://acme/report-card"}}' \
  | jq '.result.contents[0] | {uri, mimeType, hasHandshake: (.text | contains("ui/initialize"))}'

# 4) tools/call — CHECK content[1] is the embedded resource and structuredContent is present
curl -s "$BASE" -X POST "${H[@]}" -d '{
  "jsonrpc":"2.0","id":4,"method":"tools/call",
  "params":{"name":"report-lookup","arguments":{"id":"r-1"}}}' \
  | jq '{types: [.result.content[].type],
         embeddedUri: .result.content[1].resource.uri,
         mime: .result.content[1].resource.mimeType,
         hasStructured: (.result.structuredContent != null)}'
```

If all four checks pass, the server side is correct; any remaining problem is in
the widget HTML or the host.

### 6.2 Widget-level, without any host

Open the widget in a plain browser with a fake host — this catches handshake and
rendering bugs in seconds instead of a deploy cycle:

```html
<!-- harness.html: serve next to widget.html and open in a browser -->
<iframe id="w" src="widget.html" style="width:420px;border:1px solid #ccc"></iframe>
<script>
  const SAMPLE = { title: "Q3 revenue" };            // structuredContent fixture
  const frame = document.getElementById("w");
  window.addEventListener("message", (ev) => {
    const m = ev.data || {};
    if (m.method === "ui/initialize")
      frame.contentWindow.postMessage({ jsonrpc: "2.0", id: m.id, result: {} }, "*");
    else if (m.method === "ui/notifications/size-changed")
      frame.style.height = m.params.height + "px";
    else if (m.method === "ui/notifications/initialized")
      frame.contentWindow.postMessage({ jsonrpc: "2.0",
        method: "ui/notifications/tool-result",
        params: { structuredContent: SAMPLE } }, "*");
  });
</script>
```

A correct widget renders `SAMPLE` and the iframe grows to fit. This harness
mimics the host order of operations (init reply → initialized → tool-result).

### 6.3 In Cursor

1. Add the server to `~/.cursor/mcp.json` (or project `.cursor/mcp.json`):

   ```json
   { "mcpServers": { "acme": { "url": "http://127.0.0.1:8765/v1/mcp" } } }
   ```

2. Cursor Settings → MCP: the server should show connected with your tools
   listed. **Cursor caches `initialize` and `tools/list` aggressively** — after
   changing capabilities, tool `_meta`, or widget HTML, toggle the server off/on
   (or reload the window). Testing against a stale handshake is the #1 source of
   phantom bugs.
3. Ask the agent to call a widget-backed tool. The widget renders inline in
   chat, in place of the text content.
4. Debugging: Help → Toggle Developer Tools; widget `console.*` output and the
   postMessage traffic are visible from the iframe context (select it in the
   console's context dropdown).

Then repeat on your deployed environments (dev → stage → prod). The wire checks
in §6.1 run unchanged against deployed URLs (add your `Authorization` header).

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Tool result shows as plain text, no widget at all | Extension capability missing from `initialize` (req 2), or host cached an old handshake | `capabilities=ui_extension_capability()`; toggle the server in the host to force a fresh `initialize` |
| Still text-only, capability confirmed present | Tool `_meta` missing/wrong (req 4) — or only one of the two uri keys present | `meta=ui_tool_meta(resource)` (writes both keys); verify via §6.1 step 2 |
| Widget renders in one host but not Cursor | Resource registered but not embedded in the tool result (req 5) | Build content with `ui_tool_content(text, resource)` |
| Widget frame appears but is blank / 1px tall | No `ui/notifications/size-changed` from the widget | Use `mcp_app_html` (auto size reporting), or send size-changed after every render |
| Widget frame appears, never receives data | Handshake params wrong — `ui/initialize` without `protocolVersion`/`appInfo`/`appCapabilities`; or `initialized` notification never sent | Use the bootstrap; if hand-rolling, match §4.6 exactly |
| Widget shows its empty/placeholder state | Tool result has no `structuredContent`, or widget only listens on one delivery channel | Set `structured_content` on `MCPToolResult`; bootstrap reads init-result *and* tool-result channels |
| Renders once, never updates on subsequent calls | Widget rendered only from the init result | Subscribe via `mcpApp.onRender` (fires on every `tool-result`) |
| Random 400s from the server in Cursor | `missing_protocol_header=:error` while Cursor omits `MCP-Protocol-Version` | Set `:warn` or `:ignore` |
| Client and server disagree on protocol version | Server ignored the requested version | Set `supported_protocol_versions`; verify §6.1 step 1 echoes the requested version |
| `Session not found` after deploy/restart or behind LB | In-memory session store, multiple replicas or restart | Shared/persistent `session_store` |
| Widget's `tools/call` fails while the model's calls work | Action tool registered app-only… or not; visibility mismatch | Check `visibility` in `ui_tool_meta`; app-called tools need `"app"` in the list |
| Fonts/images missing in the rendered widget | Host CSP blocks external requests | Treat external assets as progressive enhancement; inline or use system fallbacks (§4.7) |
| Widget renders garbage/XSS-y content | Unescaped interpolation of tool data | Escape everything (`esc()` pattern) |

## 8. Porting checklist for a new application

Adding MCP Apps to a fresh server, in order — with §6 verification after each
group:

1. Depend on this package; create the `MCPServer` with
   `capabilities=ui_extension_capability()`, `missing_protocol_header=:warn`,
   and (if you must serve older clients) `supported_protocol_versions`.
2. Mount the transport: `serve_mcp_http`, or register `POST`/`GET`/`DELETE`
   handlers (`handle_jsonrpc_request` / `handle_stream_request` /
   `handle_session_delete`) on your existing router.
3. Author the widget: `mcp_app_html(app_name=…, body=…, css=…, script=…)` with a
   `mcpApp.onRender` entry point. Verify standalone with the §6.2 harness.
4. Register it: `card = register_ui_resource!(server; uri="ui://<app>/<widget>", html=…)`.
5. Tag tools: `meta=ui_tool_meta(card)` (use `visibility=["app"]` for
   widget-only action tools).
6. Return widget-backed results:
   `MCPToolResult(content=ui_tool_content(summary, card), structured_content=data)`.
7. Run the §6.1 curl checks. All four must pass.
8. Connect a real host (§6.3), remembering to force a handshake refresh.
9. If deploying multi-replica: shared session store. If authing: 401 challenge.
10. Keep the widget uri stable forever after.
