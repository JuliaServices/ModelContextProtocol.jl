"""
    ModelContextProtocol.prepare_stdio_client(command::Cmd; config=MCPClientConfig(),
        stderr=Base.stderr, capabilities=Dict(), client_info=default_client_info(),
        max_message_bytes=16*1024*1024, max_pending_messages=128)

Launch and own a local MCP server process. Use `initialize_client!` and the
ordinary client call APIs, then `close(client)` or `terminate_session!`. The
do-block form closes the client even when its body throws. Register handlers
and finish initialization before making concurrent calls.

Protocol selection is explicit: `2025-11-25` uses initialization and permits
server requests; `2026-07-28` uses discovery and per-request metadata. HTTP
headers, OAuth, HTTP event streams, and modern subscriptions are unsupported.
There is no automatic protocol fallback, process restart, or request replay.
Custom HTTP adapters and verbose HTTP logging are rejected.

`config.timeout.readtimeout` (seconds, positive and finite) bounds transport
waits, including queued writes; per-call `timeout_ms` overrides it. The HTTP
`connecttimeout` setting has no effect on process startup. Other timeout keys
are rejected. A response timeout sends cancellation; a write timeout breaks
the connection because a partial frame cannot be retried safely.

The byte limit applies to each incoming and outgoing message. The pending
limit bounds calls, queued writes, and queued callbacks separately. Callback
overflow or invalid server output breaks the connection. Callbacks run in
order on a separate task, so a slow or reentrant handler does not stop response
routing. Closing discards callbacks that have not started. A blocked user
callback must cooperate with shutdown; see `close(::MCPClient)`.

The child's stderr is redirected directly to a filename, `IOStream`, terminal,
pipe, or `devnull`, separately from protocol stdout. In-memory and custom IO
destinations are unsupported. Caller-provided IO remains caller-owned.
"""
function prepare_stdio_client(
    command::Cmd;
    config::MCPClientConfig=MCPClientConfig(),
    stderr::Union{IO,AbstractString}=Base.stderr,
    capabilities=Dict{String,Any}(),
    client_info=default_client_info(),
    max_message_bytes::Integer=16 * 1024 * 1024,
    max_pending_messages::Integer=128,
)
    config.transport in (nothing, :stdio) || throw(ArgumentError("stdio requires transport=nothing or :stdio"))
    config.http === HTTP || throw(ArgumentError("stdio does not use a custom HTTP adapter"))
    config.verbose && throw(ArgumentError("stdio does not support verbose HTTP logging"))
    config.protocol_version in (DEFAULT_PROTOCOL_VERSION, PROTOCOL_VERSION_2026_07_28) ||
        throw(ArgumentError("stdio supports protocol versions $(DEFAULT_PROTOCOL_VERSION) and $(PROTOCOL_VERSION_2026_07_28)"))
    max_message_bytes > 0 || throw(ArgumentError("max_message_bytes must be positive"))
    max_pending_messages > 0 || throw(ArgumentError("max_pending_messages must be positive"))
    while stderr isa IOContext
        stderr = stderr.io
    end
    stderr isa Union{AbstractString,IOStream,Base.TTY,Base.Pipe,Base.PipeEndpoint,Base.DevNull} ||
        throw(ArgumentError("stdio stderr requires a filename, OS stream, pipe, or devnull"))
    byte_limit, pending_limit = Int(max_message_bytes), Int(max_pending_messages)
    descriptor = MCPTransportDescriptor(kind=:stdio, url="stdio")
    discovery = MCPDiscovery(manifest=JSONDict(), transports=[descriptor], default_transport=descriptor)
    client = prepare_manual_client(discovery; config, transport=descriptor, capabilities, client_info)
    stdio_check_headers(client, nothing)
    stdio_timeout_seconds(client, nothing, nothing)
    process = open(pipeline(command; stderr), "r+")
    guard = ReentrantLock()
    connection = StdioConnection(process, guard, Threads.Condition(guard), Dict{String,Channel{Any}}(),
        Channel{StdioWrite}(pending_limit), Channel{JSONDict}(pending_limit), 0, 0,
        nothing, nothing, nothing, nothing, nothing, nothing, byte_limit, pending_limit)
    client.stdio = connection
    connection.writer = @async stdio_writer(client)
    connection.callbacks = @async stdio_callbacks(client)
    connection.reader = @async stdio_reader(client)
    return client
