## Running Flows In CI/CD

This guide outlines the process for running flows in various CI/CD environments.

### Github

Scan in Github using two methods:

1. Reuseable workflow
2. Github action

#### Reusable Workflow

You can utilize the reusable workflow to run flows as a job in your workflows.

The inputs for this reusable action are:

1. Client Id ([more details](../cli/))
2. Client Secret ([more details](../cli/))
3. A URL to the repository (with any authentication token needed to clone it)
4. The sub-directory to scan (optional)
5. Customer Identifier: <your-company-name>
6. Customer Environment: <environment-such-as-prod-or-stage>

**Prerequisites:** the provided runner_type should have netcat installed.

Here is an example of how to use this action

```yml
name: Piiano Flows Workflow
on:
  workflow_dispatch:
    inputs:
      client_id:
        required: true
        type: string
      client_secret:
        required: true
        type: string
      repo_url:
        required: true
        type: string
      sub_dir:
        required: false
        type: string
        default: ""
      project_name:
        required: false
        type: string
        default: ""

  run_scan_with_workflow:
    uses: piiano/flows/.github/workflows/scan.yml
    with:
      repo: ${{inputs.repo_url}}
      sub_dir: ${{inputs.sub_dir}}
      project_name: ${{inputs.project_name}}
      customer_identifier: <your-company-name>
      customer_env: github_test_action
      runner_type: <runner-type, such as ubuntu-latest , ubuntu-latest-4-cores>
    secrets:
      client_id: ${{inputs.client_id}}
      client_secret: ${{inputs.client_secret}}
```

#### Github Action

When the preparation of the code is more complex (e.g., connecting to Artifactory, running some scripts before build), it is recommended to use the provided Github action.

Here is an example workflow to use the flows scan action:

```yml
name: Piiano Flows Using Action
on:
  workflow_dispatch:
    inputs:
      client_id:
        required: true
        type: string
      client_secret:
        required: true
        type: string
      repo_url:
        required: true
        type: string
      sub_dir:
        required: false
        type: string
        default: ""
      project_name:
        required: false
        type: string
        default: ""
jobs:
  run_scan_with_action:
    runs-on: "ubuntu-latest"
    steps:
      - name: Checkout the action repo
        uses: actions/checkout@v3
        with:
          repository: flows
          path: ${{ github.workspace }}/flows
      - name: Checkout Repo to Scan
        run: |
          git clone ${{inputs.repo_url}}
      - name: Run Scan
        id: scan
        uses: ${{ github.workspace }}/flows/ci/action
        with:
          customer_identifier: piiano
          customer_env: github_test_action
          client_id: ${{inputs.client_id}}
          client_secret: ${{inputs.client_secret}}
          repo: ${{ github.workspace }}/code-scanner-test
          sub_dir: java/bank/source
          project_name: ${{inputs.project_name}}
```

The action inputs are:

1. Client Id ([more details](../cli/))
2. Client Secret ([more details](../cli/))
3. A directory to scan
4. The sub-directory to scan (optional)
5. Project name
6. Customer Identifier: <your-company-name>
7. Customer Environment: <environment-such-as-prod-or-stage>

### Gitlab

Here is an example pipeline to run Flows in a Gitlab repo. The pipeline is designed to run a scan on the project's codebase. It uses Docker-in-Docker (dind) service to facilitate Docker operations within the pipeline. The primary job is configured to run manually, and it includes installation of necessary tools, building the project, and executing the scan.


