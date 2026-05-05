# Azure Monitor → ServiceNow Integration — Project Plan

> **Primary Reference**: John Joyner (Microsoft MVP)  
> Blog: <https://blog.johnjoyner.net/integrate-azure-monitor-alerts-from-servers-with-your-itsm-system/>  
> GitHub: <https://github.com/john-joyner/Microsoft.Logic/tree/main/Integrate-Azure-Monitor-alerts-with-your-ITSM-Solution>

---

## Why this project exists

The **Azure Monitor ITSM Connector** (the Marketplace item) was deprecated in September 2022 and fully retired September 30, 2025.  Microsoft's recommended replacement — and the approach documented by John Joyner — is a **Logic App-based bi-directional connector** to ServiceNow using the ServiceNow Table REST API.

This repo automates John's 14-step deployment guide into fully repeatable, scripted, Infrastructure-as-Code-driven automation, with a ServiceNow Personal Developer Instance (PDI) developer environment path built in so anyone can contribute and test without a production SNOW instance.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          AZURE                                       │
│                                                                      │
│  Azure Monitor Alert Rule                                            │
│         │                                                            │
│         ▼ (state change: Fired / Resolved)                           │
│  Action Group  ──────────────────────────────────────────────────┐  │
│                              Logic App action                    │  │
│                                                                  ▼  │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Logic App: Azure-Monitor-Alert-ITSM-HTTP-API                │   │
│  │                                                              │   │
│  │  1. Reads SNOW secrets from Key Vault (via Managed Identity) │   │
│  │  2. Checks Alert Processing Rules (suppression check)        │   │
│  │  3. Gets computer CI from ServiceNow (cmdb_ci lookup)        │   │
│  │  4a. IF Fired  → POST /api/now/table/incident (create)       │   │
│  │  4b. IF Resolved → PATCH /api/now/table/incident/{sys_id}    │   │
│  │  5. Updates Azure Monitor alert state to Acknowledged        │   │
│  └──────────────────────┬───────────────────────────────────────┘   │
│                         │                                            │
│  Key Vault: itsm-kv ◄───┤ (Managed Identity oauthMI connection)     │
│  User-Assigned MI: ITSM-MI                                           │
│                                                                      │
└─────────────────────────┬────────────────────────────────────────────┘
                          │ ServiceNow Table REST API
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       SERVICENOW                                     │
│                                                                      │
│  Incident created / updated                                          │
│         │                                                            │
│         │ (SNOW Business Rule fires when incident is Completed)      │
│         ▼                                                            │
│  Outbound webhook call                                               │
│                                                                      │
└─────────────────────────┬────────────────────────────────────────────┘
                          │ HTTP POST to webhook URL
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          AZURE                                       │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Logic App: Azure-Monitor-Close-ITSM-HTTP-API                │   │
│  │                                                              │   │
│  │  1. Receives SNOW ticket closure notification                │   │
│  │  2. Closes / Acknowledges Azure Monitor alert via REST API   │   │
│  │  3. Writes ITSM ticket # to Azure Monitor alert history      │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Authentication Strategy: Managed Identity ONLY

> **No SPNs. No user accounts. No client secrets or certificates for Azure-side auth.**

All Azure-side authentication is handled exclusively by a **User-Assigned Managed Identity** named `ITSM-MI`.

| Auth Scenario | Method |
|---|---|
| Logic App → Key Vault | User-Assigned Managed Identity (`oauthMI` API connection type) |
| Logic App → Azure Management REST API | User-Assigned Managed Identity bearer token |
| Logic App → Azure Monitor (update alert state) | User-Assigned Managed Identity |
| Key Vault API connection | `oauthMI` — never `oauthSP` or `basicAuth` |

The **only** non-MI credential in the entire solution is the ServiceNow integration account (username + password). Those credentials live **exclusively** inside Key Vault and are never referenced in any template, parameter file, script, or devcontainer as plaintext. The Logic App retrieves them at runtime using its Managed Identity.

### RBAC assignments for ITSM-MI

| Scope | Role |
|---|---|
| Subscription | Reader |
| Subscription | Monitoring Contributor |
| Key Vault (`itsm-kv`) | Key Vault Secrets User |

---

## Key Vault Secrets

| Secret Name | Value |
|---|---|
| `ItsmApiIntegrationCode` | `https://{your-instance}.service-now.com` |
| `ItsmApiUserName` | ServiceNow integration account username |
| `ItsmApiSecret` | ServiceNow integration account password |

---

## Logic Apps (sourced from John Joyner's GitHub)