end

function prepare_stdio_client(f::Function, command::Cmd; kwargs...)
    client = prepare_stdio_client(command; kwargs...)
    try
        return f(client)
    finally
        close(client)
    end
end

function stdio_connection(client::MCPClient)
    connection = client.stdio
    connection === nothing && throw(mcp_error(:transport_closed, "Use prepare_stdio_client to own a stdio process"))
    return connection
end

function stdio_check_headers(client::MCPClient, headers)
    isempty(normalize_headers(headers)) && isempty(client.headers) && client.auth_token === nothing ||
        throw(ArgumentError("stdio has no HTTP headers or OAuth bearer token; configure the child command instead"))
end

function stdio_timeout_seconds(client::MCPClient, timeout, timeout_ms)
    settings = normalize_timeout(client, timeout)
    all(key -> key in (:connecttimeout, :readtimeout), keys(settings)) ||
        throw(ArgumentError("stdio timeout supports readtimeout and ignores connecttimeout"))
    seconds = timeout_ms === nothing ? get(settings, :readtimeout, JSONRPC_TIMEOUT.readtimeout) :
        normalize_timeout_ms(timeout_ms) / 1000
    seconds isa Real && isfinite(seconds) && seconds > 0 ||
        throw(ArgumentError("stdio readtimeout must be positive and finite"))
    return Float64(seconds)
end

stdio_now() = time_ns() / 1.0e9
stdio_deadline(client, timeout, timeout_ms) = stdio_now() + stdio_timeout_seconds(client, timeout, timeout_ms)

function stdio_wait(connection::StdioConnection, channel::Channel, deadline::Float64)
    timer = nothing
    lock(connection.lock)
    try
        isready(channel) && return take!(channel)
        connection.failure === nothing || throw(connection.failure)
        remaining = deadline - stdio_now()
        remaining > 0 || throw(mcp_error(:request_timeout, "The stdio request deadline expired"))
        expired = Ref(false)
        timer = Timer(remaining) do _
            @lock connection.lock begin
                expired[] = true
                notify(connection.changed; all=true)
            end
        end
        while !isready(channel) && connection.failure === nothing && !expired[]
            wait(connection.changed)
        end
        isready(channel) && return take!(channel)
        connection.failure === nothing || throw(connection.failure)
        throw(mcp_error(:request_timeout, "The stdio request deadline expired"))
    finally
        unlock(connection.lock)
        timer === nothing || close(timer)
    end
end

function stdio_enqueue!(client::MCPClient, body::String, deadline::Float64)
    connection = stdio_connection(client)
    ncodeunits(body) <= connection.max_message_bytes || throw(mcp_error(:message_too_large, "Outgoing stdio message exceeds max_message_bytes"))
    occursin('\n', body) && throw(mcp_error(:jsonrpc_error, "A stdio message cannot contain a literal newline"))
    job = StdioWrite(body, Channel{Any}(1), deadline)
    @lock connection.lock begin
        connection.failure === nothing || throw(connection.failure)
        connection.queued_writes < connection.max_pending_messages ||
            throw(mcp_error(:transport_busy, "The stdio write queue is full"))
        connection.queued_writes += 1
        # This lock reserves a free slot; the writer can only make more room.
        put!(connection.outgoing, job)
    end
    return job
end

function stdio_write!(client::MCPClient, body::String, deadline::Float64)
    connection = stdio_connection(client)
    job = stdio_enqueue!(client, body, deadline)
    try
        result = stdio_wait(connection, job.done, deadline)
        result isa Exception && throw(result)
    catch err
        if err isa MCPError && err.code == :request_timeout
            stdio_fail!(connection, err)
        end
        rethrow()
    end
    return nothing
