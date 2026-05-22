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
