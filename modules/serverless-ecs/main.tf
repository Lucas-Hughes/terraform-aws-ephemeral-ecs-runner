locals {
  project = lower("${var.project_name}-${var.environment}")
  tags    = merge(var.tags, { "t_environment" = upper(var.environment) })

  # IAM
  lambda_execution_policies = {
    DynamoDBAccess     = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess",
    ECSAccess          = "arn:aws:iam::aws:policy/AmazonECS_FullAccess",
    SSMParameterAccess = "arn:aws:iam::aws:policy/AmazonSSMFullAccess"
    LambdaBasic        = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  }

  ecs_task_policies = {
    ssm = "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"
  }

  ecs_task_execution_policies = {
    ecsExecution = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    ecr          = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    cwLogs       = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
    dynamo       = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
    ssm          = "arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"
  }

  use_existing_lambda_role = var.lambda_role != null
  merged_lambda_policies   = local.use_existing_lambda_role ? var.additional_lambda_policies : merge(local.lambda_execution_policies, var.additional_lambda_policies)

  use_existing_ecs_role = var.ecs_role != null
  merged_ecs_policies   = local.use_existing_ecs_role ? var.additional_ecs_policies : merge(local.ecs_task_policies, var.additional_ecs_policies)

  use_existing_ecs_task_execution_role = var.ecs_task_execution_role != null
  merged_ecs_task_execution_policies   = local.use_existing_ecs_task_execution_role ? var.additional_ecs_policies : merge(local.ecs_task_execution_policies, var.additional_ecs_task_execution_policies)

  # Logs
  flow_log_destination_type = var.enable_flow_log ? var.flow_log_destination_type : null
  flow_log_destination_arn  = var.enable_flow_log ? var.flow_log_destination_arn : null

  # Networking
  use_existing_vpc = var.private_subnets != null ? (length(var.private_subnets) > 0) : false
  base_cidr        = var.vpc_cidr_block
  azs              = slice(data.aws_availability_zones.available.names, 0, 3)

  public_subnets = var.vpc_cidr_block != null ? [
    cidrsubnet(local.base_cidr, 4, 1),
    cidrsubnet(local.base_cidr, 4, 2),
  ] : []

  private_subnets = var.vpc_cidr_block != null ? [
    cidrsubnet(local.base_cidr, 4, 3),
    cidrsubnet(local.base_cidr, 4, 4),
  ] : []
}

#Random Secret Header for Webhook
resource "random_password" "webhook_header" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"

  lifecycle {
    ignore_changes = all
  }
}

resource "aws_ssm_parameter" "webhook_header" {
  name  = "${local.project}-webhook-header"
  type  = "SecureString"
  value = random_password.webhook_header.result

  lifecycle {
    ignore_changes = all
  }
}

#DynamoDB Table
#tfsec:ignore:aws-dynamodb-enable-recovery
#tfsec:ignore:aws-dynamodb-table-customer-key
resource "aws_dynamodb_table" "gitlab_jobs_table" {
  name           = "${local.project}-gitlab-jobs"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "pipelineId"
  range_key      = "taskId"

  server_side_encryption {
    enabled = true
  }

  attribute {
    name = "pipelineId"
    type = "S"
  }

  attribute {
    name = "taskId"
    type = "S"
  }

  tags = local.tags
}

#ECS Runner
resource "aws_iam_role" "ecs_task_role" {
  count = local.use_existing_ecs_role ? 0 : 1
  name  = "${local.project}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Effect = "Allow",
        Sid    = ""
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_role_policy_attachment" {
  for_each   = local.merged_ecs_policies
  role       = aws_iam_role.ecs_task_role[0].name
  policy_arn = each.value
}

resource "aws_iam_role" "ecs_task_execution_role" {
  count = local.use_existing_ecs_task_execution_role ? 0 : 1
  name  = "${local.project}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Effect = "Allow",
        Sid    = ""
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy_attachment" {
  for_each   = local.merged_ecs_task_execution_policies
  role       = aws_iam_role.ecs_task_execution_role[0].name
  policy_arn = each.value
}

