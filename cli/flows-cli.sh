#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

BASEDIR=$(realpath $(dirname $0))
REPORT_DIR=${BASEDIR}/.flows-reports
MAX_NUM_OF_FILES_LOCAL=10240
MAX_NUM_OF_FILES_CONTAINER=10000
VERSION_FILE=$(dirname $0)/version.json
ENGINE_VERSION=$(jq -r .engine ${VERSION_FILE})
VIEWER_VERSION=$(jq -r .viewer ${VERSION_FILE})

PIIANO_CS_LOCAL_LOGGING=${FLOWS_LOCAL_PROCESSING:-'false'}
if [[ "$PIIANO_CS_LOCAL_LOGGING" = 'true' ]]; then
    PIIANO_CS_REPORT_SAMPLE='false'
    PIIANO_CS_VIEWER_MODE='none'
fi


PIIANO_CS_ENGINE_IMAGE=${FLOWS_IMAGE_ID:-"piiano/code-scanner:offline-$ENGINE_VERSION"}
PIIANO_CS_SUB_DIR=${PIIANO_CS_SUB_DIR:-""}
PIIANO_CS_DB_OPTIONS=${PIIANO_CS_DB_OPTIONS:-default}
PIIANO_CS_SECRET_ARN=arn:aws:secretsmanager:us-east-2:211558624535:secret:scanner-prod-offline-user-KPIV3c
PIIANO_CS_ENDPOINT_ROLE_TO_ASSUME=arn:aws:iam::211558624535:role/sagemaker-prod-endpoint-invocation-role
PIIANO_CS_ENDPOINT_NAME=sagemaker-prod-endpoint
PIIANO_CS_VIEWER_IMAGE=piiano/flows-viewer:${VIEWER_VERSION}
PIIANO_CS_TAINT_ANALYZER_LOG_LEVEL=${PIIANO_CS_TAINT_ANALYZER_LOG_LEVEL:-'--verbosity=progress'}
FLOWS_SKIP_ENGINE=${FLOWS_SKIP_ENGINE:-false}
PIIANO_CS_VIEWER_MODE=${PIIANO_CS_VIEWER_MODE:-online}
FLOWS_FORCE_CLEANUP=${FLOWS_FORCE_CLEANUP:-false}
UNIQUE_RUN_ID=$((RANDOM % 900000 + 100000))
PORT=${PORT:=3000}
VOL_NAME_M2=piiano_flows_m2_vol
VOL_NAME_GRADLE=piiano_flows_gradle_vol
FLOWS_MOUNT_TYPE=${FLOWS_MOUNT_TYPE:-volume}
FLOWS_TEMP_FOLDER=${FLOWS_TEMP_FOLDER:-/tmp}
FLOWS_PORT=3000
PORT_START_RANGE=${FLOWS_PORT}
PORT_END_RANGE=$(( ${PORT_START_RANGE} + 128 ))
AWS_CLI_DOCKER=amazon/aws-cli:2.13.15
NETWORK_PARAM=${NETWORK_PARAM:-""}
FLOWS_APP_URL="${FLOWS_APP_URL:-https://scanner.piiano.io}"
BACKEND_URL="${BACKEND_URL:-https://scanner.piiano.io/api/app}"
ASSUMED_ROLE_USER=${ASSUMED_ROLE_USER:-""}
PIIANO_CS_SCAN_ID_EXTERNAL=""

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

  if [[ $exit_code -eq 143 || $exit_code -eq 130 ]]; then
    echo "Script was terminated by user. Exit code: $exit_code"
    update_scan_status "canceled"
  else
    echo "An error occurred. Exit code: $exit_code"
    update_scan_status "failed"
  fi
}

update_scan_status() {
  local status="$1"

  if [ -n "$PIIANO_CS_SCAN_ID_EXTERNAL" ]; then
    BACKEND_TOKEN="${BACKEND_TOKEN:-$ACCESS_TOKEN}"

    echo "[ ] Updating the status of project: ${PROJECT_ID} scan: ${PIIANO_CS_SCAN_ID_EXTERNAL} to ${status}"
    response=$(curl --silent --location -i -X PUT \
              -H 'Content-Type: application/json' \
              -H "Authorization: Bearer ${BACKEND_TOKEN}" \
              -d "{\"status\": \"${status}\"}" \
              "${BACKEND_URL}/projects/${PROJECT_ID}/scans/${PIIANO_CS_SCAN_ID_EXTERNAL}")

    response_body=$(validate_response "$response")
    echo "[ ] Scan Updated successfully."
  fi
}

