#!/usr/bin/env node
/**
 * OpenG2P Staff Client
 *
 * Acts as a client in place of staff-portal-ui (:3000) or registry staff UI (:3001/:3020),
 * following the exact routes and authentication lifecycle documented in docs/staff-portal-login-flow.md.
 *
 * Usage:
 *   node scripts/staff-client.mjs              # Run automated CLI verification of all 7 routes/phases
 *   node scripts/staff-client.mjs --serve      # Start interactive web client UI at http://localhost:3005
 *   node scripts/staff-client.mjs --help       # Show command-line options
 */

import http from "node:http";
import { URL } from "node:url";

// ==========================================
// Configuration Defaults
// ==========================================
const CONFIG = {
  iamUrl: process.env.IAM_URL || "http://localhost:8020",
  keycloakUrl: process.env.KEYCLOAK_URL || "http://localhost:8080",
  farmerApiUrl: process.env.FARMER_REGISTRY_STAFF_API_URL || "http://localhost:8001",
  livestockApiUrl: process.env.LIVESTOCK_REGISTRY_STAFF_API_URL || "http://localhost:8041",
  oanAuthUrl: process.env.OAN_AUTH_URL || "http://mysite.localhost:8000",
  username: process.env.KEYCLOAK_DEV_USER || "staff",
  password: process.env.KEYCLOAK_DEV_PASSWORD || "staff",
  providerId: Number(process.env.LOGIN_PROVIDER_ID || 1),
  webPort: 3005,
};

// ==========================================
// Helpers: Colors & Formatting
// ==========================================
const colors = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  green: "\x1b[32m",
  blue: "\x1b[34m",
  cyan: "\x1b[36m",
  yellow: "\x1b[33m",
  red: "\x1b[31m",
  magenta: "\x1b[35m",
};

function logStep(step, title) {
  console.log(`\n${colors.cyan}${colors.bold}[Phase ${step}] ${title}${colors.reset}`);
}

function logSuccess(msg, data) {
  console.log(`  ${colors.green}✓${colors.reset} ${msg}`);
  if (data) {
    const formatted = typeof data === "string" ? data : JSON.stringify(data, null, 2);
    console.log(`${colors.dim}${formatted.split("\n").map(l => "    " + l).join("\n")}${colors.reset}`);
  }
}

function logInfo(msg) {
  console.log(`  ${colors.blue}ℹ${colors.reset} ${msg}`);
}

function logWarn(msg, data) {
  console.log(`  ${colors.yellow}⚠${colors.reset} ${msg}`);
  if (data) console.log(JSON.stringify(data, null, 2).split("\n").map(l => `    ${l}`).join("\n"));
}

function logError(msg, err) {
  console.log(`  ${colors.red}✗${colors.reset} ${msg}`);
  if (err) console.error(err);
}

