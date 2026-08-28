# Local self-hosted CI/CD over Headscale

This deployment builds immutable application images on GitHub-hosted runners,
then gives the deployment job temporary TCP/6247 access to the Docker host over
Headscale. The privileged deploy job does not check out repository code and
cannot open a normal shell, read the ledger, read application credentials, or
access the Docker socket.

The production host contract in this document is specific to `mibook`:

- Headscale control URL: `https://headscale.borry.org`
- deploy target: `100.64.0.5`
- deploy SSH port: `6247`
- public application origin: `https://beancount.mesh.arpa`
- host UID/GID baked into self-host images: `1000:1000`
- Compose project: `beancount-ledger-selfhost`

Do not apply this profile to another host without changing and reviewing all
six values together.

## Trust boundary

The workflow publishes five images for one full source SHA and passes only
their registry digests to a forced SSH command. Application and ledger secrets
remain in `/etc/beancount-ledger-selfhost/runtime.env`. Root-owned Compose,
Caddy, systemd, and deployment files are not updated by CI. Changes to those
files require a separate local installation review and a coordinated bump of
the integer in `/etc/beancount-ledger-selfhost/deploy-contract`, the workflow
manifest, the submission helper, and the deploy runner. The initial contract
is `1`.

The server and indexer images are host-specific because their non-root user is
created at build time. The agent and frontend images are still built in the
same workflow so one deployment never mixes source commits.

## Headscale policy prerequisite

Headscale allows all peer traffic when no policy is loaded. Do not create a new
policy containing only the CI rule: that would either leave the CI node broadly
connected or cut off existing personal nodes and subnet routes. First inspect
the active server-side policy and merge this grant into it:

```json
{
  "tagOwners": {
    "tag:ci-deploy": ["borui@"]
  },
  "grants": [
    {
      "src": ["tag:ci-deploy"],
      "dst": ["100.64.0.5"],
      "ip": ["tcp:6247"]
    }
  ]
}
```

Confirm that `borui@` is the existing Headscale user before loading the policy.
Reload Headscale and prove that existing personal-device and subnet-router
grants still work. Then create the CI registration key:

```bash
headscale preauthkeys create \
  --tags tag:ci-deploy \
  --reusable \
  --ephemeral \
  --expiration 90d
```

Store its output only as the `HEADSCALE_CI_PREAUTH_KEY` environment secret.
The workflow connects directly to `100.64.0.5`, so no CI DNS record is needed.
The existing `beancount.mesh.arpa` Caddy name and local CA are unchanged.

## One-time host installation

Run these commands from a reviewed checkout of the commit being installed.
They preserve the current Compose project and named volumes.

```bash
sudo install -d -m 700 -o root -g root /etc/beancount-ledger-selfhost
sudo install -d -m 700 -o root -g root /var/lib/beancount-ledger-deploy/releases
sudo install -d -m 700 -o root -g root /var/lib/beancount-ledger-deploy/runs
sudo install -m 644 -o root -g root docker/docker-compose.selfhost.yml \
  /etc/beancount-ledger-selfhost/compose.yml
sudo install -m 644 -o root -g root docker/Caddyfile \
  /etc/beancount-ledger-selfhost/Caddyfile
sudo install -m 755 -o root -g root scripts/selfhost/beancount-ledger-deploy-submit \
  /usr/local/sbin/beancount-ledger-deploy-submit
sudo install -m 755 -o root -g root scripts/selfhost/beancount-ledger-deploy-run \
  /usr/local/sbin/beancount-ledger-deploy-run
sudo install -m 755 -o root -g root scripts/selfhost/beancount-ledger-recover-pending \
  /usr/local/sbin/beancount-ledger-recover-pending
sudo install -m 755 -o root -g root scripts/selfhost/beancount-ledger-rollback \
  /usr/local/sbin/beancount-ledger-rollback
sudo install -m 644 -o root -g root docker/systemd/beancount-ledger-deploy@.service \
  /etc/systemd/system/beancount-ledger-deploy@.service
sudo install -m 644 -o root -g root docker/systemd/beancount-ledger-recover.service \
  /etc/systemd/system/beancount-ledger-recover.service
printf '2\n' | sudo tee /etc/beancount-ledger-selfhost/deploy-contract >/dev/null
sudo chmod 644 /etc/beancount-ledger-selfhost/deploy-contract
sudo chown root:root /etc/beancount-ledger-selfhost/deploy-contract
```

