#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT_DIR"

AWS_REGION=${AWS_REGION:-ap-south-1}
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAMBDA_NAME=${LAMBDA_NAME:-test-planner-function}
RUNTIME_NAME=${RUNTIME_NAME:-travel_planner_runtime}
ECR_REPOSITORY=${ECR_REPOSITORY:-travel-planner-app}
IMAGE_TAG=${IMAGE_TAG:-test}
LAMBDA_ROLE_NAME=${LAMBDA_ROLE_NAME:-travel-planner-lambda-role}
AGENTCORE_ROLE_NAME=${AGENTCORE_ROLE_NAME:-travel-planner-agentcore-role}
GATEWAY_NAME=${GATEWAY_NAME:-travel-planner-gateway}
GATEWAY_ROLE_NAME=${GATEWAY_ROLE_NAME:-travel-planner-gateway-role}
GATEWAY_LAMBDA_ROLE_NAME=${GATEWAY_LAMBDA_ROLE_NAME:-travel-planner-gateway-lambda-role}
GATEWAY_LAMBDA_NAME=${GATEWAY_LAMBDA_NAME:-travel-planner-gateway-lookup}
TRAVEL_TABLE_NAME=${TRAVEL_TABLE_NAME:-travel-plans}
COGNITO_POOL_NAME=${COGNITO_POOL_NAME:-travel-planner-m2m}
COGNITO_CLIENT_NAME=${COGNITO_CLIENT_NAME:-travel-planner-gateway-client}
COGNITO_DOMAIN_PREFIX=${COGNITO_DOMAIN_PREFIX:-travel-planner-m2m}
OAUTH_PROVIDER_NAME=${OAUTH_PROVIDER_NAME:-travel-planner-cognito}
GATEWAY_SCOPE=${GATEWAY_SCOPE:-travel-planner/read}
ECR_REGISTRY="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
ECR_URI="$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"

log() { printf '\n==> %s\n' "$1"; }

log "Starting deployment in $AWS_REGION"

role() {
  if ! aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    aws iam create-role --role-name "$1" --assume-role-policy-document "file://$2" >/dev/null
  fi
}
cat > .lambda-trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
cat > .agentcore-trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock-agentcore.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
role "$LAMBDA_ROLE_NAME" .lambda-trust.json
aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
role "$AGENTCORE_ROLE_NAME" .agentcore-trust.json
aws iam put-role-policy --role-name "$AGENTCORE_ROLE_NAME" --policy-name TravelPlannerAgentCorePermissions --policy-document file://policies/agentcore-runtime-policy.json

log "Building and pushing AgentCore image: $ECR_URI"
aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" --region "$AWS_REGION" >/dev/null 2>&1 || aws ecr create-repository --repository-name "$ECR_REPOSITORY" --region "$AWS_REGION" >/dev/null
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"
docker buildx build --platform linux/arm64 --tag "$ECR_URI" --push .

RUNTIME_ARN=$(aws bedrock-agentcore-control list-agent-runtimes --region "$AWS_REGION" --query "agentRuntimes[?agentRuntimeName=='$RUNTIME_NAME'].agentRuntimeArn | [0]" --output text)
log "Creating or updating AgentCore runtime"
if [[ -z "$RUNTIME_ARN" || "$RUNTIME_ARN" == "None" ]]; then
  RUNTIME_ARN=$(aws bedrock-agentcore-control create-agent-runtime --region "$AWS_REGION" --agent-runtime-name "$RUNTIME_NAME" --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"$ECR_URI\"}}" --role-arn "arn:aws:iam::$AWS_ACCOUNT_ID:role/$AGENTCORE_ROLE_NAME" --network-configuration '{"networkMode":"PUBLIC"}' --environment-variables '{"AGENT_OBSERVABILITY_ENABLED":"false"}' --query agentRuntimeArn --output text)
else
  aws bedrock-agentcore-control update-agent-runtime --region "$AWS_REGION" --agent-runtime-id "${RUNTIME_ARN##*/}" --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"$ECR_URI\"}}" --role-arn "arn:aws:iam::$AWS_ACCOUNT_ID:role/$AGENTCORE_ROLE_NAME" --network-configuration '{"networkMode":"PUBLIC"}' --environment-variables '{"AGENT_OBSERVABILITY_ENABLED":"false"}' >/dev/null
fi
sed "s|__RUNTIME_ARN__|$RUNTIME_ARN|g" policies/lambda-agentcore-policy.json > .lambda-policy.json
log "Creating or updating planner Lambda: $LAMBDA_NAME"
aws iam put-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-name InvokeTravelPlannerRuntime --policy-document file://.lambda-policy.json
rm -f travel-planner-lambda.zip; (cd lambda && zip -q ../travel-planner-lambda.zip lambda_function.py)
if aws lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$LAMBDA_NAME" --zip-file fileb://travel-planner-lambda.zip >/dev/null
  aws lambda wait function-updated --function-name "$LAMBDA_NAME"