resource "aws_ecs_task_definition" "gitlab_runner_task" {
  family                   = "${local.project}-gitlab-runner-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  task_role_arn            = local.use_existing_ecs_role ? var.ecs_role : aws_iam_role.ecs_task_role[0].arn
  execution_role_arn       = local.use_existing_ecs_role ? var.ecs_role : aws_iam_role.ecs_task_execution_role[0].arn
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory

  container_definitions = jsonencode([
    {
      name             = "gitlab-runner"
      image            = var.gitlab_runner_ecr_uri
      cpu              = 0
      portMappings     = []
      essential        = true
      environment      = []
      environmentFiles = []
      mountPoints      = []
      volumesFrom      = []
      secrets = [
        {
          name      = "REGISTRATION_TOKEN"
          valueFrom = var.gitlab_runner_token_ssm
        }
      ]
      ulimits = []
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-create-group"  = "true"
          "awslogs-group"         = "gitlab-runner-task"
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "${local.project}/"
        }
      }
    }
  ])
}

#tfsec:ignore:aws-cloudwatch-log-group-customer-key
resource "aws_cloudwatch_log_group" "cluster_log_group" {
  name              = "/aws/ecs/${local.project}-gitlab-runner"
  retention_in_days = 3
}

resource "aws_ecs_cluster" "gitlab_jobs_cluster" {
  name = "${local.project}-gitlab-runner"

  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"
      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.cluster_log_group.name
      }
    }
  }

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

#Jobs Lambda
resource "aws_iam_role" "lambda_execution_role" {
  count = local.use_existing_lambda_role ? 0 : 1
  name  = "${local.project}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Principal = {
          Service = "lambda.amazonaws.com"
        },
        Effect = "Allow",
        Sid    = ""
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "merged_policies" {
  for_each   = local.merged_lambda_policies
  role       = aws_iam_role.lambda_execution_role[0].name
  policy_arn = each.value
}

#tfsec:ignore:aws-cloudwatch-log-group-customer-key
resource "aws_cloudwatch_log_group" "gitlab_jobs_log_group" {
  name              = "/aws/lambda/${aws_lambda_function.gitlab_jobs.function_name}"
  retention_in_days = 3
}

data "archive_file" "jobs_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/jobs/code/"
  output_path = "${path.module}/lambda/jobs/output/gitlab-jobs.zip"
}

#tfsec:ignore:aws-lambda-enable-tracing
resource "aws_lambda_function" "gitlab_jobs" {
  filename         = "${path.module}/lambda/jobs/output/gitlab-jobs.zip"
  function_name    = "${local.project}-gitlab-jobs"
  handler          = "gitlab_jobs.lambda_handler"
  memory_size      = 512
  publish          = true
  role             = local.use_existing_lambda_role ? var.lambda_role : aws_iam_role.lambda_execution_role[0].arn
  runtime          = "python3.11"
  source_code_hash = filesha256(data.archive_file.jobs_lambda.output_path)
  tags             = local.tags

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = aws_dynamodb_table.gitlab_jobs_table.name
      SSM_PARAMETER_NAME  = aws_ssm_parameter.webhook_header.name
      ECS_CLUSTER_NAME    = aws_ecs_cluster.gitlab_jobs_cluster.name
      ECS_TASK_FAMILY     = "${local.project}-gitlab-runner-task"
      SUBNET_IDS          = join(",", length(module.vpc) > 0 ? module.vpc[0].private_subnets : var.private_subnets)
      SECURITY_GROUP_ID   = aws_security_group.gitlab_runner_sg.id
    }
  }

  lifecycle {
    ignore_changes = [source_code_hash]
  }
}

resource "aws_lambda_function_url" "gitlab_jobs_url" {
  function_name      = aws_lambda_function.gitlab_jobs.function_name
  authorization_type = "NONE"
}

#Supporting Networking Resources 
#tfsec:ignore:aws-ec2-require-vpc-flow-logs-for-all-vpcs
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
  count   = local.use_existing_vpc ? 0 : 1

  name = local.project
  cidr = local.base_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags

  enable_flow_log           = var.enable_flow_log
  flow_log_destination_type = var.enable_flow_log ? var.flow_log_destination_type : null
  flow_log_destination_arn  = var.enable_flow_log ? var.flow_log_destination_arn : null
}

data "aws_subnet" "existing" {
  count = local.use_existing_vpc ? 1 : 0
  id    = var.private_subnets[0]
}

#tfsec:ignore:aws-ec2-no-public-egress-sgr
resource "aws_security_group" "gitlab_runner_sg" {
  name_prefix = "${local.project}-"
  description = "Security group for the GitLab Runner"
  vpc_id      = local.use_existing_vpc ? data.aws_subnet.existing[0].vpc_id : module.vpc[0].vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = merge(local.tags, { "Name" = "${local.project}-sg" })
}