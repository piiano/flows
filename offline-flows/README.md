# Piiano Flows - Offline

## Running Piiano Flows

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [curl](https://curl.se/)
- [AWS CLI](https://aws.amazon.com/cli/)
- The [offline-flows.sh](./offline-flows.sh) script.

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

Using the [offline-flows.sh](./offline-flows.sh) script, run the following command:

```bash
FRONTEGG_CLIENT_ID=<frontegg-client-id> \
FRONTEGG_CLIENT_SECRET=<frontegg-client-secret> \
PIIANO_CS_CUSTOMER_IDENTIFIER=<your-company-name> \
PIIANO_CS_CUSTOMER_ENV=<environment-such-as-prod-or-stage> \
./offline-flows.sh <absolute-path-to-your-code-base>
```

This script will run the Piiano Flows container and analyze the code you provided. The container will start a server on port 3002 by default. You can access the results by opening http://localhost:3002 in your browser.