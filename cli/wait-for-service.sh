#!/bin/bash
IFS=$'\n\t'

# First argument is the service URL that defaults to "http://localhost:3000"
service_url="${1:-http://localhost:3000}"

# Second optional parameter - max attempts
max_attempts="${2:-10}"

# Third, optional argument - PID to follow. If it dies, exit
PID="${3:-0}"

SLEEP_BETWEEN_ATTEMPTS_SECS=3

echo "Wait for service on ${service_url} for ${max_attempts} and PID=${PID}"

# Poll the service until it's up or until the maximum number of attempts is reached
attempt_counter=0
while [ "$attempt_counter" -lt "$max_attempts" ]; do
    response=$(curl --write-out '%{http_code}' --silent --output /dev/null "$service_url" || true)

    if [ "$response" -eq 200 ]; then
        echo "Service is up and returned HTTP 200"
        exit 0
    else
        # print only every 10 messages - do not flood the console
        if [ $((attempt_counter % 10)) -eq 0 ]; then
          echo "Service returned HTTP $response. Retrying ${attempt_counter}..."
        fi
        ((attempt_counter++))
        if [ "$attempt_counter" -eq "$max_attempts" ]; then
            echo "Max attempts reached. Exiting."
            exit 1
        fi
      if [ ${PID} -ne 0 ] ; then
          if ! ps -p ${PID} > /dev/null 2>&1 ; then
            echo "Process ${PID} has died, exit."
            exit 1
          fi
      fi
      sleep ${SLEEP_BETWEEN_ATTEMPTS_SECS}
    fi
done

echo "Service is not up after timeout. Give up"
exit 1
