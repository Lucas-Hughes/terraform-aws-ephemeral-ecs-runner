output "lambda_url_output" {
  description = "URL for the lambda function to use in the Webhook"
  value       = module.serverless_ecs.aws_lambda_function_url
}