else
  aws lambda create-function --function-name "$LAMBDA_NAME" --runtime python3.12 --architectures arm64 --handler lambda_function.lambda_handler --role "arn:aws:iam::$AWS_ACCOUNT_ID:role/$LAMBDA_ROLE_NAME" --zip-file fileb://travel-planner-lambda.zip --timeout 900 --memory-size 512 --environment "Variables={AGENT_RUNTIME_ARN=$RUNTIME_ARN}" >/dev/null
  aws lambda wait function-active --function-name "$LAMBDA_NAME"
fi
aws lambda update-function-configuration --function-name "$LAMBDA_NAME" --environment "Variables={AGENT_RUNTIME_ARN=$RUNTIME_ARN}" >/dev/null

# Gateway Lambda, DynamoDB, and roles.
log "Creating or updating DynamoDB travel table and Gateway Lambda"
cat > .gateway-lambda-trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
role "$GATEWAY_LAMBDA_ROLE_NAME" .gateway-lambda-trust.json
aws iam attach-role-policy --role-name "$GATEWAY_LAMBDA_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam put-role-policy --role-name "$GATEWAY_LAMBDA_ROLE_NAME" --policy-name ReadTravelPlans --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"dynamodb:GetItem\",\"Resource\":\"arn:aws:dynamodb:$AWS_REGION:$AWS_ACCOUNT_ID:table/$TRAVEL_TABLE_NAME\"}]}"
aws dynamodb create-table --table-name "$TRAVEL_TABLE_NAME" --attribute-definitions AttributeName=city,AttributeType=S --key-schema AttributeName=city,KeyType=HASH --billing-mode PAY_PER_REQUEST --region "$AWS_REGION" >/dev/null 2>&1 || true
aws dynamodb wait table-exists --table-name "$TRAVEL_TABLE_NAME" --region "$AWS_REGION"
aws dynamodb put-item --table-name "$TRAVEL_TABLE_NAME" --region "$AWS_REGION" --item '{"city":{"S":"Ooty"},"budget":{"S":"$500-$1000"},"duration":{"N":"4"},"itinerary":{"S":"Day 1: Ooty Lake. Day 2: Doddabetta Peak. Day 3: Coonoor. Day 4: Departure."}}' >/dev/null
rm -f gateway-lambda.zip; (cd gateway_lambda && zip -q ../gateway-lambda.zip lambda_function.py)
GATEWAY_LAMBDA_ARN="arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:$GATEWAY_LAMBDA_NAME"
if aws lambda get-function --function-name "$GATEWAY_LAMBDA_NAME" >/dev/null 2>&1; then aws lambda update-function-code --function-name "$GATEWAY_LAMBDA_NAME" --zip-file fileb://gateway-lambda.zip >/dev/null; else aws lambda create-function --function-name "$GATEWAY_LAMBDA_NAME" --runtime python3.12 --architectures arm64 --handler lambda_function.lambda_handler --role "arn:aws:iam::$AWS_ACCOUNT_ID:role/$GATEWAY_LAMBDA_ROLE_NAME" --zip-file fileb://gateway-lambda.zip --timeout 30 --memory-size 256 --environment "Variables={TRAVEL_TABLE_NAME=$TRAVEL_TABLE_NAME}" >/dev/null; fi
aws lambda wait function-active --function-name "$GATEWAY_LAMBDA_NAME" 2>/dev/null || true

cat > .gateway-trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock-agentcore.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
role "$GATEWAY_ROLE_NAME" .gateway-trust.json
aws iam put-role-policy --role-name "$GATEWAY_ROLE_NAME" --policy-name InvokeGatewayLambda --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"$GATEWAY_LAMBDA_ARN\"}]}"