```yml
# Use an image that can be used to build the project
image: ubuntu:22.04 
services:
  - docker:dind
stages:
  - scan

variables:
  CUSTOMER_IDENTIFIER: 
    description: "Piiano client identifier"
    value: 'piiano-demo'
  CUSTOMER_ENV: 
    description: "Piiano client env - ci / dev etc..."
    value: 'ci_demo'
  SUB_DIR: 
    description: "sub dir where the project resides"
    value: 'java/bank/source'
  PROJECT_NAME: 
    description: "Project name"
    value: 'Demo GL'
  # Needed for dind to work with ubuntu image
  DOCKER_HOST: "tcp://docker:2375"
# Default job to be executed on push to main and can also be manually triggered
run_scan_with_action:
  stage: scan
  # Choose a suitable runner
  tags:
    - saas-linux-medium-amd64
  script:
    # Install requried processes for scan, jq, git, curl, netcat are needed for Flows scan
    # docker.io is neededd to work with dind service in ubuntu image 
    - apt-get update && apt-get install -y maven jq  openjdk-17-jdk git curl netcat apt-transport-https ca-certificates gnupg gnupg-agent software-properties-common docker.io
    # Build the project locally to get dependecies to local repository ( in this case mvn package , change according to the build command )
    - if [ ! -z "$SUB_DIR" ]; then cd $SUB_DIR; fi 
    - mvn package # run you own build command outside 
    - echo "Local build complete."
    - cd $CI_PROJECT_DIR
    - |
      if [ -n "$CI_JOB_TOKEN" ]; then
        echo "Running scan with the following parameters:"
        echo "Customer Identifier: $CUSTOMER_IDENTIFIER"
        echo "Customer Environment: $CUSTOMER_ENV"
        echo "Sub Directory: $SUB_DIR"
        echo "Project Name: $PROJECT_NAME"
        echo "Ref: $CI_COMMIT_REF_NAME"
        echo "Repo: $CI_PROJECT_PATH"
        # set up variables for scan
        export PIIANO_CUSTOMER_ENV=$CUSTOMER_ENV
        export PIIANO_CUSTOMER_IDENTIFIER=$CUSTOMER_IDENTIFIER
        export FLOWS_PROJECT_NAME=$PROJECT_NAME
        export PIIANO_CS_query_parallelism=1
        export PIIANO_CS_sub_dir=$SUB_DIR
        # using dind service forces this bind method, and .piiano folder to be below $CI_PROJECT_DIR
        export FLOWS_MOUNT_TYPE=bind-mount
        export FLOWS_TEMP_FOLDER=$CI_PROJECT_DIR/.piiano   
        git clone https://github.com/piiano/flows.git ./.piiano/flows
        cd ./.piiano/flows/cli
        # run the scan
        ./flows-cli.sh $CI_PROJECT_DIR
      else
        echo "CI_JOB_TOKEN is not set."
      fi
  only:
    - main
  when: manual
```


#### How to Trigger the Manual Job

1. Go to your project's CI/CD > Pipelines page.
2. Find the pipeline with the manual job waiting for action.
3. Click on the pipeline to view job details.
4. Locate the run_scan_with_action job (it will have a "Play" button next to it).
5. Click the "Play" button to trigger the manual job.



### Bitbucket

This pipeline is used to scan a Bitbucket repository with flows.

```yml
definitions:
  services:
    # Define the Docker service with 4 GB memory limit
    docker:
      memory: 4096
pipelines:
  custom:
    piiano:
      - variables: #list variable names under here
          - name: Customer_Id
          - name: Customer_Env
          - name: Project_Name
      - step:
          size: 2x
          name: Clone and run script
          image: atlassian/default-image:4 # you can use your own image
          script:
            - apt-get update && apt-get install -y netcat # install netcat, for alpine based use apk add --update --no-cache netcat-openbsd
            - ./gradlew build # run you own build command outside the flows docker to fetch dependencies
            - git clone https://github.com/piiano/flows.git ./.piiano/flows
            - export FLOWS_MOUNT_TYPE=bind-mount
            - export FLOWS_TEMP_FOLDER=$BITBUCKET_CLONE_DIR/.piiano
            - export PIIANO_CLIENT_ID=$CLIENT_ID
            - export PIIANO_CLIENT_SECRET=$CLIENT_SECRET
            - export PIIANO_CUSTOMER_ENV=$Customer_Env
            - export PIIANO_CUSTOMER_IDENTIFIER=$Customer_Id
            - export FLOWS_PROJECT_NAME=$Project_Name
            - export PIIANO_CS_query_parallelism=1
            - export PIIANO_CS_max_taint_query_memory=4096
            - cd ./.piiano/flows/cli
            - ./flows-cli.sh $BITBUCKET_CLONE_DIR
          services:
            - docker
          artifacts:
            - piiano-scanner/report.json
```

Notes:

1. The default Bitbucket runners can only handle scanning smaller repositories. Use a self-hosted larger runner to scan more complex projects.
2. Build your project in a step before running `flows-cli.sh`
3. Use the secrets `CLIENT_ID` and `CLIENT_SECRET` to save the keys (generating these tokens are described [here](../cli/)).
4. Set `$Customer_Id` and `$Customer_Env`
5. Set `$Project_Name`
6. The scan report is JSON formatted and is saved as an artifact.
7. The UI viewer URL appears in the Bitbucket Build output (e.g.`Your report will be ready in a moment at: https://scanner.piiano.io/scans/{scan_id}`).
