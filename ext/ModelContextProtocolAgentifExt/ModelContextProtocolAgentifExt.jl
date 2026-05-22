module ModelContextProtocolAgentifExt

using Agentif
using JSON
using ModelContextProtocol

const MCP = ModelContextProtocol

function json_schema_for_type(::Type{T}) where {T}
    T === Any && return Dict{String,Any}()
    T === Nothing && return Dict{String,Any}("type" => "null")
    if is_union_with_nothing(T)
        inner = non_nothing_type(T)
        return Dict{String,Any}("anyOf" => [json_schema_for_type(inner), Dict{String,Any}("type" => "null")])
    elseif T <: Bool
        return Dict{String,Any}("type" => "boolean")
    elseif T <: AbstractString
        return Dict{String,Any}("type" => "string")
    elseif T <: Integer
        return Dict{String,Any}("type" => "integer")
    elseif T <: Real
        return Dict{String,Any}("type" => "number")
    elseif T <: AbstractVector
        return Dict{String,Any}(
            "type" => "array",
            "items" => json_schema_for_type(eltype(T)),
        )
    elseif T <: Tuple
        return Dict{String,Any}("type" => "array")
    elseif T <: NamedTuple
        return agentif_parameters_schema(T)
    elseif T <: AbstractDict
        return Dict{String,Any}("type" => "object")
    else
        return Dict{String,Any}("description" => string("Julia value of type ", T))
    end
end

function is_union_with_nothing(::Type{T}) where {T}
    T isa Union || return false
    return any(==(Nothing), Base.uniontypes(T))
end

function non_nothing_type(::Type{T}) where {T}
    types = filter(!=(Nothing), Base.uniontypes(T))
    isempty(types) && return Any
    length(types) == 1 && return only(types)
    return Union{types...}
end

function agentif_parameters_schema(::Type{T}; strict::Bool=true) where {T<:NamedTuple}
    properties = Dict{String,Any}()
    required = String[]
    for (name, field_type) in zip(fieldnames(T), fieldtypes(T))
        field_name = String(name)
        properties[field_name] = json_schema_for_type(field_type)
        is_union_with_nothing(field_type) || push!(required, field_name)
    end
    schema = Dict{String,Any}(
        "type" => "object",
        "properties" => properties,
    )
    isempty(required) || (schema["required"] = required)
    strict && (schema["additionalProperties"] = false)
    return schema
end

function agentif_arguments(::Type{T}, args::Dict{String,Any}; strict::Bool=true) where {T<:NamedTuple}
    names = fieldnames(T)
    field_types = fieldtypes(T)
    if strict
        allowed = Set(String.(names))
        extras = sort([String(key) for key in keys(args) if !(String(key) in allowed)])
        isempty(extras) || throw(MCP.mcp_error(:invalid_params, string("Unexpected tool argument(s): ", join(extras, ", "))))
    end
    values = Any[]
    for (name, field_type) in zip(names, field_types)
        key = String(name)
        if haskey(args, key)
            push!(values, args[key])
        elseif is_union_with_nothing(field_type)
            push!(values, nothing)
        else
            throw(MCP.mcp_error(:invalid_params, string("Missing required tool argument: ", key)))
        end
    end
    raw = NamedTuple{names}(Tuple(values))
    try
        return convert(T, raw)
    catch err
        throw(MCP.mcp_error(:invalid_params, sprint(showerror, err)))
    end
end

function text_content(text)
    return Dict{String,Any}("type" => "text", "text" => string(text))
end

function to_string_dict(data::AbstractDict)
    return Dict{String,Any}(String(k) => v for (k, v) in data)
end

function normalize_agentif_result(result)
    if result isa AbstractDict
        data = to_string_dict(result)
        if haskey(data, "content") || haskey(data, "structuredContent") || haskey(data, "outputs")
            return data
        else
            return Dict{String,Any}(
                "content" => [text_content(JSON.json(data))],
                "structuredContent" => data,
            )
        end
    elseif result isa AbstractVector
        return Dict{String,Any}("content" => result)
    elseif result === nothing
        return Dict{String,Any}("content" => [text_content("")])
    else
        return Dict{String,Any}("content" => [text_content(result)])
    end
end

function MCP.register_tool!(
    server::MCP.MCPServer,
    tool::Agentif.AgentTool;
    name=tool.name,
    title=nothing,
    description=tool.description,
    input_schema=nothing,
    output_schema=nothing,
    execution=Dict{String,Any}(),
    icons=Dict{String,Any}[],
    annotations=Dict{String,Any}(),
    meta=Dict{String,Any}(),
    metadata=nothing,
)
    parameter_type = Agentif.parameters(tool)
    schema = input_schema === nothing ? agentif_parameters_schema(parameter_type; strict=tool.strict) : input_schema
    handler = function (_context::MCP.MCPRequestContext, args::Dict{String,Any})
        parsed = agentif_arguments(parameter_type, args; strict=tool.strict)
        return normalize_agentif_result(tool.func(parsed...))
    end
    return MCP.register_tool!(
        server;
        name=name,
        title=title,
        description=description,
        input_schema=schema,
        output_schema=output_schema,
        execution=execution,
        icons=icons,
        annotations=annotations,
        meta=meta,
        metadata=metadata,
        handler=handler,
    )
end

end
