
## This script contains the commonly used Salesforce CLI commands for various operations such as login, data query, data export, and data import.
sf org login jwt \
  --username amitasinghsfdc-5khl@force.com \
  --jwt-key-file jwt_keys/server.key \
  --client-id 3MVG9aNlkJwuH9vOTOrvpAzWMmpsUX3qgv2dQNxyi15ZA99YVGs_snkr7GQB_U_urpGyJ8mhEaumjXkSZar1G \
  --alias pre-release-org \
  --set-default \
  --instance-url https://login.salesforce.com \
  --set-default-dev-hub


### Login to the org using the alias
sf org login web \
  --instance-url https://login.salesforce.com \
  --set-default \
  --browser chrome \
  --set-default-dev-hub \
  --alias MAIN_ORG


### Run Apex Using Salesforce CLI 
sf apex run \
  --file scripts/apex/assign_perm.apex \
  --target-org order-management

sf config set --global target-org=pre-release-org target-dev-hub=pre-release-org
### Create Scratch Org 

sf org create scratch \
  --edition developer \
  --alias my-scratch-org \
  --target-dev-hub MyHub \
  --release preview \
  --duration-days 3

sf org create scratch \
  --target-dev-hub MAIN_ORG \
  --definition-file config/project-scratch-def.json \
  --set-default \
  --duration-days 30

# Check the API version and the available limits in the org
sf limits api display --target-org order-management | grep Package2

## Assign Permission Set to the User
sf org assign permset \
  --name DreamHouse \
  --on-behalf-of user1@my.org \
  --on-behalf-of user2 \
  --on-behalf-of user3 \
  --target-org my-scratch-org

## Assign Multiple Permission Set to the User
sf org assign permset \
  --name Example_permissionset Stripe_Object_Permissions \
  --on-behalf-of epic.dcf639822cda@orgfarm.com \
  --on-behalf-of in.rishabhseth@gmail.com.agentforce \
  --target-org order-management

## Deploy the Components using Salesforce CLI with test Levels

sf project deploy start \
  --source-dir force-app \
  --test-level RunSpecifiedTests \
  --tests MyTestClass1 MyTestClass2 \
  --target-org my-scratch-org \
  --wait 10 \
  --dry-run \
  --concise

  RunLocalTests - X 
  RunSpecifiedTests
  RunRelevantTests - v66.0

sf project deploy start \
  --source-dir force-app/main/default/classes \
  --source-dir force-app/main/default/objects \
  --test-level RunRelevantTests \
  --target-org my-scratch-org \
  --wait 10 \
  --dry-run \
  --concise \
  --coverage-formatters json

## Login using the SFDX URL
sf org login \
  sfdx-url \
  --sfdx-url-file authFile.json \
  --set-default \
  --alias trail-org

sf org login sfdx-url \
  --sfdx-url-file temp/auth.txt \
  --set-default \
  --alias trail-org

## Query the data using SOQL
sf data query \
  --query "SELECT Id, Name, Amount, StageName, CloseDate, Description, Account.Name FROM Opportunity Order By Amount DESC LIMIT 10" \
  --target-org my-trail-dev-org --result-format csv \
  --output-file data/oppornities.csv

## Search for records using SOSL
sf data search --query "FIND {Anna} IN Name Fields RETURNING Contact(Id, Name, Email)" --target-org my-trail-dev-org

## Export the data using Tree API
sf data export tree \
  --query      "SELECT Id, Name, Type, Industry, Description, (SELECT Id, FirstName, LastName, Email FROM Contacts), (SELECT Id, Name FROM Opportunities) FROM Account LIMIT 20" \
  --output-dir data/ \
  --target-org my-trail-dev-org \
  --plan \
  --prefix PS-34

## Import the data using the generated plan file
sf data import tree \
  --target-org order-management \
  --plan data/PS-34-Account-Contact-plan.json

# Export the data using Bulk API
sf data export bulk \
  --query "SELECT Name, StageName, CloseDate, Description, Account.Name FROM Opportunity" \
  --output-file data/export-Opportunity.csv \
  --result-format csv \
  --wait 10 \
  --all-rows

## Import the Data using Bulk API
sf data import bulk --file data/export-Opportunity.csv --sobject Opportunity --wait 10 --target-org order-management


## String Replacement Commands
PANTHER_SCHOOL_API_URL=https://api.uat.pantherschools.com/v1 ADMIN_USER_EMAIL=amit.singh@pantherschools.com.uat sf project deploy start \
  --source-dir force-app \
  --target-org order-management \
  --wait 10 \
  --concise

### Create Org Shape
sf org shape create \
  --alias my-shape \
  --target-org order-management \
  --help

### list all org shapes
sf org shape list

### Create Scratch Org using the Shape
sf org create scratch \
  --shape my-shape \
  --alias my-shaped-scratch-org \
  --target-dev-hub MyHub \
  --set-default \
  --duration-days 3

## Create Scratch Org Snapshot
sf org snapshot create \
  --alias my-snapshot \
  --target-org my-scratch-org \
  --description "Snapshot of my scratch org" \
  --target-dev-hub NightlyDevHub



### Deploy the Components using Salesforce CLI with Environment Variables
PANTHER_SCHOOL_API_URL=https://api.dev.pantherschools.com/v1  \
  sf project deploy start \
  --target-org order-management \
  --metadata ApexClass:CaseEmailService \
  --wait 10 \
  --concise

### Full options
sh scripts/shell/setup-scratch-org.sh  \
  --devhub mydevhub@company.com \
  --alias QA_Sprint12 \
  --duration 14 \
  --permsets "PS_Admin,PSG_Support_Team" \
  --definition config/project-scratch-def.json

### help
sh scripts/shell/setup-scratch-org.sh --help


### help
sh scripts/shell/retrieve_metadata_batches.sh --help