### 1. Azure-Monitor-Alert-ITSM-HTTP-API
- **Trigger**: HTTP request received (called by Action Group on every alert state change)
- **1 trigger + 58 actions**
- **Flow**:
  1. Retrieve SNOW secrets from Key Vault via `itsm-keyvault-connection-mi`
  2. Check for active Alert Processing (suppression) rule — exit if suppressed
  3. Parse alert type (Log Analytics query / ARG query / Metric)
  4. Query SNOW for CI config item matching the alerted computer
  5. **If Fired**: POST to `/api/now/table/incident`, set severity mapping, store `sys_id`
  6. Update Azure Monitor alert state to `Acknowledged`
  7. **If Resolved**: PATCH existing SNOW incident to Resolved/Closed state
- **Deploys Disabled** (zero-trust default — enable via script after configuration)

### 2. Azure-Monitor-Close-ITSM-HTTP-API
- **Trigger**: HTTP request received (webhook URL registered in SNOW Business Rule)
- **1 trigger + 6 actions**
- **Flow**:
  1. Receive closure notification from SNOW
  2. Update Azure Monitor alert user response to `Closed`
  3. Append ITSM ticket number and metadata to Azure Monitor alert history
- **Deploys Disabled** (enable after testing)

---

## ServiceNow Severity Mapping

| Azure Monitor Severity | SNOW Impact | SNOW Urgency | SNOW Priority |
|---|---|---|---|
| Sev0 — Critical | 1 – High | 1 – High | 1 – Critical |
| Sev1 — Error | 1 – High | 2 – Medium | 2 – High |
| Sev2 — Warning | 2 – Medium | 2 – Medium | 3 – Moderate |
| Sev3 — Informational | 3 – Low | 3 – Low | 4 – Low |
| Sev4 — Verbose | 3 – Low | 3 – Low | 5 – Planning |

---

## Repository Structure

```
azure-monitor-itsm/
│
├── PLAN.md                                ← This file
├── README.md                              ← Overview, architecture, quick start
│
├── docs/
│   ├── architecture.md                    Deep-dive architecture + data flow
│   ├── deployment-guide.md                Step-by-step deployment (mirrors John's 14 steps)
│   └── servicenow-pdi-setup.md            ServiceNow PDI developer environment guide
│
├── src/
│   ├── arm/                               John Joyner's ARM templates (SNOW-annotated)
│   │   ├── Azure-Monitor-Alert-ITSM-HTTP-API.json
│   │   └── Azure-Monitor-Close-ITSM-HTTP-API.json
│   └── servicenow/
│       ├── snow-field-mapping.json        Azure severity → SNOW impact/urgency/priority
│       └── snow-automation-rule-script.js SNOW Business Rule script (fires close webhook)
│
├── deploy/
│   ├── bicep/
│   │   ├── main.bicep                     Orchestrates all modules
│   │   ├── main.bicepparam                Parameter values file
│   │   └── modules/
│   │       ├── managed-identity.bicep     Creates ITSM-MI, assigns Reader + Monitoring Contributor
│   │       ├── key-vault.bicep            Creates itsm-kv, grants Secrets Officer to deployer
│   │       ├── kv-api-connection.bicep    Creates itsm-keyvault-connection-mi (oauthMI type)
│   │       ├── logic-app-alert.bicep      Deploys Alert Logic App via nested ARM template
│   │       ├── logic-app-close.bicep      Deploys Close Logic App via nested ARM template
│   │       └── action-group.bicep         Creates Action Group → Alert Logic App
│   │
│   ├── terraform/
│   │   ├── main.tf                        Equivalent of Bicep using azurerm provider
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── providers.tf
│   │
│   └── scripts/
│       ├── Deploy-Solution.ps1            ★ MAIN: full end-to-end orchestrator
│       │                                    -DeploymentMethod (Bicep | Terraform | ARM)
│       │                                    -ResourceGroup, -Location, -SubscriptionId
│       │
│       ├── New-Prerequisites.ps1          John step 1+5: Create ITSM-MI, RBAC, KV API connection
│       ├── Set-KeyVaultSecrets.ps1        John step 3+4: Create KV, store SNOW secrets, MI RBAC
│       ├── Set-KeyVaultFirewall.ps1       John step 7: Logic App IPs → KV firewall allowlist
│       ├── New-ActionGroup.ps1            John step 10: Action Group → Alert Logic App
│       ├── Enable-LogicApps.ps1           Enable both Logic Apps (they deploy Disabled)
│       ├── Test-Integration.ps1           POST test payload, poll SNOW to verify incident
│       └── New-SnowPdiSetup.ps1           PDI setup: create user, assign roles, test API
│
├── dev/
│   ├── .devcontainer/
│   │   ├── devcontainer.json              VS Code devcontainer: az-cli, bicep, tf, pwsh, git
│   │   └── Dockerfile
│   └── docker/
│       └── docker-compose.yml             Mock SNOW REST endpoint (json-server) for local dev
│
└── samples/
    ├── alert-payloads/
    │   ├── metric-alert-fired.json        Real Azure Monitor common alert schema samples
    │   ├── log-alert-fired.json
    │   └── metric-alert-resolved.json
    └── snow-responses/
        ├── incident-created.json          Sample SNOW Table API responses
        └── incident-updated.json
```

