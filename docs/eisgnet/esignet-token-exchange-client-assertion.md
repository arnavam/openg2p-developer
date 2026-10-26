# eSignet login through the Beneficiary Portal: token exchange fails on the client assertion

Status: found on 2026-10-20 during a local test. The gap in `iam-core` is not fixed. The test was moved to eSignet 1.4.1 and IAM bene API 1.1.0, the versions that match each other; see "Follow-up: running the versions OpenG2P deploys" at the end. No OpenG2P or eSignet source code was changed.

## Summary

After the user completes the OTP step on eSignet, the browser returns to the IAM bene API callback. IAM then calls eSignet's `/oauth2/token` to turn the authorization `code` into tokens. eSignet rejects that call:

```
{"error":"invalid_client","error_description":"Invalid client assertion"}
```

The user sees `{"errors":[{"code":"G2P-REQ-100","message":"Unknown Error."}]}`.

Cause: eSignet 2.0.0 requires the client assertion JWT to carry a `jti` claim and a `kid` header. The `iam-core` helper that builds the assertion sends neither. The keys themselves are correct.

## Components and versions in the test

| Component | Source repository | Ref | Image used |
|---|---|---|---|
| eSignet service (Go) | `mosip/esignet`, directory `esignet-service/` | tag `v2.0.0` (the local checkout `db528423` carries this tag) | `mosipid/esignet:2.0.0`, host `:8081` |
| eSignet login UI | `mosip/esignet`, directory `oidc-ui/` | tag `v2.0.0` | `mosipid/oidc-ui:2.0.0`, host `:3010` |
| Mock identity system | `mosip/esignet-mock-services`, directory `mock-identity-system/` | not checked against the image | `mosipid/mock-identity-system:0.14.0` |
| IAM bene API | `OpenG2P/iam`, directory `iam-bene-portal-api/` (shared code in `iam-core/`) | `509f7ec` (tip of `develop`, 2026-10-12) | `openg2p/iam-bene-portal-api:develop`, `iam-core` 1.4.0 |
| IAM staff API | `OpenG2P/iam`, directory `iam-staff-portal-api/` | `49ba890` (branch `1.3`, tag `1.3.0`) | `openg2p/iam-staff-portal-api:1.3.0`, `iam-core` 1.3.0 |
| Thunder engine (embedded in eSignet) | `thunder-id/thunderid`, directory `backend/` | `12f517c43840`, pinned by a `replace` in `esignet-service/go.mod`; read from a clone, not run separately | compiled into the eSignet image |
| Beneficiary portal UI | `OpenG2P/openg2p-beneficiary-portal-ui` | `6ee484c` (2025-11-25) | `openg2p/openg2p-beneficiary-portal-ui:local`, built locally from that commit |
| Gateway | none (config file `config/bene/gateway.conf` in the local `openg2p-developer` checkout) | not applicable | `nginx:alpine` on `:3030` |

The image tag is what ran. The ref is the commit the image label or tag points to. The eSignet ref is the tag in the local clone, and the IAM refs come from the image's `org.opencontainers.image.revision` label.

### Other sources consulted

| Source | Used for | Ref |
|---|---|---|
| `OpenG2P/registry-platform` | The registry Helm chart (`helm/openg2p-registry/templates/agent-portal-api/registrant-auth-bootstrap.yaml`), `registry-bene-api` and `registry-agent-portal-api`, to see how the registry runs eSignet login | `develop` at `e112aac` (2026-10-12), read from a shallow clone |
| `OpenG2P/openg2p-fastapi-common` | `KeymanagerCryptoHelper` in the IAM container (the keymanager signing path) | version 1.1.7 as installed in the image. The matching git tag was not checked. |
| `lepture/authlib` (package `Authlib`) | `AsyncOAuth2Client.fetch_token`, which posts the token request and raises `OAuthError` | 1.8.0 as installed |
| `mpdavis/python-jose` (package `python-jose`) | Signs the client assertion in `client_assertion_helper.py` | 3.5.0 as installed |
| `encode/httpx` | HTTP client used by the IAM container | 0.28.1 as installed |
| `docker.io` Postgres and Redis | Shared databases and Redis for IAM and eSignet | `postgres:16`, `redis:7-alpine` |
| `OpenG2P/openg2p-developer` compose files (local checkout) | Local stack and `compose/docker-compose.bene.yml`, `config/bene/*` for the bene test | local working tree, uncommitted changes |

