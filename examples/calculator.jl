#!/usr/bin/env julia

using ModelContextProtocol

const MCP = ModelContextProtocol

# Render numbers without distracting trailing zeros.
function pretty_number(value::Real)
    isfinite(value) || return string(value)
    rounded = round(Int, value)
    return isapprox(value, rounded; atol=1e-10) ? string(rounded) : string(round(value, digits=10))
end

function ensure_number_list(value, label; min_items::Int=2)
    value isa AbstractVector || throw(MCP.mcp_error(:invalid_params, "$(label) must be an array of numbers"))
    numbers = Float64[]
    for (idx, item) in enumerate(value)
        item isa Real || throw(MCP.mcp_error(:invalid_params, "$(label)[$idx] must be a real number"))
        push!(numbers, Float64(item))
    end
    length(numbers) >= min_items || throw(MCP.mcp_error(:invalid_params, "$(label) must contain at least $(min_items) numbers"))
    return numbers
end

function require_number(value, label)
    value isa Real || throw(MCP.mcp_error(:invalid_params, "$(label) must be a real number"))
    return Float64(value)
end

function register_calculator_tools!(server::MCPServer)
    register_tool!(
        server;
        name="add",
        title="Add Numbers",
        description="Add two or more numbers together.",
        input_schema=Dict(
            "type" => "object",
            "properties" => Dict(
                "numbers" => Dict(
                    "type" => "array",
                    "minItems" => 2,
                    "items" => Dict("type" => "number"),
                    "description" => "Numbers to add.",
                ),
            ),
            "required" => ["numbers"],
        ),
        output_schema=Dict(
            "type" => "object",
            "properties" => Dict("sum" => Dict("type" => "number")),
            "required" => ["sum"],
        ),
        handler=function (_::MCPRequestContext, args::Dict{String,Any})
            numbers = ensure_number_list(get(args, "numbers", nothing), "numbers")
            result = sum(numbers)
            text = string(join(pretty_number.(numbers), " + "), " = ", pretty_number(result))
            return Dict(
                "content" => [Dict("type" => "text", "text" => text)],
                "structuredContent" => Dict("sum" => result),
                "annotations" => Dict("operation" => "add", "result" => result, "operands" => numbers),
            )
        end,
    )

    register_tool!(
        server;
        name="subtract",
        title="Subtract Numbers",
        description="Subtract one number from another.",
        input_schema=Dict(
            "type" => "object",
            "properties" => Dict(
                "minuend" => Dict("type" => "number", "description" => "The starting value."),
                "subtrahend" => Dict("type" => "number", "description" => "The amount to subtract."),
            ),
            "required" => ["minuend", "subtrahend"],
        ),
        output_schema=Dict(
            "type" => "object",
            "properties" => Dict("difference" => Dict("type" => "number")),
            "required" => ["difference"],
        ),
        handler=function (_::MCPRequestContext, args::Dict{String,Any})
            minuend = require_number(get(args, "minuend", nothing), "minuend")
            subtrahend = require_number(get(args, "subtrahend", nothing), "subtrahend")
            result = minuend - subtrahend
            text = string(pretty_number(minuend), " - ", pretty_number(subtrahend), " = ", pretty_number(result))
            return Dict(
                "content" => [Dict("type" => "text", "text" => text)],
                "structuredContent" => Dict("difference" => result),
                "annotations" => Dict(
                    "operation" => "subtract",
                    "result" => result,
                    "minuend" => minuend,
                    "subtrahend" => subtrahend,
                ),
            )
        end,
    )

    register_tool!(
        server;
        name="multiply",
        title="Multiply Numbers",
        description="Multiply two or more numbers together.",
        input_schema=Dict(
            "type" => "object",
            "properties" => Dict(
                "factors" => Dict(
                    "type" => "array",
                    "minItems" => 2,
                    "items" => Dict("type" => "number"),
                    "description" => "Numbers to multiply in order.",
                ),
            ),
            "required" => ["factors"],
        ),
        output_schema=Dict(
            "type" => "object",
            "properties" => Dict("product" => Dict("type" => "number")),
            "required" => ["product"],
        ),
        handler=function (_::MCPRequestContext, args::Dict{String,Any})
            factors = ensure_number_list(get(args, "factors", nothing), "factors")
            result = prod(factors)
            text = string(join(pretty_number.(factors), " * "), " = ", pretty_number(result))
            return Dict(
                "content" => [Dict("type" => "text", "text" => text)],
                "structuredContent" => Dict("product" => result),
                "annotations" => Dict("operation" => "multiply", "result" => result, "factors" => factors),
            )
        end,
    )

    register_tool!(
        server;
        name="divide",
        title="Divide Numbers",
        description="Divide one number by another.",
        input_schema=Dict(
            "type" => "object",
            "properties" => Dict(
                "dividend" => Dict("type" => "number", "description" => "The numerator."),
                "divisor" => Dict("type" => "number", "description" => "The denominator."),
            ),
            "required" => ["dividend", "divisor"],
        ),
        output_schema=Dict(
            "type" => "object",
            "properties" => Dict("quotient" => Dict("type" => "number")),
            "required" => ["quotient"],
        ),
        handler=function (_::MCPRequestContext, args::Dict{String,Any})
            dividend = require_number(get(args, "dividend", nothing), "dividend")
            divisor = require_number(get(args, "divisor", nothing), "divisor")
            abs(divisor) > 0 || throw(MCP.mcp_error(:invalid_params, "divisor must be non-zero"))
            result = dividend / divisor
            text = string(pretty_number(dividend), " / ", pretty_number(divisor), " = ", pretty_number(result))
            return Dict(
                "content" => [Dict("type" => "text", "text" => text)],
                "structuredContent" => Dict("quotient" => result),
                "annotations" => Dict(
                    "operation" => "divide",
                    "result" => result,
                    "dividend" => dividend,
                    "divisor" => divisor,
                ),
            )
        end,
    )
