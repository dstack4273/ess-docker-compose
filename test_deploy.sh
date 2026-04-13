#!/bin/bash
# =============================================================================
# test_deploy.sh — Integration test suite for deploy.sh
#
# Scenarios:
#   A) TLD identity:       SERVER_NAME=example.test        (@user:example.test)
#   B) Subdomain identity: SERVER_NAME=matrix.example.test  (@user:matrix.example.test)
#
# Each scenario:
#   1. Runs deploy.sh with pre-set stdin
#   2. Validates all generated config files
#   3. Hits live endpoints via curl (Caddy:443 → 127.0.0.1)
#   4. Tears down the stack and cleans up
#
# Usage:
#   ./test_deploy.sh                       # full suite (config + endpoints)
#   SKIP_INTEGRATION=true ./test_deploy.sh # config-file checks only (no endpoint tests)
#
# Requires: docker, docker compose v2, bash ≥ 4, openssl, curl
# =============================================================================

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

# ─── Config ───────────────────────────────────────────────────────────────────
SKIP_INTEGRATION="${SKIP_INTEGRATION:-false}"
COMPOSE_FILE="compose-variants/docker-compose.local.yml"
COMPOSE_CMD="sudo docker compose --project-directory ."

# ─── Counters ─────────────────────────────────────────────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0

