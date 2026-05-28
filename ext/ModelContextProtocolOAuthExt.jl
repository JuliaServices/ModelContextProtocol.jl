module ModelContextProtocolOAuthExt

using HTTP
using OAuth
using ModelContextProtocol
import ModelContextProtocol: MCPClient, attach_token!, request_client_credentials_token, start_public_client_flow

function start_public_client_flow(
    prm_url::AbstractString,
    config::OAuth.PublicClientConfig;
    http=HTTP,
    issuer::Union{String,Nothing}=nothing,
    kwargs...
)
    result = OAuth.complete_pkce_authorization(
        prm_url,
        config;
        http=http,
        issuer=issuer,
        kwargs...,
    )
    resource = result.session.resource
    return (
        token=result.token,
        authorization_server=result.session.authorization_server,
        resource=resource,
        session=result.session,
        callback=result.callback,
    )
end

function start_public_client_flow(
    prm_url::AbstractString;
    client_id::AbstractString,
    redirect_uri=nothing,
    scopes=String[],
    additional_parameters=nothing,
    dpop=nothing,
    kwargs...
)
    config = OAuth.PublicClientConfig(
        client_id=String(client_id),
        redirect_uri=redirect_uri,
        scopes=scopes,
        additional_parameters=additional_parameters,
        dpop=dpop,
    )
    return start_public_client_flow(prm_url, config; kwargs...)
end

function request_client_credentials_token(
    prm_url::AbstractString,
    config::OAuth.ConfidentialClientConfig;
    http=HTTP,
    issuer=nothing,
    extra_token_params=Dict{String,String}(),
    verbose::Bool=false,
)
    return OAuth.request_client_credentials_token(
        prm_url,
        config;
        http=http,
        issuer=issuer,
        extra_token_params=extra_token_params,
        verbose=verbose,
    )
end

function attach_token!(client::MCPClient, token::OAuth.TokenResponse)
    client.auth_token = string(token.token_type, " ", token.access_token)
    return token
end

end