Move the existing environment without changing any value, especially
`AUTH_SECRET`:

```bash
sudo install -m 600 -o root -g root \
  /home/borui/.codex/worktrees/local-selfhost-tailnet/beancount-ledger-web/.env.selfhost \
  /etc/beancount-ledger-selfhost/runtime.env
```

Record the currently running mixed-worktree images as the first rollback-only
release:

```bash
sudo tee /var/lib/beancount-ledger-deploy/releases/current.env >/dev/null <<'EOF'
SELFHOST_SERVER_IMAGE=sha256:b841a113b530336ededf270956f16003a80ff555c7b1cddefbd413c372e4d271
SELFHOST_INDEXER_IMAGE=sha256:0f2b4403c887648ed466302c1664cf24b275e85424ecda789334702b48aeaea1
SELFHOST_AGENT_IMAGE=sha256:3ec919b8b5e1b4afd623b486b73bb0593c0dda49e6ad3e6a46765ebbaf342a8a
SELFHOST_FRONTEND_IMAGE=sha256:dccadf2537bc6b64a1707f866c22fb67507a7558e27fa860a7ff1b76a971092a
SELFHOST_ZIP_WORKER_IMAGE=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
SELFHOST_POSTGRES_IMAGE=postgres:17-alpine@sha256:67f624a4ad70edba8d65c82341124fab7054b277b4f7dea4b04be6f939ce2314
SELFHOST_CADDY_IMAGE=sha256:441dab1be51efa0e5644c17391b27a06d5af86ac695df9504a34de69d821bef7
SELFHOST_APP_PULL_POLICY=never
SELFHOST_DATABASE_PULL_POLICY=never
SELFHOST_CADDY_PULL_POLICY=never
SELFHOST_CADDYFILE_PATH=/etc/beancount-ledger-selfhost/Caddyfile
SELFHOST_VCS_REF=bootstrap-mixed-20260817
EOF
sudo chmod 600 /var/lib/beancount-ledger-deploy/releases/current.env
sudo chown root:root /var/lib/beancount-ledger-deploy/releases/current.env
```

Validate the fixed deployment surface before configuring SSH:

```bash
sudo docker compose \
  -p beancount-ledger-selfhost \
  --env-file /etc/beancount-ledger-selfhost/runtime.env \
  --env-file /var/lib/beancount-ledger-deploy/releases/current.env \
  -f /etc/beancount-ledger-selfhost/compose.yml \
  config --quiet
sudo systemctl daemon-reload
sudo systemctl enable beancount-ledger-recover.service
```

## Restricted SSH ingress

Generate a dedicated keypair on the operator machine. The private half becomes
the GitHub environment secret; the public half is the only key installed for
`ledger-deploy`.

```bash
deploy_key_dir="$(mktemp -d)"
chmod 700 "$deploy_key_dir"
ssh-keygen -t ed25519 -a 100 \
  -C github-actions-beancount-ledger-deploy \
  -f "$deploy_key_dir/id_ed25519" \
  -N ''
```

On mibook:

```bash
sudo useradd --create-home --shell /bin/bash ledger-deploy
sudo passwd -l ledger-deploy
sudo install -d -m 700 -o ledger-deploy -g ledger-deploy /home/ledger-deploy/.ssh
```

Back on the operator machine, create the single authorized-key line, copy only
that public line through the existing admin SSH path, and install it as
`/home/ledger-deploy/.ssh/authorized_keys` mode 0600:

```bash
{
  printf '%s ' 'restrict,from="127.0.0.1",command="sudo -n /usr/local/sbin/beancount-ledger-deploy-submit"'
  cat "$deploy_key_dir/id_ed25519.pub"
} > "$deploy_key_dir/authorized_key"
ssh mibook 'install -d -m 700 /home/borui/.config/beancount-ledger-deploy-transfer'
scp "$deploy_key_dir/authorized_key" \
  mibook:/home/borui/.config/beancount-ledger-deploy-transfer/authorized_key
ssh mibook 'sudo install -m 600 -o ledger-deploy -g ledger-deploy \
  /home/borui/.config/beancount-ledger-deploy-transfer/authorized_key \
  /home/ledger-deploy/.ssh/authorized_keys'
```

