#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

PIIANO_CS_ENDPOINT_ROLE_TO_ASSUME=arn:aws:iam::211558624535:role/sagemaker-prod-endpoint-invocation-role
PIIANO_CS_ENDPOINT_NAME=sagemaker-prod-endpoint
PIIANO_CS_IMAGE=211558624535.dkr.ecr.us-east-2.amazonaws.com/scanner-scan:cpu-0.2.655
PORT=${PORT:=3002}

is_absolute_path() {
  path="$1"

  if [ "$path" = "${path#/}" ]; then
    return 1  # Return failure (non-zero) if the path is not absolute
  else
    return 0  # Return success (0) if the path is absolute
  fi
}

# Verify inputs.
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <absolute-path-to-source-code>"
  exit 1
fi

if [ -z "${FRONTEGG_CLIENT_ID:-}" ]; then
  echo "ERROR: The environment variable FRONTEGG_CLIENT_ID is not set."
  exit 1
fi

if [ -z "${FRONTEGG_CLIENT_SECRET:-}" ]; then
  echo "ERROR: The environment variable FRONTEGG_CLIENT_SECRET is not set."
  exit 1
fi

if [ -z "${PIIANO_CS_CUSTOMER_IDENTIFIER:-}" ]; then
  echo "ERROR: The environment variable PIIANO_CS_CUSTOMER_IDENTIFIER is not set."
  exit 1
fi

if [ -z "${PIIANO_CS_CUSTOMER_ENV:-}" ]; then
  echo "ERROR: The environment variable PIIANO_CS_CUSTOMER_ENV is not set."
  exit 1
fi

if ! is_absolute_path "$1"; then
  echo "ERROR: The path to the source code must be absolute."
  exit 1
fi

# Get an access token.
echo "[ ] Getting access token..."
ACCESS_TOKEN=$(curl --silent --fail-with-body --location -X POST -H 'Content-Type: application/json' -d "{\"clientId\": \"${FRONTEGG_CLIENT_ID}\",\"secret\": \"${FRONTEGG_CLIENT_SECRET}\"}" https://auth.scanner.piiano.io/identity/resources/auth/v1/api-token | jq -r '.accessToken')
USER_ID=$(curl --silent --fail-with-body -H 'Content-Type: application/json' -H "Authorization: Bearer ${ACCESS_TOKEN}" https://auth.scanner.piiano.io/identity/resources/users/v2/me | jq -r '.sub')

# Assume AWS role.
echo "[ ] Getting AWS access..."
ASSUME_ROLE_OUTPUT=$(aws sts assume-role-with-web-identity \
    --duration-seconds 3600 \
    --role-session-name "${USER_ID}" \
    --role-arn arn:aws:iam::211558624535:role/scanner-prod-frontegg-offline-user \
    --web-identity-token "${ACCESS_TOKEN}")

# Run flows.
echo "[ ] Starting flows on port ${PORT}..."
docker run --rm \
    -e AWS_REGION=us-east-2  \
    -e AWS_ACCESS_KEY_ID="$(echo "${ASSUME_ROLE_OUTPUT}" | jq '.Credentials.AccessKeyId')" \
    -e AWS_SECRET_ACCESS_KEY="$(echo "${ASSUME_ROLE_OUTPUT}" | jq '.Credentials.SecretAccessKey')" \
    -e AWS_SESSION_TOKEN="$(echo "${ASSUME_ROLE_OUTPUT}" | jq '.Credentials.SessionToken')" \
    -e "PIIANO_CS_ONLINE=false" \
    -e "PIIANO_CS_ENDPOINT_ROLE_TO_ASSUME=${PIIANO_CS_ENDPOINT_ROLE_TO_ASSUME}" \
    -e "PIIANO_CS_ENDPOINT_NAME=${PIIANO_CS_ENDPOINT_NAME}" \
    -e "PIIANO_CS_CUSTOMER_IDENTIFIER=${PIIANO_CS_CUSTOMER_IDENTIFIER}" \
    -e "PIIANO_CS_CUSTOMER_ENV=${PIIANO_CS_CUSTOMER_ENV}" \
    -v "$1:/source" \
    -p "${PORT}:3002" \
    ${PIIANO_CS_IMAGE}