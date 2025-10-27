module ModelContextProtocol

using HTTP
using JSON
using OAuth

include("types.jl")
include("errors.jl")
include("util.jl")
include("discovery.jl")
include("auth.jl")
include("jsonrpc.jl")
include("server.jl")
include("client.jl")

export MCPError, MCPAuthenticationRequired
export MCPTransportDescriptor, MCPDiscovery
export MCPClient, MCPClientConfig, MCPAuthenticationChallenge
export MCPServer, MCPServerConfig, MCPServerTool, MCPServerPrompt, MCPServerResource
export MCPRequestContext, MCPHTTPServer
export discover_server, prepare_manual_client, attach_token!
export start_public_client_flow, request_client_credentials_token
export initialize_client!, list_tools, list_prompts, list_resources, list_resource_templates
export call_tool, get_prompt, read_resource, get_resource, subscribe_resource
export set_log_level!, completion_complete
export register_tool!, register_prompt!, register_resource!, register_resource_template!
export serve_mcp_http, stop_mcp_server, base_url, set_request_hook!, clear_request_hook!
export set_cancellation_handler!, clear_cancellation_handler!
export set_logging_handler!, clear_logging_handler!, log_message!
export set_completion_handler!, clear_completion_handler!
export send_initialized_notification!, cancel_request, open_event_stream
export register_notification_handler!, clear_notification_handlers!
export start_event_listener!, stop_event_listener!
export enqueue_server_event!, broadcast_server_event!, notify_resource_updated!

end
