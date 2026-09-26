const StdioMCP = ModelContextProtocol
using Logging

struct StdioBlockingLogger <: AbstractLogger
    started::Channel{Nothing}
    release::Channel{Nothing}
end
Logging.min_enabled_level(::StdioBlockingLogger) = Logging.Warn
Logging.shouldlog(::StdioBlockingLogger, args...) = true
Logging.catch_exceptions(::StdioBlockingLogger) = false
function Logging.handle_message(logger::StdioBlockingLogger, args...; kwargs...)
    put!(logger.started, nothing)
    take!(logger.release)
end

struct StdioGatedFlush <: IO
    input::IO
    flushing::Channel{Nothing}
    release::Base.Event
end
Base.isopen(io::StdioGatedFlush) = isopen(io.input)
Base.close(io::StdioGatedFlush) = close(io.input)
Base.unsafe_write(io::StdioGatedFlush, pointer::Ptr{UInt8}, count::UInt) = unsafe_write(io.input, pointer, count)
Base.write(io::StdioGatedFlush, byte::UInt8) = write(io.input, byte)
function Base.flush(io::StdioGatedFlush)
    put!(io.flushing, nothing)
    wait(io.release)
    return nothing
end

function stdio_test_command(mode="normal")
    if mode == "ignore_signals" && !Sys.iswindows()
        # An OS process with inherited SIG_IGN avoids Julia's own signal
        # handling. exec retains the owned PID and leaves no helper child.
        script = raw"""
        trap '' TERM
        IFS= read -r request
        printf '%s\n' '{"jsonrpc":"2.0","id":"1","result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"signal-test","version":"1"}}}'
        IFS= read -r initialized
        printf '%s\n' '{"jsonrpc":"2.0","method":"test/ready","params":{}}'
        exec sleep 60
        """
        return `sh -c $script`
    end
    return `$(Base.julia_cmd()) --startup-file=no --threads=1 --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "stdio_peer.jl")) $mode`
end

function stdio_test_client(mode="normal"; protocol="2025-11-25", kwargs...)
    return StdioMCP.prepare_stdio_client(stdio_test_command(mode);
        config=MCPClientConfig(protocol_version=protocol, timeout=(readtimeout=20,)), kwargs...)
end

function stdio_take(channel)
    timedwait(() -> isready(channel), 20; pollint=0.001) === :ok || error("stdio test signal timed out")
    return take!(channel)
end

stdio_catch(f) = try
    f()
catch err
    err
end

function stdio_test_closed(client)
    close(client; timeout=10)
    connection = client.stdio
    @test Base.process_exited(connection.process)
    @test !isopen(connection.process.in) && !isopen(connection.process.out)
    @test isempty(connection.pending)
    @test connection.queued_events == connection.queued_writes == 0
    @test all(task -> task === nothing || istaskdone(task),
        (connection.reader, connection.writer, connection.callbacks, connection.input_closer, connection.shutdown))
    @test close(client) === nothing
end