end

function stdio_writer(client::MCPClient)
    connection = stdio_connection(client)
    try
        for job in connection.outgoing
            @lock connection.lock begin
                connection.failure === nothing || return
                connection.queued_writes -= 1
            end
            stdio_now() < job.deadline || throw(mcp_error(:request_timeout, "The stdio write deadline expired"))
            completed = Ref(false)
            timer = Timer(max(0.0, job.deadline - stdio_now())) do _
                @lock connection.lock begin
                    completed[] || stdio_fail!(connection,
                        mcp_error(:request_timeout, "The stdio write deadline expired"))
                end
            end
            try
                write(connection.process.in, job.body, '\n')
                flush(connection.process.in)
                @lock connection.lock begin
                    # Completion survives the caller consuming job.done.
                    completed[] = true
                    put!(job.done, connection.failure)
                    notify(connection.changed; all=true)
                end
            finally
                close(timer)
            end
        end
    catch err
        stdio_fail!(connection, err)
    end
end

function stdio_jsonrpc_call(client::MCPClient, method::AbstractString;
    params, notification, headers, timeout, timeout_ms)
    connection = stdio_connection(client)
    stdio_check_headers(client, headers)
    deadline = stdio_deadline(client, timeout, timeout_ms)
    @lock connection.lock connection.failure === nothing || throw(connection.failure)
    method = String(method)
    method == JSONRPC_METHOD_SUBSCRIPTIONS_LISTEN &&
        throw(mcp_error(:transport_unsupported, "Modern stdio subscriptions are not implemented"))
    ensure_client_readiness(client, method, notification)
    payload = JSONDict("jsonrpc" => JSONRPC_VERSION, "method" => method)
    normalized = normalize_params(params)
    if client_is_modern(client)
        normalized === nothing && (normalized = JSONDict())
        normalized isa JSONDict && (normalized = inject_modern_meta!(client, normalized))
    end
    normalized === nothing || (payload["params"] = normalized)
    if notification
        return stdio_write!(client, JSON.json(payload), deadline)
    end
    reply = Channel{Any}(1)
    id = @lock connection.lock begin
        connection.failure === nothing || throw(connection.failure)
        length(connection.pending) < connection.max_pending_messages ||
            throw(mcp_error(:transport_busy, "Too many pending stdio requests"))
        client.next_id[] += 1
        id = string(client.next_id[])
        connection.pending[id] = reply
        id
    end
    payload["id"] = id
    sent = false
    try
        stdio_write!(client, JSON.json(payload), deadline)
        sent = true
        data = stdio_wait(connection, reply, deadline)
        data isa Exception && throw(data)
        return get(validate_jsonrpc_payload(data), "result", nothing)
    catch err
        if sent && err isa MCPError && err.code == :request_timeout && method != JSONRPC_METHOD_INITIALIZE
            # Cancellation has its own bounded write but does not extend the
            # expired caller's wait. The writer also watches unattended writes.
            cancellation = JSONDict("jsonrpc" => JSONRPC_VERSION,
                "method" => JSONRPC_METHOD_NOTIFICATIONS_CANCELLED,
                "params" => JSONDict("requestId" => id))
            client_is_modern(client) && inject_modern_meta!(client, cancellation["params"])
            try
                stdio_enqueue!(client, JSON.json(cancellation), stdio_deadline(client, nothing, nothing))
            catch cancellation_error
                stdio_fail!(connection, cancellation_error)
            end
        end
        rethrow()
    finally
        @lock connection.lock pop!(connection.pending, id, nothing)
    end
end

