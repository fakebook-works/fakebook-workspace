# Fakebook server deployment

This Compose variant deliberately places every service in the network namespace of
`fakebook-tailscale`. Because the frontend nginx already listens on port 80, the edge
proxy listens on port 8080 and is published only to host loopback as port 7069.

Configure the Cloudflare Tunnel origin as:

```text
http://127.0.0.1:7069
```

Validate and recreate the stack from this directory:

```bash
docker compose --env-file envfile -f compose.yaml config --quiet
docker compose --env-file envfile -f compose.yaml down
docker compose --env-file envfile -f compose.yaml pull
docker compose --env-file envfile -f compose.yaml up -d
docker compose --env-file envfile -f compose.yaml ps
```

The Gateway defaults all seven Fusion transports to `127.0.0.1:1001..1007`, matching
this Compose file's shared network namespace. To override a target without rebuilding
the image, set one or more of these in `envfile`:

```text
GATEWAY_AUTHENTICATION_SUBGRAPH_URL
GATEWAY_SOCIALGRAPH_SUBGRAPH_URL
GATEWAY_RECOMMENDATION_SUBGRAPH_URL
GATEWAY_SEARCH_SUBGRAPH_URL
GATEWAY_NOTIFICATION_SUBGRAPH_URL
GATEWAY_MESSAGING_SUBGRAPH_URL
GATEWAY_PAYMENT_SUBGRAPH_URL
GATEWAY_PAYMENT_WEBHOOK_URL
```

Do not set `ASPNETCORE_ENVIRONMENT=Development` on the server. Production keeps
`/graphql` available for application traffic while disabling the Nitro browser IDE.

Do not add `-v` to `down`; PostgreSQL, Redis, Tailscale state and media use persistent
bind mounts. The PostgreSQL owner credential is injected only into the PostgreSQL
container for first-time initialization; application containers continue to use their
schema-scoped runtime roles.

Verify the local edge before testing the public hostname:

```bash
curl --fail-with-body http://127.0.0.1:7069/
curl --fail-with-body \
  -H 'content-type: application/json' \
  --data '{"query":"query { __typename }"}' \
  http://127.0.0.1:7069/graphql
docker compose --env-file envfile -f compose.yaml logs --tail=100 fakebook-edge fakebook-gateway
```

Redis reports an operational warning when Linux memory overcommit is disabled. Apply
this on the host (not inside the container), then persist the setting according to the
server distribution:

```bash
sudo sysctl -w vm.overcommit_memory=1
```

The six PostgreSQL-backed .NET images must be rebuilt from their updated Dockerfiles
before pulling again if the log still contains `libgssapi_krb5.so.2` loader errors.
That package warning did not cause the `/graphql` 405, but the rebuilt Alpine images no
longer emit it.

`envfile` and `server.log` contain deployment-specific data and are intentionally
ignored by Git.
