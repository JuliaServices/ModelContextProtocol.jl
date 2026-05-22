#!/usr/bin/env julia

using JSON
using ModelContextProtocol

const SERVER_BASE_URL = "http://127.0.0.1:3010"

function print_json(value)
    io = IOBuffer()
    JSON.print(io, value, 2)
    println(String(take!(io)))
end

function with_calculator_client(f::Function)
    discovery = discover_server(SERVER_BASE_URL)
    client = prepare_manual_client(discovery)
    initialize_client!(
        client;
        client_info=Dict("name" => "Calculator User", "version" => "1.0.0"),
    )
    try
        return f(client)
    finally
        terminate_session!(client)
    end
end

function add_numbers(numbers::Vector{<:Real})
    with_calculator_client() do client
        response = call_tool(client, "add"; arguments=Dict("numbers" => collect(numbers)))
        println("Tool call response:")
        print_json(response)
        return response
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    println("Calling the calculator tool with numbers 1, 3, 4.")
    add_numbers([1, 3, 4])
end
