#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT_DIR"

AWS_REGION=${AWS_REGION:-ap-south-1}
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

LAMBDA_NAME=${LAMBDA_NAME:-test-planner-function}
RUNTIME_NAME=${RUNTIME_NAME:-travel_planner_runtime}
ECR_REPOSITORY=${ECR_REPOSITORY:-travel-planner-app}

LAMBDA_ROLE_NAME=${LAMBDA_ROLE_NAME:-travel-planner-lambda-role}
AGENTCORE_ROLE_NAME=${AGENTCORE_ROLE_NAME:-travel-planner-agentcore-role}

GATEWAY_NAME=${GATEWAY_NAME:-travel-planner-gateway}
GATEWAY_ROLE_NAME=${GATEWAY_ROLE_NAME:-travel-planner-gateway-role}

GATEWAY_LAMBDA_ROLE_NAME=${GATEWAY_LAMBDA_ROLE_NAME:-travel-planner-gateway-lambda-role}
GATEWAY_LAMBDA_NAME=${GATEWAY_LAMBDA_NAME:-travel-planner-gateway-lookup}

TRAVEL_TABLE_NAME=${TRAVEL_TABLE_NAME:-travel-plans}

COGNITO_POOL_NAME=${COGNITO_POOL_NAME:-travel-planner-m2m}
COGNITO_DOMAIN=${COGNITO_DOMAIN:-travel-planner-m2m}

OAUTH_PROVIDER_NAME=${OAUTH_PROVIDER_NAME:-travel-planner-cognito}
SECRET_NAME=${SECRET_NAME:-travel-planner/integrations}


echo "============================================================"
echo "Travel Planner - AWS Resource Cleanup"
echo "============================================================"
echo "Account : $AWS_ACCOUNT_ID"
echo "Region  : $AWS_REGION"
echo "============================================================"


# ---------------------------------------------------------------------------
# 1. AgentCore Gateway
# ---------------------------------------------------------------------------

echo
echo "[1/12] Deleting AgentCore Gateway..."

GATEWAY_ID=$(
  aws bedrock-agentcore-control list-gateways \
    --region "$AWS_REGION" \
    --query "items[?name=='$GATEWAY_NAME'].gatewayId | [0]" \
    --output text 2>/dev/null || true
)

if [[ -n "$GATEWAY_ID" && "$GATEWAY_ID" != "None" ]]; then

  echo "Gateway ID: $GATEWAY_ID"

  TARGET_IDS=$(
    aws bedrock-agentcore-control list-gateway-targets \
      --region "$AWS_REGION" \
      --gateway-identifier "$GATEWAY_ID" \
      --query 'items[].targetId' \
      --output text 2>/dev/null || true
  )

  for target_id in $TARGET_IDS; do

    if [[ -n "$target_id" && "$target_id" != "None" ]]; then

      echo "Deleting Gateway target: $target_id"

      aws bedrock-agentcore-control delete-gateway-target \
        --region "$AWS_REGION" \
        --gateway-identifier "$GATEWAY_ID" \
        --target-id "$target_id" \
        >/dev/null 2>&1 || true

    fi

  done

  echo "Deleting Gateway: $GATEWAY_ID"

  aws bedrock-agentcore-control delete-gateway \
    --region "$AWS_REGION" \
    --gateway-identifier "$GATEWAY_ID" \
    >/dev/null 2>&1 || true

else

  echo "Gateway not found."

fi


# ---------------------------------------------------------------------------
# 2. AgentCore OAuth credential provider
# ---------------------------------------------------------------------------

echo
echo "[2/12] Deleting AgentCore OAuth credential provider..."

aws bedrock-agentcore-control delete-oauth2-credential-provider \
  --region "$AWS_REGION" \
  --name "$OAUTH_PROVIDER_NAME" \
  >/dev/null 2>&1 || true


# ---------------------------------------------------------------------------
# 3. Cognito User Pool + Domain
# ---------------------------------------------------------------------------

echo
echo "[3/12] Deleting Cognito User Pool and domain..."

POOL_ID=$(
  aws cognito-idp list-user-pools \
    --max-results 60 \
    --region "$AWS_REGION" \
    --query "UserPools[?Name=='$COGNITO_POOL_NAME'].Id | [0]" \
    --output text 2>/dev/null || true
)

if [[ -n "$POOL_ID" && "$POOL_ID" != "None" ]]; then

  echo "Cognito Pool ID: $POOL_ID"

  echo "Deleting Cognito domain: $COGNITO_DOMAIN"

  aws cognito-idp delete-user-pool-domain \
    --user-pool-id "$POOL_ID" \
    --domain "$COGNITO_DOMAIN" \
    --region "$AWS_REGION" \
    >/dev/null 2>&1 || true

  echo "Deleting Cognito user pool..."

  aws cognito-idp delete-user-pool \
    --user-pool-id "$POOL_ID" \
    --region "$AWS_REGION" \
    >/dev/null 2>&1 || true

else

  echo "Cognito User Pool not found."

fi


# ---------------------------------------------------------------------------
# 4. Gateway Lambda
# ---------------------------------------------------------------------------

echo
echo "[4/12] Deleting Gateway Lambda..."