The upstream repository names for Authlib, python-jose and httpx are from general knowledge, not looked up in this session.

## What happens after OTP verification

All calls below were seen in the gateway, eSignet and IAM logs.

1. The eSignet login UI posts to `POST /flow/execute` several times (ID, OTP, consent). All return 200. OTP verification succeeded.
2. eSignet redirects the browser to `http://localhost:3030/api/portal/auth/callback?code=...&state=...&iss=http://localhost:8081`.
3. The gateway forwards to `iam-bene-api` `GET /auth/callback`.
4. IAM looks up `state` in Redis, loads the `login_providers` row, and reads the provider's endpoints.
5. IAM sends `POST http://localhost:8081/oauth2/token` with a form body. The client assertion is a form field in the request body, not a header:

   ```
   grant_type=authorization_code
   code=<code>
   redirect_uri=http://localhost:3030/api/portal/auth/callback
   code_verifier=<PKCE verifier>
   client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
   client_assertion=<JWT signed by IAM with the client private key>
   ```

6. eSignet answers 401 `invalid_client: Invalid client assertion`.
7. IAM raises `OAuthError` from `authlib` (`oidc_client.py`, `client.fetch_token`). The app's exception handler returns `G2P-REQ-100 Unknown Error`.

Steps that would follow if step 6 passed (read from code, not run): IAM stores the refresh token in Redis, sets the `X-Access-Token`, `X-ID-Token`, `X-Session-Id` and `X-CSRF-Token` cookies on a redirect to the dashboard, and the UI calls `GET /auth/get_user_profile`.

## What the client assertion is

A short JWT that proves the caller is the registered client. The client signs it with its private key. The provider verifies it with the public JWK registered for that client. The `kid` header says which registered key to use. The `jti` claim is a unique ID that lets the provider reject a replayed assertion.

This is the client authenticating to the provider. It is separate from the ID and access tokens that eSignet signs and returns later.

## How the staff API with Keycloak does it today

The staff provider row in `iam_staff.login_providers` is:

| id | provider_name | token_endpoint_auth_method | adapter_name | client_private_key | client_secret |
|---|---|---|---|---|---|
| 1 | Keycloak Staff | `client_secret_post` | `keycloak` | not set | set |

In `iam_core/user_auth/oidc_client.py`, `exchange_code_for_token` handles `client_secret_post` by passing `client_secret` and `token_endpoint_auth_method` to `AsyncOAuth2Client`. `authlib` posts `client_id` and `client_secret` in the form body. IAM signs no JWT, so no `kid` or `jti` is involved. The Keycloak adapter only normalizes roles and checks `sub`.

This path works, which is why the gap never showed in staff login.

## What was checked on the eSignet side

Goal: find another way for the client to authenticate, so no assertion is needed.

| Check | Result |
|---|---|
| `GET /.well-known/openid-configuration` | `token_endpoint_auth_methods_supported: ["private_key_jwt"]` |
| Token request with no client authentication | `invalid_client: Client authentication is required` |
| `esignet-service/internal/clientmgmt/validate.go`, `validateAuthMethods` | Rejects every value except `private_key_jwt` with `invalid_client_auth` |
| Env vars and YAML in `esignet-service` | No setting found that enables `client_secret_*` or a public client |
| Admin UI | None found. `oidc-ui` is the end-user login and consent UI. Clients are onboarded by `POST /client-mgmt/client` and `PUT /client-mgmt/client/{id}` (see `postman-collection/`) |