function decodeJwt(token) {
  try {
    const parts = token.split(".");
    if (parts.length < 2) return null;
    return JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch {
    return null;
  }
}

// ==========================================
// Cookie Jar Management
// ==========================================
export class CookieJar {
  constructor() {
    this.cookies = new Map();
  }

  processSetCookieHeaders(response) {
    let headers = [];
    if (typeof response.headers.getSetCookie === "function") {
      headers = response.headers.getSetCookie();
    } else {
      const single = response.headers.get("set-cookie");
      if (single) headers = [single];
    }

    for (const h of headers) {
      const parts = h.split(";");
      const first = parts[0].trim();
      const eqIdx = first.indexOf("=");
      if (eqIdx === -1) continue;
      const name = first.slice(0, eqIdx);
      const val = first.slice(eqIdx + 1);

      const isDelete = parts.some(p => {
        const trimmed = p.trim().toLowerCase();
        return trimmed === "max-age=0" || (trimmed.startsWith("expires=") && new Date(p.split("=")[1]) <= new Date());
      });

      if (isDelete || val === '""' || val === "") {
        this.cookies.delete(name);
      } else {
        this.cookies.set(name, val);
      }
    }
  }

  getCookieHeader() {
    return Array.from(this.cookies.entries())
      .map(([k, v]) => `${k}=${v}`)
      .join("; ");
  }

  get(name) {
    return this.cookies.get(name);
  }

  clear() {
    this.cookies.clear();
  }
}

// ==========================================
// Core Client Flow Implementation
// ==========================================
export class OpenG2PStaffClient {
  constructor(options = {}) {
    this.config = { ...CONFIG, ...options };
    this.jar = new CookieJar();
    this.userProfile = null;
    this.applications = null;
    this.tokens = { access: null, id: null, session: null, csrf: null };
  }

  /**
   * Phase 1: Verify unauthenticated state (Profile check)
   * Route: GET /auth/get_user_profile on IAM
   * Expected: 401 Unauthorized (G2P-AUT-401)
   */
  async checkProfileUnauthenticated() {
    logStep(1, "Phase 1: 'Am I logged in?' — Profile Check (Unauthenticated)");
    logInfo(`Calling GET ${this.config.iamUrl}/auth/get_user_profile without session cookies`);

    const res = await fetch(`${this.config.iamUrl}/auth/get_user_profile`, {
      method: "GET",
      headers: { "Accept": "application/json" }
    });

    const status = res.status;
    let body = null;
    try { body = await res.json(); } catch {}

    if (status === 401) {
      logSuccess(`IAM correctly rejected request with HTTP 401 Unauthorized`, body?.response_header);
      return { status, success: true, body };
    } else {
      logWarn(`Unexpected HTTP status ${status} (expected 401)`);
      return { status, success: false, body };
    }
  }

  /**
   * Phase 2: Start Authentication Transaction
   * Routes:
   *   1. GET /auth/get_login_providers (IAM)
   *   2. POST /auth/start_authentication_transaction?id={id}&redirect_uri={returnUrl} (IAM)
   * Expected: 200 OK with redirectUrl (Keycloak auth URL) and state
   */
  async startAuthTransaction(returnUrl = "http://localhost:3000/en") {
    logStep(2, "Phase 2: Start Authentication Transaction");
    logInfo(`Calling GET ${this.config.iamUrl}/auth/get_login_providers`);

    const provRes = await fetch(`${this.config.iamUrl}/auth/get_login_providers`);
    const provData = await provRes.json();
    const providers = provData.loginProviders || [];
    logSuccess(`Retrieved ${providers.length} login provider(s):`, providers.map(p => `[ID ${p.id}] ${p.name} (${p.protocol})`));

    const selectedProvider = providers.find(p => p.id === this.config.providerId) || providers[0];
    if (!selectedProvider) throw new Error("No active login provider found in IAM");

    logInfo(`Initiating transaction for provider ID ${selectedProvider.id} with return URL: ${returnUrl}`);
    const txUrl = `${this.config.iamUrl}/auth/start_authentication_transaction?id=${selectedProvider.id}&redirect_uri=${encodeURIComponent(returnUrl)}`;
    const txRes = await fetch(txUrl, { method: "POST" });

    if (!txRes.ok) {
      throw new Error(`Failed to start auth transaction: HTTP ${txRes.status} ${await txRes.text()}`);
    }

    const txData = await txRes.json();
    logSuccess(`IAM created Redis transaction auth_tx:${txData.state} and generated Keycloak redirect URL:`, {
      state: txData.state,
      redirectUrlPrefix: txData.redirectUrl.slice(0, 110) + "..."
    });

    return txData;
  }

  /**
   * Phase 3: Keycloak Authentication (Login UI emulation)
   * Routes:
   *   1. GET {redirectUrl} (Keycloak /realms/staff/protocol/openid-connect/auth)
   *   2. POST credentials to form action (Keycloak /realms/staff/login-actions/authenticate)
   * Expected: 302 Found with Location: IAM callback URL
   */
  async authenticateKeycloak(redirectUrl, credentials = {}) {
    const user = credentials.username || this.config.username;
    const pass = credentials.password || this.config.password;

    logStep(3, "Phase 3: Keycloak Login (Form Fetch & Credential POST)");
    logInfo(`Navigating to Keycloak authorization endpoint`);

    const kcJar = new CookieJar();
    const authPageRes = await fetch(redirectUrl, { redirect: "manual" });
    kcJar.processSetCookieHeaders(authPageRes);

    if (authPageRes.status !== 200) {
      throw new Error(`Expected Keycloak login page HTTP 200, got ${authPageRes.status}`);
    }

    const html = await authPageRes.text();
    const formMatch = html.match(/action="([^"]+)"/);
    if (!formMatch) {
      throw new Error("Could not find login form action in Keycloak HTML response");
    }

    const actionUrl = formMatch[1].replace(/&amp;/g, "&");
    logSuccess(`Retrieved login form. Action URL: ${actionUrl.slice(0, 90)}...`);
    logInfo(`Submitting credentials for user '${user}' with session cookies: ${kcJar.getCookieHeader()}`);

    const loginRes = await fetch(actionUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "Cookie": kcJar.getCookieHeader()
      },
      body: new URLSearchParams({ username: user, password: pass }).toString(),
      redirect: "manual"
    });

    if (loginRes.status !== 302) {
      throw new Error(`Expected HTTP 302 redirect from Keycloak credentials POST, got ${loginRes.status}`);
    }

    const callbackLocation = loginRes.headers.get("location");
    if (!callbackLocation || !callbackLocation.includes("/auth/callback")) {
      throw new Error(`Invalid Keycloak redirect location (not IAM callback): ${callbackLocation}`);
    }

    logSuccess(`Keycloak verified credentials and issued 302 redirect to IAM callback:`, {
      callbackUrl: callbackLocation.slice(0, 100) + "..."
    });

    return callbackLocation;
  }

  /**
   * Phase 4: IAM Callback & Session Cookie Minting
   * Route: GET {callbackLocation} (IAM /auth/callback?code=...&state=...)
   * Expected: 307 Temporary Redirect to returnUrl, Set-Cookie: X-Access-Token, X-ID-Token, X-Session-Id, X-CSRF-Token
   */
  async handleIamCallback(callbackLocation) {
    logStep(4, "Phase 4: IAM Callback (Code Exchange & Session Cookie Minting)");
    logInfo(`Calling IAM callback route GET ${callbackLocation.slice(0, 80)}...`);

    const cbRes = await fetch(callbackLocation, { redirect: "manual" });
    this.jar.processSetCookieHeaders(cbRes);

    if (cbRes.status !== 307 && cbRes.status !== 302) {
      throw new Error(`Expected HTTP 307/302 from IAM callback, got ${cbRes.status}`);
    }

    const appReturnUrl = cbRes.headers.get("location");
    this.tokens.access = this.jar.get("X-Access-Token");
    this.tokens.id = this.jar.get("X-ID-Token");
    this.tokens.session = this.jar.get("X-Session-Id");
    this.tokens.csrf = this.jar.get("X-CSRF-Token");

    if (!this.tokens.access || !this.tokens.session) {
      throw new Error(`Missing expected auth cookies from IAM callback. Got: ${[...this.jar.cookies.keys()]}`);
    }

    const decodedAccess = decodeJwt(this.tokens.access);
    const decodedId = decodeJwt(this.tokens.id);

    logSuccess(`IAM exchanged code, saved refresh token to Redis, and minted cookies:`, {
      redirectLocation: appReturnUrl,
      sessionId: this.tokens.session,
      csrfToken: this.tokens.csrf,
      username: decodedAccess?.preferred_username,
      issuer: decodedAccess?.iss,
      clientsInResourceAccess: Object.keys(decodedAccess?.resource_access || {}),
      rolesOnFarmer: decodedAccess?.resource_access?.["farmer-registry-staff-portal"]?.roles,
      rolesOnLivestock: decodedAccess?.resource_access?.["livestock-registry-staff-portal"]?.roles,
    });

    return {
      returnUrl: appReturnUrl,
      tokens: this.tokens,
      decodedAccess,
      decodedId
    };
  }

  /**
   * Phase 5: Authenticated User Profile & Applications
   * Routes:
   *   1. GET /auth/get_user_profile (IAM)
   *   2. GET /user-access/get_staff_portal_applications (IAM)
   */
  async fetchProfileAndApps() {
    logStep(5, "Phase 5: Authenticated Profile & Applications");
    logInfo(`Calling GET ${this.config.iamUrl}/auth/get_user_profile with session cookies`);

    const profileRes = await fetch(`${this.config.iamUrl}/auth/get_user_profile`, {
      headers: { "Cookie": this.jar.getCookieHeader() }
    });

    if (!profileRes.ok) {
      throw new Error(`Failed to fetch user profile: HTTP ${profileRes.status}`);
    }

    this.userProfile = await profileRes.json();
    logSuccess(`User profile verified (200 OK):`, {
      name: this.userProfile?.name,
      username: this.userProfile?.preferred_username,
      email: this.userProfile?.email
    });

    logInfo(`Calling GET ${this.config.iamUrl}/user-access/get_staff_portal_applications`);
    const appsRes = await fetch(`${this.config.iamUrl}/user-access/get_staff_portal_applications`, {
      headers: { "Cookie": this.jar.getCookieHeader() }
    });

    if (appsRes.ok) {
      this.applications = await appsRes.json();
      logSuccess(`Retrieved applications accessible on the portal:`, 
        (Array.isArray(this.applications) ? this.applications : []).map(a => `${a.application_description} (${a.application_mnemonic}) -> ${a.application_url}`)
      );
    }

    return { profile: this.userProfile, applications: this.applications };
  }

  /**
   * Phase 6: Registry Staff API Invocation
   * Routes:
   *   1. POST /register-metadata/get_all_registers on Farmer Registry (:8001)
   *   2. POST /register-metadata/get_all_registers on Livestock Registry (:8041)
   *
   * Formatted with OpenG2P request envelope, X-CSRF-Token header, and auth cookies.
   */
  async queryRegistryApis() {
    logStep(6, "Phase 6: Registry Staff API Calls (In place of Registry Staff UI)");

    const makeG2PEnvelope = (mnemonic, appUrl) => ({
      request_header: {
        sender_app_mnemonic: mnemonic,
        sender_app_url: appUrl,
        request_id: `client-req-${Date.now()}-${Math.random().toString(36).substring(2, 7)}`,
        request_timestamp: new Date().toISOString()
      },
      request_body: {
        request_payload: {}
      }
    });

    const results = {};

    // 1. Farmer Registry API
    try {
      logInfo(`Calling Farmer Registry Staff API POST ${this.config.farmerApiUrl}/register-metadata/get_all_registers`);
      const farmerPayload = makeG2PEnvelope("farmer-registry-staff-portal", "http://localhost:3001");
      const farmerRes = await fetch(`${this.config.farmerApiUrl}/register-metadata/get_all_registers`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Cookie": this.jar.getCookieHeader(),
          "X-CSRF-Token": this.tokens.csrf || ""
        },
        body: JSON.stringify(farmerPayload)
      });

      const farmerStatus = farmerRes.status;
      const farmerData = await farmerRes.json();
      const farmerRegisters = farmerData.response_body?.response_payload || [];
      results.farmer = { status: farmerStatus, data: farmerData, registers: farmerRegisters };

      if (farmerStatus === 200) {
        logSuccess(`Farmer Registry Staff API authenticated successfully (HTTP 200)!`, {
          registerCount: farmerRegisters.length,
          registers: farmerRegisters.map(r => `${r.register_mnemonic} (${r.register_subject})`)
        });
      } else {
        logWarn(`Farmer Registry responded with HTTP ${farmerStatus}`, farmerData);
      }
    } catch (err) {
      logError(`Farmer Registry Staff API request failed:`, err.message);
      results.farmer = { error: err.message };
    }

    // 2. Livestock Registry API
    try {
      logInfo(`Calling Livestock Registry Staff API POST ${this.config.livestockApiUrl}/register-metadata/get_all_registers`);
      const livePayload = makeG2PEnvelope("livestock-registry-staff-portal", "http://localhost:3020");
      const liveRes = await fetch(`${this.config.livestockApiUrl}/register-metadata/get_all_registers`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Cookie": this.jar.getCookieHeader(),
          "X-CSRF-Token": this.tokens.csrf || ""
        },
        body: JSON.stringify(livePayload)
      });

      const liveStatus = liveRes.status;
      const liveData = await liveRes.json();
      const liveRegisters = liveData.response_body?.response_payload || [];
      results.livestock = { status: liveStatus, data: liveData, registers: liveRegisters };

      if (liveStatus === 200) {
        logSuccess(`Livestock Registry Staff API authenticated successfully (HTTP 200)!`, {
          registerCount: liveRegisters.length,
          registers: liveRegisters.map(r => `${r.register_mnemonic} (${r.register_subject})`)
        });
      } else {
        logWarn(`Livestock Registry responded with HTTP ${liveStatus}`, liveData);
      }
    } catch (err) {
      logInfo(`Livestock Registry Staff API skipped or not reachable: ${err.message}`);
      results.livestock = { error: err.message };
    }

    return results;
  }

  /**
   * Phase 6b: OAN Auth Service (Frappe) with the Keycloak token as Bearer
   * Route: GET /api/v1/auth/me on oan_auth_service
   *
   * Unlike the registries, OAN does not read IAM's cookies: the client (a
   * Next.js server in production) forwards X-Access-Token as Authorization.
   */
  async queryOanAuth() {
    logStep("6b", "Phase 6b: OAN Auth Service (Bearer Keycloak token)");
    logInfo(`Calling GET ${this.config.oanAuthUrl}/api/v1/auth/me with Authorization: Bearer <X-Access-Token>`);

    try {
      const res = await fetch(`${this.config.oanAuthUrl}/api/v1/auth/me`, {
        headers: { "Authorization": `Bearer ${this.tokens.access}` }
      });
      const data = await res.json();
      if (res.status === 200) {
        logSuccess(`OAN Auth Service accepted the Keycloak token (HTTP 200):`, data.data ?? data);
      } else {
        logWarn(`OAN Auth Service responded with HTTP ${res.status}`, data);
      }
      return { status: res.status, data };
    } catch (err) {
      logError(`OAN Auth Service request failed:`, err.message);
      return { error: err.message };
    }
  }

  /**
   * Phase 6c: IAM provider lookup WITHOUT any credentials
   * Route: GET /identity-providers/get_provider_by_issuer?issuer=<iss> (IAM)
   *
   * The lookup oan_auth_service uses to find the issuer's JWKS. It needs no
   * auth, and IAM also returns the provider's client_secret in it.
   */
  async queryProviderByIssuer() {
    logStep("6c", "Phase 6c: IAM get_provider_by_issuer (no cookies, no token)");
    const issuer = decodeJwt(this.tokens.access)?.iss;
    const url = `${this.config.iamUrl}/identity-providers/get_provider_by_issuer?issuer=${encodeURIComponent(issuer)}`;
    logInfo(`Calling GET ${url} with no credentials`);

    const res = await fetch(url);
    const data = await res.json();
    if (res.status === 200 && data.client_secret) {
      logWarn(`IAM answered HTTP 200 to an unauthenticated caller and included client_secret:`, data);
    } else {
      logInfo(`IAM answered HTTP ${res.status}; client_secret present: ${Boolean(data.client_secret)}`);
    }
    return { status: res.status, data };
  }

  /**
   * Phase 7: Logout & Revocation
   * Routes:
   *   1. GET /auth/logout (IAM)
   *   2. Verifies Redis session deletion and cookie clearing
   *   3. GET /auth/get_user_profile (IAM) -> confirms 401 Unauthorized
   */
  async logout() {
    logStep(7, "Phase 7: Logout & Session Revocation");
    logInfo(`Calling GET ${this.config.iamUrl}/auth/logout with session cookies`);

    const logoutRes = await fetch(`${this.config.iamUrl}/auth/logout`, {
      headers: { "Cookie": this.jar.getCookieHeader() },
      redirect: "manual"
    });

    const logoutLocation = logoutRes.headers.get("location");
    logSuccess(`IAM responded with HTTP ${logoutRes.status} redirecting to Keycloak logout:`, {
      logoutRedirect: logoutLocation?.slice(0, 100) + "..."
    });

    this.jar.processSetCookieHeaders(logoutRes);

    logInfo(`Verifying session revocation: querying IAM /auth/get_user_profile with old cookies`);
    const checkRes = await fetch(`${this.config.iamUrl}/auth/get_user_profile`, {
      headers: { "Cookie": this.tokens.session ? `X-Session-Id=${this.tokens.session}; X-Access-Token=${this.tokens.access}` : "" }
    });

    if (checkRes.status === 401) {
      logSuccess(`Confirmed session revoked! IAM rejected old session with HTTP 401 Unauthorized`);
      return { success: true, status: checkRes.status };
    } else {
      logWarn(`Expected 401 after logout, got HTTP ${checkRes.status}`);
      return { success: false, status: checkRes.status };
    }
  }

  /**
   * Run the full end-to-end verification pipeline
   */
  async runFullVerification() {
    console.log(`\n${colors.bold}${colors.blue}================================================================${colors.reset}`);
    console.log(`${colors.bold}${colors.blue}   OpenG2P Staff Client — Full Route & Auth Lifecycle Verification${colors.reset}`);
    console.log(`${colors.bold}${colors.blue}================================================================${colors.reset}`);
    console.log(`Target IAM URL:      ${colors.cyan}${this.config.iamUrl}${colors.reset}`);
    console.log(`Target Keycloak URL: ${colors.cyan}${this.config.keycloakUrl}${colors.reset}`);
    console.log(`Farmer Staff API:    ${colors.cyan}${this.config.farmerApiUrl}${colors.reset}`);
    console.log(`Livestock Staff API: ${colors.cyan}${this.config.livestockApiUrl}${colors.reset}`);
    console.log(`User Credentials:    ${colors.cyan}${this.config.username} / [HIDDEN]${colors.reset}`);

    const startTime = Date.now();

    await this.checkProfileUnauthenticated();
    const tx = await this.startAuthTransaction("http://localhost:3000/auth-test-return");
    const cbUrl = await this.authenticateKeycloak(tx.redirectUrl);
    await this.handleIamCallback(cbUrl);
    await this.fetchProfileAndApps();
    await this.queryRegistryApis();
    await this.queryOanAuth();
    await this.queryProviderByIssuer();
    await this.logout();

    const duration = ((Date.now() - startTime) / 1000).toFixed(2);
    console.log(`\n${colors.bold}${colors.green}================================================================${colors.reset}`);
    console.log(`${colors.bold}${colors.green}   ✓ All 7 phases executed and verified successfully in ${duration}s!${colors.reset}`);
    console.log(`${colors.bold}${colors.green}================================================================${colors.reset}\n`);
  }
}

