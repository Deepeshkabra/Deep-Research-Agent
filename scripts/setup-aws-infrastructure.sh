#!/bin/bash
# scripts/setup-aws-infrastructure.sh
# One-time AWS infrastructure setup for ECS deployment
# Run this ONCE to set up all required AWS resources

set -e

echo "Setting up AWS Infrastructure for Deep Research Agent"
echo "======================================================="

# ============================================
# Configuration
# ============================================
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO_NAME="deep-research-agent"
ECS_CLUSTER_NAME="deep-research-cluster"
ECS_SERVICE_NAME="deep-research-service"
TASK_FAMILY="deep-research-agent"
BUDGET_LIMIT="${BUDGET_LIMIT:-20}"
VPC_CIDR="10.0.0.0/16"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-your-email@example.com}"

# Get AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account ID: $ACCOUNT_ID"
echo "Region: $AWS_REGION"

# ============================================
# Step 1: Create ECR Repository
# ============================================
echo ""
echo "Step 1: Creating ECR Repository..."

aws ecr describe-repositories --repository-names $ECR_REPO_NAME --region $AWS_REGION 2>/dev/null || \
aws ecr create-repository \
    --repository-name $ECR_REPO_NAME \
    --region $AWS_REGION \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256

echo "ECR Repository: $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME"

# ============================================
# Step 2: Create VPC and Networking
# ============================================
echo ""
echo "Step 2: Creating VPC and Networking..."

# Create VPC
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block $VPC_CIDR \
    --query 'Vpc.VpcId' \
    --output text \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=deep-research-vpc}]" \
    2>/dev/null || \
    aws ec2 describe-vpcs --filters "Name=tag:Name,Values=deep-research-vpc" --query 'Vpcs[0].VpcId' --output text)

echo "   VPC ID: $VPC_ID"

# Enable DNS hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# Create Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
    --query 'InternetGateway.InternetGatewayId' \
    --output text \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=deep-research-igw}]" \
    2>/dev/null || \
    aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=deep-research-igw" --query 'InternetGateways[0].InternetGatewayId' --output text)

aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID 2>/dev/null || true

# Create Subnets (2 AZs for high availability)
SUBNET_1_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block "10.0.1.0/24" \
    --availability-zone "${AWS_REGION}a" \
    --query 'Subnet.SubnetId' \
    --output text \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=deep-research-subnet-1}]" \
    2>/dev/null || \
    aws ec2 describe-subnets --filters "Name=tag:Name,Values=deep-research-subnet-1" --query 'Subnets[0].SubnetId' --output text)

SUBNET_2_ID=$(aws ec2 create-subnet \
    --vpc-id $VPC_ID \
    --cidr-block "10.0.2.0/24" \
    --availability-zone "${AWS_REGION}b" \
    --query 'Subnet.SubnetId' \
    --output text \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=deep-research-subnet-2}]" \
    2>/dev/null || \
    aws ec2 describe-subnets --filters "Name=tag:Name,Values=deep-research-subnet-2" --query 'Subnets[0].SubnetId' --output text)

# Enable auto-assign public IP
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_1_ID --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_2_ID --map-public-ip-on-launch

# Create Route Table
RTB_ID=$(aws ec2 create-route-table \
    --vpc-id $VPC_ID \
    --query 'RouteTable.RouteTableId' \
    --output text \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=deep-research-rtb}]" \
    2>/dev/null || \
    aws ec2 describe-route-tables --filters "Name=tag:Name,Values=deep-research-rtb" --query 'RouteTables[0].RouteTableId' --output text)

aws ec2 create-route --route-table-id $RTB_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID 2>/dev/null || true
aws ec2 associate-route-table --subnet-id $SUBNET_1_ID --route-table-id $RTB_ID 2>/dev/null || true
aws ec2 associate-route-table --subnet-id $SUBNET_2_ID --route-table-id $RTB_ID 2>/dev/null || true

