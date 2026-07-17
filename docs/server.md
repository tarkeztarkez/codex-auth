# Shared account server

The server stores Codex authentication documents so multiple codex-auth clients can share accounts. It is also the usage authority for configured clients: it refreshes usage from OpenAI every three minutes and caches the response. Configured clients read that cache instead of sending usage requests to OpenAI themselves.

When OpenAI returns `401 token_expired`, the server exchanges the stored refresh token at the same OAuth endpoint and with the same public client ID used by Codex CLI. It saves the rotated access, ID, and refresh tokens, validates them with a new usage request, and distributes the refreshed authentication document to clients on their next pull. If a refresh token has expired, been reused, or been revoked, interactive login is still required.

## Run with Docker

```shell
docker build -t codex-auth-server .
docker run --rm -p 8080:8080 \
  -e API_TOKEN='replace-with-a-long-random-secret' \
  -e DATABASE_URL='postgresql://user:password@host:5432/codex_auth' \
  codex-auth-server
```

`API_TOKEN` is required and must contain at least 16 characters. `DATABASE_URL` must point to an administrative database on the PostgreSQL instance. At startup, the server creates the database named by `DATABASE_NAME` (default `codex_auth`) when needed, then creates its `credentials` table. `PORT` defaults to `8080`. TLS should be terminated by the deployment platform or a reverse proxy.

The authenticated API is:

- `GET /v1/credentials` — return all stored credential envelopes.
- `PUT /v1/credentials` — create or replace one credential envelope.
- `GET /v1/usage` — return the latest cached usage response for every account.
- `GET /health` — unauthenticated health check.

Clients authenticate with `Authorization: Bearer <API_TOKEN>`.

## Configure a client

```shell
codex-auth config server set \
  --url https://codex-auth.example.com \
  --api-token 'the-shared-secret'
codex-auth config auto enable
```

The token is stored in `~/.codex/accounts/server.json` with private file permissions. Disable synchronization with:

```shell
codex-auth config server disable
```

Successful login and import operations upload credentials. The server is authoritative after upload; clients pull credentials rather than periodically pushing their local copies back. Network failures are logged and do not prevent local account management. API-backed usage display requires the configured server to be reachable; `--skip-api` continues to use local rollout data.
