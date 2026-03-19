# Matrix Stack Quick Reference

## Deployment

```bash
# Simple production deployment (recommended for most users)
./quickstart.sh

# Advanced deployment (local testing, Authelia, multi-machine)
./deploy.sh

# Set up messaging bridges (after core stack is running)
./setup-bridges.sh
```

## Service Management

```bash
# Status
docker compose ps
docker compose --profile single-machine ps     # if started via quickstart.sh
docker compose --profile element-call ps       # if Element Call is enabled

# Start
docker compose --profile single-machine up -d

# Stop
docker compose --profile single-machine down

# Restart one service
docker compose restart synapse
docker compose restart mas
docker compose restart caddy

# Update all images
docker compose pull
docker compose --profile single-machine up -d
```

## Logs

```bash
# Follow all
docker compose logs -f

# Follow one service
docker compose logs -f synapse
docker compose logs -f mas
docker compose logs -f caddy

# Last 100 lines
docker compose logs --tail=100 synapse

# Search for errors
docker compose logs | grep -i error
```

## Access URLs (production)

| Service | URL |
|---------|-----|
| Element Web | https://element.yourdomain.com |
| Matrix API | https://matrix.yourdomain.com |
| MAS Auth | https://auth.yourdomain.com |
| Element Admin | https://admin.yourdomain.com |
| Element Call | https://call.yourdomain.com (optional) |

## Access URLs (local testing)

| Service | URL |
|---------|-----|
| Element Web | https://element.example.test |
| Matrix API | https://matrix.example.test |
| MAS Auth | https://auth.example.test |
| Element Admin | https://admin.example.test |
| Authelia | https://authelia.example.test (optional) |

## User Management

```bash
# Create a user via MAS CLI
docker compose exec mas mas-cli manage register-user USERNAME

# Create an admin user
docker compose exec mas mas-cli manage register-user USERNAME --admin

# List users
docker compose exec mas mas-cli manage list-users
```

## Database

```bash
# Connect to PostgreSQL
docker compose exec postgres psql -U synapse

# Connect to a specific database
docker compose exec postgres psql -U synapse -d mas

# Dump all databases
docker compose exec -T postgres pg_dumpall -U synapse > backup-$(date +%Y%m%d).sql

# Database sizes
docker compose exec postgres psql -U synapse -c \
  "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database;"
```

## Backup

```bash
# Quick backup (all critical data)
tar -czf matrix-backup-$(date +%Y%m%d).tar.gz \
  postgres/data synapse/data mas/data .env mas-signing.key

# Database-only dump (can run while services are up)
docker compose exec -T postgres pg_dumpall -U synapse > db-$(date +%Y%m%d).sql
```

## Verification

```bash
# Test Matrix API
curl https://matrix.yourdomain.com/_matrix/client/versions

# Test well-known
curl https://matrix.yourdomain.com/.well-known/matrix/client | jq

# Test MAS OIDC discovery
curl https://auth.yourdomain.com/.well-known/openid-configuration | jq

# Check PostgreSQL
docker compose exec postgres pg_isready -U synapse

# Check Synapse health
curl http://localhost:8008/health
```

## Troubleshooting

```bash
# Service won't start — check logs
docker compose logs --tail=50 synapse

# Force recreate a container
docker compose up -d --force-recreate synapse

# Fix MAS provider cache (after config change)
docker compose exec postgres psql -U synapse -d mas << 'EOF'
DELETE FROM upstream_oauth_authorization_sessions WHERE upstream_oauth_provider_id = (SELECT upstream_oauth_provider_id FROM upstream_oauth_providers LIMIT 1);
DELETE FROM upstream_oauth_links WHERE upstream_oauth_provider_id = (SELECT upstream_oauth_provider_id FROM upstream_oauth_providers LIMIT 1);
DELETE FROM upstream_oauth_providers;
EOF
docker compose restart mas

# Port conflict — find what's using the port
sudo lsof -i :443
sudo lsof -i :8008

# Find all matrix containers
docker ps --filter name=matrix
```

## Bridge Operations

```bash
# Bridge status
docker compose logs --tail=30 mautrix-whatsapp
docker compose logs --tail=30 mautrix-signal
docker compose logs --tail=30 mautrix-telegram

# Restart a bridge
docker compose restart mautrix-whatsapp

# Full bridge setup (run after core stack is running)
./setup-bridges.sh
```

## Local Testing (extra steps)

```bash
# Add to /etc/hosts (both IPv4 and IPv6 required)
echo "127.0.0.1  matrix.example.test element.example.test auth.example.test authelia.example.test" | sudo tee -a /etc/hosts
echo "::1        matrix.example.test element.example.test auth.example.test authelia.example.test" | sudo tee -a /etc/hosts

# Test with self-signed cert
curl -k https://matrix.example.test/_matrix/client/versions

# Extract Caddy CA cert (if MAS can't connect to auth domain)
cp caddy/data/caddy/pki/authorities/local/root.crt mas/certs/caddy-ca.crt
docker compose restart mas
```

## Common Error Fixes

| Error | Fix |
|-------|-----|
| `password authentication failed` | postgres/data exists with old password — wipe and redeploy |
| `homeserver.domain not configured` (bridge) | Run `setup-bridges.sh` |
| `as_token was not accepted` | Registration not loaded in Synapse — check `homeserver.yaml` |
| MAS CSS missing | Add `- name: assets` to MAS listener resources |
| Element Admin: `TypeError: Failed to fetch` | Add `- name: adminapi` to MAS listener resources |
| `Template rendered to empty string` | Set `fetch_userinfo: true` in MAS upstream provider |
| Bridge: `Connection refused` | Bridge hostname is 127.0.0.1 — must be 0.0.0.0 in config |