echo "   Subnets: $SUBNET_1_ID, $SUBNET_2_ID"

# Create Security Group
SG_ID=$(aws ec2 create-security-group \
    --group-name "deep-research-sg" \
    --description "Security group for Deep Research Agent" \
    --vpc-id $VPC_ID \
    --query 'GroupId' \
    --output text \
    2>/dev/null || \
    aws ec2 describe-security-groups --filters "Name=group-name,Values=deep-research-sg" --query 'SecurityGroups[0].GroupId' --output text)

# Add inbound rules
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8123 --cidr 0.0.0.0/0 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 443 --cidr 0.0.0.0/0 2>/dev/null || true

echo "   Security Group: $SG_ID"

# ============================================
# Step 3: Create IAM Roles
# ============================================
echo ""
echo "Step 3: Creating IAM Roles..."

# ECS Task Execution Role
cat > /tmp/ecs-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ecs-tasks.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

aws iam create-role \
    --role-name ecsTaskExecutionRole \
    --assume-role-policy-document file:///tmp/ecs-trust-policy.json \
    2>/dev/null || true

aws iam attach-role-policy \
    --role-name ecsTaskExecutionRole \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
    2>/dev/null || true

# Add Secrets Manager access
cat > /tmp/secrets-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue"
            ],
            "Resource": "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret:deep-research/*"
        }
    ]
}
EOF

aws iam put-role-policy \
    --role-name ecsTaskExecutionRole \
    --policy-name SecretsManagerAccess \
    --policy-document file:///tmp/secrets-policy.json \
    2>/dev/null || true

echo "IAM Roles configured"

# ============================================
# Step 4: Store Secrets
# ============================================
echo ""
echo "Step 4: Storing Secrets..."

echo "   Storing API keys in AWS Secrets Manager..."
echo "   (You'll need to update these with real values)"

aws secretsmanager create-secret \
    --name deep-research/openrouter \
    --description "OpenRouter API Key" \
    --secret-string "${OPENROUTER_API_KEY:-placeholder-update-me}" \
    --region $AWS_REGION \
    2>/dev/null || \
    echo "   Secret deep-research/openrouter already exists"

aws secretsmanager create-secret \
    --name deep-research/tavily \
    --description "Tavily API Key" \
    --secret-string "${TAVILY_API_KEY:-placeholder-update-me}" \
    --region $AWS_REGION \
    2>/dev/null || \
    echo "   Secret deep-research/tavily already exists"

aws secretsmanager create-secret \
    --name deep-research/langsmith \
    --description "LangSmith API Key" \
    --secret-string "${LANGSMITH_API_KEY:-placeholder-update-me}" \
    --region $AWS_REGION \
    2>/dev/null || \
    echo "   Secret deep-research/langsmith already exists"

echo "Secrets stored in Secrets Manager"

# ============================================
# Step 5: Create ECS Cluster
# ============================================
echo ""
echo "Step 5: Creating ECS Cluster..."

aws ecs create-cluster \
    --cluster-name $ECS_CLUSTER_NAME \
    --capacity-providers FARGATE FARGATE_SPOT \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
    --settings name=containerInsights,value=enabled \
    --region $AWS_REGION \
    2>/dev/null || \
    echo "   Cluster $ECS_CLUSTER_NAME already exists"

echo "ECS Cluster: $ECS_CLUSTER_NAME"

# ============================================
# Step 6: Create CloudWatch Log Group
# ============================================
echo ""
echo "Step 6: Creating CloudWatch Log Group..."

aws logs create-log-group \
    --log-group-name /ecs/deep-research-agent \
    --region $AWS_REGION \
    2>/dev/null || \
    echo "   Log group already exists"

aws logs put-retention-policy \
    --log-group-name /ecs/deep-research-agent \
    --retention-in-days 7 \
    --region $AWS_REGION

echo "CloudWatch Log Group: /ecs/deep-research-agent"

