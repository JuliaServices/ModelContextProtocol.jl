const JSONDict = Dict{String,Any}
const HeaderPair = Pair{String,String}

const DEFAULT_PROTOCOL_VERSION = "2025-11-25"
const PROTOCOL_VERSION_2026_07_28 = "2026-07-28"

# Protocol versions are ISO dates, so lexicographic comparison is chronological.
is_modern_protocol_version(version::AbstractString) = String(version) >= PROTOCOL_VERSION_2026_07_28

const META_PROTOCOL_VERSION = "io.modelcontextprotocol/protocolVersion"
const META_CLIENT_INFO = "io.modelcontextprotocol/clientInfo"
const META_CLIENT_CAPABILITIES = "io.modelcontextprotocol/clientCapabilities"
const META_SERVER_INFO = "io.modelcontextprotocol/serverInfo"
const META_LOG_LEVEL = "io.modelcontextprotocol/logLevel"
const META_SUBSCRIPTION_ID = "io.modelcontextprotocol/subscriptionId"
const DEFAULT_MANIFEST_PATHS = (
    "/.well-known/ai-plugin.json",
    "/.well-known/mcp.json",
    "/.well-known/model-context-protocol",
)

Base.@kwdef struct MCPTransportDescriptor
    kind::Symbol
    url::String
    protocol::Union{String,Nothing}=nothing
    version::Union{String,Nothing}=nothing
    serialization::Union{String,Nothing}=nothing
    capabilities::Vector{String}=String[]
    raw::Union{JSONDict,Nothing}=nothing
end

Base.@kwdef struct MCPDiscovery
    manifest::JSONDict
    transports::Vector{MCPTransportDescriptor}
    default_transport::Union{MCPTransportDescriptor,Nothing}
end

Base.@kwdef struct MCPEvent
    id::String
    event::Union{String,Nothing}
    data::String
end

abstract type MCPSessionStore end

Base.@kwdef struct MCPServerConfig
    name::String
    version::String
    description::Union{String,Nothing}=nothing
    description_for_model::Union{String,Nothing}=nothing
    instructions::Union{String,Nothing}=nothing
    instructions_url::Union{String,Nothing}=nothing
    protocol_version::String=DEFAULT_PROTOCOL_VERSION
    supported_protocol_versions::Vector{String}=String[PROTOCOL_VERSION_2026_07_28]
    missing_protocol_header::Symbol=:error
    cache_ttl_ms::Int=60_000
    cache_scope::String="private"
    allowed_origins::Union{Nothing,Vector{String}}=nothing
    transport_path::String="/v1/mcp"
    manifest_paths::Vector{String}=String[DEFAULT_MANIFEST_PATHS...]
    capabilities::Dict{String,Any}=Dict{String,Any}()
    server_info::Dict{String,Any}=Dict{String,Any}()
    manifest::Dict{String,Any}=Dict{String,Any}()
    transport_metadata::Dict{String,Any}=Dict{String,Any}()
    session_store::Union{MCPSessionStore,Nothing}=nothing
    verbose::Bool=false
end

# Preserve the positional constructor from 1.0.0 after adding modern cache
# configuration fields. New code should use keyword construction.
function MCPServerConfig(
    name,
    version,
    description,
    description_for_model,
    instructions,
    instructions_url,
    protocol_version,
    supported_protocol_versions,
    missing_protocol_header,
    allowed_origins,
    transport_path,
    manifest_paths,
    capabilities,
    server_info,
    manifest,
    transport_metadata,
    session_store,
    verbose,
)
    return MCPServerConfig(
        name,
        version,
        description,
        description_for_model,
        instructions,
        instructions_url,
        protocol_version,
        supported_protocol_versions,
        missing_protocol_header,
        60_000,
        "private",
        allowed_origins,
        transport_path,
        manifest_paths,
        capabilities,
        server_info,
        manifest,
        transport_metadata,
        session_store,
        verbose,
    )
end

Base.@kwdef mutable struct MCPSession
    id::String
    initialized::Bool=false
    event_sequence::Int=0
    pending_events::Vector{MCPEvent}=MCPEvent[]
    subscriptions::Set{String}=Set{String}()
    client_info::Dict{String,Any}=Dict{String,Any}()
    client_capabilities::Dict{String,Any}=Dict{String,Any}()
