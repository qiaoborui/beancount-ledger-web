# Gmail bill import automation

Gmail automation monitors one Gmail Label, downloads matching messages with the Gmail API, and stores parsed imports in Postgres for manual Review. Ledger writes still use the existing preview, validation, deduplication, and commit path. Select its delivery mode explicitly with `GMAIL_DELIVERY_MODE`; the application never infers it from a public URL.

## Runtime flow

Webhook mode (`GMAIL_DELIVERY_MODE=webhook`, the hosted/default mode):

```text
Gmail sender filter
  -> Ledger/Bills label
  -> Gmail users.watch
  -> Cloud Pub/Sub authenticated push
  -> POST /api/integrations/gmail/pubsub
  -> durable Postgres event inbox
  -> immediate queue drain in the Pub/Sub request
  -> Gmail history.list + messages.get(format=raw)
  -> EML / CSV / XLSX / PDF / ZIP parsing
  -> Postgres pending import
  -> /import Review
  -> existing import commit

Cloud Scheduler every 30 minutes
  -> POST /api/integrations/gmail/drain
  -> retry persisted transient failures
```

The Cloud Run backend scales to zero during quiet periods. Pub/Sub wakes it to validate, persist, and immediately process each event. Google Cloud Scheduler wakes the drain endpoint every 30 minutes as a retry fallback and renews the seven-day Gmail Watch once per day. Failed transient Gmail calls use persisted backoff, so deployment restarts and Pub/Sub redelivery preserve the queued work. The webhook always validates Google's signed OIDC token, audience, and exact service-account email before it reads a payload.

Polling mode (`GMAIL_DELIVERY_MODE=poll`, the self-hosted Compose default) is for Tailnet, LAN, and other deployments without public inbound access:

```text
local long-running server
  -> periodic outbound Gmail history.list + messages.get(format=raw)
  -> EML / CSV / XLSX / PDF / ZIP parsing
  -> Postgres pending import
  -> /import Review
  -> existing import commit
```

The process runs one immediate attempt at startup and then one attempt every `GMAIL_POLL_INTERVAL` (application default `15m`; the self-hosted Compose stack sets `2m`). Each attempt has the `GMAIL_POLL_TIMEOUT` deadline (default `14m`, range `30s`–`14m`), which stays below the durable fifteen-minute Gmail sync lease. It cannot overlap another local attempt and uses that lease to avoid colliding with a manual sync. Every history or lookback scan first persists each Gmail message ID in the durable event inbox, then advances the history cursor and processes the queued messages in bounded batches. A slow PDF or ZIP can therefore time out and retry without restarting the scan. Failures are retained as the connection's last error and retried on the next interval. Shutdown cancels the active request and waits for the worker to finish. Poll mode makes only outbound Gmail API calls: it does not create `users.watch`, a Pub/Sub subscription, a Scheduler job, or an inbound webhook.

When processing reaches a durable `ready` or `failed` pending-import state, the notification service publishes one aggregated Web Push message per Gmail message. The notification reports the counts waiting for Review and requiring attention, links to `/import`, and uses a stable tag so browser notification trays can collapse repeated delivery. Retry processing publishes the same completion result with a retry-specific tag. Web Push delivery remains best-effort after the pending state is stored.

The native iOS import screen uses these same server-side delivery modes; it never connects directly to Gmail or keeps an inbox poller alive on the device. While the screen is active it subscribes to authenticated server-sent events at `GET /api/ledger/imports/pending/events`. A committed pending-state write signals clients on the same server instance immediately, with a three-second durable-store revision check covering multi-instance deployments; the stream sends no financial payload, so the App reloads the authenticated status and pending endpoints after each signal. iOS stops and reconnects the stream with the scene lifecycle. Native OAuth is selected explicitly with `POST /api/integrations/gmail/connect?client=ios`; bounded concurrent OAuth states are consumed atomically before code exchange, permitting the browser callback without sharing the App's cookie jar. The fixed `ledger://gmail-import` return includes that one-time correlation value, and the App accepts it only for an authorization it initiated before confirming success through the authenticated status endpoint. The Web callback retains its existing sensitive-cookie requirement. No User-Agent inference is used.

