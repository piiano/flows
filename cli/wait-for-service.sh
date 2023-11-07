#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Set service_url to the first parameter or default to "http://localhost:3000"
service_url="${1:-http://localhost:3000}"

# Set max_attempts to the second parameter or default to 10
max_attempts="${2:-10}"
SLEEP_BETWEEN_ATTEMPTS_SECS=10

# Poll the service until it's up or until the maximum number of attempts is reached
attempt_counter=0
while [ "$attempt_counter" -lt "$max_attempts" ]; do
  response=$(curl --write-out '%{http_code}' --silent --output /dev/null "$service_url")

  if [ "$response" -eq 200 ]; then
    echo "Service is up and returned HTTP 200"
    exit 0
  else
    echo "Service returned HTTP $response. Retrying ${attempt_counter}..."
    ((attempt_counter++))
    if [ "$attempt_counter" -eq "$max_attempts" ]; then
      echo "Max attempts reached. Exiting."
      exit 1
    fi
    sleep ${SLEEP_BETWEEN_ATTEMPTS_SECS}
  fi
done
echo "Service is not up. Give up"
exit 1
