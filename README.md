# harbor

The shared services on the VM, as code: Traefik, PostgreSQL, MongoDB and their
backups, all in one Docker Swarm stack. Every push to `main` deploys it through
[deploy.yml](.github/workflows/deploy.yml). Nothing is edited by hand on the VM.

| File | Purpose |
|---|---|
| [stack.yml](stack.yml) | Traefik, PostgreSQL, MongoDB, backups |
| [databases.txt](databases.txt) | One database and user per app |
| [deploy.sh](deploy.sh) | Creates networks, deploys the stack, creates databases |
| [backup.sh](backup.sh) | Daily dump of every database, plus restore |

## Contract with app repos

Apps never reference this repo. They rely only on these names:

| Name | Value |
|---|---|
| Networks | `public`, `db` (external, overlay, attachable) |
| Proxy subnet | `10.200.0.0/16` (`public`; trust forwarded headers from it) |
| Cert resolver | `letsencrypt` |
| Entrypoint | `websecure` (HTTP redirects to it) |
| PostgreSQL | `postgresql://<name>:<password>@postgres:5432/<name>` |
| MongoDB | `mongodb://<name>:<password>@mongo:27017/<name>` |

An app's stack file looks like this:

```yaml
services:
  api:
    image: ghcr.io/vecilije/bloodline-api:${TAG}
    environment:
      DATABASE_URL: ${DATABASE_URL}
    networks: [public, db]
    deploy:
      labels:
        - traefik.enable=true
        - traefik.http.routers.bloodline-api.rule=Host(`bloodline.example.net`) && PathPrefix(`/api`)
        - traefik.http.routers.bloodline-api.entrypoints=websecure
        - traefik.http.routers.bloodline-api.tls.certresolver=letsencrypt
        - traefik.http.services.bloodline-api.loadbalancer.server.port=8000

networks:
  public: { external: true }
  db: { external: true }
```

For private ghcr.io images, run `docker login ghcr.io` before deploying and pass
`--with-registry-auth` to `docker stack deploy`.

## First-time VM setup

1. Install Docker and run `docker swarm init`.
2. Create a deploy user that can use Docker, and allow it to log in with an SSH key:
   `adduser deploy && usermod -aG docker deploy`, then add the public key to
   `~deploy/.ssh/authorized_keys`.
3. Make sure nothing else holds ports 80 and 443, and point the domains at the VM.
4. In this repo's GitHub settings, add:

   | Secret | Value |
   |---|---|
   | `SSH_HOST` | VM IP address |
   | `SSH_USER` | `deploy` |
   | `SSH_PRIVATE_KEY` | Private half of the deploy key |
   | `SSH_KNOWN_HOSTS` | Output of `ssh-keyscan <VM IP>` |
   | `POSTGRES_ROOT_PASSWORD` | PostgreSQL superuser (`postgres`) password |
   | `MONGO_ROOT_PASSWORD` | MongoDB superuser (`root`) password |
   | `<ENGINE>_PASSWORD_<NAME>` | One per line of `databases.txt`, e.g. `MONGO_PASSWORD_FLEXIDIM` |

   and the variable `ACME_EMAIL` (for Let's Encrypt).

   Passwords must be at least 16 characters of `A-Z a-z 0-9 _ -` so they work in
   connection strings unescaped. Use `openssl rand -hex 32`.
5. Run the Deploy workflow.

## Adding an app

1. Add `postgres <name>` or `mongo <name>` to [databases.txt](databases.txt) and add
   the GitHub secret `<ENGINE>_PASSWORD_<NAME>`. Push; the deploy creates the
   database and a user that can use only that database.
2. In the app repo, set the connection string from the contract above and deploy
   with the Traefik labels and external networks.

To change an app's password, update the secret and redeploy. The same works for
`POSTGRES_ROOT_PASSWORD`, but `MONGO_ROOT_PASSWORD` is fixed once MongoDB has started.

## Backups

Every database is dumped at 03:00 UTC to the `harbor_postgres-backups` and
`harbor_mongo-backups` volumes, as `/backups/<db>/<db>-<timestamp>.dump`. Dumps
are kept for 14 days. They live on the VM's disk, so copy them elsewhere if the
VM itself might be lost.

On the VM, pick the backup service for the engine (`harbor_postgres-backup` or
`harbor_mongo-backup`):

```bash
backup=$(docker ps -q -f label=com.docker.swarm.service.name=harbor_postgres-backup)
docker exec $backup /backup.sh now            # take a backup now
docker exec $backup ls /backups/bloodline     # list backups
```

### Restoring

Stop the app so it holds no connections, restore, then start it again:

```bash
docker service scale bloodline_api=0
docker exec $backup /backup.sh restore bloodline /backups/bloodline/bloodline-20260927-030000.dump
docker service scale bloodline_api=1
```

A PostgreSQL restore runs in one transaction, so a failure leaves the database
unchanged. A MongoDB restore replaces the database collection by collection.
To restore on a new VM, deploy this repo first, then copy the dump into the
backup container with `docker cp` and restore it the same way.
