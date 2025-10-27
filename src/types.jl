const JSONDict = Dict{String,Any}
const HeaderPair = Pair{String,String}

const DEFAULT_PROTOCOL_VERSION = "2025-06-18"
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

Base.@kwdef struct MCPServerConfig
    name::String
    version::String
    description::Union{String,Nothing}=nothing
    description_for_model::Union{String,Nothing}=nothing
    instructions::Union{String,Nothing}=nothing
    instructions_url::Union{String,Nothing}=nothing
    protocol_version::String=DEFAULT_PROTOCOL_VERSION
    missing_protocol_header::Symbol=:warn
    transport_path::String="/v1/mcp"
    manifest_paths::Vector{String}=String[DEFAULT_MANIFEST_PATHS...]
    capabilities::Dict{String,Any}=Dict{String,Any}()
    server_info::Dict{String,Any}=Dict{String,Any}()
    manifest::Dict{String,Any}=Dict{String,Any}()
    transport_metadata::Dict{String,Any}=Dict{String,Any}()
    verbose::Bool=false
end

Base.@kwdef mutable struct MCPSession
    id::String
    initialized::Bool=false
    event_sequence::Int=0
    pending_events::Vector{MCPEvent}=MCPEvent[]
    subscriptions::Set{String}=Set{String}()
end

Base.@kwdef struct MCPServerTool
    name::String
    handler::Function
    title::Union{String,Nothing}=nothing
    description::Union{String,Nothing}=nothing
    input_schema::Union{Dict{String,Any},Nothing}=nothing
    output_schema::Union{Dict{String,Any},Nothing}=nothing
    annotations::Dict{String,Any}=Dict{String,Any}()
end

Base.@kwdef struct MCPServerPrompt
    name::String
    handler::Function
    description::Union{String,Nothing}=nothing
    annotations::Dict{String,Any}=Dict{String,Any}()
end

Base.@kwdef struct MCPServerResource
    uri::String
    handler::Function
    title::Union{String,Nothing}=nothing
    description::Union{String,Nothing}=nothing
    mime_type::Union{String,Nothing}=nothing
    size::Union{Int,Nothing}=nothing
    annotations::Dict{String,Any}=Dict{String,Any}()
end

Base.@kwdef struct MCPServerResourceTemplate
    name::String
    handler::Function
    description::Union{String,Nothing}=nothing
    annotations::Dict{String,Any}=Dict{String,Any}()
    input_schema::Union{Dict{String,Any},Nothing}=nothing
end

struct MCPClientConfig
    transport::Union{MCPTransportDescriptor,Symbol,Nothing}
    protocol_version::String
    headers::Vector{HeaderPair}
    http::Module
    timeout::NamedTuple
    verbose::Bool
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
    auth_token::Union{TokenResponse,Nothing}
    session::Union{JSONDict,Nothing}
    session_id::Union{String,Nothing}
    initialized::Bool
    next_id::Base.RefValue{Int}
    notification_handlers::Dict{String,Vector{Function}}
    event_task::Union{Task,Nothing}
    last_event_id::Union{String,Nothing}
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
    request_hook::Union{Function,Nothing}
    cancellation_handler::Union{Function,Nothing}
    logging_handler::Union{Function,Nothing}
    logging_level::String
    missing_protocol_header_behavior::Symbol
    completion_handler::Union{Function,Nothing}
end