# ============================================
# Step 7: Register Task Definition
# ============================================
echo ""
echo "Step 7: Registering Task Definition..."

cat > /tmp/task-definition.json << EOF
{
    "family": "$TASK_FAMILY",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "512",
    "memory": "1024",
    "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ecsTaskExecutionRole",
    "containerDefinitions": [
        {
            "name": "langgraph-server",
            "image": "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME:latest",
            "essential": true,
            "portMappings": [
                {
                    "containerPort": 8123,
                    "hostPort": 8123,
                    "protocol": "tcp"
                }
            ],
            "environment": [
                {"name": "LANGSMITH_TRACING", "value": "true"},
                {"name": "LANGSMITH_PROJECT", "value": "deep-research-agent"}
            ],
            "secrets": [
                {
                    "name": "OPENROUTER_API_KEY",
                    "valueFrom": "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret:deep-research/openrouter"
                },
                {
                    "name": "TAVILY_API_KEY",
                    "valueFrom": "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret:deep-research/tavily"
                },
                {
                    "name": "LANGSMITH_API_KEY",
                    "valueFrom": "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret:deep-research/langsmith"
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/deep-research-agent",
                    "awslogs-region": "$AWS_REGION",
                    "awslogs-stream-prefix": "ecs"
                }
            },
            "healthCheck": {
                "command": ["CMD-SHELL", "curl -f http://localhost:8123/health || exit 1"],
                "interval": 30,
                "timeout": 5,
                "retries": 3,
                "startPeriod": 60
            }
        }
    ]
}
EOF

aws ecs register-task-definition \
    --cli-input-json file:///tmp/task-definition.json \
    --region $AWS_REGION

echo "Task Definition registered: $TASK_FAMILY"

# ============================================
# Step 8: Create ECS Service
# ============================================
echo ""
echo "Step 8: Creating ECS Service..."

aws ecs create-service \
    --cluster $ECS_CLUSTER_NAME \
    --service-name $ECS_SERVICE_NAME \
    --task-definition $TASK_FAMILY \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1_ID,$SUBNET_2_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
    --deployment-configuration "minimumHealthyPercent=0,maximumPercent=200" \
    --region $AWS_REGION \
    2>/dev/null || \
    echo "   Service $ECS_SERVICE_NAME already exists"

echo "ECS Service: $ECS_SERVICE_NAME"

# ============================================
# Step 9: Create Budget and Auto-Shutdown
# ============================================
echo ""
echo "Step 9: Setting up Budget Alert..."

# Create SNS Topic for budget alerts
SNS_TOPIC_ARN=$(aws sns create-topic \
    --name deep-research-budget-alerts \
    --region $AWS_REGION \
    --query 'TopicArn' \
    --output text)

# Subscribe email to topic
aws sns subscribe \
    --topic-arn $SNS_TOPIC_ARN \
    --protocol email \
    --notification-endpoint $NOTIFICATION_EMAIL \
    --region $AWS_REGION \
    2>/dev/null || true

echo "   SNS Topic: $SNS_TOPIC_ARN"
echo "   Check your email ($NOTIFICATION_EMAIL) to confirm subscription!"

# Create Budget
cat > /tmp/budget.json << EOF
{
    "BudgetName": "DeepResearchAgentBudget",
    "BudgetLimit": {
        "Amount": "$BUDGET_LIMIT",
        "Unit": "USD"
    },
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST",
    "CostFilters": {},
    "CostTypes": {
        "IncludeTax": true,
        "IncludeSubscription": true,
        "UseBlended": false,
        "IncludeRefund": false,
        "IncludeCredit": false,
        "IncludeUpfront": true,
        "IncludeRecurring": true,
        "IncludeOtherSubscription": true,
        "IncludeSupport": true,
        "IncludeDiscount": true,
        "UseAmortized": false
    }
}
EOF