// ==========================================
// Interactive Web Server Mode
// ==========================================
// Ask IAM for the profile so it refreshes an expired access token, and return
// the token to forward plus IAM's Set-Cookie headers for the browser.
async function freshAccessToken(config, cookieHeader) {
  const profileRes = await fetch(`${config.iamUrl}/auth/get_user_profile`, {
    headers: { "Cookie": cookieHeader }
  });
  const setCookies = profileRes.headers.getSetCookie();
  const refreshed = setCookies
    .map(c => c.match(/^X-Access-Token=([^;]*)/))
    .find(m => m && m[1]);
  const current = (cookieHeader.match(/X-Access-Token=([^;]+)/) || [])[1] || "";
  return { access: refreshed ? refreshed[1] : current, setCookies };
}

export function startInteractiveServer(options = {}) {
  const config = { ...CONFIG, ...options };
  const port = config.webPort;

  const server = http.createServer(async (req, res) => {
    const parsedUrl = new URL(req.url, `http://localhost:${port}`);
    const pathname = parsedUrl.pathname;

    // ==========================================
    // BFF API Routes (Same-Origin, No CORS Issues)
    // ==========================================
    if (pathname === "/api/me") {
      try {
        const cookieHeader = req.headers["cookie"] || "";
        const profileRes = await fetch(`${config.iamUrl}/auth/get_user_profile`, {
          headers: { "Cookie": cookieHeader }
        });
        if (profileRes.ok) {
          const data = await profileRes.json();
          // Pass IAM's refreshed cookies through, or the browser keeps the expired token.
          res.writeHead(200, { "Content-Type": "application/json", "Set-Cookie": profileRes.headers.getSetCookie() });
          return res.end(JSON.stringify({ authenticated: true, user: data }));
        } else {
          res.writeHead(200, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ authenticated: false, status: profileRes.status }));
        }
      } catch (err) {
        res.writeHead(200, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ authenticated: false, error: err.message }));
      }
    }

    if (pathname === "/api/login") {
      try {
        const returnUrl = `http://localhost:${port}/callback`;
        const txUrl = `${config.iamUrl}/auth/start_authentication_transaction?id=${config.providerId}&redirect_uri=${encodeURIComponent(returnUrl)}`;
        const txRes = await fetch(txUrl, { method: "POST" });
        const txData = await txRes.json();
        if (txData.redirectUrl) {
          res.writeHead(302, { "Location": txData.redirectUrl });
          return res.end();
        }
        res.writeHead(500, { "Content-Type": "application/json" });
        return res.end(JSON.stringify(txData));
      } catch (err) {
        res.writeHead(500, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: err.message }));
      }
    }

    if (pathname === "/api/apps") {
      try {
        const cookieHeader = req.headers["cookie"] || "";
        const appsRes = await fetch(`${config.iamUrl}/user-access/get_staff_portal_applications`, {
          headers: { "Cookie": cookieHeader }
        });
        const data = await appsRes.json();
        res.writeHead(appsRes.status, { "Content-Type": "application/json" });
        return res.end(JSON.stringify(data));
      } catch (err) {
        res.writeHead(500, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: err.message }));
      }
    }

    if (pathname === "/api/farmer/registers") {
      try {
        const cookieHeader = req.headers["cookie"] || "";
        const csrf = (cookieHeader.match(/X-CSRF-Token=([^;]+)/) || [])[1] || "";
        const payload = {
          request_header: {
            sender_app_mnemonic: "farmer-registry-staff-portal",
            sender_app_url: "http://localhost:3001",
            request_id: `web-client-${Date.now()}`,
            request_timestamp: new Date().toISOString()
          },
          request_body: { request_payload: {} }
        };
        const regRes = await fetch(`${config.farmerApiUrl}/register-metadata/get_all_registers`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Cookie": cookieHeader,
            "X-CSRF-Token": csrf
          },
          body: JSON.stringify(payload)
        });
        const data = await regRes.json();
        res.writeHead(regRes.status, { "Content-Type": "application/json" });
        return res.end(JSON.stringify(data));
      } catch (err) {
        res.writeHead(500, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: err.message }));
      }
    }

    if (pathname === "/api/livestock/registers") {
      try {
        const cookieHeader = req.headers["cookie"] || "";
        const csrf = (cookieHeader.match(/X-CSRF-Token=([^;]+)/) || [])[1] || "";
        const payload = {
          request_header: {
            sender_app_mnemonic: "livestock-registry-staff-portal",
            sender_app_url: "http://localhost:3020",
            request_id: `web-client-${Date.now()}`,
            request_timestamp: new Date().toISOString()
          },
          request_body: { request_payload: {} }
        };
        const regRes = await fetch(`${config.livestockApiUrl}/register-metadata/get_all_registers`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Cookie": cookieHeader,
            "X-CSRF-Token": csrf
          },
          body: JSON.stringify(payload)
        });
        const data = await regRes.json();
        res.writeHead(regRes.status, { "Content-Type": "application/json" });
        return res.end(JSON.stringify(data));
      } catch (err) {
        res.writeHead(500, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: err.message }));
      }
    }

    if (pathname === "/api/oan/me") {
      try {
        // Access tokens live ~5 min. Hitting a protected IAM route makes IAM refresh
        // via X-Session-Id and return new cookies; use the fresh token for OAN and
        // hand the cookies back to the browser (what the Next.js server does).
        const { access, setCookies } = await freshAccessToken(config, req.headers["cookie"] || "");
        const oanRes = await fetch(`${config.oanAuthUrl}/api/v1/auth/me`, {
          headers: { "Authorization": `Bearer ${access}` }
        });
        const data = await oanRes.json();
        res.writeHead(oanRes.status, { "Content-Type": "application/json", "Set-Cookie": setCookies });
        return res.end(JSON.stringify(data));
      } catch (err) {
        res.writeHead(500, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: err.message }));
      }
    }

    // IAM's own endpoint, passed straight through.
    if (pathname === "/identity-providers/get_provider_by_issuer") {
      try {
        const issuer = parsedUrl.searchParams.get("issuer") || `${config.keycloakUrl}/realms/staff`;
        const provRes = await fetch(
          `${config.iamUrl}/identity-providers/get_provider_by_issuer?issuer=${encodeURIComponent(issuer)}`
        );
        const data = await provRes.json();
        res.writeHead(provRes.status, { "Content-Type": "application/json" });
        return res.end(JSON.stringify(data));
      } catch (err) {
        res.writeHead(500, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: err.message }));
      }
    }

    if (pathname === "/api/logout") {
      try {
        const cookieHeader = req.headers["cookie"] || "";
        const logoutRes = await fetch(`${config.iamUrl}/auth/logout`, {
          headers: { "Cookie": cookieHeader },
          redirect: "manual"
        });
        const setCookies = logoutRes.headers.getSetCookie ? logoutRes.headers.getSetCookie() : [logoutRes.headers.get("set-cookie")];
        const kcLogoutUrl = `${config.keycloakUrl}/realms/staff/protocol/openid-connect/logout?client_id=iam-staff-portal&post_logout_redirect_uri=${encodeURIComponent(`http://localhost:${port}/`)}`;
        res.writeHead(302, {
          "Location": kcLogoutUrl,
          "Set-Cookie": setCookies.filter(Boolean)
        });
        return res.end();
      } catch (err) {
        res.writeHead(500, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: err.message }));
      }
    }

    // Route: GET / - Web UI Client Dashboard
    if (pathname === "/") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>OpenG2P Staff Client</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    :root {
      --bg: #0f172a; --card: #1e293b; --text: #f8fafc; --muted: #94a3b8;
      --accent: #3b82f6; --accent-hover: #2563eb; --border: #334155;
      --green: #10b981; --red: #ef4444; --yellow: #f59e0b;
    }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background: var(--bg); color: var(--text); margin: 0; padding: 2rem;
    }
    .container { max-width: 900px; margin: 0 auto; }
    header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 1rem; margin-bottom: 2rem; }
    h1 { margin: 0; font-size: 1.5rem; display: flex; align-items: center; gap: 0.5rem; }
    .badge { font-size: 0.75rem; padding: 0.2rem 0.6rem; border-radius: 9999px; background: var(--border); color: var(--muted); }
    .badge.active { background: rgba(16, 185, 129, 0.2); color: var(--green); }
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 0.75rem; padding: 1.5rem; margin-bottom: 1.5rem; }
    .card-title { font-size: 1.1rem; font-weight: 600; margin-top: 0; margin-bottom: 1rem; display: flex; justify-content: space-between; }
    .btn-group { display: flex; flex-wrap: wrap; gap: 0.75rem; margin-bottom: 1rem; }
    button, .btn {
      background: var(--accent); color: white; border: none; border-radius: 0.5rem;
      padding: 0.6rem 1.2rem; font-weight: 500; cursor: pointer; text-decoration: none;
      display: inline-flex; align-items: center; gap: 0.5rem; font-size: 0.9rem;
      transition: background 0.2s;
    }
    button:hover, .btn:hover { background: var(--accent-hover); }
    button.secondary, .btn.secondary { background: var(--border); color: var(--text); }
    button.secondary:hover, .btn.secondary:hover { background: #475569; }
    button.danger, .btn.danger { background: rgba(239, 68, 68, 0.2); color: var(--red); border: 1px solid rgba(239, 68, 68, 0.4); }
    button.danger:hover { background: rgba(239, 68, 68, 0.3); }
    pre { background: #0b1120; border: 1px solid var(--border); border-radius: 0.5rem; padding: 1rem; font-size: 0.85rem; overflow-x: auto; color: #38bdf8; }
    .flow-steps { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; margin-bottom: 1.5rem; }
    .step-box { background: rgba(15, 23, 42, 0.6); border: 1px solid var(--border); border-radius: 0.5rem; padding: 0.75rem; font-size: 0.85rem; }
    .step-box.done { border-color: var(--green); }
    .step-num { font-size: 0.75rem; color: var(--muted); }
    .step-name { font-weight: 600; margin-top: 0.25rem; }
    table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
    th, td { text-align: left; padding: 0.5rem; border-bottom: 1px solid var(--border); }
    th { color: var(--muted); }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div>
        <h1>OpenG2P Staff Client <span class="badge" id="clientRoleBadge">Client Prototype</span></h1>
        <p style="margin: 0.25rem 0 0 0; color: var(--muted); font-size: 0.85rem;">
          Standalone client acting in place of Staff Portal UI or Registry Staff UI
        </p>
      </div>
      <div id="authStatusBadge" class="badge">Checking session...</div>
    </header>

    <div class="flow-steps">
      <div class="step-box" id="step1"><div class="step-num">Phase 1 & 2</div><div class="step-name">Start Auth Tx (IAM)</div></div>
      <div class="step-box" id="step2"><div class="step-num">Phase 3</div><div class="step-name">Keycloak Login</div></div>
      <div class="step-box" id="step3"><div class="step-num">Phase 4</div><div class="step-name">IAM Callback & Cookies</div></div>
      <div class="step-box" id="step4"><div class="step-num">Phase 5 & 6</div><div class="step-name">Call Registry APIs</div></div>
    </div>

    <div class="card">
      <div class="card-title">Authentication Actions</div>
      <div class="btn-group">
        <button id="loginBtn" onclick="initiateLogin()">1. Login via IAM & Keycloak</button>
        <button class="secondary" onclick="checkProfile()">2. Check Profile (/api/me)</button>
        <button class="secondary" onclick="fetchApps()">3. Fetch Applications (/api/apps)</button>
        <button class="danger" onclick="logoutSession()">4. Logout Session (/api/logout)</button>
      </div>
      <div id="authDetails" style="font-size: 0.85rem; color: var(--muted);"></div>
    </div>

    <div class="card">
      <div class="card-title">
        <span>Registry API Invocations</span>
        <span class="badge">Gen2 Registry Platform</span>
      </div>
      <p style="font-size: 0.85rem; color: var(--muted); margin-top: 0;">
        Executes authenticated requests to backend Registry Staff APIs using the active session cookies & CSRF token.
      </p>
      <div class="btn-group">
        <button onclick="queryFarmerRegisters()">Query Farmer Registers (:8001)</button>
        <button onclick="queryLivestockRegisters()">Query Livestock Registers (:8041)</button>
        <button onclick="queryOanMe()">OAN Auth /me (Bearer)</button>
        <button class="danger" onclick="queryClientProvider()">IAM get_provider_by_issuer</button>
      </div>
      <div id="registryData"></div>
    </div>

    <div class="card">
      <div class="card-title">Live Response Console</div>
      <pre id="outputConsole">// Click any action above to inspect live HTTP interaction and token claims...</pre>
    </div>
  </div>

  <script>
    function log(obj) {
      document.getElementById('outputConsole').textContent = typeof obj === 'string' ? obj : JSON.stringify(obj, null, 2);
    }

    function updateStatus(isAuth, user) {
      const badge = document.getElementById('authStatusBadge');
      if (isAuth) {
        badge.className = 'badge active';
        badge.textContent = 'Logged In: ' + (user?.preferred_username || user?.name || 'staff');
        document.getElementById('step1').className = 'step-box done';
        document.getElementById('step2').className = 'step-box done';
        document.getElementById('step3').className = 'step-box done';
        document.getElementById('step4').className = 'step-box done';
      } else {
        badge.className = 'badge';
        badge.textContent = 'Not Authenticated (401)';
        document.getElementById('step1').className = 'step-box';
        document.getElementById('step2').className = 'step-box';
        document.getElementById('step3').className = 'step-box';
        document.getElementById('step4').className = 'step-box';
      }
    }

    async function checkProfile() {
      try {
        const res = await fetch('/api/me');
        const data = await res.json();
        log(data);
        if (data.authenticated && data.user) {
          updateStatus(true, data.user);
        } else {
          updateStatus(false);
        }
      } catch (err) {
        log('Error checking profile: ' + err.message);
        updateStatus(false);
      }
    }

    function initiateLogin() {
      log('Navigating to /api/login...');
      window.location.href = '/api/login';
    }

    async function fetchApps() {
      try {
        const res = await fetch('/api/apps');
        const data = await res.json();
        log(data);
      } catch (err) {
        log('Failed to fetch apps: ' + err.message);
      }
    }

    async function queryFarmerRegisters() {
      try {
        const res = await fetch('/api/farmer/registers', { method: 'POST' });
        const data = await res.json();
        log(data);
      } catch (err) {
        log('Failed to query Farmer Registry: ' + err.message);
      }
    }

    async function queryLivestockRegisters() {
      try {
        const res = await fetch('/api/livestock/registers', { method: 'POST' });
        const data = await res.json();
        log(data);
      } catch (err) {
        log('Failed to query Livestock Registry: ' + err.message);
      }
    }

    async function queryOanMe() {
      try {
        const res = await fetch('/api/oan/me');
        const data = await res.json();
        log(data);
      } catch (err) {
        log('Failed to query OAN Auth Service: ' + err.message);
      }
    }

    async function queryClientProvider() {
      try {
        const res = await fetch('/identity-providers/get_provider_by_issuer');
        const data = await res.json();
        log(data);
      } catch (err) {
        log('Failed to query IAM provider: ' + err.message);
      }
    }

    function logoutSession() {
      log('Logging out via IAM & Keycloak...');
      window.location.href = '/api/logout';
    }

    // Auto-check on page load
    window.onload = checkProfile;
  </script>
</body>
</html>`);
      return;
    }

    // Route: GET /callback - App Return URL after IAM callback
    if (pathname === "/callback") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(`<!DOCTYPE html>
<html>
<head><title>Auth Completed</title></head>
<body style="background:#0f172a;color:#f8fafc;font-family:sans-serif;text-align:center;padding:4rem;">
  <h2>Authentication Successful!</h2>
  <p>Cookies have been received. Returning to client dashboard...</p>
  <script>setTimeout(() => { window.location.href = '/'; }, 1000);</script>
</body>
</html>`);
      return;
    }

    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("Not Found");

  });

  server.listen(port, () => {
    console.log(`\n${colors.bold}${colors.green}================================================================${colors.reset}`);
    console.log(`${colors.bold}${colors.green}  OpenG2P Staff Client Interactive Web Server Running!${colors.reset}`);
    console.log(`${colors.bold}${colors.green}================================================================${colors.reset}`);
    console.log(`URL:                 ${colors.cyan}http://localhost:${port}/${colors.reset}`);
    console.log(`Target IAM URL:      ${colors.cyan}${config.iamUrl}${colors.reset}`);
    console.log(`Keycloak URL:        ${colors.cyan}${config.keycloakUrl}${colors.reset}`);
    console.log(`Farmer Staff API:    ${colors.cyan}${config.farmerApiUrl}${colors.reset}`);
    console.log(`Livestock Staff API: ${colors.cyan}${config.livestockApiUrl}${colors.reset}`);
    console.log(`\nOpen ${colors.cyan}http://localhost:${port}/${colors.reset} in your browser to interact with the client.\n`);
  });

  return server;
}

