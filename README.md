# Salesforce DX — GitHub Actions CI/CD Pipeline

This repository uses GitHub Actions to automate Salesforce deployments across multiple environments. All environment-specific workflows delegate to a single **reusable template** (`template.yaml`) via `workflow_call`, keeping pipeline logic DRY and centralised.

---

## Architecture

```
feature/** branch  ──► sf.yaml            ─┐
UAT / uat branch   ──► sf_uat.yaml        ─┼──► template.yaml  (Common Pipeline)
staging branch     ──► sf_staging.yaml    ─┘
main branch        ──► sf_production.yaml  (standalone — not yet on template)

workflow_dispatch  ──► dispatch.yaml       (manual utility runs)
```

Each caller passes an `envionment` input and inherits all secrets; the template handles every build step uniformly.

---

## Workflows

### `template.yaml` — Common Pipeline (reusable)

The single source of truth for all pipeline logic. Consumed via `workflow_call`.

| Property | Value |
|----------|-------|
| Trigger | `workflow_call` (called by environment workflows) |
| Inputs | `envionment` (required, string), `runner` (required, string, default: `ubuntu-latest`) |
| Secrets | `SLACK_WEBHOOK_URL` (optional); all others inherited from caller |

### `sf.yaml` — Dev Pipeline

| Property | Value |
|----------|-------|
| GitHub Environment | `dev` |
| Trigger | Push to `feature/**` branches |
| Path Filter | `force-app/**` |
| Runner | `macos-latest` |
| Calls | `template.yaml` with `envionment: dev` |

### `sf_staging.yaml` — Staging Pipeline

| Property | Value |
|----------|-------|
| GitHub Environment | `staging` |
| Trigger | Pull Request (opened/closed) targeting `staging` |
| Path Filter | `force-app/**` |
| Runner | `macos-latest` |
| Calls | `template.yaml` with `envionment: staging` |

### `sf_uat.yaml` — UAT Pipeline

| Property | Value |
|----------|-------|
| GitHub Environment | `UAT` |
| Trigger | Pull Request (opened / closed / synchronize) targeting `UAT` or `uat` |
| Path Filter | `force-app/**` |
| Runner | `macos-latest` |
| Calls | `template.yaml` with `envionment: UAT` |

### `sf_production.yaml` — Production Pipeline

| Property | Value |
|----------|-------|
| GitHub Environment | `production` |
| Trigger | Push to `main`, or Pull Request (opened/closed) targeting `main` |
| Path Filter | `force-app/**` |
| Runner | `ubuntu-latest` |
| Note | Standalone (not yet refactored to use `template.yaml`) |

### `dispatch.yaml` — Manual Dispatch Workflow

A utility workflow (`workflow_dispatch`) with configurable inputs for ad-hoc runs:

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

The common pipeline runs the following steps for every environment:

```
 1. Checkout code              (fetch-depth: 0 for full git history)
 2. Setup Node.js              (>=20.9.0)
 3. Setup Java                 (>=11, Zulu distribution)
 4. Setup Python               (>=3.10)
 5. Read PR Body               (parse PR body → run READ_PRBODY.py → set apex_test_classes env var)
 6. Install Salesforce CLI     (npm install -g @salesforce/cli)
 7. Verify SF CLI version
 8. Install SF Code Analyzer   (sf plugins install code-analyzer)
 9. Decrypt server.key         (AES-256-CBC via openssl)
10. JWT Authentication         (sf org login jwt)
11. Run Salesforce Code Analyzer
12. Quality Gate check         (fail on Sev1/Sev2 violations, or >10 total)
13. Deploy to Salesforce org   (sf project deploy start --wait 45)
```

> **Step 5 — PR Body Parser:** The pipeline reads `github.event.pull_request.body`, writes it to `pr_body.txt`, then runs `READ_PRBODY.py` to extract Apex test class names. The result is stored in the `apex_test_classes` environment variable for optional use in the deploy step (e.g. `--test-level RunSpecifiedTests`).

---

## Authentication — JWT Flow

Authentication uses an **External Client App** with JWT (certificate-based). The private key is stored encrypted in the repository and decrypted at runtime using AES-256-CBC.

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
| `ENCRYPTION_KEY_FILE` | Repo-relative path to the encrypted key (e.g. `assets/dev/server.key.enc`) |
| `JWT_KEY_FILE` | Path where the decrypted key is written at runtime (e.g. `assets/dev/server.key`) |
| `DEPLOYMENT_USER_USERNAME` | Salesforce username used for deployment |
| `SLACK_WEBHOOK_URL` | Slack webhook URL for pipeline notifications (optional) |
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

Every pipeline runs the [Salesforce Code Analyzer](https://forcedotcom.github.io/sfdx-scanner/) (`forcedotcom/run-code-analyzer@v2`) against the full workspace. The pipeline fails if any of the following are true:

| Condition | Threshold |
|-----------|-----------|
| Severity 1 violations | > 0 |
| Severity 2 violations | > 0 |
| Total violations | > 10 |

Results are uploaded as artifacts: `sfca_results.html` and `sfca_results.json`.

---

## Branch Strategy

```
feature/**  ──►  Dev         (push only)
staging     ──►  Staging     (PR open/closed)
UAT / uat   ──►  UAT         (PR open/closed/synchronize)
main        ──►  Production  (push + PR open/closed)
```

---

## Tool Versions

| Tool | Version |
|------|---------|
| Salesforce CLI | `latest` |
| Node.js | `>=20.9.0` |
| Java (Zulu) | `>=11` |
| Python | `>=3.10` |
| Salesforce API | `65.0` |
| Default Runner | `ubuntu-latest` (template default); callers use `macos-latest` |