## Webhook mode: Google Cloud setup

1. Create a personal Google Cloud project and enable the Gmail API and Cloud Pub/Sub API.
2. Configure an OAuth consent screen. Use Production status for durable offline access; External apps left in Testing receive refresh tokens that expire after seven days when Gmail scopes are requested.
3. Create an OAuth Web application client. Add this exact redirect URI:

   ```text
   https://YOUR_LEDGER_HOST/api/integrations/gmail/callback
   ```

4. Create a Pub/Sub topic such as `projects/PROJECT_ID/topics/ledger-gmail`.
5. Grant `gmail-api-push@system.gserviceaccount.com` the Pub/Sub Publisher role on that topic.
6. Create a push subscription targeting:

   ```text
   https://YOUR_LEDGER_HOST/api/integrations/gmail/pubsub
   ```

7. Enable authenticated push. Select a dedicated service account, set the audience to the same Pub/Sub endpoint URL, set the acknowledgement deadline to 60 seconds, and grant that service account permission to invoke the deployed backend when the platform requires it.
8. Create a Cloud Scheduler HTTP job with schedule `*/30 * * * *`, method `POST`, and URL:

   ```text
   https://YOUR_LEDGER_HOST/api/integrations/gmail/drain
   ```

   Configure an OIDC token from a dedicated Scheduler service account. Set the
   token audience to `https://YOUR_LEDGER_HOST`.

9. Create a daily Cloud Scheduler HTTP job with schedule `17 3 * * *`, method
   `POST`, and URL:

   ```text
   https://YOUR_LEDGER_HOST/api/integrations/gmail/renew
   ```

   Use the same Scheduler service account and OIDC audience. The job renews
   Gmail Watch before its seven-day expiration.

## Poll mode: no-public-ingress setup

1. Create an OAuth Web application client and add the callback URI reachable by the browser during connection, for example `https://ledger.tailnet.example/api/integrations/gmail/callback`.
2. Set `GMAIL_DELIVERY_MODE=poll` and the shared Gmail variables below. No Pub/Sub, Scheduler, Pub/Sub service account, or cron credentials are needed.
3. Keep the self-hosted `server` container running. Its built-in worker calls Gmail from the container; no Google service-account credential or inbound port is required.
4. Connect Gmail once from `/import`. Poll mode initializes its history cursor from the authenticated Gmail profile and starts the regular outgoing syncs.

For Tailnet HTTPS, follow the normal WebAuthn and OAuth redirect setup. The redirect URI must be reachable by the user agent, but Gmail delivery itself never needs to reach the server.

## Gmail filter

Create the `Ledger/Bills` Label in Gmail. Add Gmail filters for the exact bank senders and optional subject terms, then apply this Label automatically. Example search:

```text
from:(service@mail.alipay.com OR service@vip.ccb.com OR ccsvc@message.cmbchina.com) subject:(账单 OR statement)
```

This covers Alipay, China Construction Bank credit cards, and China Merchants Bank credit cards. CMB statements arrive as PDF attachments from `ccsvc@message.cmbchina.com`; the backend routes those PDFs through the existing CMB credit-card importer. Configure the same exact sender addresses in `GMAIL_ALLOWED_SENDERS`. Gmail Label filtering reduces mailbox notifications; the backend allowlist provides a second sender check before parsing files.

## Environment