aws budgets create-budget \
    --account-id $ACCOUNT_ID \
    --budget file:///tmp/budget.json \
    --notifications-with-subscribers '[
        {
            "Notification": {
                "NotificationType": "ACTUAL",
                "ComparisonOperator": "GREATER_THAN",
                "Threshold": 75,
                "ThresholdType": "PERCENTAGE",
                "NotificationState": "ALARM"
            },
            "Subscribers": [
                {
                    "SubscriptionType": "EMAIL",
                    "Address": "'"$NOTIFICATION_EMAIL"'"
                }
            ]
        },
        {
            "Notification": {
                "NotificationType": "ACTUAL",
                "ComparisonOperator": "GREATER_THAN",
                "Threshold": 90,
                "ThresholdType": "PERCENTAGE",
                "NotificationState": "ALARM"
            },
            "Subscribers": [
                {
                    "SubscriptionType": "SNS",
                    "Address": "'"$SNS_TOPIC_ARN"'"
                }
            ]
        }
    ]' \
    2>/dev/null || \
    echo "   Budget already exists"

echo "Budget Alert configured: \$$BUDGET_LIMIT/month"

# ============================================
# Step 10: Create Lambda for Auto-Shutdown
# ============================================
echo ""
echo "Step 10: Creating Auto-Shutdown Lambda..."

# Create Lambda execution role
cat > /tmp/lambda-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "lambda.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

aws iam create-role \
    --role-name BudgetShutdownLambdaRole \
    --assume-role-policy-document file:///tmp/lambda-trust-policy.json \
    2>/dev/null || true

# Attach policies
cat > /tmp/lambda-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ecs:UpdateService",
                "ecs:DescribeServices"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "sns:Publish"
            ],
            "Resource": "$SNS_TOPIC_ARN"
        }
    ]
}
EOF

aws iam put-role-policy \
    --role-name BudgetShutdownLambdaRole \
    --policy-name BudgetShutdownPolicy \
    --policy-document file:///tmp/lambda-policy.json \
    2>/dev/null || true

echo "Auto-Shutdown Lambda role configured"
echo "Deploy the Lambda function from deploy/aws/budget-shutdown-lambda.py"

# ============================================
# Step 11: Save Configuration
# ============================================
echo ""
echo "Step 11: Saving configuration..."

cat > /tmp/aws-config-output.txt << EOF
AWS Infrastructure Configuration
================================
Account ID: $ACCOUNT_ID
Region: $AWS_REGION

ECR Repository: $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME
ECS Cluster: $ECS_CLUSTER_NAME
ECS Service: $ECS_SERVICE_NAME

VPC ID: $VPC_ID
Subnet 1: $SUBNET_1_ID
Subnet 2: $SUBNET_2_ID
Security Group: $SG_ID

SNS Topic: $SNS_TOPIC_ARN
Budget: \$$BUDGET_LIMIT/month
EOF

cat /tmp/aws-config-output.txt

# ============================================
# Summary
# ============================================
echo ""
echo "======================================================="
echo "AWS Infrastructure Setup Complete!"
echo "======================================================="
echo ""
echo "Next Steps:"
echo "   1. Update secrets with real API keys:"
echo "      aws secretsmanager update-secret --secret-id deep-research/openrouter --secret-string 'your-key'"
echo "      aws secretsmanager update-secret --secret-id deep-research/tavily --secret-string 'your-key'"
echo "      aws secretsmanager update-secret --secret-id deep-research/langsmith --secret-string 'your-key'"
echo ""
echo "   2. Add GitHub Secrets in your repository:"
echo "      - AWS_ACCESS_KEY_ID"
echo "      - AWS_SECRET_ACCESS_KEY"
echo ""
echo "   3. Confirm email subscription for budget alerts"
echo ""
echo "   4. Deploy the budget-shutdown Lambda function"
echo ""
echo "   5. Push to main branch to trigger first deployment!"
echo ""
echo "Monitor at: https://console.aws.amazon.com/ecs/home?region=$AWS_REGION"
echo "======================================================="


