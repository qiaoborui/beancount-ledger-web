# Google Cloud Run deployment

The hosted topology runs one standalone container on Cloud Run. The Go process
serves the Vite build and `/api/*` from the same origin, preserving the existing
session cookies, sensitive-unlock cookie, passkeys, PWA behavior, and long AI
SSE requests.

```text
Browser -> Cloud Run standalone image -> Postgres / GitHub API / Gmail / AI
Cloud Scheduler -> Cloud Run Gmail drain and Watch renewal endpoints
Private ledger GitHub Actions -> ledger-indexer -> Postgres read model
```

The deployment workflow lives at
`.github/workflows/deploy-google-cloud.yml`. It runs backend tests, frontend
typecheck/tests/build, publishes an immutable image to Artifact Registry, and
deploys the image digest to Cloud Run. Missing Google Cloud repository variables
leave the deployment job skipped.

## Prerequisites

- An active Google Cloud billing account linked to the project.
- A region close to the Postgres database. The examples use Singapore.
- The existing production origin and passkey RP ID.
- GitHub repository administrator access for Actions variables and secrets.
- DNS access for the production domain.

The `beancount-502511` project currently needs an active billing account before
Cloud Run, Artifact Registry, Secret Manager, and Cloud Scheduler resources can
be created.

## One-time Google Cloud setup

```bash
export PROJECT_ID=beancount-502511
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export REGION=asia-southeast1
export ARTIFACT_REPOSITORY=beancount-ledger-web
export CLOUD_RUN_SERVICE=beancount-ledger-web
export RUNTIME_SERVICE_ACCOUNT=ledger-web-runtime
export DEPLOY_SERVICE_ACCOUNT=ledger-web-deploy
export SCHEDULER_SERVICE_ACCOUNT=ledger-web-scheduler
export WORKLOAD_IDENTITY_POOL=github
export WORKLOAD_IDENTITY_PROVIDER=beancount-ledger-web
export GITHUB_REPOSITORY=qiaoborui/beancount-ledger-web
export GITHUB_REPOSITORY_ID="$(gh api "repos/${GITHUB_REPOSITORY}" --jq .id)"
export GITHUB_OWNER_ID="$(gh api users/qiaoborui --jq .id)"
export GITHUB_WORKFLOW_REF="${GITHUB_REPOSITORY}/.github/workflows/deploy-google-cloud.yml@refs/heads/main"

gcloud services enable \
  artifactregistry.googleapis.com \
  cloudscheduler.googleapis.com \
  iamcredentials.googleapis.com \
  run.googleapis.com \
  secretmanager.googleapis.com \
  sts.googleapis.com \
  --project "$PROJECT_ID"

gcloud artifacts repositories create "$ARTIFACT_REPOSITORY" \
  --project "$PROJECT_ID" \
  --location "$REGION" \
  --repository-format docker \
  --description "Beancount Ledger Web images"

gcloud iam service-accounts create "$RUNTIME_SERVICE_ACCOUNT" \
  --project "$PROJECT_ID" \
  --display-name "Beancount Ledger Web runtime"

gcloud iam service-accounts create "$DEPLOY_SERVICE_ACCOUNT" \
  --project "$PROJECT_ID" \
  --display-name "Beancount Ledger Web deployer"

gcloud iam service-accounts create "$SCHEDULER_SERVICE_ACCOUNT" \
  --project "$PROJECT_ID" \
  --display-name "Beancount Ledger Web scheduler"
```

Grant the deploy identity the permissions used by the workflow:

```bash
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${DEPLOY_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role roles/run.admin

gcloud artifacts repositories add-iam-policy-binding "$ARTIFACT_REPOSITORY" \
  --project "$PROJECT_ID" \
  --location "$REGION" \
  --member "serviceAccount:${DEPLOY_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role roles/artifactregistry.writer

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${DEPLOY_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role roles/serviceusage.serviceUsageConsumer

gcloud iam service-accounts add-iam-policy-binding \
  "${RUNTIME_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --project "$PROJECT_ID" \
  --member "serviceAccount:${DEPLOY_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role roles/iam.serviceAccountUser
```

## Repository-scoped Workload Identity Federation

The provider accepts tokens only from the production deployment workflow on
`refs/heads/main`. Stable GitHub repository and owner IDs keep repository
renames and name reuse outside the trust boundary.

