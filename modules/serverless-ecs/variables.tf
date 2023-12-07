variable "gitlab_runner_token_ssm" {
  description = "SSM parameter store arn where the registration token is stored."
  type        = string
  sensitive   = true
}

variable "gitlab_runner_ecr_uri" {
  description = "The ECR location where the runner image is held, also include the version. eg <ecr_uri:latest>"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
}

variable "environment" {
  type        = string
  description = "Environment you're working in"
  default     = "DEV"
}

variable "project_name" {
  type        = string
  description = "Prefix of the project that will be used throughout the deployment"
  default     = ""
}

variable "vpc_cidr_block" {
  type        = string
  description = "VPC CIDR block"
  default     = null
}

variable "region" {
  type        = string
  description = "AWS Region"
  default     = "us-east-1"
}

variable "private_subnets" {
  description = "List of private subnets where the GitLab runner will be deployed."
  type        = list(string)
  default     = null
}

variable "ecs_task_cpu" {
  description = "Number of cpu units used by the task"
  type        = string
  default     = "4096"
}

variable "ecs_task_memory" {
  description = "Number of memory (in MiB) units used by the task"
  type        = string
  default     = "8192"
}

variable "lambda_role" {
  description = "Name of the existing role to be used for deployment."
  type        = string
  default     = null
}

variable "ecs_role" {
  description = "Name of the existing role to be used for deployment."
  type        = string
  default     = null
}

variable "ecs_task_execution_role" {
  description = "Name of the existing role to be used for deployment."
  type        = string
  default     = null
}

variable "additional_lambda_policies" {
  description = "Additional IAM policies to be merged for the lambda execution role. Format is whatever_name = arn_of_policy."
  type        = map(string)
  default     = {}
}

variable "additional_ecs_policies" {
  description = "Additional IAM policies to be merged for the ecs task execution role. Format is whatever_name = arn_of_policy."
  type        = map(string)
  default     = {}
}

variable "additional_ecs_task_execution_policies" {
  description = "Additional IAM policies to be merged for the lambda execution role. Format is whatever_name = arn_of_policy."
  type        = map(string)
  default     = {}
}

variable "enable_flow_log" {
  description = "Enable or disable flow log"
  type        = bool
}

variable "flow_log_destination_type" {
  description = "The type of the flow log destination"
  type        = string
  default     = null
}

variable "flow_log_destination_arn" {
  description = "The ARN of the flow log destination"
  type        = string
  default     = null
}