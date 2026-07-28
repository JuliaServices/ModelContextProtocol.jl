module ModelContextProtocol

using Base64
using HTTP
using JSON
using UUIDs

include("types.jl")
include("errors.jl")
include("util.jl")
include("discovery.jl")
include("auth.jl")
include("jsonrpc.jl")
include("server.jl")
include("static_server.jl")
include("client.jl")
include("apps.jl")

export MCPError, MCPAuthenticationRequired
export MCPTransportDescriptor, MCPDiscovery
export MCPClient, MCPClientConfig, MCPAuthenticationChallenge
export MCPServer, MCPServerConfig, MCPSessionStore, InMemorySessionStore
export MCPServerTool, MCPToolResult, MCPTextContent
export MCPServerPrompt, MCPServerResource
export MCPRequestContext, MCPHTTPServer
export discover_server, prepare_manual_client, attach_token!
export start_public_client_flow, request_client_credentials_token
export initialize_client!, list_tools, list_prompts, list_resources, list_resource_templates
export call_tool, get_prompt, read_resource, get_resource, subscribe_resource
export unsubscribe_resource, ping
export set_log_level!, completion_complete
export register_tool!, register_tools!, register_prompt!, register_resource!, register_resource_template!
export serve_mcp_http, stop_mcp_server, base_url, set_request_hook!, clear_request_hook!
export set_cancellation_handler!, clear_cancellation_handler!
export set_logging_handler!, clear_logging_handler!, log_message!
export set_completion_handler!, clear_completion_handler!
export send_initialized_notification!, cancel_request, open_event_stream
export register_notification_handler!, clear_notification_handlers!
export register_request_handler!, clear_request_handlers!
export start_event_listener!, stop_event_listener!
export terminate_session!
export enqueue_server_event!, broadcast_server_event!, notify_resource_updated!
export PROTOCOL_VERSION_2026_07_28, MCPInputRequired
export input_responses, request_state, send_progress!, send_log!
export close_subscription_listeners!, discover_server_info!, listen_subscriptions!, is_input_required
export MCP_APPS_EXTENSION_ID, MCP_APP_HTML_MIME_TYPE, MCP_APPS_UI_PROTOCOL_VERSION
export MCPUIResource, ui_extension_capability, add_ui_extension_capability!
export ui_tool_meta, ui_resource_meta, ui_resource_contents, embedded_ui_resource
export ui_tool_content, register_ui_resource!, mcp_app_html, MCP_APP_BOOTSTRAP_JS

end