end

function MCPSession(
    id::String,
    initialized::Bool,
    event_sequence::Int,
    pending_events::Vector{MCPEvent},
    subscriptions::Set{String},
)
    return MCPSession(
        id,
        initialized,
        event_sequence,
        pending_events,
        subscriptions,
        Dict{String,Any}(),
        Dict{String,Any}(),
    )
end

Base.@kwdef mutable struct InMemorySessionStore <: MCPSessionStore
    sessions::Dict{String,MCPSession}=Dict{String,MCPSession}()
    lock::ReentrantLock=ReentrantLock()
end

Base.@kwdef struct MCPServerTool
    name::String
    handler::Function
    title::Union{String,Nothing}=nothing
    description::Union{String,Nothing}=nothing
    input_schema::Union{Dict{String,Any},Nothing}=nothing
    output_schema::Union{Dict{String,Any},Nothing}=nothing
    execution::Dict{String,Any}=Dict{String,Any}()
    icons::Vector{Dict{String,Any}}=Dict{String,Any}[]
    annotations::Dict{String,Any}=Dict{String,Any}()
    meta::Dict{String,Any}=Dict{String,Any}()
    required_client_capabilities::Dict{String,Any}=Dict{String,Any}()
end

# Preserve the positional constructor from 1.0.0.
MCPServerTool(name, handler, title, description, input_schema, output_schema, execution, icons, annotations, meta) =
    MCPServerTool(name, handler, title, description, input_schema, output_schema, execution, icons, annotations, meta, Dict{String,Any}())

Base.@kwdef struct MCPTextContent
    text::String
    annotations::Dict{String,Any}=Dict{String,Any}()
    meta::Dict{String,Any}=Dict{String,Any}()
end

"""
    MCPInputRequired(; input_requests=Dict(), request_state=nothing)

Return this from a `2026-07-28` tool, prompt, or resource handler when the
request needs a client sampling, roots, or elicitation operation. The client
retries the original request with `inputResponses` and the optional opaque
`requestState` value.
"""
Base.@kwdef struct MCPInputRequired
    input_requests::Dict{String,Any}=Dict{String,Any}()
    request_state::Union{String,Nothing}=nothing
end

Base.@kwdef struct MCPToolResult
    content::Vector{Any}=Any[]
    structured_content=nothing
    is_error::Union{Bool,Nothing}=nothing
    annotations::Dict{String,Any}=Dict{String,Any}()
    meta::Dict{String,Any}=Dict{String,Any}()
    output_schema=nothing
    next_cursor::Union{String,Nothing}=nothing
end

Base.@kwdef struct MCPServerPrompt
    name::String
    handler::Function
    title::Union{String,Nothing}=nothing
    description::Union{String,Nothing}=nothing
    arguments::Vector{Dict{String,Any}}=Dict{String,Any}[]
    icons::Vector{Dict{String,Any}}=Dict{String,Any}[]
    annotations::Dict{String,Any}=Dict{String,Any}()
    meta::Dict{String,Any}=Dict{String,Any}()
end

Base.@kwdef struct MCPServerResource
    uri::String
    handler::Function
    name::Union{String,Nothing}=nothing
    title::Union{String,Nothing}=nothing
    description::Union{String,Nothing}=nothing
    mime_type::Union{String,Nothing}=nothing
    size::Union{Int,Nothing}=nothing
    icons::Vector{Dict{String,Any}}=Dict{String,Any}[]
    annotations::Dict{String,Any}=Dict{String,Any}()
    meta::Dict{String,Any}=Dict{String,Any}()
end

Base.@kwdef struct MCPServerResourceTemplate
    name::String
    handler::Function
    uri_template::Union{String,Nothing}=nothing
    title::Union{String,Nothing}=nothing
    description::Union{String,Nothing}=nothing
    mime_type::Union{String,Nothing}=nothing
    icons::Vector{Dict{String,Any}}=Dict{String,Any}[]
    annotations::Dict{String,Any}=Dict{String,Any}()
    input_schema::Union{Dict{String,Any},Nothing}=nothing
    meta::Dict{String,Any}=Dict{String,Any}()
end

