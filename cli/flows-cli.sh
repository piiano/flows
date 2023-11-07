#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

VERSION_FILE=$(dirname $0)/version.json
ENGINE_VERSION=$(jq -r .engine ${VERSION_FILE})
VIEWER_VERSION=$(jq -r .viewer ${VERSION_FILE})

PIIANO_CS_SECRET_ARN=arn:aws:secretsmanager:us-east-2:211558624535:secret:scanner-prod-offline-user-KPIV3c
PIIANO_CS_ENDPOINT_ROLE_TO_ASSUME=arn:aws:iam::211558624535:role/sagemaker-prod-endpoint-invocation-role
PIIANO_CS_ENDPOINT_NAME=sagemaker-prod-endpoint
PIIANO_CS_ENGINE_IMAGE=piiano/code-scanner:offline-${ENGINE_VERSION}
PIIANO_CS_VIEWER_IMAGE=piiano/flows-viewer:${VIEWER_VERSION}
PORT=${PORT:=3000}
VOL_NAME=piiano_flows_m2_vol

is_absolute_path() {
  path="$1"

  if [ "$path" = "${path#/}" ]; then
    return 1  # Return failure (non-zero) if the path is not absolute
  else
    return 0  # Return success (0) if the path is absolute
  fi
}

prereq_check() {
  command -v "$1" >/dev/null 2>&1 || (echo "$1 is not installed. See https://github.com/piiano/flows/blob/main/cli/README.md for prerequisite list" && exit 1)
}

handle_error() {
  local exit_code="$?"

  if [[ $exit_code -eq 143 ]]; then
    echo "Script was terminated by user. Exit code: $exit_code"
  else
    echo "An error occurred. Exit code: $exit_code"
  fi
}

cleanup_flow_viewer() {
  echo "[ ] Stopping flows viewer..."
  docker stop piiano-flows-viewer > /dev/null
  exit $?
}

# check validity of PIIANO_CS_M2_FOLDER
# If it exists, it needs to have files in it
# If it doesn't exist try ~/.m2 and fallback to CWD
set_maven_folder() {
  if [ ! -z "${PIIANO_CS_M2_FOLDER:-}" ] ; then
    if [ ! -d "${PIIANO_CS_M2_FOLDER}/repository" ] ; then
      echo "ERROR: ${PIIANO_CS_M2_FOLDER}/repository does not exist"
      exit 1
    fi
    echo "[ ] Using ${PIIANO_CS_M2_FOLDER}/repository .m2 folder"
    return
  else
    echo "[ ] PIIANO_CS_M2_FOLDER is unset"
  fi

  if [ -d "${HOME}/.m2/repository" ] ; then
    echo "[ ] Using ${HOME}/.m2 folder"
    PIIANO_CS_M2_FOLDER=${HOME}/.m2
  else
    echo "[ ] Using .m2 repository in $(pwd)"
    PIIANO_CS_M2_FOLDER=$(pwd)/.m2
    mkdir -p ${PIIANO_CS_M2_FOLDER}/repository
  fi

  export PIIANO_CS_M2_FOLDER
}

trap handle_error ERR

# Verify prerequisites.
prereq_check curl
prereq_check jq

# Verify inputs.
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <absolute-path-to-source-code>"
  exit 1
fi

PATH_TO_SOURCE_CODE=$1

EXTRA_TEST_PARAMS=()
RUN_VIEWER="run"
if [ "$#" -gt 1 ]; then
  shift
  EXTRA_TEST_PARAMS=("$@")
  echo "Testing mode with args ${EXTRA_TEST_PARAMS[@]}"
  RUN_VIEWER="skip"
fi

if [ -z "${PIIANO_CLIENT_SECRET:-}" ]; then
  echo "ERROR: The environment variable PIIANO_CLIENT_SECRET is not set."
  exit 1
fi

if [ -z "${PIIANO_CLIENT_ID:-}" ]; then
  echo "ERROR: The environment variable PIIANO_CLIENT_ID is not set."
  exit 1
fi

if [ -z "${PIIANO_CUSTOMER_IDENTIFIER:-}" ]; then
  echo "ERROR: The environment variable PIIANO_CUSTOMER_IDENTIFIER is not set."
  exit 1
fi

if [ -z "${PIIANO_CUSTOMER_ENV:-}" ]; then
  echo "ERROR: The environment variable PIIANO_CUSTOMER_ENV is not set."
  exit 1
fi

if ! is_absolute_path "${PATH_TO_SOURCE_CODE}" ; then
  echo "ERROR: The path to the source code must be absolute."
  exit 1
fi


# Create a volume for M2


if $(docker volume inspect ${VOL_NAME} > /dev/null 2>&1) ; then
  echo "[ ] Reusing volume ${VOL_NAME}. (to remove: docker volume rm ${VOL_NAME})"
else
  echo -n "[ ] Creating volume for .m2: "
  docker volume create ${VOL_NAME}

  set_maven_folder
  echo "[ ] Copying .m2 folder ${PIIANO_CS_M2_FOLDER} to the volume"
  docker run --rm -v ${PIIANO_CS_M2_FOLDER}:/from -v ${VOL_NAME}:/to alpine sh -c "cp -r /from/* /to/"
