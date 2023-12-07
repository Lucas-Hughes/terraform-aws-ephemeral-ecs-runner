import json
import hmac
import logging
import boto3
import os
from botocore.exceptions import ClientError

# Initialize the logs
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize the clients
ssm_client = boto3.client('ssm')
ecs_client = boto3.client('ecs')
dynamodb_client = boto3.client('dynamodb')

# Use environment variables for dynamodb table name and secret token name
dynamodb_table_name = os.environ.get('DYNAMODB_TABLE_NAME')
ssm_parameter_name = os.environ.get('SSM_PARAMETER_NAME')

def get_secret_token():
    try:
        parameter = ssm_client.get_parameter(Name=ssm_parameter_name, WithDecryption=True)
        return parameter['Parameter']['Value']
    except ClientError as e:
        logger.error(f"Error retrieving secret token from SSM: {e}")
        return None

def validate_gitlab_token(event, secret_token):
    gitlab_token = event['headers'].get('x-gitlab-token', '')
    return hmac.compare_digest(gitlab_token, secret_token)

def record_job_start(pipeline_id, task_id):
    pipeline_id_str = str(pipeline_id)
    try:
        logger.info(f"Recording job start in DynamoDB for pipeline ID: {pipeline_id_str}, Task ID: {task_id}")
        dynamodb_client.put_item(
            TableName=dynamodb_table_name,
            Item={
                'pipelineId': {'S': pipeline_id_str},
                'taskId': {'S': task_id}
            }
        )
        logger.info("Recorded job start successfully.")
    except ClientError as e:
        logger.error(f"Error recording job start: {e}")
        raise

def handle_pipeline_completion(pipeline_id):
    pipeline_id_str = str(pipeline_id)
    ecs_cluster_name = os.environ['ECS_CLUSTER_NAME']

    try:
        # Query tasks for the pipeline ID
        response = dynamodb_client.query(
            TableName=dynamodb_table_name,
            KeyConditionExpression='pipelineId = :pid',
            ExpressionAttributeValues={':pid': {'S': pipeline_id_str}}
        )
        tasks = response.get('Items', [])

        # Stop each task and delete the DynamoDB entry
        for task in tasks:
            task_id = task['taskId']['S']
            ecs_client.stop_task(cluster=ecs_cluster_name, task=task_id)

            dynamodb_client.delete_item(
                TableName=dynamodb_table_name,
                Key={'pipelineId': {'S': pipeline_id_str}, 'taskId': {'S': task_id}}
            )
            logger.info(f"Stopped task {task_id} for pipeline ID {pipeline_id_str}")

    except ClientError as e:
        logger.error(f"Error handling pipeline completion: {e}")
        raise

def get_latest_task_definition(task_family):
    response = ecs_client.list_task_definitions(familyPrefix=task_family, status='ACTIVE', sort='DESC', maxResults=1)
    task_def_arns = response.get('taskDefinitionArns')
    return task_def_arns[0] if task_def_arns else None

def start_ecs_task(pipeline_id):
    task_family = os.environ['ECS_TASK_FAMILY']
    ecs_cluster_name = os.environ['ECS_CLUSTER_NAME']
    subnet_ids = os.environ['SUBNET_IDS'].split(',')
    security_group_id = os.environ['SECURITY_GROUP_ID']

    latest_task_definition = get_latest_task_definition(task_family)
    if not latest_task_definition:
        logger.error(f"No active task definitions found for family: {task_family}")
        raise Exception("No active task definitions found")

    try:
        response = ecs_client.run_task(
            cluster=ecs_cluster_name,
            taskDefinition=latest_task_definition,
            launchType='FARGATE',
            networkConfiguration={
                'awsvpcConfiguration': {
                    'subnets': subnet_ids,
                    'securityGroups': [security_group_id],
                    'assignPublicIp': 'DISABLED'
                }
            },
        )
        task_id = response['tasks'][0]['taskArn']
        logger.info(f"Started ECS task: {task_id} for pipeline ID: {pipeline_id}")
        return task_id
    except ClientError as e:
        logger.error(f"Error starting ECS task: {e}")
        raise

def lambda_handler(event, context):
    secret_token = get_secret_token()
    if not secret_token:
        return {'statusCode': 500, 'body': json.dumps({'message': 'Error retrieving secret token from SSM'})}

    if not validate_gitlab_token(event, secret_token):
        return {'statusCode': 401, 'body': json.dumps({'message': 'Unauthorized'})}

    gitlab_event_type = event['headers'].get('x-gitlab-event', '')
    gitlab_payload = json.loads(event['body'])

    if gitlab_event_type == 'Job Hook' and gitlab_payload.get('build_status') == 'pending':
        try:
            task_id = start_ecs_task(gitlab_payload['pipeline_id'])
            record_job_start(str(gitlab_payload['pipeline_id']), task_id)
        except Exception as e:
            logger.error(f"Error processing Job Hook event: {e}")
            return {'statusCode': 500, 'body': json.dumps({'message': 'Error processing Job Hook event'})}

    elif gitlab_event_type == 'Pipeline Hook' and gitlab_payload['object_attributes']['status'] in ['success', 'failed', 'canceled']:
        try:
            handle_pipeline_completion(gitlab_payload['object_attributes']['id'])
        except Exception as e:
            logger.error(f"Error processing Pipeline Hook event: {e}")
            return {'statusCode': 500, 'body': json.dumps({'message': 'Error processing Pipeline Hook event'})}

    return {'statusCode': 200, 'body': json.dumps({'message': 'Event processed successfully'})}