```bash
gcloud iam workload-identity-pools create "$WORKLOAD_IDENTITY_POOL" \
  --project "$PROJECT_ID" \
  --location global \
  --display-name "GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc "$WORKLOAD_IDENTITY_PROVIDER" \
  --project "$PROJECT_ID" \
  --location global \
  --workload-identity-pool "$WORKLOAD_IDENTITY_POOL" \
  --display-name "Beancount Ledger Web deploy" \
  --issuer-uri "https://token.actions.githubusercontent.com" \
  --attribute-mapping "google.subject=assertion.sub,attribute.repository_id=assertion.repository_id,attribute.repository_owner_id=assertion.repository_owner_id,attribute.ref=assertion.ref,attribute.workflow_ref=assertion.workflow_ref" \
  --attribute-condition "assertion.repository_id=='${GITHUB_REPOSITORY_ID}' && assertion.repository_owner_id=='${GITHUB_OWNER_ID}' && assertion.ref=='refs/heads/main' && assertion.workflow_ref=='${GITHUB_WORKFLOW_REF}'"

gcloud iam service-accounts add-iam-policy-binding \
  "${DEPLOY_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --project "$PROJECT_ID" \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WORKLOAD_IDENTITY_POOL}/attribute.repository_id/${GITHUB_REPOSITORY_ID}"

gcloud iam workload-identity-pools providers describe "$WORKLOAD_IDENTITY_PROVIDER" \
  --project "$PROJECT_ID" \
  --location global \
  --workload-identity-pool "$WORKLOAD_IDENTITY_POOL" \
  --format 'value(name)'
```

Use the returned provider name as `GCP_WORKLOAD_IDENTITY_PROVIDER`. The workflow
pins every third-party action to a full commit SHA and requests the OIDC token
after repository tests pass.

## Secret Manager

Create one Secret Manager secret per sensitive environment variable. Reuse the
current production values.

Required secrets:

- `AUTH_SECRET`
- `APP_PASSWORD`
- `DATABASE_URL`
- `LEDGER_GITHUB_TOKEN`

Feature-specific secrets include `DEEPSEEK_API_KEY`, `OPENAI_API_KEY`,
`WEB_PUSH_VAPID_PRIVATE_KEY`, `GMAIL_CLIENT_SECRET`,
`GMAIL_TOKEN_ENCRYPTION_KEY`, `GMAIL_ZIP_PASSWORDS`, and the transition-only
`CRON_SECRET`.

Example:

```bash
gcloud secrets create ledger-auth-secret \
  --project "$PROJECT_ID" \
  --replication-policy automatic

printf '%s' "$AUTH_SECRET" | gcloud secrets versions add ledger-auth-secret \
  --project "$PROJECT_ID" \
  --data-file=-

gcloud secrets add-iam-policy-binding ledger-auth-secret \
  --project "$PROJECT_ID" \
  --member "serviceAccount:${RUNTIME_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role roles/secretmanager.secretAccessor
```

Apply the same secret-level IAM binding to every secret used by the service.
The GitHub Actions secret `CLOUD_RUN_SECRET_MAPPINGS` maps environment variables
to Secret Manager versions:

```text
AUTH_SECRET=ledger-auth-secret:latest,APP_PASSWORD=ledger-app-password:latest,DATABASE_URL=ledger-database-url:latest,LEDGER_GITHUB_TOKEN=ledger-github-token:latest
```

Add feature-specific mappings for enabled integrations. Include `CRON_SECRET`
during the Vercel rollback window because the existing Vercel Cron uses it.

## GitHub repository configuration

Create a protected GitHub environment named `google-cloud-production`. Restrict
deployment branches to `main` and add required reviewers when the repository
uses multi-person administration. Create these Actions variables at repository
level so the workflow can evaluate its configuration gate:

| Variable | Value |
| --- | --- |
| `GCP_PROJECT_ID` | `beancount-502511` |
| `GCP_REGION` | Region such as `asia-southeast1` |
| `GCP_ARTIFACT_REPOSITORY` | Artifact Registry repository |
| `GCP_CLOUD_RUN_SERVICE` | Cloud Run service name |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Full provider name returned by `gcloud` |
| `GCP_DEPLOY_SERVICE_ACCOUNT` | Deploy service-account email |
| `GCP_RUNTIME_SERVICE_ACCOUNT` | Runtime service-account email |
| `LEDGER_GITHUB_OWNER` | Private ledger repository owner |
| `LEDGER_GITHUB_REPO` | Private ledger repository name |
| `LEDGER_GIT_BRANCH` | Ledger branch, normally `main` |
| `PUBLIC_ORIGIN` | Final HTTPS browser origin |
| `WEBAUTHN_RP_ID` | Existing passkey relying-party domain |
| `WEBAUTHN_PUBLIC_ORIGIN` | Allowed passkey origins |

Store `CLOUD_RUN_SECRET_MAPPINGS` as a secret in the
`google-cloud-production` environment. `CLOUD_RUN_EXTRA_ENV_VARS` carries
optional public configuration as
`KEY=VALUE|KEY=VALUE`. The pipe character is reserved as the separator. Example:

