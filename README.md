# Salesforce DX — GitHub Actions CI/CD Pipeline

This repository uses GitHub Actions to automate Salesforce deployments across four environments. All environment workflows delegate to a single **reusable template** (`template.yaml`) via `workflow_call`. The pipeline distinguishes between **Pull Request** events (validate/dry-run) and **Push** events (actual deploy), and deploys only the **delta** of changed metadata rather than the full source.

---

## Architecture

```
abc_feature/** ──► sf.yaml             ─┐
staging        ──► sf_staging.yaml     ─┤
UAT / uat      ──► sf_uat.yaml         ├──► template.yaml  (Common Pipeline)
main / master  ──► sf_production.yaml  ─┘

workflow_dispatch ──► dispatch.yaml    (manual utility runs)
```

Each caller passes an `envionment` input and inherits all secrets. The template handles every build step uniformly.

---

## Workflows

### `template.yaml` — Common Pipeline (reusable)

The single source of truth for all pipeline logic. Consumed via `workflow_call`.

| Property | Value |
|----------|-------|
| Trigger | `workflow_call` |
| Inputs | `envionment` (required, string), `runner` (required, string, default: `ubuntu-latest`) |
| Secrets | `SLACK_WEBHOOK_URL` (optional); all others inherited from the caller |
| Default test level | `RunSpecifiedTests` |

### `sf.yaml` — Dev Pipeline

| Property | Value |
|----------|-------|
| GitHub Environment | `dev` |
| Trigger | Push to `abc_feature/**` |
| Path Filter | `force-app/**` |
| Runner | `macos-latest` |
| Calls | `template.yaml` with `envionment: dev` |

### `sf_staging.yaml` — Staging Pipeline

| Property | Value |
|----------|-------|
| GitHub Environment | `staging` |
| Trigger | Pull Request (`opened`, `synchronize`) targeting `staging` |
| Path Filter | `force-app/**` |
| Runner | `macos-latest` |
| Calls | `template.yaml` with `envionment: staging` |

### `sf_uat.yaml` — UAT Pipeline

| Property | Value |
|----------|-------|
| GitHub Environment | `UAT` |
| Trigger | Pull Request (`opened`, `synchronize`) targeting `UAT` or `uat` |
| Path Filter | `force-app/**` |
| Runner | `macos-latest` |
| Calls | `template.yaml` with `envionment: UAT` |

### `sf_production.yaml` — Production Pipeline

| Property | Value |
|----------|-------|
| GitHub Environment | `production` |
| Trigger | Pull Request (`opened`, `synchronize`) targeting `main` or `master` |
| Path Filter | `force-app/**` |
| Runner | `macos-latest` |
| Calls | `template.yaml` with `envionment: production` |

### `dispatch.yaml` — Manual Dispatch Workflow

A utility workflow (`workflow_dispatch`) for ad-hoc runs with configurable inputs:

| Input | Type | Options / Default |
|-------|------|-------------------|
| `name` | string | Free text (default: `monalisa`) |
| `environment` | choice | `dev`, `UAT`, `production` |
| `test-level` | choice | `RunSpecifiedTests`, `RunLocalTests`, `RunRelevantTests`, `DefaultTests` |
| `use-emoji` | boolean | `true` / `false` |
| `message` | string | Free text (optional) |
| `runner` | choice | `ubuntu-latest`, `windows-latest`, `macos-latest` |

---

## Pipeline Steps (template.yaml)

### Setup Phase (always runs)

```
 1. Checkout code              (fetch-depth: 0 for full git history)
 2. Setup Node.js              (>=20.9.0)
 3. Setup Java                 (>=11, Zulu distribution)
 4. Setup Python               (>=3.10)
 5. Read PR Body               (write body → READ_PRBODY.py → set apex_test_classes env var)
 6. Install Salesforce CLI     (npm install -g @salesforce/cli)
 7. Verify SF CLI version
 8. Install SF Code Analyzer   (only on open PRs — not merged)
 9. Install SFDX Git Delta     (sf plugins install sfdx-git-delta)
10. Generate Delta Files       (sf sgd source delta HEAD~1 → HEAD, API 66.0, output: ./delta)
11. Decrypt server.key         (AES-256-CBC via openssl)
12. JWT Authentication         (sf org login jwt)
```

### PR Phase — open / synchronize (validate only, `--dry-run`)

