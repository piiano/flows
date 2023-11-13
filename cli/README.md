# Piiano Flows - Offline

## Running Piiano Flows

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [curl](https://curl.se/)
- [jq](https://jqlang.github.io/jq/download/)
- The [flows-cli](./flows-cli.sh) script.

### Generate a Personal Token

1. Register for a free account at https://scanner.piiano.io
2. Reach Piiano at support@piiano.com with a request for offline flows.
3. After receiving access, login to https://scanner.piiano.io and create a Personal Token:
   1. Click on your user icon in the top right corner.
   2. Click on "Settings".
   3. Click on "Personal Tokens".
   4. "Generate Token" and copy the token.
   5. Keep the Client ID and Client Secret for later.

### Run the Offline Flows

Using the [flows-cli](./flows-cli.sh) script, run the following command:

```bash
PIIANO_CLIENT_ID=<client-id> \
PIIANO_CLIENT_SECRET=<client-secret> \
PIIANO_CUSTOMER_IDENTIFIER=<your-company-name> \
PIIANO_CUSTOMER_ENV=<environment-such-as-prod-or-stage> \
PIIANO_CS_DB_OPTIONS=auto \
./flows-cli.sh <absolute-path-to-your-code-base>
```

This script will run the Piiano Flows container and analyze the code you provided. The container will start a server on port 3000 by default. You can access the results by opening http://localhost:3000 in your browser.

### Optional environment variables:

1. `PIIANO_CS_JAVA_VERSION` - Specifies the Java version used for building the repository. When not provided the Piiano Flows container will attempt to automatically detect the right version.  
2. `PIIANO_CS_M2_FOLDER` - Specifies the Maven `m2` cache folder to be used during the scan. When not provided the script will first attempt to use the default `.m2` folder under the user's home directory and verify that it has a `repository` sub folder. If that doesn't exist, the script will fallback to use the current working directory instead.
3. `PIIANO_CS_DB_OPTIONS` - Options for building the internal code database. Supported values are: `auto`, `default` and `custom`. 
4. `PIIANO_CS_BUILD_COMMAND` - Applicable when `PIIANO_CS_DB_OPTIONS=custom`. Includes the command used to build the source repo.
5. `PIIANO_CS_SUB_DIR` - Scan only a sub directory within the git repository. Useful for example in a mono-repo case.


