# Auth0-Federated MCP Calculator: A Deep Dive

## High-Level Architecture
This example wraps the Model Context Protocol (MCP) calculator server with an OAuth 2.0 authorization layer that delegates authentication to Auth0 while the MCP node continues to act as the protected resource issuer. The public OAuth metadata that MCP clients see uses the server's own base URL, preserving the proxy identity, but actual end-user tokens are issued by Auth0.
Key file: `examples/calculator_with_auth0.jl`.

- MCP transport lives at `https://<PUBLIC_BASE_URL_HOST>/v1/calculator`.
- OAuth endpoints exposed by the proxy: `/oauth/authorize`, `/oauth/token`, `/oidc/register`, and the metadata/JWKS routes.
- Auth0 endpoints consumed: `https://<AUTH0_DOMAIN>/authorize`, `/oauth/token`, and `/.well-known/jwks.json`.

## Configuration Surface
Environment variables set the integration contract:

- `PUBLIC_BASE_URL` (default `http://127.0.0.1:3010`): external origin of your proxy; used to build transport and metadata URLs.
- `AUTH0_DOMAIN`: Auth0 tenant host (no scheme).
- `AUTH0_CLIENT_ID` / `AUTH0_CLIENT_SECRET`: Auth0 application credentials (client secret optional when entire flow is PKCE).
- `AUTH0_SCOPE`: Space-separated scopes requested from Auth0; defaults to `"openid profile email"` but enforced to include `REQUIRED_SCOPES`.
- `AUTH0_CALLBACK_PATH`: Proxy endpoint receiving Auth0's authorization code (default `/oauth/idp/callback`).
- `AUTH0_AUDIENCE`: Optional API audience when requesting Auth0 access tokens. If omitted, the sample requests only the default Auth0 OIDC token set.
- `MCP_HOST` and `MCP_PORT`: Internal bind address for `serve_mcp_http`.

The proxy itself registers a single public client with ID `calculator-public-client` and enforces PKCE for all incoming authorization requests.

## In-Memory Persistence & Helpers
To mediate the Auth0 round-trip, the sample keeps transient state:

- `PendingAuthRequest` keyed by a random `state` token stores the original MCP OAuth request plus generated nonce and Auth0 PKCE verifier.
- `AuthorizationCode` store remembers issued proxy codes until they're redeemed (5-minute TTL).
- `AUTH0_TOKEN_RESPONSES` caches raw Auth0 token payloads long enough to hand the same data back during the `/oauth/token` exchange.
- `fetch_auth0_jwks` pulls Auth0 public keys and caches them for 15 minutes to verify ID tokens and protect MCP resources.

Utilities such as `authorization_parameters`, `parse_query_params`, `parse_form_params`, and PKCE helpers keep request validation compact.

## Authorization Code Flow Walkthrough

