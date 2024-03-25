## Running Flows In CI/CD

This guide outlines the process for running flows in various CI/CD environments.

### Github
There are 2 ways to run scans in Github:

#### Reusable Workflow
You can utilize the reusable workflow to run flows as a job in your workflows. 

The inputs for this reusable action are:

Client Id
Client Secret (These tokens are described [here](../cli/) )
A URL to the repository (with any authentication token needed to clone it)
The sub-directory to scan (optional)
Customer Identifier: <your-company-name>
Customer Environment: <environment-such-as-prod-or-stage>
Notes:

The provided runner_type should have netcat installed.

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
        default: ''


  run_scan_with_workflow:
    uses: piiano/flows/.github/workflows/scan-workflow.yml
    with:
      repo: ${{inputs.repo_url}}
      sub_dir: ${{inputs.sub_dir}}
      customer_identifier: <your-company-name>
      customer_env: github_test_action
      runner_type: <runner-type, such as ubuntu-latest , ubuntu-latest-4-cores>
    secrets:
      client_id: ${{inputs.client_id}}
      client_secret: ${{inputs.client_secret}}

```



#### Github Action
If the preparation of the code is more complex (e.g., connecting to Artifactory, running some scripts before build), it is recommended to use the provided Github action.

Here's an example workflow to use the flows scan action:

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
        default: ''
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
       uses: ${{ github.workspace }}/flows/continuous/action
       with:
         customer_identifier: piiano
         customer_env: github_test_action
         client_id: ${{inputs.client_id}}
         client_secret: ${{inputs.client_secret}}
         repo: ${{ github.workspace }}/code-scanner-test
         sub_dir: java/bank/source

```

The action inputs are:

Client Id
Client Secret (These tokens are described here)
A directory to scan
The sub-directory to scan (optional)
Customer Identifier: <your-company-name>
Customer Environment: <environment-such-as-prod-or-stage>


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
      - variables:          #list variable names under here
          - name: Customer_Id
          - name: Customer_Env
      - step:
          size: 2x
          name: Clone and run script
          image: atlassian/default-image:4
          script:
            - apt-get update
            - apt-get install -y netcat
            - git clone https://github.com/piiano/flows.git
            - export FLOWS_USE_VOLUMES=false
            - export PIIANO_CLIENT_ID=$CLIENT_ID
            - export PIIANO_CLIENT_SECRET=$CLIENT_SECRET
            - export PIIANO_CUSTOMER_ENV=$Customer_Env
            - export PIIANO_CUSTOMER_IDENTIFIER=$Customer_Id
            - export PIIANO_CS_sub_dir=java/bank/source
            - export PIIANO_CS_GRADLE_FOLDER=$BITBUCKET_CLONE_DIR/gradle
            - export PIIANO_CS_M2_FOLDER=$BITBUCKET_CLONE_DIR/m2
            - export PIIANO_CS_query_parallelism=1
            - export PIIANO_CS_max_taint_query_memory=4096
            - cd flows/cli
            - chmod +x flows-cli.sh
            - ./flows-cli.sh $BITBUCKET_CLONE_DIR
          services:
            - docker
          artifacts:
            - piiano-scanner/report.json

```

Notes:

The default Bitbucket runners can only handle scanning smaller repositories. Use a self-hosted larger runner to scan more complex projects.
Use the secrets CLIENT_ID & CLIENT_SECRET to save the keys (generating these tokens are described here).
Please set $Customer_Id & $Customer_Env.
The generated JSON report is saved as an artifact, and the UI viewer URL appears in the Bitbucket Build output (in a link that looks like this: Your report will be ready in a moment at: https://scanner.piiano.io/scans/{scan_id}).

