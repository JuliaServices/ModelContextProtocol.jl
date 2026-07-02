# API

## Server Types

- `MCPServerConfig`
- `MCPServer`
- `MCPRequestContext`
- `MCPHTTPServer`
- `MCPServerTool`
- `MCPServerPrompt`
- `MCPServerResource`

## Server Functions

- `register_tool!`
- `register_prompt!`
- `register_resource!`
- `register_resource_template!`
- `serve_mcp_http`
- `stop_mcp_server`
- `base_url`
- `set_request_hook!`
- `set_cancellation_handler!`
- `set_logging_handler!`
- `set_completion_handler!`
- `log_message!`
- `enqueue_server_event!`
- `broadcast_server_event!`
- `notify_resource_updated!`

## MCP Apps (SEP-1865)

Helpers for serving interactive HTML widgets that hosts render inline. See
[MCP-App-playbook.md](https://github.com/JuliaServices/ModelContextProtocol.jl/blob/main/MCP-App-playbook.md)
for the full guide.

- `MCP_APPS_EXTENSION_ID`
- `MCP_APP_HTML_MIME_TYPE`
- `MCP_APPS_UI_PROTOCOL_VERSION`
- `MCPUIResource`
- `ui_extension_capability`
- `add_ui_extension_capability!`
- `ui_tool_meta`
- `ui_resource_meta`
- `ui_resource_contents`
- `embedded_ui_resource`
- `ui_tool_content`
- `register_ui_resource!`
- `mcp_app_html`
- `MCP_APP_BOOTSTRAP_JS`

## Client Types

- `MCPDiscovery`
- `MCPTransportDescriptor`
- `MCPClientConfig`
- `MCPClient`
- `MCPAuthenticationRequired`
- `MCPAuthenticationChallenge`

## Client Functions

- `discover_server`
- `prepare_manual_client`
- `attach_token!`
- `initialize_client!`
- `list_tools`
- `call_tool`
- `list_prompts`
- `get_prompt`
- `list_resources`
- `read_resource`
- `list_resource_templates`
- `subscribe_resource`
- `unsubscribe_resource`
- `completion_complete`
- `set_log_level!`
- `ping`
- `open_event_stream`
- `register_request_handler!`
- `clear_request_handlers!`
- `start_event_listener!`
- `stop_event_listener!`
- `terminate_session!`