```
13. Run Salesforce Code Analyzer     (only on open PRs — not merged)
14. Quality Gate check               (fail on Sev1/Sev2 violations or >10 total)
15a. Validate — With Specific Tests  (if apex_test_classes != 'No Apex classes found')
15b. Validate — Default Test Level   (if apex_test_classes == 'No Apex classes found')
15c. Validate — RunRelevantTests     (if apex_test_classes == 'RunRelevantTests')
16. Enforce 82% Code Coverage        (python CODE_COVERAGE.py deploy-result.json)
```

### Push Phase — merge to branch (actual deploy, no dry-run)

```
17a. Deploy — RunRelevantTests       (if apex_test_classes == 'RunRelevantTests')
17b. Deploy — Default Test Level     (if apex_test_classes == 'No Apex classes found')
17c. Deploy — With Specific Tests    (if apex_test_classes != 'No Apex classes found')
```

### Notification Phase (always runs, both PR and Push)

```
18. Slack Notification (slackapi/slack-github-action@v3.0.3)
19. Slack Notify via curl            (status, repo, branch, actor, event, run URL)
```

---

## PR Body → Apex Test Classes

The pipeline reads `github.event.pull_request.body`, saves it to `pr_body.txt`, and runs `READ_PRBODY.py` to extract Apex test class names. The result is stored in the `apex_test_classes` environment variable and drives which validate/deploy step runs:

| `apex_test_classes` value | Validate step | Deploy step |
|---------------------------|---------------|-------------|
| Specific class names | `RunSpecifiedTests` with `--tests` | `RunSpecifiedTests` with `--tests` |
| `RunRelevantTests` | `RunRelevantTests` | `RunRelevantTests` |
| `No Apex classes found` | Default test level | Default test level |

---

## Delta Deployment (SFDX Git Delta)

Only changed metadata is deployed. The pipeline uses `sfdx-git-delta` to generate a delta `package.xml` and source directory between `HEAD~1` and `HEAD`:

```bash
mkdir delta
sf sgd source delta \
  --from "HEAD~1" \
  --to "HEAD" \
  --generate-delta \
  --ignore-file .sgdignore \
  --output-dir ./delta \
  --ignore-whitespace \
  --api-version 66.0 \
  --source-dir force-app/main/default
```

All deploy steps use `delta/force-app/main/default` as the source directory (not the full `force-app/main/default`).

---

## Authentication — JWT Flow

Authentication uses an **External Client App** with JWT (certificate-based). The private key is stored encrypted in the repository and decrypted at runtime.

**Decrypt the key at runtime:**
```bash
openssl enc -nosalt -aes-256-cbc -d \
  -in <ENCRYPTION_KEY_FILE> \
  -out <JWT_KEY_FILE> \
  -base64 \
  -K <DECRYPTION_KEY> \
  -iv <DECRYPTION_IV>
```

**Authenticate with Salesforce:**
```bash
sf org login jwt \
  --client-id <CONSUMER_KEY> \
  --jwt-key-file <JWT_KEY_FILE> \
  --username <DEPLOYMENT_USER_USERNAME> \
  --set-default \
  --alias <ORG_DEFAULT_ALIAS> \
  --instance-url <HUB_LOGIN_URL>
```

---

## One-Time Setup

### Step 1 — Generate the Certificate

```bash
# Generate encrypted private key
openssl genpkey -aes-256-cbc -algorithm RSA \
  -pass pass:<YOUR_PASSPHRASE> \
  -out assets/dev/server.pass.key \
  -pkeyopt rsa_keygen_bits:2048

# Strip the passphrase
openssl rsa -passin pass:<YOUR_PASSPHRASE> \
  -in assets/dev/server.pass.key \
  -out assets/dev/server.key

# Generate a CSR
openssl req -new -key assets/dev/server.key -out assets/dev/server.csr

# Self-sign the certificate (365 days)
openssl x509 -req -sha256 -days 365 \
  -in assets/dev/server.csr \
  -signkey assets/dev/server.key \
  -out assets/dev/server.crt
```

### Step 2 — Create an External Client App in Salesforce

1. Go to **Setup > External Client Apps > New External Client App**.
2. Enable **OAuth Settings**.
3. Set the callback URL to `http://localhost:1717/OauthRedirect`.
4. Upload `server.crt` under **Use Digital Signatures**.
5. Add the required OAuth scopes (API, refresh token, etc.).
6. Note the **Consumer Key** — this is your `CONSUMER_KEY` secret.

