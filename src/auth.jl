function start_public_client_flow end

function request_client_credentials_token end

function attach_token!(client::MCPClient, authorization::AbstractString)
    client.auth_token = String(authorization)
    return authorization
end

function preferred_resource_metadata(challenges::Vector{MCPAuthenticationChallenge})
    for challenge in challenges
        challenge.resource_metadata !== nothing && return String(challenge.resource_metadata)
    end
    return nothing
end
