# scripts/setup-aws-infrastructure.ps1
# One-time AWS infrastructure setup for ECS deployment (Windows PowerShell version)
# Run this ONCE to set up all required AWS resources

# Don't stop on AWS CLI stderr output (AWS CLI writes to stderr even for non-errors)
$ErrorActionPreference = "Continue"

Write-Host "Setting up AWS Infrastructure for Deep Research Agent" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan

# ============================================
# Configuration
# ============================================
$AWS_REGION = if ($env:AWS_REGION) { $env:AWS_REGION } else { "us-east-1" }
$ECR_REPO_NAME = "deep-research-agent"
$ECS_CLUSTER_NAME = "deep-research-cluster"
$ECS_SERVICE_NAME = "deep-research-service"
$TASK_FAMILY = "deep-research-agent"
$BUDGET_LIMIT = if ($env:BUDGET_LIMIT) { $env:BUDGET_LIMIT } else { "20" }
$VPC_CIDR = "10.0.0.0/16"
$NOTIFICATION_EMAIL = if ($env:NOTIFICATION_EMAIL) { $env:NOTIFICATION_EMAIL } else { "your-email@example.com" }

# Get AWS Account ID
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
Write-Host "AWS Account ID: $ACCOUNT_ID"
Write-Host "Region: $AWS_REGION"

# ============================================
# Step 1: Create ECR Repository
# ============================================
Write-Host ""
Write-Host "Step 1: Creating ECR Repository..." -ForegroundColor Yellow

# Check if ECR repo exists (suppress errors)
$ecrCheck = aws ecr describe-repositories --repository-names $ECR_REPO_NAME --region $AWS_REGION 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Creating new ECR repository..."
    aws ecr create-repository `
        --repository-name $ECR_REPO_NAME `
        --region $AWS_REGION `
        --image-scanning-configuration scanOnPush=true `
        --encryption-configuration encryptionType=AES256 | Out-Null
} else {
    Write-Host "   ECR repository already exists"
}

Write-Host "ECR Repository: $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME" -ForegroundColor Green

# ============================================
# Step 2: Create VPC and Networking
# ============================================
Write-Host ""
Write-Host "Step 2: Creating VPC and Networking..." -ForegroundColor Yellow

# Check if VPC exists
$existingVpc = (aws ec2 describe-vpcs --filters "Name=tag:Name,Values=deep-research-vpc" --query 'Vpcs[0].VpcId' --output text 2>&1) -replace "`r|`n", ""
if ($existingVpc -and $existingVpc -ne "None" -and $existingVpc -ne "null" -and $LASTEXITCODE -eq 0) {
    $VPC_ID = $existingVpc
    Write-Host "   Using existing VPC: $VPC_ID"
} else {
    Write-Host "   Creating new VPC..."
    $VPC_ID = (aws ec2 create-vpc `
        --cidr-block $VPC_CIDR `
        --query 'Vpc.VpcId' `
        --output text `
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=deep-research-vpc}]" 2>&1) -replace "`r|`n", ""
}

Write-Host "   VPC ID: $VPC_ID"

# Enable DNS hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{`"Value`":true}" 2>&1 | Out-Null