1. **Client -> Proxy `/oauth/authorize`**
   The MCP client hits your proxy with the standard OAuth query arguments. `authorization_get_handler` validates the request, normalizes scope (ensuring at least `openid profile email`), and captures client metadata.
   It then generates:
   - A proxy `state` token (maps to `PendingAuthRequest`).
   - A `nonce` used later to validate the Auth0 ID token.
   - A brand-new Auth0 PKCE verifier+challenge pair (distinct from the client's original challenge).
   Finally it redirects to Auth0's `/authorize`, embedding `state`, `nonce`, `code_challenge`, and optional `audience`.

2. **Auth0 -> Proxy `/oauth/idp/callback`**
   Auth0 returns either an error or an authorization code to the proxy callback. `auth0_callback_handler` loads the pending request, surfaces Auth0 errors if present, and exchanges the Auth0 code using the stored PKCE verifier.
   On success it validates the ID token's `nonce` and subject, then mints a proxy authorization code tied to the original client's redirect URI and PKCE challenge. The raw Auth0 token response is stashed alongside that proxy code so it can be replayed later.

3. **Client -> Proxy `/oauth/token`**
   The MCP client redeems the proxy authorization code at `/oauth/token`. `token_handler` enforces method, form-encoding, grant type, client ID, redirect URI, and PKCE verification against the stored `AuthorizationCode`.
   Instead of issuing new tokens, the handler returns the cached Auth0 response (access token, ID token, refresh token if present). If Auth0 omitted `scope`, it reconstructs the proxy-requested scope string. No bearer tokens are logged.

Throughout the flow, the proxy remains the OAuth authorization server from the MCP client's vantage point, yet all end-user credentials originate from Auth0.

## Protected Resource & MCP Wiring

- `register_calculator_tools!` and `register_calculation_prompt!` define the standard calculator functionality.
- The MCP server runs via `serve_mcp_http`, exposing JSON-RPC and SSE transports at `transport_path="/v1/calculator"`.

Before requests reach the MCP handlers, they pass through `protected_resource_middleware`, which verifies the `Authorization: Bearer` header using Auth0's JWKS and required scopes.
Successful verification injects the decoded OAuth token into the MCP request context under `:oauth_token`, enabling tool handlers (or future extensions) to adapt behavior based on the authenticated user.

## Discovery & Metadata Endpoints
Your proxy keeps separate identities for the authorization server and the protected resource:

- **Protected Resource Metadata** (`/.well-known/oauth-resource` by default) advertises the proxy base URL as the only authorization server for the MCP transport, maintaining the local identity.
- **Authorization Server Metadata** lists Auth0 as the issuer while still pointing clients to the proxy-hosted `/oauth/authorize` and `/oauth/token` endpoints.
- **JWKS Endpoint** serves the proxy's own signing key derived from `JWTAccessTokenIssuer`. You keep this available for potential proxy-signed tokens even though the current flow forwards Auth0 tokens.

Dynamic client registration (`/oidc/register`) responds with the single public client configuration, echoing any requested redirect URIs but always returning `calculator-public-client` with `token_endpoint_auth_method = "none"`.

## Porting the Pattern to Another Language
A senior engineer reproducing this architecture would implement:

1. **Configurable Constants** mirroring the environment surface: proxy base URL, Auth0 endpoints, required scopes, PKCE defaults, callback path.
2. **Transient Stores** for pending auth (state -> original request + nonce + Auth0 PKCE), issued proxy codes (code -> client metadata), cached Auth0 tokens, and JWKS.
3. **Authorization Handler** validating client inputs, ensuring PKCE, augmenting scopes, generating state/nonce, and redirecting to Auth0 `/authorize`.
4. **Callback Handler** that exchanges the Auth0 code with the stored verifier, verifies the ID token (`iss`, `aud`, `nonce`), creates a new proxy code, and redirects the client back with the proxy code.
5. **Token Endpoint** ensuring grant correctness, matching PKCE and redirect URI, then replaying Auth0's token response (or issuing a new one if you adopt proxy signing).
6. **Protected Resource Middleware** that guards MCP (or equivalent) traffic by validating Auth0 access tokens against their JWKS and checking scopes before invoking business logic.
7. **Discovery Documents** reflecting the proxy's base URL for clients while including Auth0-specific hints (issuer, JWKS URI) so integrators understand both authorities.
8. **Dynamic Client Registration (optional)** to publish the pre-defined public client for easier onboarding.

Translating each Julia function to another stack boils down to a combination of secure random token generation, HTTP request/response handling, JWT validation, and concurrency-safe caches-standard primitives across languages.

## Security & Operational Notes

- **State & PKCE Lifetimes:** Both pending requests and authorization codes expire after 300 seconds, limiting replay windows. Implement similar timeouts and eviction in other languages.
- **Nonce Enforcement:** ID token nonce verification (`validate_auth0_id_token`) is mandatory when accepting external identity providers.
- **Proxy Identity:** Because the resource metadata still lists the proxy as the authorization server, document for client integrators that the proxy relays to Auth0 behind the scenes. This allows you to swap IDPs without changing MCP clients.
- **Logging:** Keep bearer credentials out of logs; the sample now avoids printing token bodies.
- **JWKS Alignment:** If you later choose to re-issue tokens from the proxy, sign them with `JWTAccessTokenIssuer` so the local JWKS endpoint remains accurate; otherwise, ensure clients rely on the Auth0 `jwks_uri` when validating end-user tokens.

By following these patterns, a senior engineer can reimplement the Auth0-federated MCP server in any language with robust HTTP, OAuth, and JWT libraries, while preserving the same proxy-first topology showcased here.