The `private_key_jwt`-only check in `validate.go` was introduced by eSignet commit `d736f9cd` (2026-06-30, "Updated client management endpoints to be backward compatible"), in the Go rewrite (`develop-go`). Later commits touch the file but not that line.

### Thunder engine source (read)

eSignet embeds `github.com/thunder-id/thunderid`, pinned by `go.mod` to commit `12f517c43840`. Go is not installed locally, so the source was cloned from GitHub at that commit and read directly.

- `backend/internal/oauth/oauth2/clientauth/clientauth.go` detects the method the caller used: `client_secret_basic`, `client_secret_post`, `private_key_jwt`, or `none` (public client). It then requires the method to equal the one stored on the OAuth client (`oauthApp.TokenEndpointAuthMethod != detectedMethod` returns an error). So Thunder itself supports secret-based and public clients.
- eSignet decides what each client is. `esignet-service/internal/engine/actor_provider.go` hard-codes `TokenEndpointAuthMethod: providers.TokenEndpointAuthMethodPrivateKeyJWT` (lines 88 and 139) and `PublicClient: false` (line 90) for every client it hands to the engine. There is no environment variable or YAML field that changes this.
- Result: the only way to allow secrets or a public client is to edit `actor_provider.go` and `validateAuthMethods` in `validate.go`. That is an eSignet source change, not configuration.

The same file confirms the assertion rules found by probing:

- `aud` must be a single string equal to the issuer (`clientauth.go`, around lines 248 to 253).
- The JWT header must contain a non-empty `kid`, and it must match a key in the client's registered JWKS (around lines 285 to 302). With no `kid` the verification fails.
- The payload must contain a non-empty string `jti`. It is recorded in a replay store, so each assertion is single use (`recordAssertionJTI`, around lines 313 to 329).

So with stock eSignet 2.0.0 there is no alternative: the client must authenticate with `private_key_jwt`, with `kid` and `jti`.

## Experiment: what eSignet requires in the assertion

Assertions signed with the client's real private key were sent straight to `POST /oauth2/token` with a fake `code`. An answer of `invalid_grant` means the assertion passed and only the fake code failed.

| Assertion variant | eSignet answer |
|---|---|
| As IAM builds it (`iss`, `sub`, `aud`, `iat`, `exp`) | `invalid_client` |
| plus `jti` only | `invalid_client` |
| plus `kid` header only | `invalid_client` |
| plus `jti` and `kid` | `invalid_grant: Invalid authorization code` (assertion accepted) |
| `aud` set to the token endpoint instead of the issuer, with `jti` and `kid` | `invalid_client` |
| `jti`, `kid`, `exp` one hour | `invalid_grant` (accepted) |

Conclusions: eSignet needs both `jti` and `kid`. The `aud` must be the issuer, `http://localhost:8081`. A one-hour `exp` is fine.

Ruled out: key mismatch. The private key stored in `iam_bene.login_providers`, the PEM file, and the public JWK registered in `esignet.client_detail` all share the same RSA modulus. The client record is `ACTIVE`.

## Where IAM misses it

File: `iam-core/src/iam_core/user_auth/helpers/client_assertion_helper.py`.

- `_jwt_payload` returns `iss`, `sub`, `aud`, `iat` and `exp`. It has no `jti`.
- `generate_private_key_client_assertion` builds the header as `{"typ": "JWT"}` and adds `kid` only if `kw.get("private_key_jwt_kid")` is a non-empty string.
- Nothing passes `private_key_jwt_kid`. The bene controller calls `complete_authentication_transaction(state_value=..., code=...)` and nothing else, so `**kw` is empty down the whole chain (`auth_service` to `oidc_base` to `oidc_client` to the helper). The only caller that passes it is the unit test `iam-core/tests/test_helpers_and_middleware.py:333`.
- The `login_providers` table has no column that could supply a `kid`.

History: the helper came in with `ba37320` "G2P-5128 IAM consolidation" (2026-06-12). The `kid` option was present from that commit, and `c762c7b` (2026-07-08) added its unit test. Neither added `jti`. The same code is on `github/1.4`, `origin/develop` and in the image commit `509f7ec`, so no branch has a fix.