POOL_ID=$(aws cognito-idp list-user-pools --max-results 60 --region "$AWS_REGION" --query "UserPools[?Name=='$COGNITO_POOL_NAME'].Id | [0]" --output text)
if [[ -z "$POOL_ID" || "$POOL_ID" == None ]]; then POOL_ID=$(aws cognito-idp create-user-pool --pool-name "$COGNITO_POOL_NAME" --region "$AWS_REGION" --query UserPool.Id --output text); fi
aws cognito-idp create-user-pool-domain --user-pool-id "$POOL_ID" --domain "$COGNITO_DOMAIN_PREFIX" --region "$AWS_REGION" >/dev/null 2>&1 || true
aws cognito-idp create-resource-server --user-pool-id "$POOL_ID" --identifier travel-planner --name TravelPlanner --scopes ScopeName=read,ScopeDescription="Read travel plans" --region "$AWS_REGION" >/dev/null 2>&1 || true
CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "$POOL_ID" --region "$AWS_REGION" --query "UserPoolClients[?ClientName=='$COGNITO_CLIENT_NAME'].ClientId | [0]" --output text)
if [[ -z "$CLIENT_ID" || "$CLIENT_ID" == None ]]; then CLIENT_JSON=$(aws cognito-idp create-user-pool-client --user-pool-id "$POOL_ID" --client-name "$COGNITO_CLIENT_NAME" --generate-secret --allowed-o-auth-flows client_credentials --allowed-o-auth-scopes "$GATEWAY_SCOPE" --allowed-o-auth-flows-user-pool-client --region "$AWS_REGION"); CLIENT_ID=$(echo "$CLIENT_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["UserPoolClient"]["ClientId"])'); CLIENT_SECRET=$(echo "$CLIENT_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["UserPoolClient"]["ClientSecret"])'); else CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client --user-pool-id "$POOL_ID" --client-id "$CLIENT_ID" --region "$AWS_REGION" --query UserPoolClient.ClientSecret --output text); fi
log "Creating or reusing Cognito M2M client"
DISCOVERY_URL="https://cognito-idp.$AWS_REGION.amazonaws.com/$POOL_ID/.well-known/openid-configuration"
PROVIDER_ID=$(aws bedrock-agentcore-control list-oauth2-credential-providers --region "$AWS_REGION" --query "credentialProviders[?name=='$OAUTH_PROVIDER_NAME'].credentialProviderArn | [0]" --output text 2>/dev/null || true)
log "Creating or reusing AgentCore OAuth credential provider"
if [[ -z "$PROVIDER_ID" || "$PROVIDER_ID" == None ]]; then PROVIDER_ID=$(aws bedrock-agentcore-control create-oauth2-credential-provider --region "$AWS_REGION" --name "$OAUTH_PROVIDER_NAME" --credential-provider-vendor CustomOauth2 --oauth2-provider-config-input "{\"customOauth2ProviderConfig\":{\"oauthDiscovery\":{\"discoveryUrl\":\"$DISCOVERY_URL\"},\"clientId\":\"$CLIENT_ID\",\"clientSecret\":\"$CLIENT_SECRET\",\"clientSecretSource\":\"MANAGED\"}}" --query credentialProviderArn --output text); fi
GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways --region "$AWS_REGION" --query "items[?name=='$GATEWAY_NAME'].gatewayId | [0]" --output text 2>/dev/null || true)
log "Creating or reusing AgentCore Gateway and Lambda target"
if [[ -z "$GATEWAY_ID" || "$GATEWAY_ID" == None ]]; then GATEWAY_ID=$(aws bedrock-agentcore-control create-gateway --region "$AWS_REGION" --name "$GATEWAY_NAME" --role-arn "arn:aws:iam::$AWS_ACCOUNT_ID:role/$GATEWAY_ROLE_NAME" --protocol-type MCP --authorizer-type CUSTOM_JWT --authorizer-configuration "{\"customJWTAuthorizer\":{\"discoveryUrl\":\"$DISCOVERY_URL\",\"allowedScopes\":[\"$GATEWAY_SCOPE\"]}}" --query gatewayId --output text); fi
TOOL_SCHEMA=$(tr -d '\n' < gateway_tools.json)
if ! aws bedrock-agentcore-control list-gateway-targets --region "$AWS_REGION" --gateway-identifier "$GATEWAY_ID" --query "items[?name=='travel-planner-lambda'].targetId | [0]" --output text | grep -qv '^None$'; then
  aws bedrock-agentcore-control create-gateway-target --region "$AWS_REGION" --gateway-identifier "$GATEWAY_ID" --name travel-planner-lambda --target-configuration "{\"mcp\":{\"lambda\":{\"lambdaArn\":\"$GATEWAY_LAMBDA_ARN\",\"toolSchema\":{\"inlinePayload\":$TOOL_SCHEMA}}}}" --credential-provider-configurations "[{\"credentialProviderType\":\"OAUTH\",\"credentialProvider\":{\"oauthCredentialProvider\":{\"providerArn\":\"$PROVIDER_ID\",\"scopes\":[\"$GATEWAY_SCOPE\"],\"grantType\":\"CLIENT_CREDENTIALS\"}}}]"
fi
TOKEN_URL="https://$COGNITO_DOMAIN_PREFIX.auth.$AWS_REGION.amazoncognito.com/oauth2/token"
SECRET="{\"agentcore_gateway_url\":\"https://$GATEWAY_ID.gateway.bedrock-agentcore.$AWS_REGION.amazonaws.com/mcp\",\"agentcore_gateway_tool_name\":\"travel-planner-lambda___get_travel_plan\",\"agentcore_gateway_tool_input_key\":\"city\",\"cognito_token_url\":\"$TOKEN_URL\",\"cognito_client_id\":\"$CLIENT_ID\",\"cognito_client_secret\":\"$CLIENT_SECRET\",\"cognito_scope\":\"$GATEWAY_SCOPE\"}"
if aws secretsmanager describe-secret --secret-id travel-planner/integrations --region "$AWS_REGION" >/dev/null 2>&1; then aws secretsmanager put-secret-value --secret-id travel-planner/integrations --secret-string "$SECRET" --region "$AWS_REGION" >/dev/null; else aws secretsmanager create-secret --name travel-planner/integrations --secret-string "$SECRET" --region "$AWS_REGION" >/dev/null; fi
rm -f .lambda-trust.json .agentcore-trust.json .gateway-lambda-trust.json .gateway-trust.json .lambda-policy.json travel-planner-lambda.zip gateway-lambda.zip
log "Deployment complete: runtime, Lambda, DynamoDB, Cognito, Gateway, and Gateway target are ready"
