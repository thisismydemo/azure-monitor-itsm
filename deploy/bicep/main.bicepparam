using './main.bicep'

// ── Required parameters — fill these in before deploying ─────────────────────

// Your Azure AD Object ID (run: az ad signed-in-user show --query id -o tsv)
param deployerObjectId = '<your-object-id>'

// ServiceNow instance URL (no trailing slash)
// PDI example: https://dev123456.service-now.com
// Production example: https://mycompany.service-now.com
param snowInstanceUrl = 'https://<your-instance>.service-now.com'

// ServiceNow integration service account
param snowUsername = 'azure_monitor_svc'

// ServiceNow integration service account password (use Key Vault reference in CI/CD)
param snowPassword = '<your-snow-password>'

// ── Optional overrides ────────────────────────────────────────────────────────

// Azure region (defaults to resource group location)
// param location = 'eastus'

// Managed identity name (default: ITSM-MI)
// param managedIdentityName = 'ITSM-MI'

// Key Vault name (default: itsm-kv — must be globally unique)
// param keyVaultName = 'itsm-kv'

// SNOW queue/company IDs — customize after deployment per John Joyner's guide step 8
// param itsmCompanyId = '0'
// param itsmQueueId = '0'
