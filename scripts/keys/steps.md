# Salesforce JWT Bearer Authentication - Setup Guide

A complete reference for setting up passwordless, server-to-server Salesforce authentication using the OAuth 2.0 JWT Bearer flow with **External Client Apps (ECA)** - the modern replacement for Connected Apps in Salesforce.

> **Why External Client Apps?**
> Starting Spring '26, Salesforce requires new integrations to use External Client Apps (ECAs) instead of Connected Apps. ECAs are fully metadata-compliant, support modern CI/CD workflows, enforce a closed security model by default, and cleanly separate developer-controlled settings from admin-controlled subscriber policies.

---

## Table of Contents

- [Overview](#overview)
- [ECA vs Connected App - Key Differences](#eca-vs-connected-app--key-differences)
- [Prerequisites](#prerequisites)
- [Phase 1 - Create Private Key and Certificate](#phase-1--create-private-key-and-certificate)
  - [Step 1.1 - Set OpenSSL config path (Windows only)](#step-11--set-openssl-config-path-windows-only)
  - [Step 1.2 - Generate an encrypted RSA private key](#step-12--generate-an-encrypted-rsa-private-key)
  - [Step 1.3 - Strip encryption and create the plain key](#step-13--strip-encryption-and-create-the-plain-key)
  - [Step 1.4 - Generate the Certificate Signing Request (CSR)](#step-14--generate-the-certificate-signing-request-csr)
  - [Step 1.5 - Self-sign the X.509 certificate](#step-15--self-sign-the-x509-certificate)
  - [Files produced](#files-produced)
- [Phase 2 - Create an External Client App (ECA)](#phase-2--create-an-external-client-app-eca)
  - [Step 2.1 - Navigate to External Client App Manager](#step-21--navigate-to-external-client-app-manager)
  - [Step 2.2 - Basic information](#step-22--basic-information)
  - [Step 2.3 - Enable OAuth and upload certificate](#step-23--enable-oauth-and-upload-certificate)
  - [Step 2.4 - Select OAuth scopes and enable JWT flow](#step-24--select-oauth-scopes-and-enable-jwt-flow)
  - [Step 2.5 - Configure OAuth policies (pre-authorization)](#step-25--configure-oauth-policies-pre-authorization)
  - [Step 2.6 - Retrieve Consumer Key](#step-26--retrieve-consumer-key)
- [Phase 3 - Build the JWT Token](#phase-3--build-the-jwt-token)
- [Phase 4 - Authenticate and Get an Access Token](#phase-4--authenticate-and-get-an-access-token)
  - [Salesforce CLI (SFDX)](#option-a--salesforce-cli-sfdx)
- [Common Errors and Fixes](#common-errors-and-fixes)
- [References](#references)

---

## Overview

The JWT Bearer Token flow allows a server application to authenticate to Salesforce **without any user interaction** or browser redirect. The client proves its identity by signing a JSON Web Token (JWT) using a private key. Salesforce validates the signature using the public certificate registered in an External Client App.

```
App (server.key) → signs JWT → Salesforce verifies with server.crt → returns access_token
```

**When to use this flow:**
- CI/CD pipelines (GitHub Actions, Jenkins, Azure DevOps, Salesforce DevOps Center)
- ETL tools and middleware integrations
- Scheduled Apex-to-external or external-to-Salesforce API calls
- Any scenario where a human login is not possible

---

## ECA vs Connected App - Key Differences

| Feature | Connected App (legacy) | External Client App (ECA) |
|---|---|---|
| Navigation | Setup → App Manager | Setup → **External Client App Manager** |
| Metadata support | Limited | Fully metadata-compliant (deployable via SFDX/CI) |
| Security model | Open by default | **Closed by default** - must be explicitly installed |
| Settings vs policies | Combined | **Separated** - developer settings packageable; admin policies are not |
| Spring '26 onwards | Cannot create new ones without Salesforce Support approval | **Recommended path** for all new integrations |
| Source control | Partial | Consumer key/secret isolated in GlobalOAuth settings (not in source control) |

> **Migration note:** For existing Connected Apps, Salesforce provides an automated migration path in App Manager via "Migrate to External Client App" for local (non-packaged) apps.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| OpenSSL | Pre-installed on macOS/Linux. [Download for Windows](http://gnuwin32.sourceforge.net/packages/openssl.htm) |
| Salesforce CLI (SFDX) | Optional - needed for Option A authentication |
| Salesforce org access | System Admin profile required to create an ECA |
| Java / keytool | Only needed if converting to JKS format for Apex |

---

## Phase 1 - Create Private Key and Certificate

All commands below are run in your terminal from a dedicated folder (e.g. `~/jwt/`).

### Step 1.1 - Set OpenSSL config path (Windows only)

```bash
set OPENSSL_CONF=C:\openssl\share\openssl.cnf
```

> Skip this step on macOS and Linux.

---

### Step 1.2 - Generate an encrypted RSA private key

Creates a **DES3-encrypted** 2048-bit RSA private key. The passphrase `x` is temporary and is only used to produce the clean key in the next step.

```bash
openssl genrsa -des3 -passout pass:x -out server.pass.key 2048
```

**Output:** `server.pass.key` - the encrypted private key file.

> **What is the encrypted file?**
> `server.pass.key` is the encrypted form of your private key. The `-des3` flag applies Triple DES symmetric encryption using the passphrase you supply. This protects the raw key material at rest. You would use this file when a tool or workflow specifically requires an encrypted PEM key.

---

### Step 1.3 - Strip encryption and create the plain key

Extracts the raw RSA private key from the encrypted file. Most tools - including the Salesforce CLI - consume this unencrypted version directly.

```bash
openssl rsa -passin pass:x -in server.pass.key -out server.key
```

**Output:** `server.key` - the unencrypted RSA private key.

> You can safely delete `server.pass.key` after this step. **Keep `server.key` secret** - it acts as a password. Anyone with this file can authenticate as your ECA integration user.

---

### Step 1.4 - Generate the Certificate Signing Request (CSR)

```bash
openssl req -new -key server.key -out server.csr
```

You will be prompted to fill in identity details. These are embedded in the certificate:

```
Country Name []:           IN
State or Province []:      Uttar Pradesh
Locality Name []:          Ghaziabad
Organization Name []:      Your Company Name
Organizational Unit []:    DevOps
Common Name []:            (leave blank or use your org domain)
Email Address []:          you@yourcompany.com
```

**Output:** `server.csr` - the certificate signing request.

---

### Step 1.5 - Self-sign the X.509 certificate

Signs the CSR with your own private key to produce a self-signed certificate valid for 365 days.

```bash
openssl x509 -req -sha256 -days 365 -in server.csr -signkey server.key -out server.crt
```

**Output:** `server.crt` - the X.509 certificate. **This is the file you upload to the External Client App.**

---

### Files produced

| File | Purpose | Keep? |
|---|---|---|
| `server.pass.key` | Encrypted private key (intermediate) | Optional - can delete |
| `server.key` | Plain RSA private key for JWT signing | ✅ Keep secret |
| `server.csr` | Certificate signing request | Optional |
| `server.crt` | X.509 certificate - upload to ECA | ✅ Keep |

---

## Phase 2 - Create an External Client App (ECA)

### Step 2.1 - Navigate to External Client App Manager

1. Go to **Salesforce Setup**
2. In the Quick Find box, type `External`
3. Select **External Client App Manager** from the dropdown
4. Click **New External Client App** (top right corner)

---

### Step 2.2 - Basic information

Fill in the following fields:

| Field | Description |
|---|---|
| External Client App Name | A human-readable name (e.g. `JWT Integration App`) |
| API Name | Auto-filled based on the name; used in metadata and deployments |
| Contact Email | Your team's support or admin email |
| Distribution State | `Local` for single-org use; `Packageable` for ISV/multi-org scenarios |
| Description | (Optional) Describe the integration purpose |

---

### Step 2.3 - Enable OAuth and upload certificate

1. Scroll down and expand the **API (Enable OAuth Settings)** section
2. Click **Enable OAuth**
3. Enter the **Callback URL**:
   ```
   http://localhost:1717/OauthRedirect
   ```
4. Under **Flow Enablement**, select **JWT Bearer Flow**
5. Upload your `server.crt` certificate file when prompted for a **public certificate**

---

### Step 2.4 - Select OAuth scopes and enable JWT flow

Select the following **OAuth Scopes**:

- `Manage user data via APIs (api)`
- `Manage user data via Web browsers (web)`
- `Perform requests at any time (refresh_token, offline_access)`

> Add additional scopes based on your integration requirements.

Click **Create** to save the ECA.

---

### Step 2.5 - Configure OAuth policies (pre-authorization)

After creating the ECA, navigate to the **Policies** tab and click **Edit**:

1. Under **OAuth Policies**, set:
   - **Permitted Users** → `Admin approved users are pre-authorized`
   - Confirm the warning prompt if it appears
2. Under **App Policies**, add the appropriate **Profile** or **Permission Set** for the integration user
3. Click **Save**

> Without this step, JWT authentication will fail with:
> ```json
> {"error":"invalid_grant","error_description":"user hasn't approved this consumer"}
> ```
> Or the ECA-specific error:
> ```json
> {"error":"app_not_found","error_description":"External client app is not installed in this org"}
> ```

---

### Step 2.6 - Retrieve Consumer Key

1. On the ECA detail page, click the **Settings** tab
2. Under **OAuth Settings**, click **Consumer Key and Secret**
3. Verify your identity with the emailed verification code
4. Copy and securely store the **Consumer Key** - you will need it for JWT claims and CLI commands

---

## Phase 3 - Authenticate and Get an Access Token

### Salesforce CLI (SFDX)

```bash
sf org login jwt \
  --username <Your-username> \
  --jwt-key-file server.key \
  --client-id <Client-ID> \
  --alias pre-release-org \
  --set-default \
  --instance-url https://login.salesforce.com
```

On success:
```
Successfully authorized your@salesforce.user with org ID 00DXXXXXXXXXXXXXXX
```

---

Deploy using Salesforce CLI:

```bash
sf project deploy start --source-dir force-app
```

---

## Common Errors and Fixes

| Error | Cause | Fix |
|---|---|---|
| `user hasn't approved this consumer` | ECA not pre-authorized | Set Permitted Users to "Admin approved" and add the user's profile under App Policies |
| `app_not_found - External client app is not installed` | ECA policies not configured or user not pre-authorized | Ensure Permitted Users is "Admin approved" and the correct profile/permission set is added |
| `expired authorization code` | JWT `exp` claim is in the past | Regenerate the JWT with `exp` = current Unix time + 120 seconds |
| `invalid_client_id` | Wrong Consumer Key in `iss` claim | Ensure `iss` is lowercase and contains the exact Consumer Key from the ECA Settings tab |
| `Audience Invalid` | Wrong `aud` value | Use `https://login.salesforce.com` (prod) or `https://test.salesforce.com` (sandbox) - custom domain URLs are not valid audience values |
| `invalid assertion` | Malformed JWT or wrong private key | Re-generate and verify the JWT at jwt.io using the correct `server.key` |
| `unsupported_grant_type` | Incorrect grant_type string | Use the full value: `urn:ietf:params:oauth:grant-type:jwt-bearer` |

---

## References

- [Salesforce Help - Create a Local External Client App](https://help.salesforce.com/s/articleView?id=xcloud.create_a_local_external_client_app.htm&type=5)
- [Salesforce Help - Configure OAuth 2.0 JWT Bearer Flow for External Client Apps](https://help.salesforce.com/s/articleView?id=xcloud.meta_configure_oauth_jwt_flow_external_client_apps.htm&type=5)
- [Salesforce Blog - Secure Your Org with External Client Apps](https://developer.salesforce.com/blogs/2025/01/secure-your-org-with-external-client-apps)
- [Salesforce DX Developer Guide - Create a Private Key and Self-Signed Certificate](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_auth_key_and_cert.htm)
- [Salesforce DX Developer Guide - Authorize an Org Using the JWT Flow](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_auth_jwt_flow.htm)
- [Trailhead - Build Integrations with External Client Apps](https://trailhead.salesforce.com/content/learn/projects/build-integrations-with-external-client-apps)
- [JWT Debugger](https://jwt.io)
- [Unix Timestamp Converter](https://www.unixtimestamp.com)
- [OpenSSL for Windows](http://gnuwin32.sourceforge.net/packages/openssl.htm)