aws lambda delete-function \
  --function-name "$GATEWAY_LAMBDA_NAME" \
  --region "$AWS_REGION" \
  >/dev/null 2>&1 || true


# ---------------------------------------------------------------------------
# 5. DynamoDB
# ---------------------------------------------------------------------------

echo
echo "[5/12] Deleting DynamoDB table..."

aws dynamodb delete-table \
  --table-name "$TRAVEL_TABLE_NAME" \
  --region "$AWS_REGION" \
  >/dev/null 2>&1 || true


# ---------------------------------------------------------------------------
# 6. Gateway IAM roles
# ---------------------------------------------------------------------------

echo
echo "[6/12] Deleting Gateway IAM roles..."

aws iam delete-role-policy \
  --role-name "$GATEWAY_ROLE_NAME" \
  --policy-name InvokeGatewayLambda \
  >/dev/null 2>&1 || true

aws iam delete-role \
  --role-name "$GATEWAY_ROLE_NAME" \
  >/dev/null 2>&1 || true


aws iam delete-role-policy \
  --role-name "$GATEWAY_LAMBDA_ROLE_NAME" \
  --policy-name ReadTravelPlans \
  >/dev/null 2>&1 || true

aws iam detach-role-policy \
  --role-name "$GATEWAY_LAMBDA_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
  >/dev/null 2>&1 || true

aws iam delete-role \
  --role-name "$GATEWAY_LAMBDA_ROLE_NAME" \
  >/dev/null 2>&1 || true


# ---------------------------------------------------------------------------
# 7. Secrets Manager
# ---------------------------------------------------------------------------

echo
echo "[7/12] Deleting Secrets Manager secret..."

aws secretsmanager delete-secret \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" \
  --force-delete-without-recovery \
  >/dev/null 2>&1 || true


# ---------------------------------------------------------------------------
# 8. AgentCore Runtime
# ---------------------------------------------------------------------------

echo
echo "[8/12] Deleting AgentCore Runtime..."

RUNTIME_ARN=$(
  aws bedrock-agentcore-control list-agent-runtimes \
    --region "$AWS_REGION" \
    --query "agentRuntimes[?agentRuntimeName=='$RUNTIME_NAME'].agentRuntimeArn | [0]" \
    --output text 2>/dev/null || true
)

if [[ -n "$RUNTIME_ARN" && "$RUNTIME_ARN" != "None" ]]; then

  RUNTIME_ID="${RUNTIME_ARN##*/}"

  echo "Runtime ARN: $RUNTIME_ARN"
  echo "Runtime ID : $RUNTIME_ID"

  aws bedrock-agentcore-control delete-agent-runtime \
    --region "$AWS_REGION" \
    --agent-runtime-id "$RUNTIME_ID" \
    >/dev/null 2>&1 || true

else

  echo "AgentCore Runtime not found."

fi


# ---------------------------------------------------------------------------
# 9. Planner Lambda
# ---------------------------------------------------------------------------

echo
echo "[9/12] Deleting Planner Lambda..."

aws lambda delete-function \
  --function-name "$LAMBDA_NAME" \
  --region "$AWS_REGION" \
  >/dev/null 2>&1 || true


# ---------------------------------------------------------------------------
# 10. ECR
# ---------------------------------------------------------------------------

echo
echo "[10/12] Deleting ECR repository..."

aws ecr delete-repository \
  --repository-name "$ECR_REPOSITORY" \
  --region "$AWS_REGION" \
  --force \
  >/dev/null 2>&1 || true


# ---------------------------------------------------------------------------
# 11. Lambda + AgentCore IAM roles
# ---------------------------------------------------------------------------

echo
echo "[11/12] Deleting Lambda and AgentCore IAM roles..."

aws iam delete-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name InvokeTravelPlannerRuntime \
  >/dev/null 2>&1 || true

aws iam detach-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
  >/dev/null 2>&1 || true

aws iam delete-role \
  --role-name "$LAMBDA_ROLE_NAME" \
  >/dev/null 2>&1 || true


aws iam delete-role-policy \
  --role-name "$AGENTCORE_ROLE_NAME" \
  --policy-name TravelPlannerAgentCorePermissions \
  >/dev/null 2>&1 || true

aws iam delete-role \
  --role-name "$AGENTCORE_ROLE_NAME" \
  >/dev/null 2>&1 || true


# ---------------------------------------------------------------------------
# 12. CloudWatch Logs + local artifacts
# ---------------------------------------------------------------------------

echo
echo "[12/12] Deleting CloudWatch logs and local artifacts..."

aws logs delete-log-group \
  --log-group-name "/aws/lambda/$LAMBDA_NAME" \
  --region "$AWS_REGION" \
  >/dev/null 2>&1 || true

aws logs delete-log-group \
  --log-group-name "/aws/lambda/$GATEWAY_LAMBDA_NAME" \
  --region "$AWS_REGION" \
  >/dev/null 2>&1 || true


rm -f \
  travel-planner-lambda.zip \
  gateway-lambda.zip \
  lambda-test-response.json \
  .lambda-policy.json


# ---------------------------------------------------------------------------
# Complete
# ---------------------------------------------------------------------------

echo
echo "============================================================"
echo "Complete cleanup finished."
echo "Account : $AWS_ACCOUNT_ID"
echo "Region  : $AWS_REGION"
echo "============================================================"