# Create Internet Gateway
$existingIgw = (aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=deep-research-igw" --query 'InternetGateways[0].InternetGatewayId' --output text 2>&1) -replace "`r|`n", ""
if ($existingIgw -and $existingIgw -ne "None" -and $existingIgw -ne "null" -and $LASTEXITCODE -eq 0) {
    $IGW_ID = $existingIgw
    Write-Host "   Using existing Internet Gateway: $IGW_ID"
} else {
    Write-Host "   Creating Internet Gateway..."
    $IGW_ID = (aws ec2 create-internet-gateway `
        --query 'InternetGateway.InternetGatewayId' `
        --output text `
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=deep-research-igw}]" 2>&1) -replace "`r|`n", ""
    
    aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID 2>&1 | Out-Null
}

# Create Subnets
$existingSubnet1 = (aws ec2 describe-subnets --filters "Name=tag:Name,Values=deep-research-subnet-1" --query 'Subnets[0].SubnetId' --output text 2>&1) -replace "`r|`n", ""
if ($existingSubnet1 -and $existingSubnet1 -ne "None" -and $existingSubnet1 -ne "null" -and $LASTEXITCODE -eq 0) {
    $SUBNET_1_ID = $existingSubnet1
} else {
    Write-Host "   Creating Subnet 1..."
    $SUBNET_1_ID = (aws ec2 create-subnet `
        --vpc-id $VPC_ID `
        --cidr-block "10.0.1.0/24" `
        --availability-zone "${AWS_REGION}a" `
        --query 'Subnet.SubnetId' `
        --output text `
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=deep-research-subnet-1}]" 2>&1) -replace "`r|`n", ""
}

$existingSubnet2 = (aws ec2 describe-subnets --filters "Name=tag:Name,Values=deep-research-subnet-2" --query 'Subnets[0].SubnetId' --output text 2>&1) -replace "`r|`n", ""
if ($existingSubnet2 -and $existingSubnet2 -ne "None" -and $existingSubnet2 -ne "null" -and $LASTEXITCODE -eq 0) {
    $SUBNET_2_ID = $existingSubnet2
} else {
    Write-Host "   Creating Subnet 2..."
    $SUBNET_2_ID = (aws ec2 create-subnet `
        --vpc-id $VPC_ID `
        --cidr-block "10.0.2.0/24" `
        --availability-zone "${AWS_REGION}b" `
        --query 'Subnet.SubnetId' `
        --output text `
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=deep-research-subnet-2}]" 2>&1) -replace "`r|`n", ""
}

# Enable auto-assign public IP
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_1_ID --map-public-ip-on-launch 2>&1 | Out-Null
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_2_ID --map-public-ip-on-launch 2>&1 | Out-Null

# Create Route Table
$existingRtb = (aws ec2 describe-route-tables --filters "Name=tag:Name,Values=deep-research-rtb" --query 'RouteTables[0].RouteTableId' --output text 2>&1) -replace "`r|`n", ""
if ($existingRtb -and $existingRtb -ne "None" -and $existingRtb -ne "null" -and $LASTEXITCODE -eq 0) {
    $RTB_ID = $existingRtb
} else {
    Write-Host "   Creating Route Table..."
    $RTB_ID = (aws ec2 create-route-table `
        --vpc-id $VPC_ID `
        --query 'RouteTable.RouteTableId' `
        --output text `
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=deep-research-rtb}]" 2>&1) -replace "`r|`n", ""
    
    aws ec2 create-route --route-table-id $RTB_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID 2>&1 | Out-Null
    aws ec2 associate-route-table --subnet-id $SUBNET_1_ID --route-table-id $RTB_ID 2>&1 | Out-Null
    aws ec2 associate-route-table --subnet-id $SUBNET_2_ID --route-table-id $RTB_ID 2>&1 | Out-Null
}

Write-Host "   Subnets: $SUBNET_1_ID, $SUBNET_2_ID" -ForegroundColor Green

# Create Security Group
$existingSg = (aws ec2 describe-security-groups --filters "Name=group-name,Values=deep-research-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text 2>&1) -replace "`r|`n", ""
if ($existingSg -and $existingSg -ne "None" -and $existingSg -ne "null" -and $LASTEXITCODE -eq 0) {
    $SG_ID = $existingSg
} else {
    Write-Host "   Creating Security Group..."
    $SG_ID = (aws ec2 create-security-group `
        --group-name "deep-research-sg" `
        --description "Security group for Deep Research Agent" `
        --vpc-id $VPC_ID `
        --query 'GroupId' `
        --output text 2>&1) -replace "`r|`n", ""
    
    # Add inbound rules
    aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 8123 --cidr 0.0.0.0/0 2>&1 | Out-Null
    aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 443 --cidr 0.0.0.0/0 2>&1 | Out-Null
}

Write-Host "   Security Group: $SG_ID" -ForegroundColor Green

# ============================================
# Step 3: Create IAM Roles
# ============================================
Write-Host ""
Write-Host "Step 3: Creating IAM Roles..." -ForegroundColor Yellow

# ECS Task Execution Role Trust Policy
$ecsTrustPolicy = @"
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
"@

$ecsTrustPolicyFile = [System.IO.Path]::GetTempFileName()
$ecsTrustPolicy | Out-File -FilePath $ecsTrustPolicyFile -Encoding utf8 -NoNewline

$roleCheck = aws iam get-role --role-name ecsTaskExecutionRole 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Creating ECS Task Execution Role..."
    aws iam create-role `
        --role-name ecsTaskExecutionRole `
        --assume-role-policy-document "file://$ecsTrustPolicyFile" 2>&1 | Out-Null
} else {
    Write-Host "   ECS Task Execution Role already exists"
}

aws iam attach-role-policy `
    --role-name ecsTaskExecutionRole `
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>&1 | Out-Null

