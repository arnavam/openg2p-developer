# eSignet issues no refresh token, and how long its tokens last

Status: finding from source reading on 2026-10-20, during a local test of the Beneficiary Portal login. No code was changed.

Related: [IAM 1.2 and later require a refresh token](iam-refresh-token-required.md), which is where this becomes a problem.

## What eSignet does

eSignet allows only the `authorization_code` grant, in both generations, so it never returns a `refresh_token`.

| eSignet | Evidence |
|---|---|
| Java 1.x (`mosip/esignet` tags v1.4.1 and v1.8.0 checked) | No `refresh_token` handling anywhere in the Java source. |
| Go 2.0.0 (`mosip/esignet`, `esignet-service/`) | The embedded Thunder engine (`thunder-id/thunderid` at `12f517c43840`) can issue refresh tokens. `backend/internal/oauth/oauth2/token/service.go` issues one when the grant supports it and the client allows the `refresh_token` grant. eSignet prevents this in two places. `internal/engine/actor_provider.go:85` hard-codes every client to `GrantTypes: []providers.GrantType{providers.GrantTypeAuthorizationCode}`. `internal/clientmgmt/validate.go`, `validateGrantTypes`, rejects any grant type other than `authorization_code` at registration (`invalid_grant_type`). |

In the Go version this is a deliberate restriction in eSignet's own code, because the engine underneath supports refresh tokens.

## Why: what MOSIP says

Nothing explicit was found.

- `docs.esignet.io` (asked on 2026-10-20) has no mention of refresh tokens or a reason for leaving them out.
- `mosip/esignet` GitHub issues and pull requests: the only reference is issue #2007, "eSignet- Thunder: Review Access Token and ID Token for Functional Gaps", which says "refresh token, userinfo are out of scope" without a reason.

## Why: what the code implies

eSignet stores no identity data. It brokers a login to an ID system.

1. At login the user authenticates with OTP or biometrics. eSignet calls the ID system's `kyc-auth`, then `kyc-exchange`, and receives the user's claims.
2. eSignet caches those claims for the access token's lifetime. In the 1.4.1 compose configuration the cache expiry entry is `'userinfo': ${mosip.esignet.access-token-expire-seconds}`.
3. After that, eSignet holds nothing it could serve. New claims need a new KYC exchange, which the ID system only allows after a fresh authentication by the user.

A refresh token promises new tokens without the user present. eSignet could not back those tokens with data, because the ID system releases data only on a live authentication. Refresh tokens would contradict how eSignet gets its data.

This is a reading of the design from the code, not a statement by MOSIP.

## Token lifetimes

| Item | Value | Source |
|---|---|---|
| Access token, Java 1.4.1 | 3600 s | `mosip.esignet.access-token-expire-seconds=3600` in `compose/esignet-java/config/esignet-default.properties` |
| ID token, Java 1.4.1 | 3600 s | `mosip.esignet.id-token-expire-seconds=3600`, same file |
| Cached userinfo, Java 1.4.1 | same as the access token | `mosip.esignet.cache.expire-in-seconds`, entry `'userinfo'` |
| Access token, Go 2.0.0 | 120 s by default | `jwt.validity_period: 120` in `esignet-service/data/deployment.yaml`, override `MOSIP_ESIGNET_JWT_VALIDITY_PERIOD`. eSignet sets no per-client access token lifetime in `actor_provider.go`, so Thunder falls back to `cfg.JWT.ValidityPeriod` (`backend/internal/oauth/oauth2/tokenservice/utils.go`). Read from source, not observed. |
| Authorization code, Go 2.0.0 | 60 s | `oauth.authorization_code.validity_period: 60`, same file |
| IAM bene session cookie | 1800 s | `IAM_BENE_AUTH_COOKIE_MAX_AGE=1800` in `config/bene/iam-bene-portal-api.env` |

## Is that long enough

- Current local setup (Java 1.4.1 with IAM bene 1.1.0): the session lasts 30 minutes, limited by the IAM cookie, then the user logs in again. That is reasonable for a beneficiary portal. The cookie can be raised to 3600 s to match the token, but not beyond the token's expiry.
- Go 2.0.0 at its default: 2 minutes is too short for a portal session without refresh tokens. A deployment would have to raise `MOSIP_ESIGNET_JWT_VALIDITY_PERIOD`. That setting also covers other JWTs eSignet signs, so its wider effect needs checking.
- A refresh token is not needed for this flow. The portal can treat eSignet as a login, run its own session, and send the user back to eSignet when it ends. The gap is in IAM, which since 1.2 assumes every provider issues a refresh token.