### Step 3 — Encrypt the Private Key for GitHub Actions

```bash
# Generate AES-256 encryption key and IV
openssl enc -aes-256-cbc -k <YOUR_PASSPHRASE> -P -md sha1 -nosalt

# Encrypt server.key
openssl enc -nosalt -aes-256-cbc \
  -in assets/dev/server.key \
  -out assets/dev/server.key.enc \
  -base64 \
  -K <KEY_FROM_ABOVE> \
  -iv <IV_FROM_ABOVE>
```

Commit `assets/dev/server.key.enc` to the repository. **Never commit the raw `server.key`.**

### Step 4 — Authenticate Locally (one-time verification)

```bash
sf org login jwt \
  --client-id <YOUR-CLIENT-ID> \
  --jwt-key-file assets/dev/server.key \
  --username <deployment-user-name> \
  --set-default --alias DEV_INT_ORG \
  --instance-url https://test.salesforce.com
```

---

## GitHub Environments & Secrets

Create four GitHub Environments (`dev`, `staging`, `UAT`, `production`) under **Settings > Environments**, each with the following secrets and variables.

### Secrets (per environment)

| Secret | Description |
|--------|-------------|
| `CONSUMER_KEY` | External Client App client ID |
| `ENCRYPTION_KEY` | AES encryption key (reference/other use) |
| `DECRYPTION_KEY` | AES key used to decrypt `server.key.enc` at runtime |
| `DECRYPTION_IV` | AES IV used to decrypt `server.key.enc` at runtime |
| `ENCRYPTION_KEY_FILE` | Path to the encrypted key file (e.g. `assets/dev/server.key.enc`) |
| `JWT_KEY_FILE` | Path where the decrypted key is written at runtime (e.g. `assets/dev/server.key`) |
| `DEPLOYMENT_USER_USERNAME` | Salesforce username used for deployment |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook URL for pipeline notifications |
| `SLACK_API_KEY` | Slack API key |

### Variables (per environment)

| Variable | Example Value | Description |
|----------|---------------|-------------|
| `ORG_DEFAULT_ALIAS` | `DEV_INT_ORG` | Salesforce org alias for this environment |
| `HUB_LOGIN_URL` | `https://test.salesforce.com` | `test.salesforce.com` for sandbox, `login.salesforce.com` for production |
| `NODE_VERSION` | `>=20.9.0` | Node.js version |
| `SF_CLI_VERSION` | `latest` | Salesforce CLI version |
| `PYTHON_VERSION` | `>=3.10` | Python version |

### Organization-Level Variable

| Variable | Description |
|----------|-------------|
| `ORGANIZATION_VARIABLE` | Shared variable available across all environments |

---

## Code Quality Gate

The Salesforce Code Analyzer (`forcedotcom/run-code-analyzer@v2`) runs only on open (not merged) Pull Requests. Results are uploaded as artifacts (`sfca_results.html`, `sfca_results.json`). The pipeline fails if any condition below is met:

| Condition | Threshold |
|-----------|-----------|
| Severity 1 violations | > 0 |
| Severity 2 violations | > 0 |
| Total violations | > 10 |

---

## Code Coverage Enforcement

After every dry-run validation on a PR, `CODE_COVERAGE.py` parses `deploy-result.json` and enforces a minimum of **82% Apex code coverage**. The job fails if coverage falls below this threshold.

---

## Slack Notifications

Every pipeline run sends a Slack notification on completion (success or failure) via two methods:

1. **`slackapi/slack-github-action@v3.0.3`** — official action with `webhook-trigger` mode.
2. **`curl` POST** — rich attachment payload including repository, branch, triggered-by, event type, and a direct link to the Actions run.

Both steps run with `if: always()` so notifications fire even when earlier steps fail.

---

## Branch Strategy

```
abc_feature/**  ──►  Dev         (push only)
staging         ──►  Staging     (PR opened/synchronize)
UAT / uat       ──►  UAT         (PR opened/synchronize)
main / master   ──►  Production  (PR opened/synchronize)
```

---

## Tool Versions

| Tool | Version |
|------|---------|
| Salesforce CLI | `latest` |
| Node.js | `>=20.9.0` |
| Java (Zulu) | `>=11` |
| Python | `>=3.10` |
| Salesforce API (delta) | `66.0` |
| Salesforce API (source) | `65.0` |
| Default Runner (template) | `ubuntu-latest` |
| Runner (all callers) | `macos-latest` |
