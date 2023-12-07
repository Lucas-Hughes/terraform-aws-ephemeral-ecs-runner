output "aws_lambda_function_url" {
  description = "URL to access the lambda function. Needed for webhook"
  value       = "Use this URL when creating the webhook in GitLab - ${aws_lambda_function_url.gitlab_jobs_url.function_url}"
}