The production host runs `tailscaled` with `--tun=userspace-networking`, so an
inbound tailnet connection is handed to `sshd` from loopback. Keep the key's
`from` restriction at the exact `127.0.0.1` address for this host; using the
tailnet CIDR rejects the correct key because OpenSSH never sees the remote
tailnet source address. The Headscale grant remains the network source control:
only `tag:ci-deploy` may reach this host on TCP/6247. Direct LAN or public
connections do not arrive from loopback and therefore cannot use this key.

Install `/etc/sudoers.d/beancount-ledger-deploy` as root, mode 0440:

```text
ledger-deploy ALL=(root) NOPASSWD: /usr/local/sbin/beancount-ledger-deploy-submit
```

Install `/etc/ssh/sshd_config.d/60-beancount-ledger-deploy.conf`:

```text
Match User ledger-deploy
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitTTY no
    AllowTcpForwarding no
    PermitTunnel no
    X11Forwarding no
```

Validate before reloading SSH:

```bash
sudo visudo -cf /etc/sudoers.d/beancount-ledger-deploy
sudo sshd -t
sudo systemctl reload ssh
ss -ltn '( sport = :6247 )'
```

Compare the host's ed25519 fingerprint with the scanned key, then store the
scan's full `[100.64.0.5]:6247 ssh-ed25519 ...` line as the
`SELFHOST_SSH_KNOWN_HOSTS` environment secret:

```bash
ssh mibook 'sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'
ssh-keyscan -p 6247 -t ed25519 100.64.0.5 > "$deploy_key_dir/known_hosts"
ssh-keygen -lf "$deploy_key_dir/known_hosts"
```

Never use `StrictHostKeyChecking=no`. After both GitHub secrets are confirmed,
shred the temporary private key and remove the transfer copy from mibook; do
not do either before confirmation.

## GitHub environment

Create `local-selfhost-production` with these settings:

- selected deployment branch: `main`
- no required reviewers
- administrator bypass disabled

Environment secrets:

- `HEADSCALE_CI_PREAUTH_KEY`
- `SELFHOST_DEPLOY_SSH_PRIVATE_KEY`
- `SELFHOST_SSH_KNOWN_HOSTS`

Environment variables:

```text
HEADSCALE_CONTROL_URL=https://headscale.borry.org
SELFHOST_DEPLOY_IP=100.64.0.5
SELFHOST_DEPLOY_PORT=6247
SELFHOST_DEPLOY_USER=ledger-deploy
```

```bash
gh variable set HEADSCALE_CONTROL_URL --body https://headscale.borry.org \
  --repo qiaoborui/beancount-ledger-web --env local-selfhost-production
gh variable set SELFHOST_DEPLOY_IP --body 100.64.0.5 \
  --repo qiaoborui/beancount-ledger-web --env local-selfhost-production
gh variable set SELFHOST_DEPLOY_PORT --body 6247 \
  --repo qiaoborui/beancount-ledger-web --env local-selfhost-production
gh variable set SELFHOST_DEPLOY_USER --body ledger-deploy \
  --repo qiaoborui/beancount-ledger-web --env local-selfhost-production
```

After the environment exists and the two fingerprints match, upload the two
local key files without printing them:

```bash
gh secret set SELFHOST_DEPLOY_SSH_PRIVATE_KEY \
  --repo qiaoborui/beancount-ledger-web \
  --env local-selfhost-production < "$deploy_key_dir/id_ed25519"
gh secret set SELFHOST_SSH_KNOWN_HOSTS \
  --repo qiaoborui/beancount-ledger-web \
  --env local-selfhost-production < "$deploy_key_dir/known_hosts"
```

No application, ledger, Postgres, GitHub Contents, Telegram, Gmail, AI, Caddy,
or GHCR credential belongs in this environment.

Once GitHub confirms both secrets, remove the temporary private material and
the public transfer copy using the already resolved temporary directory:

```bash
ssh mibook 'rm -f /home/borui/.config/beancount-ledger-deploy-transfer/authorized_key'
shred -u "$deploy_key_dir/id_ed25519"
rm -f "$deploy_key_dir/id_ed25519.pub" \
  "$deploy_key_dir/authorized_key" \
  "$deploy_key_dir/known_hosts"
rmdir "$deploy_key_dir"
```

The five GHCR packages are built only after the reusable CI gate passes. Keep
them linked to this public source repository and make these exact packages
public so the host needs no registry credential:

- `beancount-ledger-web-server`
- `beancount-ledger-web-indexer`
- `beancount-ledger-web-agent`
- `beancount-ledger-web-frontend`

The first `main` push creates all five packages while the activation variable is
still unset and the deploy job is skipped. Set their visibility to public and
prove one emitted digest can be pulled without `docker login` before enabling
deployment.

Use a default-branch ruleset to require pull requests with zero required
approving reviews and to prevent force pushes/deletion. Leave code-owner,
last-push, and unattributed-change approvals disabled. Keep conversation
resolution and the stable `CI / Gate` status check in classic branch
protection. The workflow remains inert while repository variable
`SELFHOST_DEPLOY_ENABLED` is unset. Only after the host, Headscale policy,
environment protections, secrets, variables, and public GHCR visibility are
ready, perform the final explicit activation:

```bash
gh variable set SELFHOST_DEPLOY_ENABLED --body true \
  --repo qiaoborui/beancount-ledger-web
gh workflow run deploy-selfhost.yml \
  --repo qiaoborui/beancount-ledger-web --ref main
```

## Deployment transaction

The host pulls every candidate digest before stopping the current stack. It
then stops all writers and the browser entrypoint, creates and verifies a
Postgres custom-format dump, and starts the candidate without Caddy in a
write-isolated maintenance environment. In that environment the Go API skips
module lifecycles and Gmail polling and rejects every route except health and
readiness, the indexer exposes `/health` but remains standby and unready, and
the Bub Telegram token is blank. The host verifies the
database/server/agent/indexer health, server readiness, and frontend process,
then stops the maintenance containers before committing the release.

Commit and activation are separate durable phases. Commit installs the active
release environment, writes both the one-level rollback record and
`/var/lib/beancount-ledger-deploy/activation.json`, then removes and fsyncs
`pending.json` before any normal writer or public entrypoint starts. Activation
starts the normal server, agent, indexer, and frontend; requires server and
indexer readiness; starts Caddy last; and verifies both loopback and
`https://beancount.mesh.arpa/api/ready` through the existing system Caddy CA.
Only then does it durably stage `completion.json`, remove and fsync the
activation marker, publish success, and consume the completion marker. A crash
in that final window republishes status without redeploying the active release.

The workflow and host both serialize deployments. A failed preflight leaves
production untouched. A failure before commit restores the dump and previous
release. Once `activation.json` exists, normal writers may have run, so recovery
never restores the old dump: it quiesces the committed release and retries only
forward activation. Operator rollback is refused until activation finishes.
If rollback or activation fails, application Caddy and writers remain stopped
and the durable marker is retained. The deploy unit also starts the recovery
unit on failure, including a Docker daemon interruption; the recovery unit
requires Docker and finishes `pending.json`, `activation.json`, and
`completion.json` in that order. Database restore follows the same boundary:
it commits and removes `pending.json` before starting the prior release, using
`rollback-activation.json` for idempotent, forward-only activation.
Every Docker, Compose, Git, and HTTP operation has a finite deadline; systemd
caps the deploy transaction at 35 minutes and gives its TERM-triggered recovery
up to 20 additional minutes before forcing the unit down with the durable
marker retained.

Backups are written under the root-only
`/var/lib/beancount-ledger-deploy/backups/` tree. Preserve a separate encrypted
copy of `/etc/beancount-ledger-selfhost/runtime.env`; it and the dump are an
inseparable recovery set. Do not automate backup deletion.

Each successful deployment leaves exactly one operator rollback record. To
exercise or invoke it, announce a maintenance window, read the active SHA from
the root-only record, then supply that same SHA as the destructive confirmation.
The command stops the application entrypoint before restoring data:

```bash
deployed_sha="$(sudo jq -r '.deployed_sha' /var/lib/beancount-ledger-deploy/rollback.json)"
sudo /usr/local/sbin/beancount-ledger-rollback \
  --confirm-deployed-sha "$deployed_sha"
curl --resolve beancount.mesh.arpa:443:127.0.0.1 \
  --cacert /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt \
  -fsS https://beancount.mesh.arpa/api/ready
```

This restores the exact predeployment database dump and prior images, consumes
the one-level rollback record, and retains the dump. It can discard passkeys,
notifications, or other database changes made after deployment; ledger commits
already pushed to the private GitHub repository remain authoritative and are
not deleted. Use it promptly in a maintenance window, then verify indexer
reconciliation before reopening traffic.

## First deployment verification

After the workflow reports success, verify the promoted SHA, all five
runtime labels, health, and absence of an unfinished transaction:

```bash
release_sha="$(sudo sed -n 's/^SELFHOST_VCS_REF=//p' /var/lib/beancount-ledger-deploy/releases/current.env)"
sudo test ! -e /var/lib/beancount-ledger-deploy/pending.json
sudo test ! -e /var/lib/beancount-ledger-deploy/rollback-activation.json
sudo test ! -e /var/lib/beancount-ledger-deploy/activation.json
sudo test ! -e /var/lib/beancount-ledger-deploy/completion.json
sudo jq -e --arg sha "$release_sha" '.deployed_sha == $sha' \
  /var/lib/beancount-ledger-deploy/rollback.json
for service in server indexer agent frontend zip-worker; do
  container_id="$(sudo docker compose \
    -p beancount-ledger-selfhost \
    --env-file /etc/beancount-ledger-selfhost/runtime.env \
    --env-file /var/lib/beancount-ledger-deploy/releases/current.env \
    -f /etc/beancount-ledger-selfhost/compose.yml ps -q "$service")"
  sudo docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
    "$container_id" | grep -Fx "$release_sha"
done
curl --resolve beancount.mesh.arpa:443:127.0.0.1 \
  --cacert /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt \
  -fsS https://beancount.mesh.arpa/api/ready
```

Run `headscale nodes list` on the Headscale server as the final network check.

Perform the one-level rollback command above before normal use, repeat these
health checks against the bootstrap release, then dispatch the same `main` SHA
again. Only the second healthy digest promotion proves both forward
deployment and recovery. Confirm that nodes whose names begin with
`gha-ledger-` are absent or expired after each job. Policy tests must prove
that `tag:ci-deploy` can reach only `100.64.0.5:6247`; separately preserve every
pre-existing personal-device and subnet-router grant.

## Retire the persistent runner

Only after the first digest deployment and rollback exercise succeed:

```bash
sudo systemctl disable --now \
  actions.runner.qiaoborui-beancount-ledger-web.mibook-beancount-ledger-web.service
runner_id="$(gh api repos/qiaoborui/beancount-ledger-web/actions/runners \
  --jq '.runners[] | select(.name == "mibook-beancount-ledger-web") | .id')"
test "$runner_id" = 22
gh api --method DELETE \
  "repos/qiaoborui/beancount-ledger-web/actions/runners/${runner_id}"
sudo install -d -m 700 -o root -g root /root/runner-quarantine
sudo mv /home/borui/actions-runner-beancount-ledger-web \
  /root/runner-quarantine/actions-runner-beancount-ledger-web-20260817
```

Audit and rotate any old `DEPLOY_*` or `RASPI_*` secrets that the runner could
read before deleting its quarantine. Do not keep a persistent or JIT runner on
this Docker host as a fallback.

## Explicit non-scope

- CI never updates root-owned Compose, Caddy, systemd, SSH, or deploy helpers.
- CI never receives application secrets, ledger data, Docker access, or a
  general-purpose host shell.
- Deployment never runs `git pull`, builds on the host, uses mutable image
  tags, changes the existing system Caddy site/CA, or adds CI DNS records.
- This profile does not replace the unknown active Headscale policy; the grant
  above must be merged only after the server-side policy and user identity are
  confirmed.
- Backups, runner quarantine, old GitHub secrets, and GHCR images are not
  deleted automatically.
