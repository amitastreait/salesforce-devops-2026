# Replace Strings in Code Before Deploying or Packaging

Automatically replace strings in your metadata source files with specific values right before you deploy the files to an org or create a package version.
These sample use cases describe scenarios for using string replacement:

A NamedCredential contains an endpoint that you use for testing. But when you deploy the source to your production org, you want to specify a different endpoint.
An ExternalDataSource contains a password that you don’t want to store in your repository, but you’re required to deploy the password along with your metadata.
You deploy near-identical code to multiple orgs. You want to conditionally swap out some values depending on which org you’re deploying to.

## Location of Files
One of the following properties is required:
1. filename: Single file that contains the string to be replaced.
2. glob: Collection of files that contain the string to be replaced. Example: **/classes/*.cls.

## String to be Replaced
One of the following properties is required:
1. stringToReplace: The string to be replaced.
2. regexToReplace: A regular expression (regex) that specifies a string pattern to be replaced.
    1. Example - ``` "regexToReplace": "<apiVersion>\\d+\\.0</apiVersion>",```

## Replacement Value
One of the following properties is required:
1. replaceWithEnv: Specifies that the string is replaced with the value of the specified environment variable.
2. replaceWithFile: Specifies that the string is replaced with the contents of the specified file.

### Sample Replacement File

```json
    "replacements": [
        {
        "filename": "force-app/main/default/classes/AccountService.cls",
        "stringToReplace": "amit@pantherschools.com",
        "replaceWithEnv": "ADMIN_USER_EMAIL",
        "allowUnsetEnvVariable": true
        },
        {
        "filename": "force-app/main/default/namedCredentials/PantherSchools.namedCredential-meta.xml",
        "stringToReplace": "https://api.dev.pantherschools.com/v1",
        "replaceWithEnv": "PANTHER_SCHOOL_API_URL",
        "allowUnsetEnvVariable": true
        },
        {
        "glob": "force-app/main/default/classes/*.xml",
        "regexToReplace": "<apiVersion>\\d+\\.0</apiVersion>",
        "replaceWithFile": "replacements/api-version.txt"
        }
    ],
```

#### Complete sfdx-project.json file

```json
{
  "packageDirectories": [
    {
      "path": "force-app",
      "default": true
    }
  ],
  "replacements": [
    {
      "filename": "force-app/main/default/classes/AccountService.cls",
      "stringToReplace": "{env.ADMIN_USER_EMAIL}",
      "replaceWithEnv": "ADMIN_USER_EMAIL",
      "allowUnsetEnvVariable": true
    },
    {
      "filename": "force-app/main/default/namedCredentials/PantherSchools.namedCredential-meta.xml",
      "stringToReplace": "https://api.dev.pantherschools.com/v1",
      "replaceWithEnv": "PANTHER_SCHOOL_API_URL",
      "allowUnsetEnvVariable": true
    },
    {
      "glob": "force-app/main/default/classes/*.xml",
      "regexToReplace": "<apiVersion>\\d+\\.0</apiVersion>",
      "replaceWithFile": "replacements/api-version.txt"
    }
  ],
  "name": "devops-23245",
  "namespace": "",
  "sfdcLoginUrl": "https://login.salesforce.com",
  "sourceApiVersion": "66.0",
  "defaultLwcLanguage": "javascript"
}
```
