#!/usr/bin/env julia

using ModelContextProtocol
using HTTP
using JSON3

const MCP = ModelContextProtocol

function use_calculator_to_add(numbers::Vector)
    # Connect to the calculator MCP server
    client = MCPClient("http://127.0.0.1:3010/v1/calculator")
    
    try
        # Initialize the connection
        initialize!(client; client_name="Calculator User", client_version="1.0")
        
        # Call the add tool with the numbers
        result = call_tool(client, "add", Dict("numbers" => numbers))
        
        # Extract and display the result
        if haskey(result, "content") && !isempty(result["content"])
            text_content = result["content"][1]["text"]
            println("Result: ", text_content)
        end
        
        if haskey(result, "annotations")
            annotations = result["annotations"]
            println("Sum: ", annotations["result"])
        end
        
        return result
    finally
        close(client)
    end
end

# Add the numbers: 1, 3, 4
println("Using calculator MCP server to add: 1, 3, 4")
use_calculator_to_add([1, 3, 4])