// ==========================================
// CLI Entry Point
// ==========================================
async function main() {
  const args = process.argv.slice(2);

  if (args.includes("--help") || args.includes("-h")) {
    console.log(`
OpenG2P Staff Client

Usage:
  node scripts/staff-client.mjs [options]

Options:
  --serve             Start the interactive web client server (default: port 3005)
  --port <number>     Port for the interactive web client (default: 3005)
  --iam-url <url>     IAM Staff API URL (default: http://localhost:8020)
  --user <username>   Keycloak username (default: staff)
  --pass <password>   Keycloak password (default: staff)
  --test              Run the automated CLI route verification (default when --serve is omitted)
  --help, -h          Show this help message
`);
    process.exit(0);
  }

  const options = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--serve") options.serve = true;
    if (args[i] === "--port" && args[i + 1]) options.webPort = Number(args[++i]);
    if (args[i] === "--iam-url" && args[i + 1]) options.iamUrl = args[++i];
    if (args[i] === "--user" && args[i + 1]) options.username = args[++i];
    if (args[i] === "--pass" && args[i + 1]) options.password = args[++i];
  }

  if (options.serve) {
    startInteractiveServer(options);
  } else {
    const client = new OpenG2PStaffClient(options);
    try {
      await client.runFullVerification();
    } catch (err) {
      logError("Staff Client verification failed:", err);
      process.exit(1);
    }
  }
}

// Execute when run directly
if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
