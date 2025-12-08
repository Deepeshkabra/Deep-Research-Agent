# Deployment Guide: Deep Research Agent on AWS ECS

This guide covers deploying the Deep Research Agent to AWS ECS with automated CI/CD via GitHub Actions.

## Architecture Overview

```
GitHub Repository
       │
       ├── Push to development branch → CI only (lint, test, build)
       │
       └── Push to main branch → CI + CD (deploy to AWS ECS)
                                      │
                                      ▼
                              AWS ECS Fargate
                              (LangGraph Server)
                                      │
                                      ├── OpenRouter API (LLM)
                                      ├── Tavily API (Search)
                                      └── LangSmith (Observability)
```

## Prerequisites

- AWS Account with credits ($20 budget)
- GitHub repository
- API keys:
  - OpenRouter API key
  - Tavily API key
  - LangSmith API key

## Environment Variables

Create a `.env` file with the following variables:

```bash
# LLM Provider (OpenRouter)
OPENROUTER_API_KEY=your_openrouter_api_key

# Search Provider (Tavily)
TAVILY_API_KEY=your_tavily_api_key

# LangSmith (Observability)
LANGSMITH_API_KEY=your_langsmith_api_key
LANGSMITH_TRACING=true
LANGSMITH_PROJECT=deep-research-agent

# AWS Configuration (for setup script)
AWS_REGION=us-east-1
BUDGET_LIMIT=20
NOTIFICATION_EMAIL=your-email@example.com
```

## Quick Start

### 1. Set Up AWS Infrastructure (One-Time)

**On Windows (PowerShell):**
```powershell
# Install AWS CLI and configure credentials
aws configure

# Set environment variables
$env:OPENROUTER_API_KEY = "your-key"
$env:TAVILY_API_KEY = "your-key"
$env:LANGSMITH_API_KEY = "your-key"
$env:NOTIFICATION_EMAIL = "your-email@example.com"
$env:BUDGET_LIMIT = "20"

# Run setup script
.\scripts\setup-aws-infrastructure.ps1
```

**On Linux/macOS/Git Bash:**
```bash
# Install AWS CLI and configure credentials
aws configure

# Set environment variables
export OPENROUTER_API_KEY="your-key"
export TAVILY_API_KEY="your-key"
export LANGSMITH_API_KEY="your-key"
export NOTIFICATION_EMAIL="your-email@example.com"
export BUDGET_LIMIT=20

# Run setup script
chmod +x scripts/setup-aws-infrastructure.sh
./scripts/setup-aws-infrastructure.sh
```

### 2. Update AWS Secrets

After running the setup script, update the secrets with your actual API keys:

```bash
aws secretsmanager update-secret \
    --secret-id deep-research/openrouter \
    --secret-string "your-actual-openrouter-key"

aws secretsmanager update-secret \
    --secret-id deep-research/tavily \
    --secret-string "your-actual-tavily-key"

aws secretsmanager update-secret \
    --secret-id deep-research/langsmith \
    --secret-string "your-actual-langsmith-key"
```

### 3. Add GitHub Secrets

Go to your GitHub repository → Settings → Secrets and variables → Actions

Add the following secrets:

| Secret Name | Description |
|-------------|-------------|
| `AWS_ACCESS_KEY_ID` | Your AWS access key |
| `AWS_SECRET_ACCESS_KEY` | Your AWS secret key |
| `OPENROUTER_API_KEY_TEST` | Test key for CI (can be dummy) |
| `TAVILY_API_KEY_TEST` | Test key for CI (can be dummy) |
| `LANGSMITH_API_KEY_TEST` | Test key for CI (can be dummy) |

### 4. Create Development Branch

```bash
git checkout -b development
git push -u origin development
git checkout main
```

### 5. Deploy

Push to main branch to trigger deployment:

```bash
git add .
git commit -m "Initial deployment setup"
git push origin main
```

## Branch Workflow

| Branch | On Push | Actions |
|--------|---------|---------|
| `development` | CI only | Lint → Test → Build (no deploy) |
| `main` | CI + CD | Lint → Test → Build → Deploy to AWS |
| `feature/*` | CI only | Lint → Test → Build (no deploy) |

## CI/CD Pipeline

### CI Pipeline (All Branches)

1. **Lint**: Runs Ruff linter on source code
2. **Test**: Runs pytest on test files
3. **Build**: Builds Docker image (validation only)

### CD Pipeline (Main Branch Only)

1. Runs CI checks first
2. Logs into Amazon ECR
3. Builds and pushes Docker image
4. Updates ECS task definition
5. Deploys to ECS service

## Budget Protection

The infrastructure includes automatic budget protection:

- **75% threshold**: Email notification
- **90% threshold**: Auto-shutdown Lambda triggered
- **Action**: ECS service scaled to 0 tasks

### Restarting After Budget Shutdown

```bash
aws ecs update-service \
    --cluster deep-research-cluster \
    --service deep-research-service \
    --desired-count 1
```

Or push a new commit to main branch.

## Monitoring

### AWS Console

- ECS Dashboard: `https://console.aws.amazon.com/ecs/home?region=us-east-1`
- CloudWatch Logs: `/ecs/deep-research-agent`

### LangSmith Studio

Access at: `https://smith.langchain.com`

View traces, debug runs, and analyze agent behavior.

## Manual Deployment

If you need to deploy manually:

```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 | \
    docker login --username AWS --password-stdin \
    YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com

# Build and push
docker build -t deep-research-agent .
docker tag deep-research-agent:latest \
    YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/deep-research-agent:latest
docker push \
    YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/deep-research-agent:latest

# Update service
aws ecs update-service \
    --cluster deep-research-cluster \
    --service deep-research-service \
    --force-new-deployment
```

## Troubleshooting

### Service Not Starting

Check CloudWatch logs:

```bash
aws logs tail /ecs/deep-research-agent --follow
```

### Task Failing Health Check

The health check endpoint is `http://localhost:8123/health`. Ensure the LangGraph server is starting correctly.

### Budget Lambda Not Triggering

1. Verify SNS subscription is confirmed (check email)
2. Check Lambda CloudWatch logs
3. Verify IAM permissions

## Cost Estimation

| Component | Estimated Monthly Cost |
|-----------|----------------------|
| ECS Fargate (0.5 vCPU, 1GB) | $8-12 |
| ECR Storage | ~$0.50 |
| CloudWatch Logs | ~$0.50 |
| Data Transfer | ~$1-2 |
| **Total Infrastructure** | **$10-15** |

API costs (OpenRouter, Tavily) are separate and usage-based.

## Files Reference

| File | Purpose |
|------|---------|
| `.github/workflows/ci.yml` | CI pipeline for all branches |
| `.github/workflows/deploy.yml` | CD pipeline for main only |
| `scripts/setup-aws-infrastructure.sh` | One-time AWS setup (Linux/macOS/Git Bash) |
| `scripts/setup-aws-infrastructure.ps1` | One-time AWS setup (Windows PowerShell) |
| `deploy/aws/task-definition.json` | ECS task configuration |
| `deploy/aws/budget-shutdown-lambda.py` | Auto-shutdown function |
| `.dockerignore` | Docker build exclusions |
| `Dockerfile` | Container image (generated by `langgraph build`) |
| `langgraph.json` | LangGraph configuration |


