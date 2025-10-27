normalize_pair(name, value) = String(name) => String(value)

function normalize_headers(headers)
    headers === nothing && return HeaderPair[]
    if headers isa HeaderPair
        return HeaderPair[normalize_pair(headers.first, headers.second)]
    elseif headers isa AbstractVector
        normalized = HeaderPair[]
        for item in headers
            if item isa Pair
                push!(normalized, normalize_pair(item.first, item.second))
            elseif item isa Tuple && length(item) == 2
                push!(normalized, normalize_pair(item[1], item[2]))
            else
                throw(ArgumentError("Unsupported header entry $(item)"))
            end
        end
        return normalized
    elseif headers isa AbstractDict
        return HeaderPair[normalize_pair(k, v) for (k, v) in headers]
    elseif headers isa HTTP.Headers
        return HeaderPair[normalize_pair(k, v) for (k, v) in headers]
    else
        throw(ArgumentError("Unsupported headers container: $(typeof(headers))"))
    end
end

build_headers(headers::Vector{HeaderPair}) = HTTP.Headers(headers)

function merge_headers(base::HTTP.Headers, additions::Vector{HeaderPair})
    isempty(additions) && return base
    merged = HTTP.Headers(base)
    for (name, value) in additions
        HTTP.setheader(merged, name => value)
    end
    return merged
end

function ensure_http_url(url::AbstractString, label::AbstractString)
    uri = HTTP.URI(String(url))
    scheme = uri.scheme === nothing ? "" : lowercase(String(uri.scheme))
    scheme in ("http", "https") || throw(mcp_error(:invalid_uri, "$(label) must be http or https (got $(url))"))
    uri.host === nothing && throw(mcp_error(:invalid_uri, "$(label) must be absolute (missing host)"))
    return String(url)
end

function absolute_url(base::AbstractString, target::AbstractString)
    uri = HTTP.URI(String(target))
    scheme = uri.scheme === nothing ? "" : String(uri.scheme)
    if isempty(scheme)
        base_uri = HTTP.URI(String(base))
        rel_path = uri.path === nothing ? "" : String(uri.path)
        base_path = base_uri.path === nothing ? "/" : String(base_uri.path)
        path = if isempty(rel_path)
            base_path
        elseif startswith(rel_path, "/")
            rel_path
        else
            base_dir = endswith(base_path, "/") ? base_path : string(dirname(base_path), "/")
            string(base_dir, rel_path)
        end
        new_uri = HTTP.URI(
            scheme = base_uri.scheme,
            host = base_uri.host,
            port = base_uri.port,
            path = path,
            query = uri.query,
            fragment = uri.fragment,
        )
        return string(new_uri)
    end
    return String(target)
end

maybe_string(value) = value === nothing ? nothing : String(value)

function collect_strings(xs)
    xs isa AbstractVector || return String[]
    strings = String[]
    for item in xs
        item isa AbstractString && push!(strings, String(item))
    end
    return strings
end

function to_json_dict(data)
    result = JSONDict()
    data isa AbstractDict || return result
    for (k, v) in data
        result[String(k)] = v
    end
    return result
end

function to_string_dict(data)
    data === nothing && return Dict{String,Any}()
    data isa AbstractDict || throw(ArgumentError("Expected dictionary, got $(typeof(data))"))
    result = Dict{String,Any}()
    for (k, v) in data
        result[String(k)] = v
    end
    return result
end

function is_absolute_http_url(url::AbstractString)
    uri = HTTP.URI(String(url))
    scheme = uri.scheme === nothing ? "" : lowercase(String(uri.scheme))
    return scheme in ("http", "https")
end

function split_scopes(value)
    value === nothing && return String[]
    scope_str = String(value)
    isempty(scope_str) && return String[]
    parts = split(scope_str)
    return String[p for p in parts if !isempty(p)]
end

function extract_auth_challenges(headers::HTTP.Headers)
    challenges = MCPAuthenticationChallenge[]
    for (name, value) in headers
        lowercase(String(name)) == "www-authenticate" || continue
        parsed = parse_www_authenticate(String(value))
        for ch in parsed
            metadata = get(ch.params, "resource_metadata", nothing)
            scopes = split_scopes(get(ch.params, "scope", nothing))
            push!(challenges, MCPAuthenticationChallenge(challenge=ch, resource_metadata=metadata, scopes=scopes))
        end
    end
    return challenges
end

function headers_to_pairs(headers)
    pairs = Pair{String,String}[]
    for (name, value) in headers
        push!(pairs, String(name) => String(value))
    end
    return pairs
end