```text
LEDGER_AI_PROVIDER=deepseek|GMAIL_CLIENT_ID=client-id.apps.googleusercontent.com|GMAIL_OAUTH_REDIRECT_URL=https://beancount.borry.org/api/integrations/gmail/callback|GMAIL_PUBSUB_TOPIC=projects/beancount-502511/topics/ledger-gmail|GMAIL_PUBSUB_AUDIENCE=https://beancount.borry.org/api/integrations/gmail/pubsub|GMAIL_PUBSUB_SERVICE_ACCOUNT=gmail-push@beancount-502511.iam.gserviceaccount.com|GMAIL_LABEL=Ledger/Bills|GMAIL_ALLOWED_SENDERS=bill@example.com|CRON_OIDC_AUDIENCE=https://beancount.borry.org|CRON_OIDC_SERVICE_ACCOUNT=ledger-web-scheduler@beancount-502511.iam.gserviceaccount.com
```

## First deployment

Merge the deployment change, configure the repository values, then run `Deploy
Google Cloud` from `main`. The workflow deploys with request-based CPU, zero
minimum instances, two maximum instances, concurrency eight, a 15-minute
request timeout, and 512 MiB memory. Each revision starts with zero production
traffic behind a unique tag. The workflow verifies the tagged URL, promotes the
revision, verifies the service URL, and restores the previous traffic split
when post-promotion health checks fail.

Verify the generated `run.app` URL:

1. `/` serves the Vite application.
2. `/api/health` reports healthy Postgres runtime and read-model adapters.
3. Password login and sensitive unlock succeed.
4. Ledger reads show the same active revision as production.
5. A preview-ledger write creates a GitHub commit and appears after indexing.
6. AI chat streams SSE events through the same Cloud Run origin.
7. Import preview upload and pending-import retrieval succeed.

Passkey verification follows after the production domain is mapped because the
RP ID remains the existing domain.

## Production domain

Cloud Run domain mapping is available in `asia-southeast1` as a Preview
feature. Google documents latency limitations and recommends its GA load
balancer path for production services. Domain mapping is the explicit low-fixed-
cost tradeoff for this personal deployment, with Vercel retained as the
production fallback during observation.

```bash
export DOMAIN=beancount.borry.org

gcloud components install beta

gcloud domains list-user-verified
gcloud domains verify borry.org

gcloud beta run domain-mappings create \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --service "$CLOUD_RUN_SERVICE" \
  --domain "$DOMAIN"

gcloud beta run domain-mappings describe \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --domain "$DOMAIN"
```

Apply the returned DNS records, then verify password login, passkey login,
ledger reads and writes, AI streaming, import upload, PWA installation, and web
push on the production domain. A global external Application Load Balancer is
the future GA domain option when its fixed monthly cost fits the deployment.

## Cloud Scheduler OIDC

The API validates Google-signed scheduler identity tokens by audience and exact
service-account email. Scheduler jobs carry no reusable cron secret.

Grant the operator creating jobs permission to attach the scheduler identity:

```bash
export OPERATOR_ACCOUNT="$(gcloud config get-value account)"

gcloud iam service-accounts add-iam-policy-binding \
  "${SCHEDULER_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --project "$PROJECT_ID" \
  --member "user:${OPERATOR_ACCOUNT}" \
  --role roles/iam.serviceAccountUser
```

Create the drain and Gmail Watch renewal jobs after the production domain is
active:

```bash
export PUBLIC_ORIGIN=https://beancount.borry.org
export SCHEDULER_EMAIL="${SCHEDULER_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud scheduler jobs create http ledger-gmail-drain \
  --project "$PROJECT_ID" \
  --location "$REGION" \
  --schedule "* * * * *" \
  --uri "${PUBLIC_ORIGIN}/api/integrations/gmail/drain" \
  --http-method POST \
  --oidc-service-account-email "$SCHEDULER_EMAIL" \
  --oidc-token-audience "$PUBLIC_ORIGIN"

gcloud scheduler jobs create http ledger-gmail-renew \
  --project "$PROJECT_ID" \
  --location "$REGION" \
  --schedule "17 3 * * *" \
  --uri "${PUBLIC_ORIGIN}/api/integrations/gmail/renew" \
  --http-method POST \
  --oidc-service-account-email "$SCHEDULER_EMAIL" \
  --oidc-token-audience "$PUBLIC_ORIGIN"
```

Set `CRON_OIDC_AUDIENCE` to `PUBLIC_ORIGIN` and
`CRON_OIDC_SERVICE_ACCOUNT` to `SCHEDULER_EMAIL`. The existing `CRON_SECRET`
path remains available during the Vercel transition.

## Rollback

During the migration window, restoring the previous DNS records returns traffic
to Vercel. GitHub and Postgres remain shared throughout the migration.

Cloud Run retains previous revisions for later releases:

```bash
gcloud run revisions list \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --service "$CLOUD_RUN_SERVICE"

gcloud run services update-traffic "$CLOUD_RUN_SERVICE" \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --to-revisions PREVIOUS_REVISION=100
```

After 24–48 hours of healthy production traffic, disable the Vercel deployment
and remove its Speed Insights and deployment configuration in a focused cleanup
change.