validate_response() {
  local response="$1"
  http_status=$(echo "$response" | grep -Fi HTTP/ | awk '{print $2}')
  body=$(echo "$response" | sed '1,/^\r$/d')
  
  if [ "$http_status" != "200" ]; then
      echo "[ ] Error: ${body}"
      exit 1
  fi
  echo "$body"
}

cleanup_flow_viewer() {
  echo "[ ] Stopping flows viewer..."
  docker stop piiano-flows-viewer-${UNIQUE_RUN_ID} > /dev/null || true
  exit 0
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

# check validity of PIIANO_CS_M2_GRADLE
# If it exists, it needs to have files in it
# If it doesn't exist try ~/.gradle and fallback to CWD
set_gradle_folder() {
  if [ ! -z "${PIIANO_CS_GRADLE_FOLDER:-}" ] ; then
    if [ ! -d "${PIIANO_CS_GRADLE_FOLDER}/caches" ] ; then
      echo "ERROR: ${PIIANO_CS_GRADLE_FOLDER}/caches does not exist"
      exit 1
    fi
    echo "[ ] Using ${PIIANO_CS_GRADLE_FOLDER} gradle folder"
    return
  else
    echo "[ ] PIIANO_CS_GRADLE_FOLDER is unset"
  fi

  if [ -d "${HOME}/.gradle/caches" ] ; then
    echo "[ ] Using ${HOME}/.gradle/caches folder"
    PIIANO_CS_GRADLE_FOLDER=${HOME}/.gradle
  else
    echo "[ ] Using .gradle in $(pwd)"
    PIIANO_CS_GRADLE_FOLDER=$(pwd)/.gradle
    mkdir -p ${PIIANO_CS_GRADLE_FOLDER}/caches
  fi

  export PIIANO_CS_GRADLE_FOLDER
}

set_available_port()
{
  for ((port=${PORT_START_RANGE}; port<=${PORT_END_RANGE}; port++)); do
      # Check if the port is in use using nc
      if ! nc -z localhost $port > /dev/null 2>&1; then
          PORT=${port}
          return
      fi
  done

  echo "ERROR: unable to find an available port in the range: ${PORT_START_RANGE} - ${PORT_END_RANGE}"
  exit 1
}

initial_cleanup()
{
    if [ ${FLOWS_FORCE_CLEANUP} = "true" ] ; then
        echo "[ ] Clenup of previous reports"
        rm -rf ${REPORT_DIR}

        # Cleanup previous run (will be removed when supporting multiple runs)
        echo "[ ] Removing previous containers"
        docker ps -q --filter "name=piiano-flows" | xargs -r docker stop > /dev/null 2>&1 || true
    fi
}


create_scan() {
  
  BACKEND_TOKEN="${BACKEND_TOKEN:-$ACCESS_TOKEN}"
  SOURCE_CODE_DIR_NAME=$(basename ${PATH_TO_SOURCE_CODE})
  FLOWS_PROJECT_NAME="${FLOWS_PROJECT_NAME:-${SOURCE_CODE_DIR_NAME}}"

  # Create proejct
  echo "[ ] Creating a new scan for project: ${FLOWS_PROJECT_NAME}"
  response=$(curl --silent --location -i -X POST \
            -H 'Content-Type: application/json' \
            -H "Authorization: Bearer ${BACKEND_TOKEN}" \
            -d "{\"name\": \"${FLOWS_PROJECT_NAME}\",\"subDir\": \"${PIIANO_CS_SUB_DIR}\",\"repositoryUrl\": \"${SOURCE_CODE_DIR_NAME}\",\"runningMode\": \"offline\"}" \
            "${BACKEND_URL}/projects?ignoreIfExist=true")

  response_body=$(validate_response "$response")

  PROJECT_ID=$(echo "$response_body" | jq -r '.uid')
  PIIANO_CS_SCAN_ID_EXTERNAL=$(echo "$response_body" | jq -r '.scans[0].uid')
  echo "[ ] Project Id: ${PROJECT_ID}  Scan Id: ${PIIANO_CS_SCAN_ID_EXTERNAL}"

  export PIIANO_CS_SCAN_ID_EXTERNAL
}

create_m2_volume() {
  if $(docker volume inspect ${VOL_NAME_M2} > /dev/null 2>&1) ; then
    echo "[ ] Reusing volume ${VOL_NAME_M2}. (to remove: docker volume rm ${VOL_NAME_M2})"
  else
    echo -n "[ ] Creating volume for .m2: "
    docker volume create ${VOL_NAME_M2}

    set_maven_folder
    echo "[ ] Copying .m2 folder ${PIIANO_CS_M2_FOLDER} to the volume"
    docker run --rm -v ${PIIANO_CS_M2_FOLDER}:/from -v ${VOL_NAME_M2}:/to alpine sh -c "cp -r /from/* /to/"
  fi
}

create_gradle_volume() {
  if $(docker volume inspect ${VOL_NAME_GRADLE} > /dev/null 2>&1) ; then
    echo "[ ] Reusing volume ${VOL_NAME_GRADLE}. (to remove: docker volume rm ${VOL_NAME_GRADLE})"
  else
    echo -n "[ ] Creating volume for .gradle: "
    docker volume create ${VOL_NAME_GRADLE}

    set_gradle_folder
    echo "[ ] Copying .gradle folder ${PIIANO_CS_GRADLE_FOLDER} to the volume"
    docker run --rm -v ${PIIANO_CS_GRADLE_FOLDER}:/from -v ${VOL_NAME_GRADLE}:/to alpine sh -c "cp -r /from/* /to/"
  fi
}

create_m2_bind_mount() {
  M2_BM_FOLDER=${FLOWS_TEMP_FOLDER}/m2
  if [ -d ${M2_BM_FOLDER} ] ; then
    echo "[ ] Reusing bind mount to ${M2_BM_FOLDER}. (to remove: rm -r ${M2_BM_FOLDER})"
  else
    echo "[ ] Creating directory for .m2 bind mount"
    mkdir -p ${M2_BM_FOLDER}
  
    set_maven_folder
    echo "[ ] Copying .m2 folder ${PIIANO_CS_M2_FOLDER} to the bind mount directory ${M2_BM_FOLDER}"
    cp -R "${PIIANO_CS_M2_FOLDER}/." ${M2_BM_FOLDER}
  fi
  
  # Count directories using find command and count lines
  num_directories=$(find "${M2_BM_FOLDER}" -mindepth 1 -type d | wc -l)
  echo "Number of directories in ${M2_BM_FOLDER}: $num_directories"
}

create_gradle_bind_mount() {
  GRADLE_BM_FOLDER=${FLOWS_TEMP_FOLDER}/gradle
  if [ -d ${GRADLE_BM_FOLDER} ] ; then
    echo "[ ] Reusing bind mount to ${GRADLE_BM_FOLDER}. (to remove: rm -r ${GRADLE_BM_FOLDER})"
  else
    echo "[ ] Creating directory for gradle bind mount"
    mkdir -p ${GRADLE_BM_FOLDER}

    set_gradle_folder
    echo "[ ] Copying gradle folder ${PIIANO_CS_GRADLE_FOLDER} to the bind mount directory ${GRADLE_BM_FOLDER}"
    cp -R "${PIIANO_CS_GRADLE_FOLDER}/." ${GRADLE_BM_FOLDER}
  fi

  # Count directories using find command and count lines
  num_directories=$(find "${GRADLE_BM_FOLDER}" -mindepth 1 -type d | wc -l)
  echo "Number of directories in ${GRADLE_BM_FOLDER}: $num_directories"
}

trap handle_error ERR

# Conditional inital cleanup.
initial_cleanup

# Verify prerequisites.
prereq_check curl
prereq_check jq
prereq_check nc
prereq_check realpath

# Verify inputs.
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <absolute-path-to-source-code>"
  exit 1
fi

PATH_TO_SOURCE_CODE=$1

EXTRA_TEST_PARAMS=()
if [ "$#" -gt 1 ]; then
  shift
  EXTRA_TEST_PARAMS=("$@")
  echo "Testing mode with args ${EXTRA_TEST_PARAMS[@]}"
  
  if [ ${PIIANO_CS_VIEWER_MODE} = "local" ] ; then
      PIIANO_CS_VIEWER_MODE="none"
  fi 
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

if [ ! -z "${PIIANO_CS_SUB_DIR:-}" ]; then
  echo "[ ] Scanning limited to sub directory: ${PIIANO_CS_SUB_DIR}"
  if [ ! -d "${PATH_TO_SOURCE_CODE}/${PIIANO_CS_SUB_DIR}" ] ; then
    echo "ERROR: unable to find subdirectory: ${PATH_TO_SOURCE_CODE}/${PIIANO_CS_SUB_DIR}"
    exit 1
  fi
fi

if [[ "${PIIANO_CS_VIEWER_MODE}" != "online" && "${PIIANO_CS_VIEWER_MODE}" != "local" && "${PIIANO_CS_VIEWER_MODE}" != "none" ]]; then
    echo "ERROR: invalid PIIANO_CS_VIEWER_MODE, use online,local or none."
    exit 1
fi

if [[ "${FLOWS_SKIP_ENGINE}" = "true" &&  "${PIIANO_CS_VIEWER_MODE}" != "local"  ]]; then
    echo "ERROR: FLOWS_SKIP_ENGINE can only be used with local viewer (PIIANO_CS_VIEWER_MODE=local)"
    exit 1
fi


if [[ "${FLOWS_MOUNT_TYPE}" != "volume" && "${FLOWS_MOUNT_TYPE}" != "bind-mount" && "${FLOWS_MOUNT_TYPE}" != "none" ]]; then
    echo "ERROR: invalid FLOWS_MOUNT_TYPE, use volume,bind-mount or none."
    exit 1
fi


# Bump file limit to for copying and downloads
ulimit -n ${MAX_NUM_OF_FILES_LOCAL}

# Create volumes
if [[ "${FLOWS_MOUNT_TYPE}" = "volume" ]] ; then
  create_m2_volume
  create_gradle_volume
  VOLUME_DOCKER_FLAGS=(-v ${VOL_NAME_M2}:"/root/.m2" -v ${VOL_NAME_GRADLE}:"/root/.gradle")
elif [[ "${FLOWS_MOUNT_TYPE}" = "bind-mount" ]] ; then
  create_m2_bind_mount
  create_gradle_bind_mount
  VOLUME_DOCKER_FLAGS=(-v ${FLOWS_TEMP_FOLDER}/m2:"/root/.m2" -v ${FLOWS_TEMP_FOLDER}/gradle:"/root/.gradle")
else
  VOLUME_DOCKER_FLAGS=""  
fi

# Get an access token.
echo "[ ] Getting access token..."
ACCESS_TOKEN=$(curl --silent --fail --location -X POST -H 'Content-Type: application/json' -d "{\"clientId\": \"${PIIANO_CLIENT_ID}\",\"secret\": \"${PIIANO_CLIENT_SECRET}\"}" https://auth.scanner.piiano.io/identity/resources/auth/v1/api-token | jq -r '.accessToken')

echo "[ ] Obtaining user ID..."
PIIANO_CS_USER_ID=$(curl --silent --fail -H 'Content-Type: application/json' -H "Authorization: Bearer ${ACCESS_TOKEN}" https://auth.scanner.piiano.io/identity/resources/users/v2/me | jq -r '.sub')

echo "[ ] Getting AWS access..."
response=$(curl --silent --location -i -X GET \
            -H 'Content-Type: application/json' -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            "https://scanner.piiano.io/api/app/users/aws-access")

ASSUME_ROLE_OUTPUT=$(validate_response "$response")

# Set AWS credentials.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
AWS_ACCESS_KEY_ID=$(echo "${ASSUME_ROLE_OUTPUT}" | jq -r '.Credentials.AccessKeyId')
AWS_SECRET_ACCESS_KEY=$(echo "${ASSUME_ROLE_OUTPUT}" | jq -r '.Credentials.SecretAccessKey')
AWS_SESSION_TOKEN=$(echo "${ASSUME_ROLE_OUTPUT}" | jq -r '.Credentials.SessionToken')

if [ -z "$ASSUMED_ROLE_USER" ]; then
  ASSUMED_ROLE_USER=$(echo "${ASSUME_ROLE_OUTPUT}" | jq -r '.AssumedRoleUser.AssumedRoleId')
fi

# Login to ECR.
echo "[ ] Login into container registry..."
docker run -i --rm \
    -e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}" \
    -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}" \
    -e "AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN}" \
    ${AWS_CLI_DOCKER} secretsmanager get-secret-value --secret-id "${PIIANO_CS_SECRET_ARN}" --region us-east-2 | jq -r '.SecretString' | jq -r '.dockerhub_token' | docker login -u piianoscanner --password-stdin

# Run with TTY if possible
ADDTTY=""
if [ -t 1 ]; then
  ADDTTY="-it"
  echo "[ ] Running in interactive mode"
else
  echo "[ ] Not a tty - will not run interactive"
fi


if [ ${PIIANO_CS_VIEWER_MODE} = "online" ] ; then
  create_scan
fi 

# Run flows.
if [ ${FLOWS_SKIP_ENGINE} = "true" ] ; then
  echo "[ ] Skipping engine"
else
  
  echo "[ ] Starting flows engine (run id ${UNIQUE_RUN_ID})..."
  docker run ${NETWORK_PARAM} ${ADDTTY} --rm --pull=always --name piiano-flows-engine-${UNIQUE_RUN_ID}  \
      --hostname offline-flows-container \
      -e AWS_REGION=us-east-2  \
      -e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
      -e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
      -e AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN}" \
      -e ASSUMED_ROLE_USER="${ASSUMED_ROLE_USER}" \
      -e "PIIANO_CS_ONLINE=${PIIANO_CS_ONLINE:-false}" \
      -e "PIIANO_CS_ENDPOINT_ROLE_TO_ASSUME=${PIIANO_CS_ENDPOINT_ROLE_TO_ASSUME}" \
      -e "PIIANO_CS_ENDPOINT_NAME=${PIIANO_CS_ENDPOINT_NAME}" \
      -e "PIIANO_CS_CUSTOMER_IDENTIFIER=${PIIANO_CUSTOMER_IDENTIFIER}" \
      -e "PIIANO_CS_CUSTOMER_ENV=${PIIANO_CUSTOMER_ENV}" \
      -e "PIIANO_CS_USER_ID=${PIIANO_CS_USER_ID}" \
      -e "PIIANO_CS_TAINT_ANALYZER_LOG_LEVEL=${PIIANO_CS_TAINT_ANALYZER_LOG_LEVEL}" \
      -e "PIIANO_CS_DEBUG=$(uname -a)" \
      -e "EXPERIMENTAL_DOCKER_DESKTOP_FORCE_QEMU"=1 \
      -e "PIIANO_CS_SCAN_ID_EXTERNAL=${PIIANO_CS_SCAN_ID_EXTERNAL:-}" \
     --env-file <(env | grep PIIANO_CS) \
      -v "${PATH_TO_SOURCE_CODE}:/source" ${VOLUME_DOCKER_FLAGS[@]:-} \
      --ulimit nofile=${MAX_NUM_OF_FILES_CONTAINER}:${MAX_NUM_OF_FILES_CONTAINER} \
      ${PIIANO_CS_ENGINE_IMAGE} ${EXTRA_TEST_PARAMS[@]:-}
fi

if [ "${PIIANO_CS_VIEWER_MODE}" = "online" ] ; then
  VIEWER_BASE_URL="${VIEWER_BASE_URL:-https://scanner.piiano.io}"
  echo "Your report will be ready in a moment at: ${FLOWS_APP_URL}/projects/${PROJECT_ID}/scans/${PIIANO_CS_SCAN_ID_EXTERNAL}"
  exit 0
fi

if [ ${PIIANO_CS_VIEWER_MODE} = "none" ] ; then
  echo "Skipping viewer"
  exit 0
fi

SCAN_OUTPUT_DIR=${PATH_TO_SOURCE_CODE}/piiano-scanner
if [ ! -e ${SCAN_OUTPUT_DIR}/report.json ] ; then
  echo "ERROR: expecting report.json file to be at ${SCAN_OUTPUT_DIR}/report.json"
  exit 1
fi

# Create a report directory with a placeholder for the api to be mapped to flows-viewer
CURRENT_API_FOLDER=${REPORT_DIR}/api-$(date "+%y%m%d_%H%M%S")-${UNIQUE_RUN_ID}
mkdir -p ${REPORT_DIR} ${CURRENT_API_FOLDER}
cp ${SCAN_OUTPUT_DIR}/report.json ${CURRENT_API_FOLDER}/offline-report.json

set_available_port
echo "[ ] Starting flows viewer on port ${PORT}..."

docker run ${ADDTTY} -d --rm --pull=always --name piiano-flows-viewer-${UNIQUE_RUN_ID}  \
    --hostname offline-flows-container \
    -e "PIIANO_CS_CUSTOMER_IDENTIFIER=${PIIANO_CUSTOMER_IDENTIFIER}" \
    -e "PIIANO_CS_CUSTOMER_ENV=${PIIANO_CUSTOMER_ENV}" \
    -v "${CURRENT_API_FOLDER}:/api" \
    -p "${PORT}:3000" \
    ${PIIANO_CS_VIEWER_IMAGE}

${BASEDIR}/wait-for-service.sh localhost:${PORT} 5 > /dev/null
trap cleanup_flow_viewer INT
echo "Flows viewer is ready at: http://localhost:${PORT}"
echo "Hit <CTRL-C> to stop viewer"
while : ; do sleep 3600 ; done