Scope: the helper is shared. The staff, bene and agent apps all use it for any provider with `token_endpoint_auth_method = private_key_jwt`. Any of them would fail against eSignet 2.0.0 the same way. No staff or agent login through eSignet was run, so that part is from reading the shared code.

## Other findings from the same test

- The eSignet client was registered with `private_key_jwt`, PKCE, and the redirect URIs `http://localhost:3030/api/portal/auth/callback` and `http://localhost:3030/v1/selfservice/auth/callback`.
- The IAM provider row needed `jwt_assertion_aud`, `token_endpoint`, `authorization_endpoint`, `userinfo_endpoint` and `jwks_uri` set explicitly. IAM does not read them from discovery. Without them the earlier error was `token_endpoint (or jwt_assertion_aud) is required for client assertion.`
- eSignet needs `MOSIP_ESIGNET_OIDC_UI_PORT=3010`, otherwise it redirects to `localhost:3000/signin`.
- The nginx gateway needs `absolute_redirect off;`, otherwise redirects drop port 3030.

## Options to unblock

1. Fix `iam-core`: add a random `jti` to `_jwt_payload`, and take the `kid` from a provider setting (a new column or a key in existing extra config). One change covers all three apps.
2. Test the same change as a local, uncommitted patch mounted into the bene container, then send it upstream to `OpenG2P/iam`.
3. Report the gap to the OpenG2P maintainers and wait.

Option 1 has not been applied. The test instead switched versions, described below.

## Follow-up: running the versions OpenG2P deploys

`OpenG2P/openg2p-deployment` (`main`) pins eSignet in `charts/esignet`: chart `1.4.3`, `appVersion: 1.4.1`, images `mosipid/esignet:1.4.1` and `mosipid/oidc-ui:1.4.1`. `charts/mock-identity-system` pins `mosipid/mock-identity-system:0.9.3`. This is the Java eSignet generation.

Java eSignet added the `jti` requirement in v1.6.0 (commit `c5b775ae`, ES-2249, 2025-03-19; released 2025-07-14). Up to v1.5.x it required only `sub`, `aud`, `exp`, `iss` and `iat`, verified against the single registered JWK, so no `kid` is needed. The IAM helper sends exactly those five claims.

The test stack was moved to:

| Component | Version | Notes |
|---|---|---|
| eSignet | `mosipid/esignet:1.4.1`, `mosipid/oidc-ui:1.4.1`, `mosipid/mock-identity-system:0.9.3` | `compose/esignet-java/` in `openg2p-developer`, built from `mosip/esignet` tag `v1.4.1` `docker-compose/`. Host ports: service `8088`, UI `3011`, mock `8083`. Also runs `artifactory-server`, Kafka, Zookeeper and its own Postgres. |
| IAM bene API | `openg2p/iam-bene-portal-api:1.1.0` (2026-05-08) | Built from archived `OpenG2P/openg2p-iam-service` tag `v1.1.0`. Same routes as 1.4.0, has `private_key_jwt`, no refresh-token step. |
| Go eSignet 2.0.0 | retired | `docker compose down` in `esignet/docker-compose`. Images and databases kept. |

Result: the client assertion was accepted and the token exchange succeeded. After two more fixes the callback set the cookies, `get_user_profile` returned 200, and the portal dashboard loaded (confirmed in the browser on 2026-10-20).

Two further issues came up on the way, each written up separately:

- [eSignet 1.4.1 bundled compose configuration](esignet-1.4.1-compose-config-issues.md): missing cache names break `send-otp`, and the discovery `issuer` differs from the token `iss`.
- [IAM 1.2 and later require a refresh token](iam-refresh-token-required.md): why the current IAM image cannot complete an eSignet login, and why 1.1.0 is used.

Related: [Why eSignet issues no refresh token, and token lifetimes](esignet-no-refresh-token.md).
