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
OAUTH_PROVIDER_NAME=${OAUTH_PROVIDER_NAME:-travel-planner-cognito}

GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways --region "$AWS_REGION" --query "items[?name=='$GATEWAY_NAME'].gatewayId | [0]" --output text 2>/dev/null || true)
if [[ -n "$GATEWAY_ID" && "$GATEWAY_ID" != None ]]; then
  for target_id in $(aws bedrock-agentcore-control list-gateway-targets --region "$AWS_REGION" --gateway-identifier "$GATEWAY_ID" --query 'items[].targetId' --output text 2>/dev/null || true); do aws bedrock-agentcore-control delete-gateway-target --region "$AWS_REGION" --gateway-identifier "$GATEWAY_ID" --target-id "$target_id" >/dev/null 2>&1 || true; done
  aws bedrock-agentcore-control delete-gateway --region "$AWS_REGION" --gateway-identifier "$GATEWAY_ID" >/dev/null 2>&1 || true
fi
aws bedrock-agentcore-control delete-oauth2-credential-provider --region "$AWS_REGION" --name travel-planner-cognito >/dev/null 2>&1 || true
POOL_ID=$(aws cognito-idp list-user-pools --max-results 60 --region "$AWS_REGION" --query "UserPools[?Name=='$COGNITO_POOL_NAME'].Id | [0]" --output text 2>/dev/null || true)
if [[ -n "$POOL_ID" && "$POOL_ID" != None ]]; then aws cognito-idp delete-user-pool --user-pool-id "$POOL_ID" --region "$AWS_REGION" >/dev/null; fi
aws lambda delete-function --function-name "$GATEWAY_LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || true
aws dynamodb delete-table --table-name "$TRAVEL_TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || true
aws iam delete-role-policy --role-name "$GATEWAY_ROLE_NAME" --policy-name InvokeGatewayLambda 2>/dev/null || true
aws iam delete-role --role-name "$GATEWAY_ROLE_NAME" 2>/dev/null || true
aws iam delete-role-policy --role-name "$GATEWAY_LAMBDA_ROLE_NAME" --policy-name ReadTravelPlans 2>/dev/null || true
aws iam detach-role-policy --role-name "$GATEWAY_LAMBDA_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam delete-role --role-name "$GATEWAY_LAMBDA_ROLE_NAME" 2>/dev/null || true
aws secretsmanager delete-secret --secret-id travel-planner/integrations --region "$AWS_REGION" --force-delete-without-recovery >/dev/null 2>&1 || true

RUNTIME_ARN=$(aws bedrock-agentcore-control list-agent-runtimes --region "$AWS_REGION" --query "agentRuntimes[?agentRuntimeName=='$RUNTIME_NAME'].agentRuntimeArn | [0]" --output text 2>/dev/null || true)
if [[ -n "$RUNTIME_ARN" && "$RUNTIME_ARN" != None ]]; then aws bedrock-agentcore-control delete-agent-runtime --region "$AWS_REGION" --agent-runtime-id "${RUNTIME_ARN##*/}" >/dev/null 2>&1 || true; fi
aws lambda delete-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || true
aws ecr delete-repository --repository-name "$ECR_REPOSITORY" --region "$AWS_REGION" --force >/dev/null 2>&1 || true
aws iam delete-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-name InvokeTravelPlannerRuntime 2>/dev/null || true
aws iam detach-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam delete-role --role-name "$LAMBDA_ROLE_NAME" 2>/dev/null || true
aws iam delete-role-policy --role-name "$AGENTCORE_ROLE_NAME" --policy-name TravelPlannerAgentCorePermissions 2>/dev/null || true
aws iam delete-role --role-name "$AGENTCORE_ROLE_NAME" 2>/dev/null || true
aws logs delete-log-group --log-group-name "/aws/lambda/$LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || true
aws logs delete-log-group --log-group-name "/aws/lambda/$GATEWAY_LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || true
rm -f travel-planner-lambda.zip gateway-lambda.zip lambda-test-response.json .lambda-policy.json

echo "Complete cleanup finished for account $AWS_ACCOUNT_ID in $AWS_REGION."
