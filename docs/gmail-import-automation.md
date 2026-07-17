# Gmail bill import automation

Gmail automation watches one Gmail Label, receives mailbox history notifications through authenticated Cloud Pub/Sub, downloads matching messages with the Gmail API, and stores parsed imports in Postgres for manual Review. Ledger writes still use the existing preview, validation, deduplication, and commit path.

## Runtime flow

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

The Cloud Run backend scales to zero during quiet periods. Pub/Sub wakes it to validate, persist, and immediately process each event. Google Cloud Scheduler wakes the drain endpoint every 30 minutes as a retry fallback and renews the seven-day Gmail Watch once per day. Failed transient Gmail calls use persisted backoff, so deployment restarts and Pub/Sub redelivery preserve the queued work.

## Google Cloud setup

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

The backend validates Google-signed OIDC tokens, their audience, and the exact
service-account email for Pub/Sub and Scheduler requests.

## Gmail filter

Create the `Ledger/Bills` Label in Gmail. Add Gmail filters for the exact bank senders and optional subject terms, then apply this Label automatically. Example search:

```text
from:(statement@example-bank.com OR bill@example-card.com) subject:(账单 OR statement)
```

Configure the same exact sender addresses in `GMAIL_ALLOWED_SENDERS`. Gmail Label filtering reduces mailbox notifications; the backend allowlist provides a second sender check before parsing files.

## Environment

```dotenv
GMAIL_CLIENT_ID=
GMAIL_CLIENT_SECRET=
GMAIL_OAUTH_REDIRECT_URL=https://YOUR_LEDGER_HOST/api/integrations/gmail/callback
GMAIL_PUBSUB_TOPIC=projects/PROJECT_ID/topics/ledger-gmail
GMAIL_PUBSUB_AUDIENCE=https://YOUR_LEDGER_HOST/api/integrations/gmail/pubsub
GMAIL_PUBSUB_SERVICE_ACCOUNT=gmail-push@PROJECT_ID.iam.gserviceaccount.com
GMAIL_LABEL=Ledger/Bills
GMAIL_ALLOWED_SENDERS=statement@example-bank.com,bill@example-card.com
GMAIL_TOKEN_ENCRYPTION_KEY=
GMAIL_SYNC_LOOKBACK_DAYS=30
GMAIL_ZIP_PASSWORDS=
GMAIL_ZIP_TIMEOUT_SECONDS=20
CRON_OIDC_AUDIENCE=https://YOUR_LEDGER_HOST
CRON_OIDC_SERVICE_ACCOUNT=ledger-web-scheduler@PROJECT_ID.iam.gserviceaccount.com
# Transition fallback for Vercel Cron and existing secret-header jobs.
CRON_SECRET=
```

Generate the encryption key with `openssl rand -base64 32`. `GMAIL_ZIP_PASSWORDS` accepts comma-separated known passwords and tries them before automatic search. Automatic search tries six-digit numeric passwords first, then six-character combinations of digits and uppercase letters within `GMAIL_ZIP_TIMEOUT_SECONDS`. The built-in fast path supports unencrypted ZIP and classic ZipCrypto entries using stored or deflate compression. AES-encrypted, ZIP64, multi-disk, oversized, and deeply nested archives are rejected with a visible pending-import error.

## Connect and verify

1. Deploy the environment variables and open `/import` while signed in.
2. Select **Connect Gmail**, approve read-only Gmail access, and return to the import page.
3. Confirm the card shows the connected Gmail address and `Ledger/Bills` Label.
4. Send or relabel one safe test statement from an allowed sender.
5. Confirm a pending Review item appears and its Web Push notification links to `/import`.
6. Review the generated entries and commit them through the normal import flow.

The status endpoint is `GET /api/integrations/gmail/status`. Sensitive unlock protects connection changes, synchronization, pending financial previews, dismissal, and Gmail-backed commits. Cloud Scheduler calls `POST /api/integrations/gmail/drain` and `POST /api/integrations/gmail/renew` with Google-signed OIDC tokens. Disconnect revokes the Google refresh token before deleting the local encrypted credential.

See [google-cloud-run.md](google-cloud-run.md) for the Cloud Run, Secret
Manager, Scheduler, domain, and rollback commands.