```dotenv
# Shared in both modes
GMAIL_CLIENT_ID=
GMAIL_CLIENT_SECRET=
GMAIL_OAUTH_REDIRECT_URL=https://YOUR_LEDGER_HOST/api/integrations/gmail/callback
GMAIL_LABEL=Ledger/Bills
GMAIL_ALLOWED_SENDERS=service@mail.alipay.com,service@vip.ccb.com,ccsvc@message.cmbchina.com
GMAIL_TOKEN_ENCRYPTION_KEY=
GMAIL_SYNC_LOOKBACK_DAYS=30
GMAIL_ZIP_PASSWORDS=
GMAIL_ZIP_TIMEOUT_SECONDS=840
ZIP_WORKER_URL=
ZIP_WORKER_AUDIENCE=

# Hosted/public deployment (default): authenticated Pub/Sub push + Scheduler
GMAIL_DELIVERY_MODE=webhook
GMAIL_PUBSUB_TOPIC=projects/PROJECT_ID/topics/ledger-gmail
GMAIL_PUBSUB_AUDIENCE=https://YOUR_LEDGER_HOST/api/integrations/gmail/pubsub
GMAIL_PUBSUB_SERVICE_ACCOUNT=gmail-push@PROJECT_ID.iam.gserviceaccount.com
CRON_OIDC_AUDIENCE=https://YOUR_LEDGER_HOST
CRON_OIDC_SERVICE_ACCOUNT=ledger-web-scheduler@PROJECT_ID.iam.gserviceaccount.com
# Transition fallback for Vercel Cron and existing secret-header jobs.
CRON_SECRET=

# Tailnet/LAN deployment: outbound local scheduler only
# GMAIL_DELIVERY_MODE=poll
# GMAIL_POLL_INTERVAL=15m
# GMAIL_POLL_TIMEOUT=14m
```

Generate the encryption key with `openssl rand -base64 32`. `GMAIL_ZIP_PASSWORDS` accepts comma-separated known passwords and tries them before automatic search. Automatic search tries six-digit numeric passwords in the main application, then sends the archive to the IAM-protected ZIP Worker for six-character uppercase-alphanumeric search when `ZIP_WORKER_URL` is configured. `ZIP_WORKER_AUDIENCE` defaults to the worker URL. The main application verifies the returned password against the archive before extraction. Local and non-Cloud Run environments retain the in-process uppercase-alphanumeric fallback. The built-in fast path supports unencrypted ZIP and classic ZipCrypto entries using stored or deflate compression. AES-encrypted, ZIP64, multi-disk, oversized, and deeply nested archives are rejected with a visible pending-import error.

## Connect and verify

1. Deploy the environment variables and open `/import` while signed in.
2. Select **Connect Gmail**, approve read-only Gmail access, and return to the import page.
3. Confirm the card shows the connected Gmail address and `Ledger/Bills` Label.
4. Send or relabel one safe test statement from an allowed sender.
5. Confirm the Web Push notification reports the processing result and links to `/import`.
6. Review the generated entries and commit them through the normal import flow.

The status endpoint is `GET /api/integrations/gmail/status`; it includes the active delivery mode. Sensitive unlock protects connection changes, synchronization, pending financial previews, dismissal, and Gmail-backed commits. In webhook mode, Cloud Scheduler calls `POST /api/integrations/gmail/drain` and `POST /api/integrations/gmail/renew` with Google-signed OIDC tokens. Disconnect revokes the Google refresh token before deleting the local encrypted credential.

## Migrating modes

To move from webhook to poll, deploy `GMAIL_DELIVERY_MODE=poll` with the shared variables intact, then remove or disable the Pub/Sub push subscription and both Scheduler jobs after the new server has started. Existing persisted retry events are drained by the polling worker before its regular history sync. To move back, first create or verify the authenticated push subscription and Scheduler jobs, set the webhook-only variables, and deploy `GMAIL_DELIVERY_MODE=webhook`. Immediately invoke `POST /api/integrations/gmail/renew` once with the Scheduler OIDC identity (or configured cron secret) before considering the migration complete; this establishes the new `users.watch` without waiting for the daily renewal schedule. The webhook endpoint remains authenticated in either release; poll mode returns `404` for incoming Pub/Sub delivery instead of accepting an unauthenticated fallback.

See [google-cloud-run.md](google-cloud-run.md) for the Cloud Run, Secret
Manager, Scheduler, domain, and rollback commands.