function stdio_message!(client::MCPClient, bytes::Vector{UInt8})
    text = String(copy(bytes))
    isvalid(text) || throw(mcp_error(:jsonrpc_error, "Stdio messages must be valid UTF-8"))
    raw = try
        JSON.parse(text)
    catch err
        throw(mcp_error(:jsonrpc_error, "Malformed stdio JSON: $(sprint(showerror, err))"))
    end
    raw isa AbstractDict && get(raw, "jsonrpc", nothing) == JSONRPC_VERSION ||
        throw(mcp_error(:jsonrpc_error, "Stdio messages must be JSON-RPC 2.0 objects"))
    data = to_json_dict(raw)
    connection = stdio_connection(client)
    if haskey(data, "method")
        data["method"] isa AbstractString || throw(mcp_error(:jsonrpc_error, "Invalid stdio method"))
        (haskey(data, "result") || haskey(data, "error")) &&
            throw(mcp_error(:jsonrpc_error, "A stdio request cannot contain a result or error"))
        if haskey(data, "id")
            client_is_modern(client) && throw(mcp_error(:jsonrpc_error, "Modern MCP servers cannot initiate requests"))
            id = data["id"]
            (id isa AbstractString || (id isa Integer && !(id isa Bool))) ||
                throw(mcp_error(:jsonrpc_error, "Invalid server request ID"))
        end
        @lock connection.lock begin
            connection.failure === nothing || return
            connection.queued_events < connection.max_pending_messages ||
                throw(mcp_error(:callback_overflow, "The stdio callback queue is full"))
            connection.queued_events += 1
            put!(connection.events, data)
        end
    else
        xor(haskey(data, "result"), haskey(data, "error")) ||
            throw(mcp_error(:jsonrpc_error, "A stdio response must contain exactly one of result or error"))
        id = get(data, "id", nothing)
        id isa String || throw(mcp_error(:jsonrpc_error, "Stdio response ID must match the client's string ID"))
        @lock connection.lock begin
            reply = pop!(connection.pending, id, nothing)
            if reply === nothing
                # Replies may race cancellation. Only a previously issued,
                # identically encoded ID can be ignored as a late response.
                number = tryparse(Int, id)
                number !== nothing && 0 < number <= client.next_id[] && string(number) == id ||
                    throw(mcp_error(:jsonrpc_error, "Unexpected stdio response ID $(repr(id))"))
            else
                put!(reply, data)
                notify(connection.changed; all=true)
            end
        end
    end
    return nothing
end

function stdio_reader(client::MCPClient)
    connection = stdio_connection(client)
    input = connection.process.out
    chunk = Vector{UInt8}(undef, 8192)
    frame = UInt8[]
    try
        while !eof(input)
            count = readbytes!(input, chunk, min(length(chunk), max(1, bytesavailable(input))))
            start = 1
            for i in 1:count
                if chunk[i] == 0x0a
                    length(frame) + i - start <= connection.max_message_bytes ||
                        throw(mcp_error(:message_too_large, "Incoming stdio message exceeds max_message_bytes"))
                    append!(frame, @view chunk[start:i-1])
                    stdio_message!(client, frame)
                    empty!(frame)
                    start = i + 1
                end
            end
            length(frame) + count - start + 1 <= connection.max_message_bytes ||
                throw(mcp_error(:message_too_large, "Incoming stdio message exceeds max_message_bytes"))
            append!(frame, @view chunk[start:count])
        end
        isempty(frame) || throw(mcp_error(:jsonrpc_error, "Stdio output ended with an incomplete frame"))
        throw(mcp_error(:transport_closed, "The stdio server closed its output"))
    catch err
        stdio_fail!(connection, err)
    end
end

function stdio_callbacks(client::MCPClient)
    connection = stdio_connection(client)
    for payload in connection.events
        @lock connection.lock begin
            connection.failure === nothing || return
            connection.queued_events -= 1
        end
        try
            if get(payload, "method", nothing) == JSONRPC_METHOD_PING && haskey(payload, "id") &&
                !haskey(client.request_handlers, JSONRPC_METHOD_PING)
                send_jsonrpc_response!(client, payload["id"])
            else
                Base.invokelatest(handle_jsonrpc_event!, client, payload)
            end
        catch err
            if @lock(connection.lock, connection.failure === nothing)
                @warn "Stdio callback failed" exception=(err, catch_backtrace())
            end
        end
    end
