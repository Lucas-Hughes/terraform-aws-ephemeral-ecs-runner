<!-- BEGIN_TF_DOCS -->

  This module is designed to create a stateless, event-driven GitLab runner utilizing the shell executor

  # GitLab Runner on ECS with shell executor

This repository contains a Terraform module for deploying a self-managed GitLab Runner on an ECS cluster that only spins up tasks whenever there is a pending job in the pipeline. This is done via sending job and pipeline status via a GitLab webhook to the lambda URL output by this module.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Known Issues](#limitations-with-this-module)
- [Usage](#usage)
  - [Step 1: Optional - Complete the prerequisite requirements](#step-1-optional-if-completed-previously-prerequisites)
  - [Step 2: Create a GitLab Runner Manager](#step-2-create-a-gitlab-runner-manager)
  - [Step 3: Use the Correct Source Block for this Terraform Module](#step-3-copy-the-module-block-from-below-to-the-terraform-maintf-you-want-to-deploy-the-runners-from)
  - [Step 4: Deploy the GitLab Runner](#step-4-deploy-the-gitlab-runner)
  - [Step 5: Create the GitLab Webhook](#step-5-create-the-gitlab-webhook)
- [Documentation](#documentation)
- [Support](#support)

## Overview

The GitLab Runner is responsible for executing CI/CD jobs defined in your GitLab projects. The runner that delegates the jobs lives in GitLab and utilizes the containers spun up by this module and the shell executor within a container in an ECS cluster to run the jobs.

## Prerequisites

To use this repository, you need the following:

- AWS account with appropriate permissions
- [Terraform](https://www.terraform.io/downloads.html) installed (version 1.5.0 or later)
- [Git](https://git-scm.com/downloads) installed
- At least reporter permissions in GitLab
- A personal access token created in GitLab and added to your ~/.terraformrc (see step 1 below)

## Limitations with this module

- In `.gitlab-ci.yml` files, you normally define an `image: alpine:latest` or something similar, that does not apply to these containers as they use the ECR image that you bake to use in the tasks.
- This module is unable to bake docker images using DinD (Docker in Docker) as Fargate does not support it. I have not tested using Kaniko for this, but I believe that it will be similar issues.

The EC2 version of this module will support and resolve both of these issues, but with a slightly longer spin up time.

## Usage

Follow these steps to deploy the GitLab Runner on your AWS infrastructure:

### Step 1 (Optional if completed previously): Prerequisites

## Create a GitLab personal access token and add to ~/.terraformrc

To access the private terraform module registry from your local machine, you will need to authenticate to that registry using the personal access token created in the GitLab console.

Click on your profile image -> edit profile -> Access Tokens -> Add New Token -> Create a token with api and read\_api permissions.

Once the token value is generated, grab that token and place it in your ~/.terraformrc file using the following echo command. You can also place the token value using the text editor of your choice. If you do not have a a ~/.terraformrc, please create one.

`echo 'credentials "gitlab.com" {token = "glpat-yourtokenvalue"}' >> ~/.terraformrc`

This token will now allow us to run `terraform init` and pull the module into our local machine.

## Baking a runner Docker image and pushing to ECR.

Because this module consumes an image in ECR, you will need to complete that prior to consuming this module as we will need the URI and version of the image as seen in the step below.

Example Dockerfile:

```go
FROM alpine:latest

# Install necessary packages
RUN apk add --no-cache \
    aws-cli \
    bash \
    ca-certificates \
    curl \
    docker-cli \
    git \
    git-lfs \
    openssh-client \
    && git lfs install

# Install Terraform
ENV TERRAFORM_VERSION=1.5.7
RUN curl -O https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip \
    && unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip -d /usr/local/bin \
    && rm terraform_${TERRAFORM_VERSION}_linux_amd64.zip

# Install tfsec
ENV TFSEC_VERSION=1.28.4
RUN curl -LO https://github.com/aquasecurity/tfsec/releases/download/v${TFSEC_VERSION}/tfsec-linux-amd64 \
    && mv tfsec-linux-amd64 tfsec \
    && chmod +x tfsec \
    && mv tfsec /usr/local/bin/

# Install TFLint
ENV TFLINT_VERSION=0.49.0
RUN curl -LO "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_amd64.zip" \
    && unzip tflint_linux_amd64.zip \
    && mv tflint /usr/local/bin/

# Install GitLab Runner
RUN curl -L https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-linux-amd64 -o /usr/local/bin/gitlab-runner \
    && chmod +x /usr/local/bin/gitlab-runner

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh

# Make entrypoint script executable
RUN chmod +x /entrypoint.sh

# Define entrypoint
ENTRYPOINT ["/entrypoint.sh"]
```

After defining the Dockerfile, you will need to build and publish it. Given that Apple M1 chips have issues with building Docker images sometimes, here's the commands that I used to build, tag, and push the image to AWS ECR.

`Use Alpine Linux as the base image - on mac

docker buildx build --platform linux/amd64 -t ecs-gitlab-runner . --load

docker tag ecs-gitlab-runner:latest 821585847758.dkr.ecr.us-east-1.amazonaws.com/forge/ecs-gitlab-runner:latest

aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 821585847758.dkr.ecr.us-east-1.amazonaws.com

docker push 821585847758.dkr.ecr.us-east-1.amazonaws.com/forge/ecs-gitlab-runner:latest`

Once this is completed, fetch the ECR URI and version as we need it to define a property below in Step 3.

### Step 2: Create a GitLab Runner Manager

Due to token architecture changes, you need to create the GitLab runner manager inside the GitLab console and get a token from there.

- If you are working at the group level, navigate to `group -> build -> runners -> New Group Runner`, create a new runner, and grab the token.
- If you are working at the project level, navigate to `settings -> CI/CD -> runners -> New Project Runner`, create a new runner, and grab the token.

Remember, you need to have maintainer/owner permissions in GitLab to perform these actions.

Once you obtain to token, head to the AWS console and search for the service `parameter store`. You will need to create a new parameter with the `SecureString` type. The name can be of your choosing. Once this is completed, grab the arn of that resource to pass as a property in Step 3.

### Step 3: Copy the module block from below to the terraform main.tf you want to deploy the runners from.

Please note that you must provide either the property `vpc_cidr_block` which will create a new vpc to host the runner or `private_subnets` which will create the runner in already existing private subnet(s).

```hcl
module "serverless_ecs_runner" {
  source  = "<module_url>"
  version = "<module_version>"

  project_name            = "ephemeral"
  vpc_cidr_block          = "10.0.0.0/24" #or you can pass in `private_subnets = ["your_subnet_id"]` to use an already existing VPC
  gitlab_runner_ecr_uri   = "<account_id>.dkr.ecr.us-east-1.amazonaws.com/ecs-gitlab-runner:latest"
  gitlab_runner_token_ssm = "arn:aws:ssm:us-east-1:<account_id>:parameter/ecs-gitlab-runner-secret"
  enable_flow_log         = false

  additional_ecs_policies = {
    ec2 = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
    s3  = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  }

  tags = {
    "Owner"       = "lucas.j.hughes@outlook.com"
    "environment" = "DEMO"
    "project"     = "gitlab-runners"
  }
}
```

If you are still unsure what a complete main.tf to deploy the runner should look like, please look at the ./examples/ directory to see a working example of the module being called. Please note that the source block will look different.

### Step 4: Deploy the GitLab Runner

1. Initialize the Terraform backend and download the required providers:

    ```bash
    terraform init
    ```

2. (Optional) Review the Terraform plan:

    ```bash
    terraform plan
    ```

3. Apply the Terraform configuration to deploy the GitLab Runner:

    ```bash
    terraform apply
    yes
    ```

### Step 5: Create the GitLab Webhook

The final piece of this configuration is the Webhook creation that sends events for jobs to the Lambda URL that is output after the terraform creation is completed.

1. You will need to grab the output URL, navigate to GitLab (either project or group level), settings, webhooks.

2. Click `Add a new webhook`

3. Paste the Lambda URL that was generated after the terraform is finished.

4. Navigate to the AWS account where the terraform was deployed -> Systems Manager -> Parameter Store -> look for the parameter that is named `${project-name}-webhook-header`. This will be the `Secret Token` for the Webook

5. Select the `Job events` and `Pipeline events` trigger. Keep SSL verification checked.

6. Add Webhook

Once this is completed, the next time you run a job, it should send information to the Lambda via the webhook, scale up tasks in ECS to execute these jobs, then terminate the tasks after they are completed.

## Other notes

There are cloudwatch log groups created for the processing Lambda function as well as the ECS task definitions giving insight needed to see where there may be issues.

## Documentation

For more information about GitLab Runners, Docker, and Terraform, refer to the following documentation:

- [GitLab Runner documentation](https://docs.gitlab.com/runner/)
- [Docker documentation](https://docs.docker.com/)
- [Terraform documentation](https://www.terraform.io/docs/index.html)

## Support

If you encounter any issues or have questions about this GitLab Runner configuration, please open an issue in this repository, or contact your organization's support team.

#### Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | ~> 2.4 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.6 |

#### Providers

| Name | Version |
|------|---------|
| <a name="provider_archive"></a> [archive](#provider\_archive) | ~> 2.4 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.6 |

#### Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | ~> 5.0 |

#### Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_log_group.cluster_log_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.gitlab_jobs_log_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_dynamodb_table.gitlab_jobs_table](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dynamodb_table) | resource |
| [aws_ecs_cluster.gitlab_jobs_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster) | resource |
| [aws_ecs_task_definition.gitlab_runner_task](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws_iam_role.ecs_task_execution_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.ecs_task_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.lambda_execution_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.ecs_task_execution_policy_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.ecs_task_role_policy_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.merged_policies](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_lambda_function.gitlab_jobs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_function_url.gitlab_jobs_url](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function_url) | resource |
| [aws_security_group.gitlab_runner_sg](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_ssm_parameter.webhook_header](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [random_password.webhook_header](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [archive_file.jobs_lambda](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [aws_subnet.existing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |

#### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_enable_flow_log"></a> [enable\_flow\_log](#input\_enable\_flow\_log) | Enable or disable flow log | `bool` | n/a | yes |
| <a name="input_gitlab_runner_ecr_uri"></a> [gitlab\_runner\_ecr\_uri](#input\_gitlab\_runner\_ecr\_uri) | The ECR location where the runner image is held, also include the version. eg <ecr\_uri:latest> | `string` | n/a | yes |
| <a name="input_gitlab_runner_token_ssm"></a> [gitlab\_runner\_token\_ssm](#input\_gitlab\_runner\_token\_ssm) | SSM parameter store arn where the registration token is stored. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Common tags for all resources | `map(string)` | n/a | yes |
| <a name="input_additional_ecs_policies"></a> [additional\_ecs\_policies](#input\_additional\_ecs\_policies) | Additional IAM policies to be merged for the ecs task execution role. Format is whatever\_name = arn\_of\_policy. | `map(string)` | `{}` | no |
| <a name="input_additional_ecs_task_execution_policies"></a> [additional\_ecs\_task\_execution\_policies](#input\_additional\_ecs\_task\_execution\_policies) | Additional IAM policies to be merged for the lambda execution role. Format is whatever\_name = arn\_of\_policy. | `map(string)` | `{}` | no |
| <a name="input_additional_lambda_policies"></a> [additional\_lambda\_policies](#input\_additional\_lambda\_policies) | Additional IAM policies to be merged for the lambda execution role. Format is whatever\_name = arn\_of\_policy. | `map(string)` | `{}` | no |
| <a name="input_ecs_role"></a> [ecs\_role](#input\_ecs\_role) | Name of the existing role to be used for deployment. | `string` | `null` | no |
| <a name="input_ecs_task_cpu"></a> [ecs\_task\_cpu](#input\_ecs\_task\_cpu) | Number of cpu units used by the task | `string` | `"4096"` | no |
| <a name="input_ecs_task_execution_role"></a> [ecs\_task\_execution\_role](#input\_ecs\_task\_execution\_role) | Name of the existing role to be used for deployment. | `string` | `null` | no |
| <a name="input_ecs_task_memory"></a> [ecs\_task\_memory](#input\_ecs\_task\_memory) | Number of memory (in MiB) units used by the task | `string` | `"8192"` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment you're working in | `string` | `"DEV"` | no |
| <a name="input_flow_log_destination_arn"></a> [flow\_log\_destination\_arn](#input\_flow\_log\_destination\_arn) | The ARN of the flow log destination | `string` | `null` | no |
| <a name="input_flow_log_destination_type"></a> [flow\_log\_destination\_type](#input\_flow\_log\_destination\_type) | The type of the flow log destination | `string` | `null` | no |
| <a name="input_lambda_role"></a> [lambda\_role](#input\_lambda\_role) | Name of the existing role to be used for deployment. | `string` | `null` | no |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | List of private subnets where the GitLab runner will be deployed. | `list(string)` | `null` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Prefix of the project that will be used throughout the deployment | `string` | `""` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS Region | `string` | `"us-east-1"` | no |
| <a name="input_vpc_cidr_block"></a> [vpc\_cidr\_block](#input\_vpc\_cidr\_block) | VPC CIDR block | `string` | `null` | no |

#### Outputs

| Name | Description |
|------|-------------|
| <a name="output_aws_lambda_function_url"></a> [aws\_lambda\_function\_url](#output\_aws\_lambda\_function\_url) | URL to access the lambda function. Needed for webhook |

<!-- END_TF_DOCS -->