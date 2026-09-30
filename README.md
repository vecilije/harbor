# harbor

The shared services on the VM, as code: Traefik, PostgreSQL, MongoDB and their
backups in the Docker Swarm stack `harbor`, and the identity provider Zitadel in the
stack `auth`. Every push to `main` deploys them through
[deploy.yml](.github/workflows/deploy.yml). Nothing is edited by hand on the VM.

| File | Purpose |
|---|---|
| [stack.yml](stack.yml) | Traefik, PostgreSQL, MongoDB, backups |
| [auth.yml](auth.yml) | Zitadel and its login pages |
| [databases.txt](databases.txt) | One database and user per app (and one for Zitadel) |
| [deploy.sh](deploy.sh) | Creates networks, deploys `harbor`, creates databases, deploys `auth`, runs `zitadel.sh` |
| [zitadel.sh](zitadel.sh) | Applies Zitadel's instance-wide settings through its API |
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
| Identity provider | OpenID Connect issuer `https://<AUTH_DOMAIN>` (Zitadel) |

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
   | `ZITADEL_MASTERKEY` | Exactly 32 characters: `openssl rand -hex 16` |
   | `ZITADEL_LOGIN_COOKIE_SECRET` | At least 32 characters |
   | `ZITADEL_ADMIN_PASSWORD` | First admin's initial password: 12+ characters with upper and lower case letters, a digit and a symbol |
   | `ZITADEL_TOKEN` | Added after the first deploy: the automation service account's token (see [Zitadel](#zitadel)) |

   and the variables `ACME_EMAIL` (for Let's Encrypt), `AUTH_DOMAIN` (Zitadel's domain) and
   `ZITADEL_ADMIN_EMAIL` (the first admin's email address).

   Passwords must be at least 16 characters of `A-Z a-z 0-9 _ -` so they work in
   connection strings unescaped. Use `openssl rand -hex 32`. `ZITADEL_ADMIN_PASSWORD`
   is the exception.
5. Run the Deploy workflow.

## Adding an app

1. Add `postgres <name>` or `mongo <name>` to [databases.txt](databases.txt), add
   the GitHub secret `<ENGINE>_PASSWORD_<NAME>`, and pass it to the Deploy step in
   [deploy.yml](.github/workflows/deploy.yml). Push; the deploy creates the
   database and a user that can use only that database.
2. In the app repo, set the connection string from the contract above and deploy
   with the Traefik labels and external networks.

To change an app's password, update the secret and redeploy. The same works for
`POSTGRES_ROOT_PASSWORD`, but `MONGO_ROOT_PASSWORD` is fixed once MongoDB has started.

## Zitadel

Zitadel runs at `https://<AUTH_DOMAIN>` from its own database, `zitadel`. It creates
its schema itself on start, as the database's owner, so it never needs the superuser.

**Keep a copy of `ZITADEL_MASTERKEY` outside GitHub** (e.g. in a password manager).
It encrypts the keys and secrets Zitadel stores, so a database backup is useless
without it, and it can never be changed.

The first deploy creates an instance with the organization `Harbor` for instance
administrators:

- The admin logs in at `https://<AUTH_DOMAIN>/ui/console` as
  `admin@harbor.<AUTH_DOMAIN>` with `ZITADEL_ADMIN_PASSWORD`, and must set a new password right
  away. Changing the secret later has no effect.
- A service account `automation` with the instance owner role configures Zitadel through its API.
  Its token is written once to the `auth_bootstrap` volume. Copy it into the GitHub secret
  `ZITADEL_TOKEN` of this repo and of every app repo that configures Zitadel, then delete it from
  the VM:

  ```bash
  docker run --rm -v auth_bootstrap:/bootstrap alpine cat /bootstrap/automation.pat
  docker run --rm -v auth_bootstrap:/bootstrap alpine rm /bootstrap/automation.pat
  ```

  Don't delete `login-client.pat` from that volume: the login pages use it.

Once `ZITADEL_TOKEN` is set, every deploy runs [zitadel.sh](zitadel.sh), which changes only what
differs from:

- no self-registration and no registration through external identity providers, as the default
  for every organization;
- accounts locked after 5 wrong passwords or one-time codes;
- a second factor required for the `Harbor` organization (the admin sets one up at the next login);
- the admin's email address `ZITADEL_ADMIN_EMAIL` (set as verified: there is no mail server yet);
- the service account's name, `automation`.

Settings not listed there are changed in the console.

Apps create their own organization, project and applications in Zitadel and validate
tokens against the issuer's keys (`https://<AUTH_DOMAIN>/oauth/v2/keys`).

To upgrade, bump both image tags in [auth.yml](auth.yml) together, after reading the
release notes.

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