# Add Secrets Manager access
$secretsPolicy = @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue"
            ],
            "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:deep-research/*"
        }
    ]
}
"@

$secretsPolicyFile = [System.IO.Path]::GetTempFileName()
$secretsPolicy | Out-File -FilePath $secretsPolicyFile -Encoding utf8 -NoNewline

aws iam put-role-policy `
    --role-name ecsTaskExecutionRole `
    --policy-name SecretsManagerAccess `
    --policy-document "file://$secretsPolicyFile" 2>&1 | Out-Null

Write-Host "IAM Roles configured" -ForegroundColor Green

# ============================================
# Step 4: Store Secrets
# ============================================
Write-Host ""
Write-Host "Step 4: Storing Secrets..." -ForegroundColor Yellow

Write-Host "   Storing API keys in AWS Secrets Manager..."
Write-Host "   (You'll need to update these with real values)"

$OPENROUTER_KEY = if ($env:OPENROUTER_API_KEY) { $env:OPENROUTER_API_KEY } else { "placeholder-update-me" }
$TAVILY_KEY = if ($env:TAVILY_API_KEY) { $env:TAVILY_API_KEY } else { "placeholder-update-me" }
$LANGSMITH_KEY = if ($env:LANGSMITH_API_KEY) { $env:LANGSMITH_API_KEY } else { "placeholder-update-me" }

$secretCheck = aws secretsmanager describe-secret --secret-id deep-research/openrouter --region $AWS_REGION 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Creating secret deep-research/openrouter..."
    aws secretsmanager create-secret `
        --name deep-research/openrouter `
        --description "OpenRouter API Key" `
        --secret-string $OPENROUTER_KEY `
        --region $AWS_REGION 2>&1 | Out-Null
} else {
    Write-Host "   Secret deep-research/openrouter already exists"
}

$secretCheck = aws secretsmanager describe-secret --secret-id deep-research/tavily --region $AWS_REGION 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Creating secret deep-research/tavily..."
    aws secretsmanager create-secret `
        --name deep-research/tavily `
        --description "Tavily API Key" `
        --secret-string $TAVILY_KEY `
        --region $AWS_REGION 2>&1 | Out-Null
} else {
    Write-Host "   Secret deep-research/tavily already exists"
}

$secretCheck = aws secretsmanager describe-secret --secret-id deep-research/langsmith --region $AWS_REGION 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Creating secret deep-research/langsmith..."
    aws secretsmanager create-secret `
        --name deep-research/langsmith `
        --description "LangSmith API Key" `
        --secret-string $LANGSMITH_KEY `
        --region $AWS_REGION 2>&1 | Out-Null
} else {
    Write-Host "   Secret deep-research/langsmith already exists"
}

Write-Host "Secrets stored in Secrets Manager" -ForegroundColor Green

# ============================================
# Step 5: Create ECS Cluster
# ============================================
Write-Host ""
Write-Host "Step 5: Creating ECS Cluster..." -ForegroundColor Yellow

$clusterStatus = (aws ecs describe-clusters --clusters $ECS_CLUSTER_NAME --region $AWS_REGION --query 'clusters[0].status' --output text 2>&1) -replace "`r|`n", ""
if ($clusterStatus -ne "ACTIVE") {
    Write-Host "   Creating ECS Cluster..."
    aws ecs create-cluster `
        --cluster-name $ECS_CLUSTER_NAME `
        --capacity-providers FARGATE FARGATE_SPOT `
        --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 `
        --settings name=containerInsights,value=enabled `
        --region $AWS_REGION 2>&1 | Out-Null
} else {
    Write-Host "   Cluster $ECS_CLUSTER_NAME already exists"
}

Write-Host "ECS Cluster: $ECS_CLUSTER_NAME" -ForegroundColor Green

# ============================================
# Step 6: Create CloudWatch Log Group
# ============================================
Write-Host ""
Write-Host "Step 6: Creating CloudWatch Log Group..." -ForegroundColor Yellow

$logGroupName = (aws logs describe-log-groups --log-group-name-prefix /ecs/deep-research-agent --region $AWS_REGION --query 'logGroups[0].logGroupName' --output text 2>&1) -replace "`r|`n", ""
if ($logGroupName -ne "/ecs/deep-research-agent") {
    Write-Host "   Creating CloudWatch Log Group..."
    aws logs create-log-group `
        --log-group-name /ecs/deep-research-agent `
        --region $AWS_REGION 2>&1 | Out-Null
} else {
    Write-Host "   Log group already exists"
}

