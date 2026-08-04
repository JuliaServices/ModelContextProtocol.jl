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

Base.showerror(io::IO, err::MCPMissingRequiredClientCapability) =
    print(io, "Missing required client capabilities: ", join(sort!(collect(keys(err.required))), ", "))

Base.showerror(io::IO, err::MCPAuthenticationRequired) = begin
    print(io, "MCPAuthenticationRequired(status=$(err.status))")
    isempty(err.challenges) || print(io, " challenges=$(err.challenges)")
end

mcp_error(code::Symbol, msg) = MCPError(code, String(msg))
