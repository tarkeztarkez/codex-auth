# Credential server

The server stores Codex authentication documents so multiple codex-auth clients can share accounts. It does not call OpenAI APIs and does not manage usage limits.

## Run with Docker

```shell
docker build -t codex-auth-server .
docker run --rm -p 8080:8080 \
  -e API_TOKEN='replace-with-a-long-random-secret' \
  -e DATABASE_URL='postgresql://user:password@host:5432/codex_auth' \
  codex-auth-server
```

`API_TOKEN` is required and must contain at least 16 characters. `DATABASE_URL` must point to a PostgreSQL database; the server creates its `credentials` table at startup. `PORT` defaults to `8080`. TLS should be terminated by the deployment platform or a reverse proxy.

The authenticated API is:

- `GET /v1/credentials` — return all stored credential envelopes.
- `PUT /v1/credentials` — create or replace one credential envelope.
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

Successful login and import operations upload credentials. Successful expired-token repair uploads the refreshed credential. Every daemon cycle first downloads server credentials and then uploads the merged local set. Network failures are logged and do not prevent local account management or usage refresh.
