# Project: Salesforce DX - Salesforce-DevOps-2026

## Environment Context
- **Org Alias**: `pre-release-org`
- **Tooling**: Salesforce CLI (sf), Salesforce DX MCP Server
- **Metadata Format**: Source-tracked (SFDX)
- **Primary Namespace**: 

## Critical Commands
- **Deploy Source**: `sf project deploy start`
- **Retrieve Source**: `sf project retrieve start`
- **Open Org**: `sf org open`
- **Execute Anonymous**: `sf apex run --file temp.apex`
- **Check Coverage**: `sf apex run test --code-coverage --result-format human`

## Development Rules
- **Bypass Logic**: Every record-triggered Flow must include a "Bypass" check using a Custom Permission or Hierarchy Setting to allow data migrations.
- **Trigger Pattern**: Only one trigger per object. Use a logic-less trigger that delegates to a Handler, Helper & Service classes.
- **Builder Pattern**: Make Sure all the classes having a DML statements are having the Builder Pattern for creating the records. (e.g. `new AccountBuinder().withName().withIndustry().withParentId().build()` or `new AccountBuinder().withName().withIndustry().withParentId().buildAndInsert()`)
- **Governor Limits**: Never perform DML or SOQL inside loops. Use collections and maps for bulkification.
- **Naming Conventions**: 
  - Apex: `PascalCase` for classes, `camelCase` for methods.
  - LWCs: `kebab-case` for folders, `camelCase` for JS properties.
  - Flows: Append the type to the label (e.g., "Account Update: After Create/Update").
- **Security**: 
  - All Apex classes must explicitly state `with sharing`, `without sharing`, or `inherited sharing`.
  - All DML must explicitly check for the permissions  `insert as user`, `update as system`
  - All SOQL explicitly check for the permissions for the queries related to any object or fields `with user_mode`, `with system_mode`

## Testing Standards
- **Data Factory**: Use a `TestDataFactory` class for all record creation; do not use `(seeAllData=true)`.
- **Assertions**: Every test must contain at least one `Assert.areEqual()` or similar system assertion.
- **Coverage**: New code should aim for >85% coverage, even if the org requirement is 75%.

## Workflows
- **Deployment**: Always run `sf project deploy validate` before a final production push.
- **Conflict Resolution**: If a "Remote Change" error occurs, retrieve first, merge manually, then deploy.