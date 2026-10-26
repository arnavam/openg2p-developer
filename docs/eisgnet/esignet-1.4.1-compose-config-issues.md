# eSignet 1.4.1: bundled compose configuration errors

Status: found on 2026-10-20 during a local test of the Beneficiary Portal login. Fixed locally in `openg2p-developer/compose/esignet-java/config/esignet-default.properties` (1a) and in the IAM `login_providers` row (1b). Not reported upstream.

Context: eSignet 1.4.1 is the version OpenG2P deploys (`OpenG2P/openg2p-deployment`, `charts/esignet`, `appVersion: 1.4.1`). The local stack in `openg2p-developer/compose/esignet-java/` is built from `mosip/esignet` tag `v1.4.1`, directory `docker-compose/`, with images `mosipid/esignet:1.4.1`, `mosipid/oidc-ui:1.4.1` and `mosipid/mock-identity-system:0.9.3`. See [the client assertion finding](esignet-token-exchange-client-assertion.md) for why the test moved to this version.

All three problems are in `docker-compose/config/esignet-default.properties` from `mosip/esignet` tag `v1.4.1`. They are configuration errors in that file, not code bugs.

## 1a. Missing cache names break `send-otp`

Symptom: `POST /v1/esignet/authorization/send-otp` returns 500 with an empty message.

eSignet log:

```
java.lang.NullPointerException: null
    at io.mosip.esignet.services.CacheUtilService.getApiRateLimitTransaction(CacheUtilService.java:168)
```

Cause: `CacheUtilService` reads two caches, `apiRateLimit` (`Constants.RATE_LIMIT_CACHE`) and `blocked` (`Constants.BLOCKED_CACHE`). The file defines sizes and expiry for both in `mosip.esignet.cache.size` and `mosip.esignet.cache.expire-in-seconds`, but leaves them out of `mosip.esignet.cache.names`. With `spring.cache.type=simple` only listed caches are created, so `getCache(...)` returns null. The repo's own `esignet-service/src/main/resources/application-local.properties` at the same tag lists both names.

Fix applied locally: append `,apiRateLimit,blocked` to `mosip.esignet.cache.names` and restart eSignet.

## 1b. Discovery `issuer` differs from the token `iss`

Symptom: after a successful login, `GET /auth/get_user_profile` returns `{"errors":[{"code":"G2P-AUT-401","message":"Unauthorized"}]}`. IAM log: `Unauthorized. Unknown Issuer. http://localhost:8088/v1/esignet`.

Cause: two properties set the issuer, and they disagree.

| Property | Used for | Value |
|---|---|---|
| `mosip.esignet.discovery.issuer-id` = `${mosip.esignet.domain.url}${server.servlet.path}` | `iss` in issued tokens (`TokenServiceImpl.issuerId`) | `http://localhost:8088/v1/esignet` |
| `mosip.esignet.discovery.key-values` entry `'issuer': '${mosip.esignet.domain.url}'` | `issuer` in `/.well-known/openid-configuration` | `http://localhost:8088` |

IAM finds the provider for a token by exact match of the token `iss` against `login_providers.issuer`. The row had the discovery value, so no provider matched.

Fix applied: set `login_providers.issuer` to `http://localhost:8088/v1/esignet`. The cleaner fix is in the eSignet file: set the discovery `'issuer'` to `${mosip.esignet.discovery.issuer-id}`.

The Go eSignet 2.0.0 does not have this problem in its source: one value, `cfg.Issuer` from `MOSIP_ESIGNET_HOST`, feeds both discovery and `cfg.JWT.Issuer` (`internal/config/app.go:342`). No token was obtained from 2.0.0, so this is not confirmed at run time.

## 1c. Discovery `authorization_endpoint` points at the service, not the UI

Discovery `authorization_endpoint` is `${mosip.esignet.domain.url}/authorize`, which is the service host (`8088`). `/authorize` is a page of the login UI, which runs on its own host (`3011` here). The IAM row sets `authorization_endpoint` to `http://localhost:3011/authorize` explicitly.