struct MCPClientConfig
    transport::Union{MCPTransportDescriptor,Symbol,Nothing}
    protocol_version::String
    headers::Vector{HeaderPair}
    http::Module
    timeout::NamedTuple
    verbose::Bool
end

Base.@kwdef struct WWWAuthenticateChallenge
    scheme::String
    token::Union{String,Nothing}
    params::Dict{String,String}
end

function WWWAuthenticateChallenge(scheme::AbstractString; token=nothing, params=Dict{String,String}())
    return WWWAuthenticateChallenge(
        scheme=String(scheme),
        token=token === nothing ? nothing : String(token),
        params=Dict{String,String}(params),
    )
end

Base.@kwdef struct MCPAuthenticationChallenge
    challenge::WWWAuthenticateChallenge
    resource_metadata::Union{String,Nothing}
    scopes::Vector{String}
end

mutable struct MCPClient
    manifest::JSONDict
    transport::MCPTransportDescriptor
    protocol_version::String
    http::Module
    headers::HTTP.Headers
    timeout::NamedTuple
    verbose::Bool
    capabilities::Dict{String,Any}
    client_info::Dict{String,Any}
    auth_token::Union{String,Nothing}
    session::Union{JSONDict,Nothing}
    session_id::Union{String,Nothing}
    initialized::Bool
    next_id::Base.RefValue{Int}
    notification_handlers::Dict{String,Vector{Function}}
    request_handlers::Dict{String,Function}
    event_task::Union{Task,Nothing}
    last_event_id::Union{String,Nothing}
    tool_schemas::Dict{String,Dict{String,Any}}
end

# Preserve the public positional client constructors that predate modern
# request metadata and the internal tool-schema cache.
MCPClient(manifest, transport, protocol_version, http, headers, timeout, verbose, auth_token, session, session_id, initialized, next_id, notification_handlers, request_handlers, event_task, last_event_id) =
    MCPClient(manifest, transport, protocol_version, http, headers, timeout, verbose, Dict{String,Any}(), Dict{String,Any}(), auth_token, session, session_id, initialized, next_id, notification_handlers, request_handlers, event_task, last_event_id, Dict{String,Dict{String,Any}}())

MCPClient(manifest, transport, protocol_version, http, headers, timeout, verbose, capabilities, client_info, auth_token, session, session_id, initialized, next_id, notification_handlers, request_handlers, event_task, last_event_id) =
    MCPClient(manifest, transport, protocol_version, http, headers, timeout, verbose, capabilities, client_info, auth_token, session, session_id, initialized, next_id, notification_handlers, request_handlers, event_task, last_event_id, Dict{String,Dict{String,Any}}())

# A live subscriptions/listen stream (2026-07-28): notifications matching the
# opted-in filter are pushed onto the channel by the server broadcast helpers.
struct MCPSubscriptionListener
    id::Any
    tools::Bool
    prompts::Bool
    resources::Bool
    resource_uris::Set{String}
    channel::Channel{Dict{String,Any}}
end

mutable struct MCPServer
    config::MCPServerConfig
    transport_path::String
    capabilities::Dict{String,Any}
    server_info::Dict{String,Any}
    tools::Dict{String,MCPServerTool}
    prompts::Dict{String,MCPServerPrompt}
    resources::Dict{String,MCPServerResource}
    resource_templates::Dict{String,MCPServerResourceTemplate}
    sessions::Dict{String,MCPSession}
    session_store::MCPSessionStore
    request_hook::Union{Function,Nothing}
    cancellation_handler::Union{Function,Nothing}
    logging_handler::Union{Function,Nothing}
    logging_level::String
    missing_protocol_header_behavior::Symbol
    completion_handler::Union{Function,Nothing}
    listeners::Vector{MCPSubscriptionListener}
    listeners_lock::ReentrantLock
end

# Preserve the positional server constructor from 1.0.0.
MCPServer(config, transport_path, capabilities, server_info, tools, prompts, resources, resource_templates, sessions, session_store, request_hook, cancellation_handler, logging_handler, logging_level, missing_protocol_header_behavior, completion_handler) =
    MCPServer(config, transport_path, capabilities, server_info, tools, prompts, resources, resource_templates, sessions, session_store, request_hook, cancellation_handler, logging_handler, logging_level, missing_protocol_header_behavior, completion_handler, MCPSubscriptionListener[], ReentrantLock())
