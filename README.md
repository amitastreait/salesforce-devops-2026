# Salesforce DX - GitHub Actions CI/CD Pipeline

This repository uses GitHub Actions to automate Salesforce deployments across four environments: **Dev**, **Staging**, **UAT**, and **Production**. Every pipeline follows the same steps: environment setup → JWT authentication → static code analysis → deployment.

[![Salesforce Pipeline](https://github.com/SFDCPantherV1/salesforce-devops-2026/actions/workflows/sf.yaml/badge.svg)](https://github.com/SFDCPantherV1/salesforce-devops-2026/actions/workflows/sf.yaml)

---

## Pipeline Overview

```
feature/** branch  →  Dev Pipeline        (sf.yaml)
staging branch     →  Staging Pipeline    (sf_staging.yaml)
UAT branch         →  UAT Pipeline        (sf_uat.yaml)
main branch        →  Production Pipeline (sf_production.yaml)
```

Changes are only triggered when files under `force-app/**` are modified.

---

## Workflows

### 1. Dev Pipeline - `sf.yaml`

| Property | Value |
|----------|-------|
| GitHub Environment | `dev` |
| Trigger | Push to `feature/**` branches, or manual (`workflow_dispatch`) |
| Path Filter | `force-app/**` |

### 2. Staging Pipeline - `sf_staging.yaml`

| Property | Value |
|----------|-------|
| GitHub Environment | `staging` |
| Trigger | Push to `staging`, or Pull Request (opened/closed) targeting `staging` |
| Path Filter | `force-app/**` |

### 3. UAT Pipeline - `sf_uat.yaml`

| Property | Value |
|----------|-------|
| GitHub Environment | `UAT` |
| Trigger | Push to `UAT`, or Pull Request (opened/closed) targeting `UAT` |
| Path Filter | `force-app/**` |

### 4. Production Pipeline - `sf_production.yaml`

| Property | Value |
|----------|-------|
| GitHub Environment | `production` |
| Trigger | Push to `main`, or Pull Request (opened/closed) targeting `main` |
| Path Filter | `force-app/**` |

### 5. Manual Dispatch Workflow - `dispatch.yaml`

A utility workflow (`workflow_dispatch`) with configurable inputs for ad-hoc runs:

| Input | Type | Options |
|-------|------|---------|
| `name` | string | Free text (default: `monalisa`) |
| `environment` | choice | `dev`, `UAT`, `production` |
| `test-level` | choice | `RunSpecifiedTests`, `RunLocalTests`, `RunRelevantTests`, `DefaultTests` |
| `use-emoji` | boolean | `true` / `false` |
| `message` | string | Free text (optional) |
| `runner` | choice | `ubuntu-latest`, `windows-latest`, `macos-latest` |

---

## Pipeline Steps (all environments)

Each pipeline runs a single job (`setup-salesforce`) on `ubuntu-latest` with these sequential steps:

```
1. Checkout code            (fetch-depth: 0 for full git history)
2. Setup Node.js            (>=20.9.0)
3. Setup Java               (>=11, Zulu distribution)
4. Setup Python             (>=3.10)
5. Install Salesforce CLI   (npm install -g @salesforce/cli)
6. Verify SF CLI version
7. Install SF Code Analyzer plugin
8. Decrypt server.key       (AES-256-CBC via openssl)
9. JWT Authentication       (sf org login jwt)
10. Run Salesforce Code Analyzer
11. Quality Gate check      (fail on Sev1/Sev2 violations or >10 total)
12. Re-authenticate         (SFDX URL method)
13. Deploy to Salesforce org (sf project deploy start --wait 45)
```

---

## Authentication - JWT Flow

Authentication uses a Connected App with JWT (certificate-based), not username/password. The private key is stored encrypted in the repository and decrypted at runtime.

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

### Step 1 - Generate the Certificate

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

### Step 2 - Create an External Client App in Salesforce

1. Go to **Setup > External Client Apps > New External Client App**.
2. Enable **OAuth Settings**.
3. Set the callback URL to `http://localhost:1717/OauthRedirect`.
4. Upload `server.crt` under **Use Digital Signatures**.
5. Add the required OAuth scopes (API, refresh token, etc.).
6. Note the **Consumer Key** - this is your `CONSUMER_KEY` secret.

### Step 3 - Encrypt the Private Key for GitHub Actions

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

---

## GitHub Environments & Secrets

Create four GitHub Environments (`dev`, `staging`, `UAT`, `production`) under **Settings > Environments**, each with the following secrets and variables.

### Secrets (per environment)

| Secret | Description |
|--------|-------------|
| `CONSUMER_KEY` | Connected App client ID |
| `ENCRYPTION_KEY` | AES encryption key (for reference/other use) |
| `DECRYPTION_KEY` | AES key used to decrypt `server.key.enc` at runtime |
| `DECRYPTION_IV` | AES IV used to decrypt `server.key.enc` at runtime |
| `ENCRYPTION_KEY_FILE` | Repo-relative path to the encrypted key (e.g. `assets/dev/server.key.enc`) |
| `JWT_KEY_FILE` | Path where the decrypted key is written at runtime (e.g. `assets/dev/server.key`) |
| `DEPLOYMENT_USER_USERNAME` | Salesforce username used for deployment |
| `PROD_SFDX_AUTH_URL` | SFDX auth URL for secondary authentication |
| `SFDX_AUTH_FILE_PATH` | Temp file path used to store the SFDX auth URL |
| `SLACK_API_KEY` | Slack API key (for notifications) |

### Variables (per environment)

| Variable | Example Value | Description |
|----------|---------------|-------------|
| `ORG_DEFAULT_ALIAS` | `DEV_INT_ORG` | Salesforce org alias for this environment |
| `HUB_LOGIN_URL` | `https://test.salesforce.com` | Login URL (`test.salesforce.com` for sandbox, `login.salesforce.com` for prod) |
| `NODE_VERSION` | `>=20.9.0` | Node.js version |
| `SF_CLI_VERSION` | `latest` | Salesforce CLI version |
| `PYTHON_VERSION` | `>=3.10` | Python version |

### Organization-Level Variable

| Variable | Description |
|----------|-------------|
| `ORGANIZATION_VARIABLE` | Shared variable available across all environments |

---

## Code Quality Gate

Every pipeline runs the [Salesforce Code Analyzer](https://forcedotcom.github.io/sfdx-scanner/) (`forcedotcom/run-code-analyzer@v2`) against the full workspace and fails if any of the following conditions are met:

- Any **Severity 1** violations found
- Any **Severity 2** violations found
- More than **10 total violations** found

Results are saved as artifacts (`sfca_results.html`, `sfca_results.json`) and uploaded to the run summary.

---

## Branch Strategy

```
main          ──►  Production deployment
UAT           ──►  UAT deployment
staging       ──►  Staging deployment
feature/**    ──►  Dev deployment (also supports manual trigger)
```

Pull requests into `staging`, `UAT`, and `main` also trigger the pipeline on open and close events.

---

## Tool Versions

| Tool | Version |
|------|---------|
| Salesforce CLI | `latest` |
| Node.js | `>=20.9.0` |
| Java (Zulu) | `>=11` |
| Python | `>=3.10` |
| Salesforce API | `65.0` |
| Runner OS | `ubuntu-latest` |
