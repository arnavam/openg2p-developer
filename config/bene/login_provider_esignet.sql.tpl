-- eSignet login provider for the Beneficiary Portal (iam_bene.login_providers).
INSERT INTO public.login_providers (
    id, provider_name, description, client_id, client_private_key,
    token_endpoint_auth_method, server_metadata_url, jwt_assertion_aud,
    token_endpoint, authorization_endpoint, userinfo_endpoint, jwks_uri, adapter_name, scope,
    enable_pkce, extra_authorize_params, issuer, oauth_callback_url,
    default_redirect_uri, active, created_at
) VALUES (
    1,
    'eSignet',
    'Login with eSignet',
    'openg2p-beneficiary-esignet',
    convert_to($pem$__PRIVATE_KEY_PEM__$pem$, 'UTF8'),
    'private_key_jwt',
    'http://localhost:8081/.well-known/openid-configuration',
    'http://localhost:8081',
    'http://localhost:8081/oauth2/token',
    'http://localhost:8081/oauth2/authorize',
    'http://localhost:8081/oauth2/userinfo',
    'http://localhost:8081/oauth2/jwks',
    'esignet',
    'openid profile email',
    true,
    '{"acr_values":"mosip:idp:acr:generated-code mosip:idp:acr:password mosip:idp:acr:biometrics","claims":{"userinfo":{"name":{"essential":true},"phone_number":{"essential":false},"email":{"essential":false},"gender":{"essential":true},"birthdate":{"essential":true},"address":{"essential":false},"picture":{"essential":false}},"id_token":{}}}',
    'http://localhost:8081',
    'http://localhost:3030/api/portal/auth/callback',
    'http://localhost:3030/portal',
    true,
    now()
) ON CONFLICT (id) DO NOTHING;