# ─── Output helpers ───────────────────────────────────────────────────────────
pass()   { echo -e "  ${GREEN}✓${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail()   { echo -e "  ${RED}✗${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
info()   { echo -e "  ${BLUE}ℹ${NC} $1"; }
warn()   { echo -e "  ${YELLOW}⚠${NC} $1"; }
header() { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"; }
section(){ echo -e "\n${BOLD}${MAGENTA}════ $1 ════${NC}"; }

# ─── Sudo shim for root CI environments that lack sudo ───────────────────────
setup_sudo_shim() {
    if ! command -v sudo &>/dev/null; then
        local d; d=$(mktemp -d)
        printf '#!/bin/sh\nexec "$@"\n' > "$d/sudo"
        chmod +x "$d/sudo"
        export PATH="$d:$PATH"
        info "Created sudo passthrough shim (running as root)"
    fi
}

# ─── Prerequisites ────────────────────────────────────────────────────────────
check_prereqs() {
    header "Prerequisites"
    local ok=true

    for cmd in bash openssl curl; do
        command -v "$cmd" &>/dev/null \
            && pass "$cmd available" \
            || { fail "$cmd not found"; ok=false; }
    done

    sudo docker ps &>/dev/null \
        && pass "Docker daemon reachable" \
        || { fail "Docker not accessible (sudo docker ps failed)"; ok=false; }

    sudo docker compose version &>/dev/null \
        && pass "docker compose v2 available" \
        || { fail "docker compose not available"; ok=false; }

    [[ -f deploy.sh ]] \
        || { fail "deploy.sh not found — run from repo root"; ok=false; }

    [[ "$ok" == "true" ]] || { echo -e "\n${RED}Prerequisites failed. Aborting.${NC}"; exit 1; }
}

# ─── Stop stack and wipe all data volumes ─────────────────────────────────────
teardown_stack() {
    info "Stopping Docker stack and removing volumes..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    sudo rm -rf postgres/data mas/data mas/certs caddy/data caddy/config 2>/dev/null || true
    # Wipe synapse/data fully so no leftover signing keys or log configs
    # confuse the next scenario's `docker run ... generate` step
    sudo rm -rf synapse/data 2>/dev/null || true
    mkdir -p synapse/data
}

# ─── Remove all generated config files ────────────────────────────────────────
cleanup_configs() {
    info "Removing generated configs..."
    rm -f .env mas-signing.key authelia_private.pem
    rm -f caddy/Caddyfile caddy/Caddyfile.production
    rm -f livekit/livekit.yaml
    rm -f appservices/doublepuppet.yaml
    # These may be root-owned from docker run or previous deploys
    sudo rm -f mas/config/config.yaml 2>/dev/null || true
    sudo rm -f element/config/config.json 2>/dev/null || true
    sudo rm -f authelia/config/configuration.yml authelia/config/users_database.yml 2>/dev/null || true
    sudo rm -f synapse/data/homeserver.yaml synapse/data/homeserver.yaml.bak 2>/dev/null || true
}

# ─── Assertions ───────────────────────────────────────────────────────────────
assert_file() {
    local file="$1" label="$2"
    [[ -f "$file" ]] && pass "$label" || fail "$label  (missing: $file)"
}

assert_contains() {
    local file="$1" pattern="$2" label="$3"
    if grep -qF "$pattern" "$file" 2>/dev/null; then
        pass "$label"
    else
        fail "$label  [expected '${pattern}' in ${file}]"
    fi
}

assert_not_contains() {
    local file="$1" pattern="$2" label="$3"
    if grep -qF "$pattern" "$file" 2>/dev/null; then
        fail "$label  [unexpected '${pattern}' found in ${file}]"
    else
        pass "$label"
    fi
}

# Regex variant — use when the value may be quoted/unquoted (grep -E)
assert_matches() {
    local file="$1" pattern="$2" label="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$label"
    else
        fail "$label  [expected /$pattern/ in ${file}]"
    fi
}

# ─── Config-file assertions (no Docker needed) ────────────────────────────────
assert_configs() {
    local server_name="$1"
    local matrix_domain="matrix.example.test"

    header "Config assertions  (SERVER_NAME=${server_name})"

    # .env
    assert_file ".env" ".env generated"
    assert_contains ".env" "SERVER_NAME=${server_name}"          ".env → SERVER_NAME"
    assert_contains ".env" "MATRIX_DOMAIN=${matrix_domain}"      ".env → MATRIX_DOMAIN"

    # MAS config
    assert_file "mas/config/config.yaml" "mas/config/config.yaml generated"
    assert_contains "mas/config/config.yaml" \
        "homeserver: '${server_name}'"                           "MAS → homeserver"
    assert_contains "mas/config/config.yaml" \
        "name: adminapi"                                         "MAS → adminapi listener present"

    # Element Web config (heredoc format has spaces: `"key": "value"`)
    assert_file "element/config/config.json" "element/config/config.json generated"
    assert_contains "element/config/config.json" \
        "\"server_name\": \"${server_name}\""                    "Element → server_name"
    assert_contains "element/config/config.json" \
        "\"default_server_name\": \"${server_name}\""            "Element → default_server_name"
    assert_contains "element/config/config.json" \
        "\"base_url\": \"https://${matrix_domain}\""             "Element → base_url stays matrix domain"

    # Synapse homeserver.yaml
    assert_file "synapse/data/homeserver.yaml" "synapse/data/homeserver.yaml generated"
    # Synapse may quote the value: `server_name: "example.test"` or `server_name: example.test`
    assert_matches "synapse/data/homeserver.yaml" \
        "^server_name: \"?${server_name//./\\.}\"?" "Synapse → server_name"
    assert_contains "synapse/data/homeserver.yaml" \
        "app_service_config_files:"                          "Synapse → app_service_config_files present"
    assert_contains "synapse/data/homeserver.yaml" \
        "/appservices/doublepuppet.yaml"                     "Synapse → doublepuppet.yaml registered"

    # Double-puppeting appservice
    assert_file "appservices/doublepuppet.yaml" "appservices/doublepuppet.yaml generated"
    assert_contains "appservices/doublepuppet.yaml" \
        "id: doublepuppet"                                   "doublepuppet.yaml → id"
    assert_contains "appservices/doublepuppet.yaml" \
        "url: null"                                          "doublepuppet.yaml → url null"
    assert_contains "appservices/doublepuppet.yaml" \
        "as_token:"                                          "doublepuppet.yaml → as_token present"
    assert_contains "appservices/doublepuppet.yaml" \
        "@.*:${server_name}"                                 "doublepuppet.yaml → user regex matches server_name"

    # Caddyfile (JSON blobs are compact, no spaces around ':')
    assert_file "caddy/Caddyfile" "caddy/Caddyfile generated"
    assert_contains "caddy/Caddyfile" \
        "\"server_name\":\"${server_name}\""                     "Caddyfile JSON → server_name"
    assert_contains "caddy/Caddyfile" \
        "\"default_server_name\":\"${server_name}\""             "Caddyfile JSON → default_server_name"
    assert_contains "caddy/Caddyfile" \
        "\"base_url\":\"https://${matrix_domain}\""              "Caddyfile JSON → base_url stays matrix domain"

    if [[ "$server_name" != "$matrix_domain" ]]; then
        # TLD mode: identity domain block must be present
        assert_contains "caddy/Caddyfile" \
            "# Identity Domain (well-known delegation)"          "Caddyfile → identity domain block present"
        assert_contains "caddy/Caddyfile" \
            "${server_name}:443 {"                               "Caddyfile → ${server_name}:443 block"
        assert_contains "caddy/Caddyfile" \
            "\"m.server\":\"${matrix_domain}:443\""              "Caddyfile → m.server delegates to matrix domain"
    else
        # Subdomain mode: no identity domain block
        assert_not_contains "caddy/Caddyfile" \
            "# Identity Domain (well-known delegation)"          "Caddyfile → no identity block in subdomain mode"
    fi

    # ── MAS config correctness ───────────────────────────────────────────────
    local auth_domain="auth.example.test"
    assert_contains "mas/config/config.yaml" \
        "public_base: 'https://${auth_domain}/'"             "MAS → public_base uses auth domain"
    assert_contains "mas/config/config.yaml" \
        "issuer: 'https://${auth_domain}/'"                  "MAS → issuer uses auth domain"
    assert_contains "mas/config/config.yaml" \
        "endpoint: 'http://synapse:8008'"                    "MAS → synapse endpoint correct"
    assert_contains "mas/config/config.yaml" \
        "enabled: false"                                     "MAS → open registration disabled by default"

    # ── Synapse config correctness ───────────────────────────────────────────
    assert_contains "synapse/data/homeserver.yaml" \
        "endpoint: 'http://mas:8080'"                        "Synapse → MAS endpoint correct"
    assert_contains "synapse/data/homeserver.yaml" \
        "enable_registration: false"                         "Synapse → registration disabled"
    assert_contains "synapse/data/homeserver.yaml" \
        "allow_public_rooms_without_auth: false"             "Synapse → public rooms not public"
    assert_contains "synapse/data/homeserver.yaml" \
        "allow_public_rooms_over_federation: false"          "Synapse → public rooms not over federation"

    # ── Caddyfile security ───────────────────────────────────────────────────
    assert_contains "caddy/Caddyfile" \
        "admin localhost:2019"                               "Caddyfile → admin API localhost only"
    assert_contains "caddy/Caddyfile" \
        "header_up X-Forwarded-Host"                        "Caddyfile → MAS proxy forwards X-Forwarded-Host"
    assert_contains "caddy/Caddyfile" \
        "/_synapse/admin"                                   "Caddyfile → synapse admin route present"

    # ── Well-known completeness ──────────────────────────────────────────────
    assert_contains "caddy/Caddyfile" \
        '"m.authentication"'                                "Caddyfile → well-known includes m.authentication"
    assert_contains "caddy/Caddyfile" \
        "\"issuer\":\"https://${auth_domain}/\""            "Caddyfile → well-known m.authentication.issuer correct"
}

# ─── Curl an HTTPS endpoint, routing *.example.test → 127.0.0.1 ─────────────
curl_local() {
    local domain="$1" path="$2"
    local -a args=(-sf --max-time 15 --resolve "${domain}:443:127.0.0.1")
    if [[ -f mas/certs/caddy-ca.crt ]]; then
        args+=(--cacert mas/certs/caddy-ca.crt)
    else
        args+=(-k)
    fi
    curl "${args[@]}" "https://${domain}${path}" 2>/dev/null || true
}

# Returns only the HTTP status code (does not fail on non-2xx)
curl_local_status() {
    local domain="$1" path="$2"
    local -a args=(-s --max-time 15 --resolve "${domain}:443:127.0.0.1" -o /dev/null -w "%{http_code}")
    if [[ -f mas/certs/caddy-ca.crt ]]; then
        args+=(--cacert mas/certs/caddy-ca.crt)
    else
        args+=(-k)
    fi
    curl "${args[@]}" "https://${domain}${path}" 2>/dev/null || echo "000"
}

# ─── Copy Caddy CA to MAS and restart MAS ────────────────────────────────────
# deploy.sh only waits 5s for the PKI file — not reliable. Use Caddy's admin
# API (localhost:2019) instead, which returns the CA cert as soon as Caddy is up.
setup_mas_ca() {
    local ca_dst="mas/certs/caddy-ca.crt"
    local waited=0
    info "Fetching Caddy CA via admin API (up to 60s)..."
    while (( waited < 60 )); do
        local resp; resp=$(curl -sf --max-time 5 http://localhost:2019/pki/ca/local 2>/dev/null || echo "")
        if echo "$resp" | grep -q '"root_certificate"'; then
            # Extract PEM from JSON: value uses literal \n; strip key/quotes, unescape newlines
            echo "$resp" \
                | grep -o '"root_certificate":"[^"]*"' \
                | sed 's/"root_certificate":"//; s/"$//' \
                | sed 's/\\n/\n/g' \
                | sudo tee "$ca_dst" > /dev/null
            info "Caddy CA fetched → restarting MAS..."
            $COMPOSE_CMD -f "$COMPOSE_FILE" restart mas 2>/dev/null || true
            sleep 10
            return 0
        fi
        sleep 3; waited=$((waited + 3))
    done
    warn "Caddy admin API did not return CA after 60s — MAS OIDC test will fail"
}

# ─── Live endpoint assertions ─────────────────────────────────────────────────
assert_endpoints() {
    local server_name="$1"
    local matrix_domain="matrix.example.test"

    header "Endpoint tests  (SERVER_NAME=${server_name})"
    info "Allowing 20s for full service initialization..."
    sleep 20

    setup_mas_ca

    # Synapse /health
    local health; health=$(curl_local "$matrix_domain" "/health")
    [[ "$health" == "OK" ]] \
        && pass "Synapse /health → OK" \
        || fail "Synapse /health (got: '${health:-no response}')"

    # .well-known/matrix/client on matrix domain
    local wk; wk=$(curl_local "$matrix_domain" "/.well-known/matrix/client")
    echo "$wk" | grep -q '"m.homeserver"' \
        && pass "${matrix_domain} → .well-known/matrix/client responds" \
        || fail "${matrix_domain} → .well-known/matrix/client (got: '${wk:-no response}')"
    echo "$wk" | grep -q "https://${matrix_domain}" \
        && pass ".well-known base_url = https://${matrix_domain}" \
        || fail ".well-known base_url wrong (got: '${wk:-}')"

    if [[ "$server_name" != "$matrix_domain" ]]; then
        # TLD mode: identity domain must serve well-known

        local wk_id; wk_id=$(curl_local "$server_name" "/.well-known/matrix/client")
        echo "$wk_id" | grep -q '"m.homeserver"' \
            && pass "${server_name} → .well-known/matrix/client responds" \
            || fail "${server_name} → .well-known/matrix/client (got: '${wk_id:-no response}')"

        local wk_srv; wk_srv=$(curl_local "$server_name" "/.well-known/matrix/server")
        echo "$wk_srv" | grep -q '"m.server"' \
            && pass "${server_name} → .well-known/matrix/server responds" \
            || fail "${server_name} → .well-known/matrix/server (got: '${wk_srv:-no response}')"
        echo "$wk_srv" | grep -q "$matrix_domain" \
            && pass ".well-known/matrix/server delegates to ${matrix_domain}" \
            || fail ".well-known/matrix/server missing ${matrix_domain} (got: '${wk_srv:-}')"
    fi

    # MAS OIDC discovery
    local auth_domain="auth.example.test"
    local oidc; oidc=$(curl_local "$auth_domain" "/.well-known/openid-configuration")
    echo "$oidc" | grep -q '"issuer"' \
        && pass "MAS OIDC discovery responds" \
        || fail "MAS OIDC discovery (got: '${oidc:-no response}')"
    # issuer and authorization_endpoint must use the public auth domain, not an internal hostname
    # (regression test for issue #16 — missing X-Forwarded-Host caused silent OAuth2 breakage)
    echo "$oidc" | grep -q "\"issuer\":\"https://${auth_domain}/\"" \
        && pass "MAS OIDC issuer = https://${auth_domain}/" \
        || fail "MAS OIDC issuer wrong — check X-Forwarded-Host forwarding (got: '${oidc:-}')"
    echo "$oidc" | grep -q "\"authorization_endpoint\":\"https://${auth_domain}/" \
        && pass "MAS OIDC authorization_endpoint on ${auth_domain}" \
        || fail "MAS OIDC authorization_endpoint wrong — login button will silently fail (got: '${oidc:-}')"

    # .well-known must include m.authentication so clients find MAS
    echo "$wk" | grep -q '"m.authentication"' \
        && pass ".well-known includes m.authentication" \
        || fail ".well-known missing m.authentication (got: '${wk:-}')"
    echo "$wk" | grep -q "\"issuer\":\"https://${auth_domain}/\"" \
        && pass ".well-known m.authentication.issuer = https://${auth_domain}/" \
        || fail ".well-known m.authentication.issuer wrong (got: '${wk:-}')"

    # Synapse /_matrix/client/versions (confirms Synapse is up and routing works)
    local versions; versions=$(curl_local "$matrix_domain" "/_matrix/client/versions")
    echo "$versions" | grep -q '"versions"' \
        && pass "Synapse /_matrix/client/versions responds" \
        || fail "Synapse /_matrix/client/versions (got: '${versions:-no response}')"

    # Login compat endpoint must be proxied to MAS (not return Synapse 404)
    local login; login=$(curl_local "$matrix_domain" "/_matrix/client/v3/login")
    echo "$login" | grep -qE '"flows"|"type"' \
        && pass "/_matrix/client/v3/login proxied to MAS" \
        || fail "/_matrix/client/v3/login not proxied to MAS (got: '${login:-no response}')"

    # Synapse admin API must be blocked at Caddy (403)
    local admin_code; admin_code=$(curl_local_status "$matrix_domain" "/_synapse/admin/v1/server_version")
    [[ "$admin_code" == "403" ]] \
        && pass "/_synapse/admin blocked (403)" \
        || fail "/_synapse/admin not blocked (HTTP ${admin_code})"

    # Element Web
    local elem; elem=$(curl_local "element.example.test" "/")
    echo "$elem" | grep -qi "element" \
        && pass "Element Web root serves HTML" \
        || fail "Element Web root (no Element content in response)"
}

# ─── Quickstart config assertions ────────────────────────────────────────────
assert_quickstart_configs() {
    local domain="$1"
    local matrix_domain="matrix.${domain}"
    local auth_domain="auth.${domain}"

    header "Quickstart config assertions  (domain=${domain})"

    assert_file ".env"                        ".env generated"
    assert_contains ".env" "DOMAIN=${domain}" ".env → DOMAIN"
    assert_contains ".env" "MATRIX_DOMAIN=${matrix_domain}" ".env → MATRIX_DOMAIN"

    assert_file "mas/config/config.yaml"      "mas/config/config.yaml generated"
    assert_contains "mas/config/config.yaml"  "homeserver: '${matrix_domain}'"       "MAS → homeserver"
    assert_contains "mas/config/config.yaml"  "name: adminapi"                        "MAS → adminapi listener"
    assert_contains "mas/config/config.yaml"  "public_base: 'https://${auth_domain}/'" "MAS → public_base"
    assert_contains "mas/config/config.yaml"  "issuer: 'https://${auth_domain}/'"     "MAS → issuer"
    assert_contains "mas/config/config.yaml"  "enabled: false"                        "MAS → open registration disabled"

    assert_file "element/config/config.json"  "element/config/config.json generated"

    assert_file "synapse/data/homeserver.yaml" "synapse/data/homeserver.yaml generated"
    assert_contains "synapse/data/homeserver.yaml" "enable_registration: false"                  "Synapse → registration disabled"
    assert_contains "synapse/data/homeserver.yaml" "allow_guest_access: false"                   "Synapse → guest access disabled"
    assert_contains "synapse/data/homeserver.yaml" "allow_public_rooms_without_auth: false"      "Synapse → public rooms blocked"
    assert_contains "synapse/data/homeserver.yaml" "allow_public_rooms_over_federation: false"   "Synapse → public rooms over federation blocked"

    assert_file "caddy/Caddyfile"             "caddy/Caddyfile generated"
    assert_contains     "caddy/Caddyfile" "admin localhost:2019"       "Caddyfile → admin API localhost only"
    assert_contains     "caddy/Caddyfile" "/_synapse/admin"            "Caddyfile → synapse admin block present"
    assert_contains     "caddy/Caddyfile" "header_up X-Forwarded-Host" "Caddyfile → MAS proxy forwards X-Forwarded-Host"
    assert_contains     "caddy/Caddyfile" "handle /account/"           "Caddyfile → /account/ uses handle (preserves prefix)"
    assert_not_contains "caddy/Caddyfile" "handle_path /account/"      "Caddyfile → /account/ not handle_path"
}

# ─── Run one full scenario ────────────────────────────────────────────────────
run_scenario() {
    local name="$1"
    local sn_choice="$2"       # "1" = TLD, "2" = subdomain
    local expected_sn="$3"

    section "$name"
    teardown_stack
    cleanup_configs

    info "Running deploy.sh (piped stdin)"

    # Stdin answers in prompt order:
    #   [1] Deployment type:                1  (local)
    #   [2] Include Authelia?               n
    #   [3] Enable Element Call?            n
    #   [4] Allow open registration?        n  (default: closed)
    #   [5] Custom Docker registry prefix:  (empty → default)
    #   [6] Use hardened images?            n
    #   [7] SERVER_NAME choice:             $sn_choice  (1=TLD, 2=subdomain)
    #   [8] Press Enter to continue:        (empty)
    printf '%s\n' "1" "n" "n" "n" "" "n" "$sn_choice" "" \
        | bash deploy.sh

    assert_configs "$expected_sn"

    if [[ "$SKIP_INTEGRATION" == "true" ]]; then
        warn "Skipping endpoint tests (SKIP_INTEGRATION=true)"
    else
        assert_endpoints "$expected_sn"
    fi
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"
    echo -e "${BOLD}  Results: ${GREEN}${TESTS_PASSED} passed${NC}${BOLD}, ${RED}${TESTS_FAILED} failed${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"
    echo ""
    if (( TESTS_FAILED > 0 )); then
        echo -e "${RED}✗ Test suite FAILED${NC}"
        exit 1
    else
        echo -e "${GREEN}✓ All tests PASSED${NC}"
    fi
}

# ─── Cleanup on exit (INT, TERM, or normal exit) ──────────────────────────────
cleanup_on_exit() {
    echo ""
    section "Cleanup"
    teardown_stack
    cleanup_configs
    info "Done."
}
trap cleanup_on_exit EXIT

# ─── Main ─────────────────────────────────────────────────────────────────────
cd "$(dirname "$(realpath "$0")")"  # ensure we're in the repo root
setup_sudo_shim
check_prereqs

# Scenario A — TLD identity:       @user:example.test
run_scenario \
    "A · TLD identity  (@user:example.test)" \
    "1" \
    "example.test"

# Scenario B — Subdomain identity: @user:matrix.example.test
run_scenario \
    "B · Subdomain identity  (@user:matrix.example.test)" \
    "2" \
    "matrix.example.test"

# Scenario P — production Caddyfile generation (config only, no Let's Encrypt)
section "P · Production Caddyfile  (config only)"
teardown_stack
cleanup_configs
info "Running deploy.sh production mode (piped stdin, SKIP_START=true)"
# Stdin answers in prompt order:
#   [1] Deployment type:               2  (production)
#   [2] Include Authelia?              n
#   [3] Enable Element Call?           n
#   [4] Allow open registration?       n  (default: closed)
#   [5] Custom Docker registry prefix: (empty)
#   [6] Use hardened images?           n
#   [7] Base domain:                   example.com
#   [8] Matrix subdomain:              (empty → matrix)
#   [9] Element subdomain:             (empty → element)
#  [10] Admin subdomain:               (empty → admin)
#  [11] Auth subdomain:                (empty → auth)
#  [12] Authelia subdomain:            (empty → authelia)
#  [13] SERVER_NAME choice:            1  (TLD: @user:example.com)
#  [14] Matrix server address:         (empty → 10.0.1.10)
#  [15] Authelia server address:       (empty → 10.0.1.20)
#  [16] Let's Encrypt email:           (empty → admin@example.com)
printf '%s\n' "2" "n" "n" "n" "" "n" "example.com" "" "" "" "" "" "1" "" "" "" \
    | SKIP_START=true bash deploy.sh

header "Production Caddyfile assertions"
assert_file "caddy/Caddyfile.production"                              "caddy/Caddyfile.production generated"
assert_contains     "caddy/Caddyfile.production" "admin localhost:2019"        "Caddyfile.production → admin API localhost only"
assert_contains     "caddy/Caddyfile.production" "/_synapse/admin"             "Caddyfile.production → synapse admin block present"
assert_contains     "caddy/Caddyfile.production" "header_up X-Forwarded-Host"  "Caddyfile.production → MAS proxy forwards X-Forwarded-Host"
assert_contains     "caddy/Caddyfile.production" "handle /account/"            "Caddyfile.production → /account/ uses handle (preserves prefix)"
assert_not_contains "caddy/Caddyfile.production" "handle_path /account/"       "Caddyfile.production → /account/ not handle_path"
assert_contains     "caddy/Caddyfile.production" '"m.authentication"'          "Caddyfile.production → well-known includes m.authentication"
assert_contains     "caddy/Caddyfile.production" "Access-Control-Allow-Origin" "Caddyfile.production → well-known has CORS header"

# Scenario Q — quickstart.sh config generation (registration closed, default)
section "Q · quickstart.sh  (single-machine, config only)"
teardown_stack
cleanup_configs
info "Running quickstart.sh (piped stdin, SKIP_START=true)"
# Stdin answers in prompt order:
#   [1] Domain:                    example.test
#   [2] Let's Encrypt email:       test@example.test
#   [3] Enable Element Call?       n
#   [4] Allow open registration?   n  (default: closed)
printf '%s\n' "example.test" "test@example.test" "n" "n" \
    | SKIP_START=true bash quickstart.sh
assert_quickstart_configs "example.test"
if [[ "$SKIP_INTEGRATION" != "true" ]]; then
    warn "Quickstart endpoint tests skipped (stack not started in SKIP_START mode)"
fi

# Scenario Q2 — quickstart.sh with open registration enabled
section "Q2 · quickstart.sh open registration  (config only)"
teardown_stack
cleanup_configs
info "Running quickstart.sh with open registration=y (piped stdin, SKIP_START=true)"
printf '%s\n' "example.test" "test@example.test" "n" "y" \
    | SKIP_START=true bash quickstart.sh
header "Quickstart open registration assertions"
assert_file "mas/config/config.yaml" "mas/config/config.yaml generated"
assert_contains "mas/config/config.yaml" \
    "enabled: true"   "MAS → open registration enabled when y chosen (quickstart)"
if [[ "$SKIP_INTEGRATION" != "true" ]]; then
    warn "Quickstart endpoint tests skipped (stack not started in SKIP_START mode)"
fi

# Scenario R — open registration enabled (config only)
section "R · Open registration enabled  (config only)"
teardown_stack
cleanup_configs
info "Running deploy.sh with open registration=y (piped stdin, SKIP_START=true)"
# Stdin answers in prompt order:
#   [1] Deployment type:                1  (local)
#   [2] Include Authelia?               n
#   [3] Enable Element Call?            n
#   [4] Allow open registration?        y  ← testing the enabled path
#   [5] Custom Docker registry prefix:  (empty)
#   [6] Use hardened images?            n
#   [7] SERVER_NAME choice:             1  (TLD)
#   [8] Press Enter to continue:        (empty)
printf '%s\n' "1" "n" "n" "y" "" "n" "1" "" \
    | SKIP_START=true bash deploy.sh
header "Open registration assertions"
assert_file "mas/config/config.yaml" "mas/config/config.yaml generated"
assert_contains "mas/config/config.yaml" \
    "enabled: true"                                              "MAS → open registration enabled when y chosen"
assert_not_contains "mas/config/config.yaml" \
    "enabled: false"                                             "MAS → no 'enabled: false' when open registration on"

trap - EXIT
cleanup_on_exit
print_summary