end

function register_calculation_prompt!(server::MCPServer)
    register_prompt!(
        server;
        name="calculation_playbook",
        description="Generate a checklist to translate a word problem into calculator-ready steps.",
        handler=function (_::MCPRequestContext, args::Dict{String,Any})
            goal = string(get(args, "goal", "the calculation"))
            context_hint = let values = get(args, "known_values", nothing)
                if values isa AbstractVector && !isempty(values)
                    joined = join(string.(values), ", ")
                    "Known values: $(joined)."
                else
                    "List the quantities you already know."
                end
            end
            body = join((
                "Goal: $(goal).",
                context_hint,
                "Checklist:",
                "1. Translate the goal into one or more equations.",
                "2. Identify which calculator tool (add, subtract, multiply, divide) applies to each equation.",
                "3. Plug in the numbers and record interim results.",
                "4. Verify the final answer and note any units or rounding.",
            ), "\n")
            return Dict(
                "messages" => [
                    Dict(
                        "role" => "system",
                        "content" => [
                            Dict(
                                "type" => "text",
                                "text" => "You help users break down problems into clear calculator operations. Favor concise checklists and highlight when to call each tool.",
                            ),
                        ],
                    ),
                    Dict(
                        "role" => "assistant",
                        "content" => [Dict("type" => "text", "text" => body)],
                    ),
                ],
            )
        end,
        annotations=Dict(
            "goalParameter" => Dict(
                "description" => "Optional plain-language statement of what should be calculated.",
                "example" => "Compute the total cost of a \$24.99 item with 8.5% sales tax.",
            ),
            "knownValuesParameter" => Dict(
                "description" => "Optional array of numbers or short labels that are already known.",
                "example" => ["price: 24.99", "tax_rate: 0.085"],
            ),
        ),
    )
end

function start_server()
    config = MCPServerConfig(
        name="Calculator MCP Server",
        version="0.1.0",
        description="Example arithmetic tools implemented with the Model Context Protocol.",
        transport_path="/v1/calculator",
        verbose=true,
    )
    server = MCPServer(config)
    register_calculator_tools!(server)
    register_calculation_prompt!(server)

    host = get(ENV, "MCP_HOST", "127.0.0.1")
    port_str = get(ENV, "MCP_PORT", "3010")
    port = try
        parse(Int, port_str)
    catch err
        error("Invalid MCP_PORT value $(port_str): $(err)")
    end

    http_server = serve_mcp_http(server; host=host, port=port, verbose=false)
    base = base_url(http_server)
    println("Calculator MCP server ready.")
    println("Transport URL: $(base)$(server.transport_path)")
    manifest_urls = [string(base, path) for path in server.config.manifest_paths]
    println("Manifest endpoints: $(join(manifest_urls, ", "))")

    try
        wait(http_server.http)
    catch err
        err isa InterruptException || rethrow(err)
        println("\nInterrupt received, shutting down...")
    finally
        stop_mcp_server(http_server)
        println("Server stopped.")
    end
end

start_server()
