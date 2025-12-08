"""
AWS Lambda function to auto-shutdown ECS tasks when budget threshold is reached.
Triggered by AWS Budget alerts via SNS.

To deploy this Lambda:
1. Zip this file: zip budget-shutdown-lambda.zip budget-shutdown-lambda.py
2. Create Lambda function in AWS Console or via CLI
3. Set environment variables: ECS_CLUSTER, ECS_SERVICE, SNS_TOPIC_ARN
4. Subscribe this Lambda to your budget alert SNS topic
"""

import boto3
import json
import os


def lambda_handler(event, context):
    """
    Stop ECS service when budget threshold is reached.
    
    This function is triggered by SNS notifications from AWS Budgets.
    When the budget threshold (90%) is exceeded, it scales the ECS service
    to 0 tasks, effectively shutting down the application.
    
    Args:
        event: SNS event containing budget alert information
        context: Lambda context object
        
    Returns:
        dict: Response with status code and message
    """
    ecs = boto3.client('ecs')
    sns = boto3.client('sns')
    
    # Configuration from environment variables
    cluster = os.environ.get('ECS_CLUSTER', 'deep-research-cluster')
    service = os.environ.get('ECS_SERVICE', 'deep-research-service')
    topic_arn = os.environ.get('SNS_TOPIC_ARN')
    
    print(f"Budget alert received: {json.dumps(event)}")
    
    # Parse SNS message if present
    budget_details = "Budget threshold exceeded"
    if 'Records' in event:
        try:
            sns_message = event['Records'][0]['Sns']['Message']
            budget_details = sns_message
            print(f"SNS Message: {sns_message}")
        except (KeyError, IndexError) as e:
            print(f"Could not parse SNS message: {e}")
    
    try:
        # Check current service status
        response = ecs.describe_services(
            cluster=cluster,
            services=[service]
        )
        
        if not response['services']:
            return {
                'statusCode': 404,
                'body': json.dumps(f'Service {service} not found in cluster {cluster}')
            }
        
        current_count = response['services'][0]['desiredCount']
        print(f"Current desired count: {current_count}")
        
        if current_count == 0:
            return {
                'statusCode': 200,
                'body': json.dumps('Service already scaled to 0')
            }
        
        # Scale down to 0 tasks
        ecs.update_service(
            cluster=cluster,
            service=service,
            desiredCount=0
        )
        
        print(f"Successfully scaled service {service} to 0 tasks")
        
        # Send notification
        notification_message = f"""
BUDGET ALERT: Deep Research Agent Shutdown

Your Deep Research Agent has been automatically shut down because your AWS 
spending has reached the budget threshold.

Details:
- Cluster: {cluster}
- Service: {service}
- Previous Task Count: {current_count}
- New Task Count: 0
- Reason: {budget_details}

To restart the service, run:
  aws ecs update-service --cluster {cluster} --service {service} --desired-count 1

Or push a new commit to the main branch to trigger redeployment.

---
This is an automated message from your budget protection system.
        """
        
        if topic_arn:
            sns.publish(
                TopicArn=topic_arn,
                Subject='Deep Research Agent - Budget Shutdown',
                Message=notification_message
            )
            print(f"Notification sent to {topic_arn}")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Service scaled down successfully',
                'cluster': cluster,
                'service': service,
                'previous_count': current_count,
                'new_count': 0
            })
        }
        
    except ecs.exceptions.ServiceNotFoundException:
        error_msg = f"Service {service} not found in cluster {cluster}"
        print(f"Error: {error_msg}")
        return {
            'statusCode': 404,
            'body': json.dumps(error_msg)
        }
    except ecs.exceptions.ClusterNotFoundException:
        error_msg = f"Cluster {cluster} not found"
        print(f"Error: {error_msg}")
        return {
            'statusCode': 404,
            'body': json.dumps(error_msg)
        }
    except Exception as e:
        error_msg = f"Error scaling down service: {str(e)}"
        print(f"Error: {error_msg}")
        
        # Try to send error notification
        if topic_arn:
            try:
                sns.publish(
                    TopicArn=topic_arn,
                    Subject='Deep Research Agent - Shutdown FAILED',
                    Message=f"Failed to shut down service: {str(e)}\n\nPlease manually stop the service to prevent further charges."
                )
            except Exception as sns_error:
                print(f"Failed to send error notification: {sns_error}")
        
        return {
            'statusCode': 500,
            'body': json.dumps(error_msg)
        }


# For local testing
if __name__ == "__main__":
    # Test event simulating SNS notification
    test_event = {
        "Records": [
            {
                "Sns": {
                    "Message": "Budget threshold exceeded: 90% of $20.00 monthly budget"
                }
            }
        ]
    }
    
    # Set test environment variables
    os.environ['ECS_CLUSTER'] = 'deep-research-cluster'
    os.environ['ECS_SERVICE'] = 'deep-research-service'
    
    print("Testing Lambda handler...")
    result = lambda_handler(test_event, None)
    print(f"Result: {json.dumps(result, indent=2)}")