aws logs put-retention-policy `
    --log-group-name /ecs/deep-research-agent `
    --retention-in-days 7 `
    --region $AWS_REGION 2>&1 | Out-Null

Write-Host "CloudWatch Log Group: /ecs/deep-research-agent" -ForegroundColor Green

# ============================================
# Step 7: Register Task Definition
# ============================================
Write-Host ""
Write-Host "Step 7: Registering Task Definition..." -ForegroundColor Yellow

$taskDefinition = @"
{
    "family": "$TASK_FAMILY",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "512",
    "memory": "1024",
    "executionRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskExecutionRole",
    "containerDefinitions": [
        {
            "name": "langgraph-server",
            "image": "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}:latest",
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
                    "valueFrom": "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:deep-research/openrouter"
                },
                {
                    "name": "TAVILY_API_KEY",
                    "valueFrom": "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:deep-research/tavily"
                },
                {
                    "name": "LANGSMITH_API_KEY",
                    "valueFrom": "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:deep-research/langsmith"
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
"@

$taskDefFile = [System.IO.Path]::GetTempFileName()
$taskDefinition | Out-File -FilePath $taskDefFile -Encoding utf8 -NoNewline

Write-Host "   Registering task definition..."
aws ecs register-task-definition `
    --cli-input-json "file://$taskDefFile" `
    --region $AWS_REGION 2>&1 | Out-Null

Write-Host "Task Definition registered: $TASK_FAMILY" -ForegroundColor Green

# ============================================
# Step 8: Create ECS Service
# ============================================
Write-Host ""
Write-Host "Step 8: Creating ECS Service..." -ForegroundColor Yellow

$serviceStatus = (aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $ECS_SERVICE_NAME --region $AWS_REGION --query 'services[0].status' --output text 2>&1) -replace "`r|`n", ""
if ($serviceStatus -ne "ACTIVE") {
    Write-Host "   Creating ECS Service..."
    aws ecs create-service `
        --cluster $ECS_CLUSTER_NAME `
        --service-name $ECS_SERVICE_NAME `
        --task-definition $TASK_FAMILY `
        --desired-count 1 `
        --launch-type FARGATE `
        --platform-version LATEST `
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1_ID,$SUBNET_2_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" `
        --deployment-configuration "minimumHealthyPercent=0,maximumPercent=200" `
        --region $AWS_REGION 2>&1 | Out-Null
} else {
    Write-Host "   Service $ECS_SERVICE_NAME already exists"
}

Write-Host "ECS Service: $ECS_SERVICE_NAME" -ForegroundColor Green

# ============================================
# Step 9: Create Budget and Auto-Shutdown
# ============================================
Write-Host ""
Write-Host "Step 9: Setting up Budget Alert..." -ForegroundColor Yellow

# Create SNS Topic for budget alerts
Write-Host "   Creating SNS Topic..."
$SNS_TOPIC_ARN = (aws sns create-topic `
    --name deep-research-budget-alerts `
    --region $AWS_REGION `
    --query 'TopicArn' `
    --output text 2>&1) -replace "`r|`n", ""

# Subscribe email to topic
Write-Host "   Subscribing email to topic..."
aws sns subscribe `
    --topic-arn $SNS_TOPIC_ARN `
    --protocol email `
    --notification-endpoint $NOTIFICATION_EMAIL `
    --region $AWS_REGION 2>&1 | Out-Null

Write-Host "   SNS Topic: $SNS_TOPIC_ARN"
Write-Host "   Check your email ($NOTIFICATION_EMAIL) to confirm subscription!" -ForegroundColor Magenta

# Create Budget
$budgetJson = @"
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
"@

$budgetFile = [System.IO.Path]::GetTempFileName()
$budgetJson | Out-File -FilePath $budgetFile -Encoding utf8 -NoNewline

$notificationsJson = "[{`"Notification`":{`"NotificationType`":`"ACTUAL`",`"ComparisonOperator`":`"GREATER_THAN`",`"Threshold`":75,`"ThresholdType`":`"PERCENTAGE`",`"NotificationState`":`"ALARM`"},`"Subscribers`":[{`"SubscriptionType`":`"EMAIL`",`"Address`":`"$NOTIFICATION_EMAIL`"}]},{`"Notification`":{`"NotificationType`":`"ACTUAL`",`"ComparisonOperator`":`"GREATER_THAN`",`"Threshold`":90,`"ThresholdType`":`"PERCENTAGE`",`"NotificationState`":`"ALARM`"},`"Subscribers`":[{`"SubscriptionType`":`"SNS`",`"Address`":`"$SNS_TOPIC_ARN`"}]}]"

$budgetCheck = aws budgets describe-budget --account-id $ACCOUNT_ID --budget-name DeepResearchAgentBudget 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Creating Budget..."
    aws budgets create-budget `
        --account-id $ACCOUNT_ID `
        --budget "file://$budgetFile" `
        --notifications-with-subscribers $notificationsJson 2>&1 | Out-Null
} else {
    Write-Host "   Budget already exists"
}

