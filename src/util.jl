normalize_pair(name, value) = String(name) => String(value)
header_tuple(pair::Pair) = (String(pair.first), String(pair.second))
header_tuple(pair::Tuple) = (String(pair[1]), String(pair[2]))

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

function build_headers(headers::AbstractVector)
    tuples = header_tuple.(headers)
    try
        return HTTP.Headers(tuples)
    catch err
        err isa MethodError || rethrow()
        return HTTP.Headers(headers)
    end
end

function set_header!(headers::HTTP.Headers, name::AbstractString, value::AbstractString)
    entry = (String(name), String(value))
    try
        HTTP.setheader(headers, entry)
    catch err
        err isa MethodError || rethrow()
        HTTP.setheader(headers, entry[1] => entry[2])
    end
    return headers
end

function http_header_value(headers, name::AbstractString, default=nothing)
    sentinel = gensym()
    value = HTTP.header(headers, name, sentinel)
    value === sentinel || return value
    for header in headers
        key, val = header_tuple(header)
        if lowercase(key) == lowercase(String(name))
            return val
        end
    end
    return default
end

function merge_headers(base::HTTP.Headers, additions::Vector{HeaderPair})
    isempty(additions) && return base
    merged = build_headers(normalize_headers(base))
    for (name, value) in additions
        set_header!(merged, name, value)
    end
    return merged
end

function transport_timeout_kwargs(timeout::NamedTuple)
    kwargs = Pair{Symbol,Any}[]
    for (key, value) in Base.pairs(timeout)
        normalized_key = if !isdefined(HTTP, :Servers) && key == :connecttimeout
            :connect_timeout
        elseif !isdefined(HTTP, :Servers) && key == :readtimeout
            :read_idle_timeout
        else
            key
        end
        push!(kwargs, normalized_key => value)
    end
    return (; kwargs...)
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

function parse_www_authenticate(header::AbstractString)
    challenges = WWWAuthenticateChallenge[]
    idx = firstindex(header)
    stop = lastindex(header)
    while true
        idx = skip_delimiters(header, idx, stop)
        idx > stop && break
        scheme, idx = read_token(header, idx, stop)
        isempty(scheme) && break
        params = Dict{String,String}()
        token = nothing
        seen_param = false
        while true
            idx = skip_spaces(header, idx, stop)
            idx > stop && break
            if header[idx] == ','
                next_idx = Base.nextind(header, idx)
                peek_idx = skip_delimiters(header, next_idx, stop)
                peek_token, after_peek = read_token(header, peek_idx, stop)
                if isempty(peek_token)
                    idx = after_peek
                    continue
                end
                if after_peek <= stop && header[after_peek] == '='
                    idx = peek_idx
                else
                    idx = next_idx
                    break
                end
            end
            key_start = idx
            key, idx = read_token(header, idx, stop)
            isempty(key) && break
            idx = skip_spaces(header, idx, stop)
            if idx <= stop && header[idx] == '='
                idx = Base.nextind(header, idx)
                idx = skip_spaces(header, idx, stop)
                value, idx = read_value(header, idx, stop)
                params[String(key)] = value
                seen_param = true
            else
                if seen_param || token !== nothing
                    idx = key_start
                    break
                end
                token = String(key)
            end
        end
        push!(challenges, WWWAuthenticateChallenge(String(scheme); token, params))
    end
    return challenges
end

function skip_spaces(str, idx, stop)
    while idx <= stop
        c = str[idx]
        if c == ' ' || c == '\t'
            idx = Base.nextind(str, idx)
        else
            break
        end
    end
    return idx
end

function skip_delimiters(str, idx, stop)
    while idx <= stop
        c = str[idx]
        if c == ' ' || c == '\t' || c == ','
            idx = Base.nextind(str, idx)
        else
            break
        end
    end
    return idx
end

function read_token(str, idx, stop)
    start = idx
    while idx <= stop
        c = str[idx]
        if c == ' ' || c == '\t' || c == '=' || c == ',' || c == '"'
            break
        end
        idx = Base.nextind(str, idx)
    end
    idx == start && return "", idx
    last = Base.prevind(str, idx)
    return String(str[start:last]), idx
end

function read_value(str, idx, stop)
    idx > stop && return "", idx
    if str[idx] == '"'
        idx = Base.nextind(str, idx)
        buf = IOBuffer()
        escaped = false
        while idx <= stop
            c = str[idx]
            if escaped
                write(buf, c)
                escaped = false
            elseif c == '\\'
                escaped = true
            elseif c == '"'
                idx = Base.nextind(str, idx)
                break
            else
                write(buf, c)
            end
            idx = Base.nextind(str, idx)
        end
        return String(take!(buf)), idx
    end
    start = idx
    while idx <= stop
        c = str[idx]
        if c == ',' || c == ' ' || c == '\t'
            break
        end
        idx = Base.nextind(str, idx)
    end
    idx == start && return "", idx
    last = Base.prevind(str, idx)
    return String(str[start:last]), idx
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
