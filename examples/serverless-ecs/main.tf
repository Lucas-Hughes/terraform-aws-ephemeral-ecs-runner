terraform {
  required_version = ">= 1.5"
}

module "serverless_ecs" {
  source = "../../modules/serverless-ecs"

  project_name            = "sample"
  vpc_cidr_block          = "10.0.0.0/24"
  gitlab_runner_ecr_uri   = "" #your baked ECR image + version, see README.md
  gitlab_runner_token_ssm = "" #your gitlab runner registration token, see README.md

  additional_ecs_policies = {
    ec2 = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
    s3  = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  }

  tags = {
    "Owner"       = "lucas.hughes@pearson.com"
    "environment" = "DEMO"
    "project"     = "gitlab-runners"
  }
}