## Running Flows In CI/CD

We support running flows in Various CI/CD environments. 

### Github

We have 2 Ways to run Scans in Github:

#### Reusable Workflow

This [workflow](./reusable-workflow.yml) can be used to run Flows as a job in your workflows, for example like in this Workflow which scans the Shopizer source code.

The inputs for this reusable actions are:

1. Client Id 
2. Client Secret 
(these tokens are described [here](../cli/) ))
3. A Url to the repo (with any authentication token needed to clone it)
4. The sub directory to scan (optional)
5. customer_identifier: <your-company-name>
6.  customer_env: <environment-such-as-prod-or-stage>

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

Notes:
1. The provided runner_type should have netcat installed

#### Github Action

In case the prepation of the code is more complex (connecting to artifactory , running some script before build ), it is recommended to use the provided github action.

This is an example workdflow to use the flows scan action:

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

The Action inputs are:


1. Client Id 
2. Client Secret 
(these tokens are described [here](../cli/) ))
3. A directory to scan
4. The sub directory to scan (optional)
5. customer_identifier: <your-company-name>
6.  customer_env: <environment-such-as-prod-or-stage>


### Bitbucket

this pipeline is used to scan a Bitbucket repo with flows 

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

The default Bitbucket runners can only handle scanning of smalelr repositories, use a self hosted larger runner to scan more complex projects.

Use the secrets CLIENT_ID & CLIENT_SECRET to save the Keys (generating these tokens are described [here](../cli/) )

Please set  $Customer_Id & $Customer_Env.

The generated JSON report is saved as an artifact , and the UI viewer URL appears in the Bitbucket Build output ( In a lint that looks like this:
    `Your report will be ready in a moment at: https://scanner.piiano.io/scans/{scan_id}}`
)