@testset "Owned stdio client" begin
    @testset "Protocol $protocol" for protocol in ("2025-11-25", "2026-07-28")
        notifications = Channel{Any}(4)
        cancelled = Channel{Any}(2)
        client = stdio_test_client(; protocol,
            capabilities=Dict("roots"=>Dict()), client_info=Dict("name"=>"owned-test", "version"=>"1"))
        register_notification_handler!(client, "test/event", (_, _, value) -> put!(notifications, value))
        register_notification_handler!(client, "test/cancelled", (_, _, value) -> put!(cancelled, value))
        register_request_handler!(client, "test/request", (c, _, value, _) ->
            call_tool(c, "echo"; arguments=value)["structuredContent"])
        register_request_handler!(client, "test/error", (_, _, _, _) -> error("handler failed"))
        try
            initialized = initialize_client!(client)
            if protocol == "2025-11-25"
                @test initialized["received"]["clientInfo"]["name"] == "owned-test"
                @test haskey(initialized["received"]["capabilities"], "roots")
                @test client.session_id === nothing
            else
                @test initialized["supportedVersions"] == [protocol]
            end
            @test list_tools(client)["tools"][1]["name"] == "echo"
            args = Dict("text"=>"line one\nλ\0line two", "array"=>Any[1, false, nothing])
            result = call_tool(client, "echo"; arguments=args)
            @test result["structuredContent"] == args
            protocol == "2026-07-28" && @test result["received"]["_meta"][StdioMCP.META_PROTOCOL_VERSION] == protocol
            @test get_prompt(client, "example")["received"]["method"] == "prompts/get"
            @test read_resource(client, "test://resource")["received"]["method"] == "resources/read"
            interim = call_tool(client, "input_required")
            @test StdioMCP.is_input_required(interim)
            @test interim["requestState"] == "state"
            call_tool(client, "notify"; arguments=Dict("value"=>1))
            @test stdio_take(notifications)["value"] == 1
            error = stdio_catch(() -> call_tool(client, "error"))
            @test error isa MCPError
            @test occursin("-32602", sprint(showerror, error))
            @test occursin("field", sprint(showerror, error))

            reversed = [@async(call_tool(client, "reverse"; arguments=Dict("value"=>i))) for i in 1:2]
            @test [fetch(task)["value"] for task in reversed] == [1, 2]
            concurrent = [Threads.@spawn(call_tool(client, "echo"; arguments=Dict("value"=>i))) for i in 1:16]
            @test [fetch(task)["structuredContent"]["value"] for task in concurrent] == collect(1:16)

            if protocol == "2025-11-25"
                # An integer server ID and the client's string IDs occupy
                # separate directions. The handler calls back into the client.
                callback = call_tool(client, "server_request"; arguments=Dict("id"=>1, "value"=>42))
                @test callback["callback"]["id"] === 1
                @test callback["callback"]["result"]["value"] == 42
                missing = call_tool(client, "server_request"; arguments=Dict("id"=>"unknown", "method"=>"missing"))
                @test missing["callback"]["error"]["code"] == -32601
                failed = call_tool(client, "server_request"; arguments=Dict("method"=>"test/error"))
                @test failed["callback"]["error"]["code"] == -32603
                @test occursin("handler failed", failed["callback"]["error"]["message"])
                @test haskey(call_tool(client, "server_request"; arguments=Dict("method"=>"ping"))["callback"], "result")
            end

            timed = stdio_catch(() -> call_tool(client, "hang"; timeout_ms=50))
            @test timed isa MCPError && timed.code == :request_timeout
            @test stdio_take(cancelled)["requestId"] isa String
            @test call_tool(client, "echo"; arguments=Dict("after"=>"late response"))["structuredContent"]["after"] == "late response"
            @test isempty(client.stdio.pending)
            @test_throws ArgumentError call_tool(client, "echo"; headers=["X-Test"=>"no"])
            @test_throws ArgumentError call_tool(client, "echo"; timeout_ms=0)
            @test_throws ArgumentError StdioMCP.jsonrpc_call(client, "tools/list"; timeout=(retry=true,))
            @test_throws MCPError open_event_stream(client)
            @test_throws MCPError start_event_listener!(client)
            @test_throws MCPError StdioMCP.listen_subscriptions!(client)

            # Retain each existing positional construction arity.
            fields = ntuple(i -> getfield(client, i), 19)
            @test MCPClient(fields...).stdio === nothing
            @test MCPClient(fields[1:18]...).stdio === nothing
            @test MCPClient(fields[1:7]..., fields[10:18]...).stdio === nothing
        finally
            stdio_test_closed(client)
        end
    end

    @testset "Configuration and ownership" begin
        absent = Cmd(["not-an-installed-mcp-test-command"])
        for config in (MCPClientConfig(transport=:http), MCPClientConfig(protocol_version="unknown"),
            MCPClientConfig(http=Base), MCPClientConfig(verbose=true),
            MCPClientConfig(headers=["X-Test"=>"no"]), MCPClientConfig(timeout=(readtimeout=0,)),
            MCPClientConfig(timeout=(readtimeout=Inf,)), MCPClientConfig(timeout=(retry=true,)))
            @test_throws ArgumentError StdioMCP.prepare_stdio_client(absent; config)
        end
        @test_throws ArgumentError StdioMCP.prepare_stdio_client(absent; max_message_bytes=0)
        @test_throws ArgumentError StdioMCP.prepare_stdio_client(absent; max_pending_messages=0)
        @test_throws ArgumentError StdioMCP.prepare_stdio_client(absent; stderr=IOBuffer())
        @test_throws Base.IOError StdioMCP.prepare_stdio_client(absent)
        client = stdio_test_client("wrong_version"; stderr=devnull)
        try
            @test_throws ArgumentError initialize_client!(client; protocol_version="2026-07-28")
            error = stdio_catch(() -> initialize_client!(client))
            @test error isa MCPError && error.code == :unsupported_protocol_version
            @test !client.initialized && client.session === nothing
        finally
            stdio_test_closed(client)
        end
        owned = Ref{Any}()
        original = ErrorException("do-block body failed")
        error = stdio_catch() do
            StdioMCP.prepare_stdio_client(stdio_test_command(); stderr=devnull) do client
                owned[] = client
                initialize_client!(client)
                throw(original)
            end
        end
        @test error === original
        stdio_test_closed(owned[])
        client = stdio_test_client(; max_message_bytes=2048, stderr=devnull)
        try
            initialize_client!(client)
            error = stdio_catch(() -> call_tool(client, "echo"; arguments=Dict("large"=>repeat("x", 4096))))
            @test error isa MCPError && error.code == :message_too_large
            @test isempty(client.stdio.pending)
            @test call_tool(client, "echo"; arguments=Dict("still"=>"usable"))["structuredContent"]["still"] == "usable"
        finally
            stdio_test_closed(client)
        end
    end

    @testset "Protocol failure $name" for (name, code) in
        (("bad_id", :jsonrpc_error), ("unknown_id", :jsonrpc_error),
         ("malformed", :jsonrpc_error), ("invalid_utf8", :jsonrpc_error),
         ("partial", :jsonrpc_error), ("eof", :transport_closed), ("oversized", :message_too_large))
        client = stdio_test_client(; max_message_bytes=2048, stderr=devnull)
        try
            initialize_client!(client)
            error = stdio_catch(() -> call_tool(client, name))
            @test error isa MCPError && error.code == code
            @test_throws MCPError call_tool(client, "echo")
        finally
            stdio_test_closed(client)
        end
        name == "eof" && @test client.stdio.process.exitcode == 7
    end

    @testset "Modern server calls are rejected" begin
        client = stdio_test_client(; protocol="2026-07-28", stderr=devnull)
        try
            initialize_client!(client)
            @test_throws MCPError call_tool(client, "server_request")
        finally
            stdio_test_closed(client)
        end
    end

    @testset "A completed response remains valid before EOF" begin
        client = stdio_test_client(; stderr=devnull)
        try
            initialize_client!(client)
            @test call_tool(client, "reply_then_eof")["complete"]
        finally
            stdio_test_closed(client)
        end
    end

    @testset "Stderr is separate and borrowed" begin
        mktemp() do _, output
            client = stdio_test_client(; stderr=output)
            try
                initialize_client!(client)
                @test call_tool(client, "stderr")["ok"]
            finally
                stdio_test_closed(client)
            end
            @test isopen(output)
            seekstart(output)
            @test length(readlines(output)) == 10000
        end
    end

    @testset "A blocked callback cannot block response routing" begin
        started, release = Channel{Nothing}(1), Channel{Nothing}(1)
        client = stdio_test_client(; max_pending_messages=2, stderr=devnull)
        register_notification_handler!(client, "test/event", (_, _, _) -> (put!(started, nothing); take!(release)))
        try
            initialize_client!(client)
            call_tool(client, "notify")
            stdio_take(started)
            @test call_tool(client, "echo"; arguments=Dict("routed"=>true))["structuredContent"]["routed"]
            error = stdio_catch(() -> call_tool(client, "flood"))
            @test error isa MCPError && error.code == :callback_overflow
            closed = stdio_catch(() -> close(client; timeout=0.5))
            @test closed isa MCPError && closed.code == :callback_timeout
            @test Base.process_exited(client.stdio.process)
            @test !istaskdone(client.stdio.callbacks)
        finally
            put!(release, nothing)
            stdio_test_closed(client)
        end
    end

    @testset "A blocked stderr sink does not prevent shutdown" begin
        output = Pipe()
        Base.link_pipe!(output; reader_supports_async=true, writer_supports_async=true)
        client = stdio_test_client(; stderr=output)
        try
            initialize_client!(client)
            error = stdio_catch(() -> call_tool(client, "stderr"; timeout_ms=300))
            @test error isa MCPError && error.code == :request_timeout
            stdio_test_closed(client)
            @test isopen(output.in) && isopen(output.out)
        finally
            close(output)
            stdio_test_closed(client)
        end
    end

    @testset "Callback logging does not hold the routing lock" begin
        logger = StdioBlockingLogger(Channel{Nothing}(1), Channel{Nothing}(1))
        client = with_logger(logger) do
            stdio_test_client(; max_message_bytes=2048, stderr=devnull)
        end
        register_request_handler!(client, "test/request", (_, _, _, _) -> Base.error(repeat("x", 4096)))
        outer = nothing
        try
            initialize_client!(client)
            outer = @async stdio_catch(() -> call_tool(client, "server_request"))
            stdio_take(logger.started)
            routed = @async call_tool(client, "echo"; arguments=Dict("routed"=>true))
            finished = timedwait(() -> istaskdone(routed), 3; pollint=0.001) === :ok
            @test finished
            if finished
                @test fetch(routed)["structuredContent"]["routed"]
                error = stdio_catch(() -> close(client; timeout=0.5))
                @test error isa MCPError && error.code == :callback_timeout
            end
        finally
            put!(logger.release, nothing)
            stdio_test_closed(client)
        end
        @test fetch(outer) isa MCPError
    end

    @testset "Close from a reentrant callback" begin
        closed = Channel{Any}(1)
        client = stdio_test_client(; stderr=devnull)
        register_request_handler!(client, "test/request", (c, _, _, _) -> begin
            nested = call_tool(c, "echo"; arguments=Dict("nested"=>true))["structuredContent"]["nested"]
            close(c)
            put!(closed, nested)
            nothing
        end)
        try
            initialize_client!(client)
            @test_throws MCPError call_tool(client, "server_request")
            @test stdio_take(closed)
        finally
            stdio_test_closed(client)
        end
    end

    @testset "Reentrant calls race $action" for action in ("eof", "close")
        nested = Channel{Any}(1)
        client = stdio_test_client(; stderr=devnull)
        register_request_handler!(client, "test/request", (c, _, _, _) -> begin
            put!(nested, stdio_catch(() -> call_tool(c, "hang")))
            Dict()
        end)
        try
            initialize_client!(client)
            outer = @async stdio_catch(() -> call_tool(client, "server_request"))
            @test timedwait(() -> lock(() -> length(client.stdio.pending) == 2, client.stdio.lock),
                20; pollint=0.001) === :ok
            if action == "eof"
                @test_throws MCPError call_tool(client, "eof")
            else
                close(client)
            end
            @test fetch(outer) isa MCPError
            @test stdio_take(nested) isa MCPError
        finally
            stdio_test_closed(client)
        end
    end

    @testset "Bounded pending calls and close" begin
        waiting = Channel{Any}(2)
        client = stdio_test_client(; max_pending_messages=2, stderr=devnull)
        register_notification_handler!(client, "test/waiting", (_, _, params) -> put!(waiting, params))
        initialize_client!(client)
        calls = [@async(stdio_catch(() -> call_tool(client, "hang"))) for _ in 1:2]
        stdio_take(waiting)
        stdio_take(waiting)
        error = stdio_catch(() -> call_tool(client, "echo"))
        @test error isa MCPError && error.code == :transport_busy
        stdio_test_closed(client)
        @test timedwait(() -> all(istaskdone, calls), 1; pollint=0.001) === :ok
        @test all(task -> fetch(task) isa MCPError, calls)
    end

    @testset "One deadline does not expire another call" begin
        waiting = Channel{Any}(2)
        client = stdio_test_client(; stderr=devnull)
        register_notification_handler!(client, "test/waiting", (_, _, value) -> put!(waiting, value))
        try
            initialize_client!(client)
            short = @async stdio_catch(() -> call_tool(client, "hang";
                arguments=Dict("tag"=>"short"), timeout_ms=100))
            long = @async stdio_catch(() -> call_tool(client, "hang";
                arguments=Dict("tag"=>"long"), timeout_ms=5000))
            messages = [stdio_take(waiting), stdio_take(waiting)]
            long_id = only(message["id"] for message in messages if message["tag"] == "long")
            expired = fetch(short)
            @test expired isa MCPError && expired.code == :request_timeout
            @test !istaskdone(long)
            StdioMCP.cancel_request(client, long_id)
            @test fetch(long)["late"]
        finally
            stdio_test_closed(client)
        end
    end

    @testset "Blocked stdin writes have deadlines" begin
        ready = Channel{Nothing}(1)
        client = stdio_test_client("blocked_input"; stderr=devnull)
        register_notification_handler!(client, "test/ready", (_, _, _) -> put!(ready, nothing))
        try
            initialize_client!(client)
            stdio_take(ready)
            started = time_ns()
            error = stdio_catch(() -> call_tool(client, "echo";
                arguments=Dict("large"=>repeat("x", 8 * 1024 * 1024)), timeout_ms=300))
            @test error isa MCPError && error.code == :request_timeout
            @test (time_ns() - started) / 1e9 < 3
        finally
            stdio_test_closed(client)
        end
    end

    @testset "A late flush cannot publish success after its deadline" begin
        client = stdio_test_client(; stderr=devnull)
        gate = nothing
        try
            initialize_client!(client)
            connection = client.stdio
            gate = StdioGatedFlush(connection.process.in, Channel{Nothing}(1), Base.Event())
            connection.process.in = gate
            body = StdioMCP.JSON.json(Dict("jsonrpc"=>"2.0", "method"=>"notifications/initialized"))
            job = StdioMCP.stdio_enqueue!(client, body, StdioMCP.stdio_now() + 1)
            stdio_take(gate.flushing)
            @test timedwait(() -> lock(() -> connection.failure !== nothing, connection.lock),
                3; pollint=0.001) === :ok
            failure = connection.failure
            @test failure isa MCPError && failure.code == :request_timeout
            # The bytes were written, but flush was held until after the
            # actual write timer failed the connection. Publish that failure.
            notify(gate.release)
            @test timedwait(() -> isready(job.done), 3; pollint=0.001) === :ok
            @test StdioMCP.stdio_wait(connection, job.done, StdioMCP.stdio_now() + 1) === failure
        finally
            gate === nothing || notify(gate.release)
            stdio_test_closed(client)
        end
    end

    @testset "Shutdown escalation $mode" for mode in ("ignore_eof", "ignore_signals")
        ready = Channel{Nothing}(1)
        client = stdio_test_client(mode; stderr=devnull)
        register_notification_handler!(client, "test/ready", (_, _, _) -> put!(ready, nothing))
        initialize_client!(client)
        stdio_take(ready)
        close(client; timeout=3)
        stdio_test_closed(client)
        mode == "ignore_signals" && !Sys.iswindows() && @test client.stdio.process.termsignal == Base.SIGKILL
    end

    @testset "Completed failed cleanup is retryable" begin
        client = stdio_test_client(; stderr=devnull)
        initialize_client!(client)
        connection = client.stdio
        release = Channel{Nothing}(1)
        original = StdioMCP.mcp_error(:shutdown_timeout, "Injected failure after child exit")
        # Fault injection holds the first close at a real task barrier and
        # leaves process cleanup incomplete, as an expired shutdown would.
        connection.shutdown = @async begin
            take!(release)
            connection.input_closer = @async close(connection.process.in)
            wait(connection.process)
            original
        end
        first_close = @async stdio_catch(() -> close(client))
        @test timedwait(() -> lock(() -> connection.failure !== nothing, connection.lock),
            20; pollint=0.001) === :ok
        put!(release, nothing)
        @test fetch(first_close) === original
        input_closer = connection.input_closer
        stdio_test_closed(client)
        @test connection.input_closer === input_closer
    end

    @testset "Exit racing escalation" begin
        for _ in 1:4
            client = stdio_test_client(; stderr=devnull)
            initialize_client!(client)
            gate = Channel{Nothing}(2)
            exited = @async (take!(gate); stdio_catch(() -> call_tool(client, "eof")))
            closed = @async (take!(gate); stdio_catch(() -> close(client; timeout=0.01)))
            put!(gate, nothing)
            put!(gate, nothing)
            @test fetch(exited) isa MCPError
            first_close = fetch(closed)
            @test first_close === nothing || (first_close isa MCPError && first_close.code == :shutdown_timeout)
            @test timedwait(() -> istaskdone(client.stdio.shutdown) && Base.process_exited(client.stdio.process),
                20; pollint=0.001) === :ok
            stdio_test_closed(client)
        end
    end
end