fi

# Get an access token.
echo "[ ] Getting access token..."
ACCESS_TOKEN=$(curl --silent --fail --location -X POST -H 'Content-Type: application/json' -d "{\"clientId\": \"${PIIANO_CLIENT_ID}\",\"secret\": \"${PIIANO_CLIENT_SECRET}\"}" https://auth.scanner.piiano.io/identity/resources/auth/v1/api-token | jq -r '.accessToken')

echo "[ ] Obtaining user ID..."
PIIANO_CS_USER_ID=$(curl --silent --fail -H 'Content-Type: application/json' -H "Authorization: Bearer ${ACCESS_TOKEN}" https://auth.scanner.piiano.io/identity/resources/users/v2/me | jq -r '.sub')

# Assume AWS role.
echo "[ ] Getting AWS access..."
ASSUME_ROLE_OUTPUT=$(aws sts assume-role-with-web-identity \
    --region=us-east-2 \
    --duration-seconds 3600 \
    --role-session-name "${PIIANO_CS_USER_ID}" \
    --role-arn arn:aws:iam::211558624535:role/scanner-prod-flows-offline-user \
    --web-identity-token "${ACCESS_TOKEN}")

# Set AWS credentials.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
AWS_ACCESS_KEY_ID=$(echo "${ASSUME_ROLE_OUTPUT}" | jq -r '.Credentials.AccessKeyId')
AWS_SECRET_ACCESS_KEY=$(echo "${ASSUME_ROLE_OUTPUT}" | jq -r '.Credentials.SecretAccessKey')
AWS_SESSION_TOKEN=$(echo "${ASSUME_ROLE_OUTPUT}" | jq -r '.Credentials.SessionToken')

# Login to ECR.
echo "[ ] Login into container registry..."
docker run -i --rm \
    -e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}" \
    -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}" \
    -e "AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN}" \
    amazon/aws-cli:2.13.15 secretsmanager get-secret-value --secret-id "${PIIANO_CS_SECRET_ARN}" --region us-east-2 | jq -r '.SecretString' | jq -r '.dockerhub_token' | docker login -u piianoscanner --password-stdin

# Run flows.
echo "[ ] Starting flows engine..."

# Bump file limit to speed up maven download
ulimit -n 2048

# Run with TTY if possible
ADDTTY=""
if [ -t 1 ]; then
  ADDTTY="-it"
  echo "[ ] Running in interactive mode"
else
  echo "[ ] Not a tty - will not run interactive"
fi

docker run ${ADDTTY} --rm --pull=always --name piiano-flows  \
    --hostname offline-flows-container \
    -e AWS_REGION=us-east-2  \
    -e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
    -e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
    -e AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}" \
    -e "PIIANO_CS_ONLINE=false" \
    -e "PIIANO_CS_ENDPOINT_ROLE_TO_ASSUME=${PIIANO_CS_ENDPOINT_ROLE_TO_ASSUME}" \
    -e "PIIANO_CS_ENDPOINT_NAME=${PIIANO_CS_ENDPOINT_NAME}" \
    -e "PIIANO_CS_CUSTOMER_IDENTIFIER=${PIIANO_CUSTOMER_IDENTIFIER}" \
    -e "PIIANO_CS_CUSTOMER_ENV=${PIIANO_CUSTOMER_ENV}" \
    -e "PIIANO_CS_USER_ID=${PIIANO_CS_USER_ID}" \
    --env-file <(env | grep PIIANO_CS) \
    -v "${PATH_TO_SOURCE_CODE}:/source" \
    -v ${VOL_NAME}:"/root/.m2" \
    ${PIIANO_CS_ENGINE_IMAGE} ${EXTRA_TEST_PARAMS[@]:-}

if [ ${RUN_VIEWER} = "skip" ] ; then
  echo "Skipping viewer"
  exit 0
fi

OUTPUT_DIR=${PATH_TO_SOURCE_CODE}/piiano-scanner
mkdir -p ${OUTPUT_DIR}/api
cp -f ${OUTPUT_DIR}/report.json ${OUTPUT_DIR}/api/offline-report.json

echo "[ ] Starting flows viewer on port ${PORT}..."

docker run ${ADDTTY} -d --rm --pull=always --name piiano-flows-viewer  \
    --hostname offline-flows-container \
    -e "PIIANO_CS_CUSTOMER_IDENTIFIER=${PIIANO_CUSTOMER_IDENTIFIER}" \
    -e "PIIANO_CS_CUSTOMER_ENV=${PIIANO_CUSTOMER_ENV}" \
    -v "${OUTPUT_DIR}/api:/api" \
    -p "${PORT}:3000" \
    ${PIIANO_CS_VIEWER_IMAGE}

./wait-for-service.sh localhost:${PORT} 6
trap cleanup_flow_viewer INT
echo "Flows viewer is ready at: http://localhost:${PORT}"
echo "Hit <CTRL-C> to stop viewer"
while : ; do sleep 3600 ; done