end

function stdio_fail!(connection::StdioConnection, error::Exception; shutdown_timeout=5.0)
    @lock connection.lock begin
        if connection.failure === nothing
            connection.failure = error
            for reply in values(connection.pending)
                put!(reply, error)
            end
            empty!(connection.pending)
            close(connection.outgoing)
            close(connection.events)
            while isready(connection.outgoing)
                take!(connection.outgoing)
            end
            while isready(connection.events)
                take!(connection.events)
            end
            connection.queued_writes = connection.queued_events = 0
            notify(connection.changed; all=true)
        end
        if connection.shutdown === nothing ||
            (istaskdone(connection.shutdown) && fetch(connection.shutdown) isa Exception)
            connection.shutdown = @async try
                stdio_shutdown(connection, shutdown_timeout)
                nothing
            catch err
                err
            end
        end
    end
    return nothing
end

function stdio_shutdown(connection::StdioConnection, timeout::Real)
    process = connection.process
    # Closing a pipe can wait for a blocked write. It must not prevent the
    # separate shutdown task from escalating termination of a non-reading child.
    if connection.input_closer === nothing
        connection.input_closer = @async close(process.in)
    end
    interval = timeout / 3
    try
        for signal in (nothing, Base.SIGTERM, Base.SIGKILL)
            if signal !== nothing && Base.process_running(process)
                kill(process, signal)
            end
            timedwait(() -> Base.process_exited(process), interval; pollint=0.001) === :ok && break
        end
        Base.process_exited(process) || throw(mcp_error(:shutdown_timeout, "The stdio child did not exit after termination"))
    finally
        Base.process_exited(process) && wait(process)
        close(process.out)
    end
    return nothing
end

"""
    close(client::MCPClient; timeout=5.0)

For an owned stdio client, stop accepting calls, close stdin, then terminate
and, if necessary, kill the child. Fail pending calls and wait for owned IO and
callback tasks. `timeout` bounds this wait; unfinished cleanup is retained and
a later `close` may finish it. The caller owns any custom stderr destination.

Julia cannot safely interrupt arbitrary user callback code. If a callback
remains blocked after process/IO shutdown, throw `MCPError(:callback_timeout)`;
release the callback and close again. A callback that calls `close` does not
wait on itself, and finishes when its handler returns. Queued callbacks are
discarded. HTTP clients delegate to `terminate_session!`.
"""
function Base.close(client::MCPClient; timeout::Real=5.0)
    isfinite(timeout) && timeout > 0 || throw(ArgumentError("close timeout must be positive and finite"))
    client.transport.kind == :stdio || return terminate_session!(client; timeout=(readtimeout=timeout,))
    connection = stdio_connection(client)
    deadline = stdio_now() + timeout
    stdio_fail!(connection, mcp_error(:transport_closed, "The stdio client was closed"); shutdown_timeout=timeout)
    task = connection.shutdown
    timedwait(() -> istaskdone(task), max(0.0, deadline - stdio_now()); pollint=0.001) === :ok ||
        throw(mcp_error(:shutdown_timeout, "Stdio process cleanup is still in progress; close again to wait"))
    result = fetch(task)
    result isa Exception && throw(result)
    for worker in (connection.input_closer, connection.reader, connection.writer, connection.callbacks)
        worker === nothing && continue
        worker === current_task() && continue
        if timedwait(() -> istaskdone(worker), max(0.0, deadline - stdio_now()); pollint=0.001) !== :ok
            code = worker === connection.callbacks ? :callback_timeout : :shutdown_timeout
            throw(mcp_error(code, "A stdio task is still active; release user callback code and close again"))
        end
        fetch(worker)
    end
    client.initialized = false
    client.session = nothing
    client.session_id = nothing
    return nothing
end
