struct MCPError <: Exception
    code::Symbol
    message::String
end

Base.showerror(io::IO, err::MCPError) = print(io, "MCPError($(err.code)): $(err.message)")

struct MCPAuthenticationRequired <: Exception
    status::Int
    challenges::Vector{MCPAuthenticationChallenge}
    body::Union{String,Nothing}
end

struct MCPMissingRequiredClientCapability <: Exception
    required::Dict{String,Any}
end

"A protocol error with structured data and a safe, server-generated message."
struct MCPEventError <: Exception
    code::Int
    message::String
    data::JSONDict
end

Base.showerror(io::IO, err::MCPEventError) = print(io, err.message)

Base.showerror(io::IO, err::MCPMissingRequiredClientCapability) =
    print(io, "Missing required client capabilities: ", join(sort!(collect(keys(err.required))), ", "))

Base.showerror(io::IO, err::MCPAuthenticationRequired) = begin
    print(io, "MCPAuthenticationRequired(status=$(err.status))")
    isempty(err.challenges) || print(io, " challenges=$(err.challenges)")
end

mcp_error(code::Symbol, msg) = MCPError(code, String(msg))