---

## Deployment Steps (Automated)

The `Deploy-Solution.ps1` orchestrator automates all 14 steps from John Joyner's guide:

| Step | John's Guide Step | Script |
|------|-------------------|--------|
| 1 | Create MI + RBAC | `New-Prerequisites.ps1` |
| 2 | Get SNOW API data | (manual input prompted by `Set-KeyVaultSecrets.ps1`) |
| 3 | Create Key Vault + secrets | `Set-KeyVaultSecrets.ps1` |
| 4 | Grant MI KV Secrets User | `Set-KeyVaultSecrets.ps1` |
| 5 | Create KV API connection | `New-Prerequisites.ps1` |
| 6 | Deploy Logic Apps | `Deploy-Solution.ps1` (Bicep / Terraform / ARM) |
| 7 | Add Logic App IPs to KV firewall | `Set-KeyVaultFirewall.ps1` |
| 8 | Set Logic App parameters | Handled in Bicep/Terraform parameter files |
| 9 | Customize SNOW API tasks | Documented in `docs/deployment-guide.md` |
| 10 | Create Action Group | `New-ActionGroup.ps1` |
| 11 | Trigger test alert | `Test-Integration.ps1` |
| 12 | Validate all alert types | `Test-Integration.ps1` (metric + log + ARG) |
| 13 | Configure SNOW Business Rule | `src/servicenow/snow-automation-rule-script.js` + guide |
| 14 | Enable secure inputs/outputs | `Enable-LogicApps.ps1` |

---

## Developer Environment — ServiceNow PDI

Anyone can test this solution without a production ServiceNow instance using a free **Personal Developer Instance (PDI)**.

### Getting a PDI
1. Go to <https://developer.servicenow.com>
2. Sign up for a free developer account
3. Click **Request Instance** — choose your preferred release version
4. Note your instance URL (`https://dev######.service-now.com`), admin username, and admin password

> **Note**: PDIs hibernate after inactivity (you'll get email warnings). Log in to keep it active.
> Outbound email is disabled on PDIs — not a concern for this integration.

### Automated PDI Setup
Run `New-SnowPdiSetup.ps1` to:
- Create a dedicated integration service account (via `/api/now/table/sys_user`)
- Assign `itil` and `rest_service` roles (via `/api/now/table/sys_user_has_role`)
- Validate the Table API with a test incident create + close roundtrip

### Local Mock (no PDI needed)
`dev/docker/docker-compose.yml` spins up a `json-server` mock of the ServiceNow Table API for
fully offline development and CI testing.

---

## Parameters Reference

| Parameter | Required | Description | Example |
|---|---|---|---|
| `snowInstance` | ✅ | SNOW instance hostname | `dev123456.service-now.com` |
| `snowUsername` | ✅ | SNOW integration account | `azure_monitor_svc` |
| `snowPassword` | ✅ (secret) | SNOW integration password | stored in KV only |
| `snowTargetTable` | ✅ | Record type to create | `incident` / `em_event` / `change_request` / `problem` |
| `resourceGroupName` | ✅ | Azure resource group | `rg-itsm-integration` |
| `location` | ✅ | Azure region | `eastus` |
| `subscriptionId` | ✅ | Azure subscription ID | `00000000-...` |
| `keyVaultName` | optional | Override KV name | default: `itsm-kv` |
| `managedIdentityName` | optional | Override MI name | default: `ITSM-MI` |

---

## Security Posture

- ✅ Managed Identity everywhere on the Azure side — no SPN, no user auth, no static credentials
- ✅ ServiceNow credentials in Key Vault only — never in templates, scripts, or environment variables
- ✅ Key Vault firewall restricted to Logic App outbound IPs
- ✅ Logic Apps deploy in `Disabled` state — explicit enable step required
- ✅ Logic App Access Control restricts inbound calls to Azure Monitor IP ranges
- ✅ Secure inputs/outputs enabled on Key Vault tasks (step 14) hides secrets from run history

---

## References

- John Joyner blog: <https://blog.johnjoyner.net/integrate-azure-monitor-alerts-from-servers-with-your-itsm-system/>
- John Joyner GitHub: <https://github.com/john-joyner/Microsoft.Logic>
- Azure Monitor Action Groups: <https://learn.microsoft.com/azure/azure-monitor/alerts/action-groups>
- Azure Monitor common alert schema: <https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-common-schema>
- Logic Apps + Azure Monitor: <https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-logic-apps>
- ServiceNow Table API: <https://www.servicenow.com/docs/bundle/zurich-api-reference/page/build/applications/concept/api-rest.html>
- ServiceNow PDI: <https://developer.servicenow.com>