Write-Host "Budget Alert configured: `$$BUDGET_LIMIT/month" -ForegroundColor Green

# ============================================
# Step 10: Create Lambda for Auto-Shutdown
# ============================================
Write-Host ""
Write-Host "Step 10: Creating Auto-Shutdown Lambda Role..." -ForegroundColor Yellow

# Lambda Trust Policy
$lambdaTrustPolicy = @"
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
"@

$lambdaTrustFile = [System.IO.Path]::GetTempFileName()
$lambdaTrustPolicy | Out-File -FilePath $lambdaTrustFile -Encoding utf8 -NoNewline

$lambdaRoleCheck = aws iam get-role --role-name BudgetShutdownLambdaRole 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "   Creating Lambda Role..."
    aws iam create-role `
        --role-name BudgetShutdownLambdaRole `
        --assume-role-policy-document "file://$lambdaTrustFile" 2>&1 | Out-Null
} else {
    Write-Host "   Lambda Role already exists"
}

# Lambda Policy
$lambdaPolicy = @"
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
"@

$lambdaPolicyFile = [System.IO.Path]::GetTempFileName()
$lambdaPolicy | Out-File -FilePath $lambdaPolicyFile -Encoding utf8 -NoNewline

aws iam put-role-policy `
    --role-name BudgetShutdownLambdaRole `
    --policy-name BudgetShutdownPolicy `
    --policy-document "file://$lambdaPolicyFile" 2>&1 | Out-Null

Write-Host "Auto-Shutdown Lambda role configured" -ForegroundColor Green
Write-Host "Deploy the Lambda function from deploy/aws/budget-shutdown-lambda.py"

# ============================================
# Summary
# ============================================
Write-Host ""
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "AWS Infrastructure Setup Complete!" -ForegroundColor Green
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration Summary:" -ForegroundColor Yellow
Write-Host "   Account ID: $ACCOUNT_ID"
Write-Host "   Region: $AWS_REGION"
Write-Host "   ECR Repository: $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME"
Write-Host "   ECS Cluster: $ECS_CLUSTER_NAME"
Write-Host "   ECS Service: $ECS_SERVICE_NAME"
Write-Host "   VPC ID: $VPC_ID"
Write-Host "   Subnets: $SUBNET_1_ID, $SUBNET_2_ID"
Write-Host "   Security Group: $SG_ID"
Write-Host "   SNS Topic: $SNS_TOPIC_ARN"
Write-Host "   Budget: `$$BUDGET_LIMIT/month"
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "   1. Update secrets with real API keys:"
Write-Host "      aws secretsmanager update-secret --secret-id deep-research/openrouter --secret-string 'your-key'"
Write-Host "      aws secretsmanager update-secret --secret-id deep-research/tavily --secret-string 'your-key'"
Write-Host "      aws secretsmanager update-secret --secret-id deep-research/langsmith --secret-string 'your-key'"
Write-Host ""
Write-Host "   2. Add GitHub Secrets in your repository:"
Write-Host "      - AWS_ACCESS_KEY_ID"
Write-Host "      - AWS_SECRET_ACCESS_KEY"
Write-Host ""
Write-Host "   3. Confirm email subscription for budget alerts"
Write-Host ""
Write-Host "   4. Deploy the budget-shutdown Lambda function"
Write-Host ""
Write-Host "   5. Push to main branch to trigger first deployment!"
Write-Host ""
Write-Host "Monitor at: https://console.aws.amazon.com/ecs/home?region=$AWS_REGION" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan

# Cleanup temp files
Remove-Item $ecsTrustPolicyFile -ErrorAction SilentlyContinue
Remove-Item $secretsPolicyFile -ErrorAction SilentlyContinue
Remove-Item $taskDefFile -ErrorAction SilentlyContinue
Remove-Item $budgetFile -ErrorAction SilentlyContinue
Remove-Item $lambdaTrustFile -ErrorAction SilentlyContinue
Remove-Item $lambdaPolicyFile -ErrorAction SilentlyContinue

