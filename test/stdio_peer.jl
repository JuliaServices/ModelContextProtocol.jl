using ModelContextProtocol: JSON

const VERSION_KEY = "io.modelcontextprotocol/protocolVersion"
const mode = isempty(ARGS) ? "normal" : only(ARGS)
const output_lock = ReentrantLock()
function emit(message)
    lock(output_lock) do
        println(stdout, JSON.json(message))
        flush(stdout)
    end
end
respond(id, result) = emit(Dict("jsonrpc"=>"2.0", "id"=>id, "result"=>result))
notify(method, params=Dict()) = emit(Dict("jsonrpc"=>"2.0", "method"=>method, "params"=>params))
const held = Any[]
const callbacks = Dict{Any,Any}()
initialized = false

for line in eachline(stdin)
    message = JSON.parse(line)
    method = get(message, "method", nothing)
    id = get(message, "id", nothing)
    params = get(message, "params", Dict())
    if method === nothing
        original = pop!(callbacks, id)
        respond(original, Dict("callback"=>message))
    elseif method == "initialize"
        version = mode == "wrong_version" ? "1900-01-01" : params["protocolVersion"]
        respond(id, Dict("protocolVersion"=>version, "capabilities"=>Dict("tools"=>Dict()),
            "serverInfo"=>Dict("name"=>"local-test-peer", "version"=>"1"), "received"=>params))
    elseif method == "notifications/initialized"
        global initialized = true
        if mode == "blocked_input"
            notify("test/ready")
            wait(Condition())
        elseif mode in ("ignore_eof", "ignore_signals")
            notify("test/ready")
        end
    elseif method == "server/discover"
        @assert params["_meta"][VERSION_KEY] == "2026-07-28"
        respond(id, Dict("supportedVersions"=>["2026-07-28"], "capabilities"=>Dict("tools"=>Dict()), "serverInfo"=>Dict("name"=>"test")))
    elseif method == "notifications/cancelled"
        notify("test/cancelled", params)
        # A reply already being written can race cancellation. It must not be
        # mistaken for the next request, nor close an otherwise usable client.
        respond(params["requestId"], Dict("late"=>true))
    elseif method == "tools/list"
        @assert initialized || params["_meta"][VERSION_KEY] == "2026-07-28"
        respond(id, Dict("tools"=>[Dict("name"=>"echo", "inputSchema"=>Dict("type"=>"object"))], "received"=>params))
    elseif method == "ping"
        respond(id, Dict())
    elseif method == "tools/call"
        @assert initialized || params["_meta"][VERSION_KEY] == "2026-07-28"
        name = params["name"]
        arguments = get(params, "arguments", Dict())
        if name == "echo"
            respond(id, Dict("structuredContent"=>arguments, "received"=>params))
        elseif name == "reverse"
            push!(held, (id, arguments))
            if length(held) == 2
                for (request_id, value) in reverse(held)
                    respond(request_id, value)
                end
                empty!(held)
            end
        elseif name == "hang"
            notify("test/waiting", Dict("id"=>id, "tag"=>get(arguments, "tag", nothing)))
        elseif name == "error"
            emit(Dict("jsonrpc"=>"2.0", "id"=>id, "error"=>Dict("code"=>-32602, "message"=>"bad argument", "data"=>Dict("field"=>"x"))))
        elseif name == "notify"
            notify("test/event", arguments)
            respond(id, Dict())
        elseif name == "server_request"
            request_id = get(arguments, "id", 77)
            callbacks[request_id] = id
            emit(Dict("jsonrpc"=>"2.0", "id"=>request_id, "method"=>get(arguments, "method", "test/request"), "params"=>arguments))
        elseif name == "flood"
            for i in 1:8
                notify("test/event", Dict("value"=>i))
            end
            respond(id, Dict())
        elseif name == "stderr"
            write(stderr, repeat("diagnostic only\n", 10000))
            flush(stderr)
            respond(id, Dict("ok"=>true))
        elseif name == "bad_id"
            emit(Dict("jsonrpc"=>"2.0", "id"=>parse(Int, id), "result"=>Dict()))
        elseif name == "unknown_id"
            respond("never-issued", Dict())
        elseif name == "malformed"
            println(stdout, "not json")
            flush(stdout)
        elseif name == "invalid_utf8"
            write(stdout, UInt8[0xff, 0x0a])
            flush(stdout)
        elseif name == "oversized"
            println(stdout, repeat("x", 4096))
            flush(stdout)
        elseif name == "partial"
            write(stdout, JSON.json(Dict("jsonrpc"=>"2.0", "id"=>id, "result"=>Dict())))
            flush(stdout)
            exit(0)
        elseif name == "eof"
            exit(7)
        elseif name == "reply_then_eof"
            respond(id, Dict("complete"=>true))
            exit(0)
        elseif name == "input_required"
            respond(id, Dict("resultType"=>"input_required", "inputRequests"=>Dict("x"=>Dict("method"=>"sampling/createMessage")), "requestState"=>"state"))
        else
            error("unrecognized test method $name")
        end
    else
        respond(id, Dict("received"=>message))
    end
end
mode in ("ignore_eof", "ignore_signals") && wait(Condition())
