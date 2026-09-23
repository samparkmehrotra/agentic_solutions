#!/usr/bin/env bash

###############################################################################
# Travel Planner - Production Deployment
#
# Architecture
#
#                       ┌──────────────────────┐
#                       │       Cognito        │
#                       │   M2M OAuth Client   │
#                       └──────────┬───────────┘
#                                  │
#                              JWT Token
#                                  │
#                                  ▼
#                       ┌──────────────────────┐
#                       │  AgentCore Gateway   │
#                       │     CUSTOM_JWT       │
#                       └──────────┬───────────┘
#                                  │
#                           IAM Role
#                    GATEWAY_IAM_ROLE
#                                  │
#                                  ▼
#                       ┌──────────────────────┐
#                       │   Gateway Lambda     │
#                       │  get_travel_plan()  │
#                       └──────────┬───────────┘
#                                  │
#                                  ▼
#                       ┌──────────────────────┐
#                       │      DynamoDB        │
#                       │     travel-plans     │
#                       └──────────────────────┘
#
#
# Separately:
#
#                       ┌──────────────────────┐
#                       │   Planner Lambda     │
#                       └──────────┬───────────┘
#                                  │
#                                  │ IAM
#                                  ▼
#                       ┌──────────────────────┐
#                       │ AgentCore Runtime    │
#                       │       CrewAI         │
#                       └──────────────────────┘
#
###############################################################################

set -euo pipefail

###############################################################################
# 1. PROJECT / AWS CONFIGURATION
###############################################################################

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

AWS_REGION="${AWS_REGION:-ap-south-1}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

###############################################################################
# AgentCore Runtime
###############################################################################

RUNTIME_NAME="${RUNTIME_NAME:-travel_planner_runtime}"
AGENTCORE_ROLE_NAME="${AGENTCORE_ROLE_NAME:-travel-planner-agentcore-role}"

###############################################################################
# ECR
###############################################################################

ECR_REPOSITORY="${ECR_REPOSITORY:-travel-planner-app}"
IMAGE_TAG="${IMAGE_TAG:-test}"

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_URI="${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"

###############################################################################
# Planner Lambda
###############################################################################

LAMBDA_NAME="${LAMBDA_NAME:-test-planner-function}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-travel-planner-lambda-role}"

###############################################################################
# Gateway
###############################################################################

GATEWAY_NAME="${GATEWAY_NAME:-travel-planner-gateway}"
GATEWAY_ROLE_NAME="${GATEWAY_ROLE_NAME:-travel-planner-gateway-role}"
GATEWAY_TARGET_NAME="${GATEWAY_TARGET_NAME:-travel-planner-lambda}"

###############################################################################
# Gateway Lambda
###############################################################################

GATEWAY_LAMBDA_NAME="${GATEWAY_LAMBDA_NAME:-travel-planner-gateway-lookup}"
GATEWAY_LAMBDA_ROLE_NAME="${GATEWAY_LAMBDA_ROLE_NAME:-travel-planner-gateway-lambda-role}"

###############################################################################
# DynamoDB
###############################################################################

TRAVEL_TABLE_NAME="${TRAVEL_TABLE_NAME:-travel-plans}"

###############################################################################
# Cognito
###############################################################################

COGNITO_POOL_NAME="${COGNITO_POOL_NAME:-travel-planner-m2m}"
COGNITO_CLIENT_NAME="${COGNITO_CLIENT_NAME:-travel-planner-gateway-client}"
COGNITO_DOMAIN_PREFIX="${COGNITO_DOMAIN_PREFIX:-travel-planner-m2m}"

COGNITO_RESOURCE_SERVER_IDENTIFIER="${COGNITO_RESOURCE_SERVER_IDENTIFIER:-travel-planner}"
COGNITO_SCOPE_NAME="${COGNITO_SCOPE_NAME:-read}"

GATEWAY_SCOPE="${COGNITO_RESOURCE_SERVER_IDENTIFIER}/${COGNITO_SCOPE_NAME}"

###############################################################################
# Secrets Manager
###############################################################################

INTEGRATION_SECRET_NAME="${INTEGRATION_SECRET_NAME:-travel-planner/integrations}"

###############################################################################
# 2. LOGGING
###############################################################################

log() {
    printf "\n============================================================\n"
    printf "==> %s\n" "$1"
    printf "============================================================\n"
}

info() {
    printf "    %s\n" "$1"
}

warn() {
    printf "    WARNING: %s\n" "$1"
}

die() {
    printf "\nERROR: %s\n\n" "$1" >&2
    exit 1
}

###############################################################################
# 3. REQUIRED COMMANDS / FILES
###############################################################################

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_file() {
    [[ -f "$1" ]] || die "Required file not found: $1"
}

log "Checking prerequisites"

require_command aws
require_command docker
require_command zip
require_command python3

require_file "policies/agentcore-runtime-policy.json"
require_file "policies/lambda-agentcore-policy.json"
require_file "gateway_tools.json"
require_file "lambda/lambda_function.py"
require_file "gateway_lambda/lambda_function.py"

###############################################################################
# 4. AWS ACCOUNT INFORMATION
###############################################################################

info "AWS Region : $AWS_REGION"
info "AWS Account: $AWS_ACCOUNT_ID"
info "ECR Image  : $ECR_URI"

###############################################################################
# 5. IAM ROLE HELPER
###############################################################################

ensure_role() {

    local ROLE_NAME="$1"
    local TRUST_POLICY_FILE="$2"

    if aws iam get-role \
        --role-name "$ROLE_NAME" \
        >/dev/null 2>&1
    then

        info "IAM role already exists: $ROLE_NAME"

    else

        info "Creating IAM role: $ROLE_NAME"

        aws iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document "file://${TRUST_POLICY_FILE}" \
            >/dev/null

    fi
}

###############################################################################
# 6. PLANNER LAMBDA IAM ROLE
###############################################################################

log "Configuring Planner Lambda IAM role"

cat > .lambda-trust.json <<'JSON'
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
JSON

ensure_role \
    "$LAMBDA_ROLE_NAME" \
    ".lambda-trust.json"

aws iam attach-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

###############################################################################
# 7. AGENTCORE RUNTIME IAM ROLE
###############################################################################

log "Configuring AgentCore Runtime IAM role"

cat > .agentcore-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "bedrock-agentcore.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

ensure_role \
    "$AGENTCORE_ROLE_NAME" \
    ".agentcore-trust.json"

aws iam put-role-policy \
    --role-name "$AGENTCORE_ROLE_NAME" \
    --policy-name TravelPlannerAgentCorePermissions \
    --policy-document file://policies/agentcore-runtime-policy.json

###############################################################################
# 8. ECR REPOSITORY
###############################################################################

log "Preparing ECR repository"

if aws ecr describe-repositories \
    --repository-names "$ECR_REPOSITORY" \
    --region "$AWS_REGION" \
    >/dev/null 2>&1
then

    info "ECR repository already exists: $ECR_REPOSITORY"

else

    info "Creating ECR repository: $ECR_REPOSITORY"

    aws ecr create-repository \
        --repository-name "$ECR_REPOSITORY" \
        --region "$AWS_REGION" \
        >/dev/null

fi

###############################################################################
# 9. BUILD AND PUSH AGENTCORE IMAGE
###############################################################################

log "Building and pushing AgentCore image"

aws ecr get-login-password \
    --region "$AWS_REGION" |
docker login \
    --username AWS \
    --password-stdin "$ECR_REGISTRY"

docker buildx build \
    --platform linux/arm64 \
    --tag "$ECR_URI" \
    --push \
    .

###############################################################################
# 10. AGENTCORE RUNTIME
###############################################################################

log "Creating or updating AgentCore Runtime"

RUNTIME_ARN="$(
    aws bedrock-agentcore-control list-agent-runtimes \
        --region "$AWS_REGION" \
        --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeArn | [0]" \
        --output text
)"

RUNTIME_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${AGENTCORE_ROLE_NAME}"

RUNTIME_ARTIFACT="$(
    python3 - <<PY
import json

print(json.dumps({
    "containerConfiguration": {
        "containerUri": "${ECR_URI}"
    }
}))
PY
)"

RUNTIME_NETWORK='{"networkMode":"PUBLIC"}'

RUNTIME_ENV='{
  "AGENT_OBSERVABILITY_ENABLED": "false"
}'

if [[ -z "$RUNTIME_ARN" || "$RUNTIME_ARN" == "None" ]]; then

    info "Creating AgentCore Runtime: $RUNTIME_NAME"

    RUNTIME_ARN="$(
        aws bedrock-agentcore-control create-agent-runtime \
            --region "$AWS_REGION" \
            --agent-runtime-name "$RUNTIME_NAME" \
            --agent-runtime-artifact "$RUNTIME_ARTIFACT" \
            --role-arn "$RUNTIME_ROLE_ARN" \
            --network-configuration "$RUNTIME_NETWORK" \
            --environment-variables "$RUNTIME_ENV" \
            --query agentRuntimeArn \
            --output text
    )"

else

    info "Updating AgentCore Runtime: $RUNTIME_NAME"

    aws bedrock-agentcore-control update-agent-runtime \
        --region "$AWS_REGION" \
        --agent-runtime-id "${RUNTIME_ARN##*/}" \
        --agent-runtime-artifact "$RUNTIME_ARTIFACT" \
        --role-arn "$RUNTIME_ROLE_ARN" \
        --network-configuration "$RUNTIME_NETWORK" \
        --environment-variables "$RUNTIME_ENV" \
        >/dev/null

fi

info "Runtime ARN: $RUNTIME_ARN"

###############################################################################
# 11. PLANNER LAMBDA PERMISSIONS
###############################################################################

log "Configuring Planner Lambda permissions"

sed \
    "s|__RUNTIME_ARN__|$RUNTIME_ARN|g" \
    policies/lambda-agentcore-policy.json \
    > .lambda-policy.json

aws iam put-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-name InvokeTravelPlannerRuntime \
    --policy-document file://.lambda-policy.json

###############################################################################
# 12. PLANNER LAMBDA DEPLOYMENT
###############################################################################

log "Creating or updating Planner Lambda"

rm -f travel-planner-lambda.zip

(
    cd lambda
    zip -q ../travel-planner-lambda.zip lambda_function.py
)

LAMBDA_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"

if aws lambda get-function \
    --function-name "$LAMBDA_NAME" \
    >/dev/null 2>&1
then

    info "Updating Planner Lambda code"

    aws lambda update-function-code \
        --function-name "$LAMBDA_NAME" \
        --zip-file fileb://travel-planner-lambda.zip \
        >/dev/null

    aws lambda wait function-updated \
        --function-name "$LAMBDA_NAME"

    info "Updating Planner Lambda configuration"

    aws lambda update-function-configuration \
        --function-name "$LAMBDA_NAME" \
        --environment "Variables={AGENT_RUNTIME_ARN=$RUNTIME_ARN}" \
        >/dev/null

else

    info "Creating Planner Lambda: $LAMBDA_NAME"

    aws lambda create-function \
        --function-name "$LAMBDA_NAME" \
        --runtime python3.12 \
        --architectures arm64 \
        --handler lambda_function.lambda_handler \
        --role "$LAMBDA_ROLE_ARN" \
        --zip-file fileb://travel-planner-lambda.zip \
        --timeout 900 \
        --memory-size 512 \
        --environment "Variables={AGENT_RUNTIME_ARN=$RUNTIME_ARN}" \
        >/dev/null

    aws lambda wait function-active \
        --function-name "$LAMBDA_NAME"

fi

###############################################################################
# 13. GATEWAY LAMBDA IAM ROLE
###############################################################################

log "Configuring Gateway Lambda IAM role"

cat > .gateway-lambda-trust.json <<'JSON'
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
JSON

ensure_role \
    "$GATEWAY_LAMBDA_ROLE_NAME" \
    ".gateway-lambda-trust.json"

aws iam attach-role-policy \
    --role-name "$GATEWAY_LAMBDA_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

###############################################################################
# 14. DYNAMODB TABLE
###############################################################################

log "Creating or verifying DynamoDB table"

if aws dynamodb describe-table \
    --table-name "$TRAVEL_TABLE_NAME" \
    --region "$AWS_REGION" \
    >/dev/null 2>&1
then

    info "DynamoDB table already exists: $TRAVEL_TABLE_NAME"

else

    info "Creating DynamoDB table: $TRAVEL_TABLE_NAME"

    aws dynamodb create-table \
        --table-name "$TRAVEL_TABLE_NAME" \
        --attribute-definitions \
            AttributeName=city,AttributeType=S \
        --key-schema \
            AttributeName=city,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$AWS_REGION" \
        >/dev/null

fi

aws dynamodb wait table-exists \
    --table-name "$TRAVEL_TABLE_NAME" \
    --region "$AWS_REGION"

###############################################################################
# 15. GATEWAY LAMBDA DYNAMODB PERMISSION
###############################################################################

log "Configuring Gateway Lambda DynamoDB permissions"

cat > .gateway-lambda-dynamodb-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem"
      ],
      "Resource": "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/${TRAVEL_TABLE_NAME}"
    }
  ]
}
EOF

aws iam put-role-policy \
    --role-name "$GATEWAY_LAMBDA_ROLE_NAME" \
    --policy-name ReadTravelPlans \
    --policy-document file://.gateway-lambda-dynamodb-policy.json

###############################################################################
# 16. DYNAMODB TEST DATA
###############################################################################

log "Seeding DynamoDB test data"

aws dynamodb put-item \
    --table-name "$TRAVEL_TABLE_NAME" \
    --region "$AWS_REGION" \
    --item '{
      "city": {
        "S": "Ooty"
      },
      "budget": {
        "S": "$500-$1000"
      },
      "duration": {
        "N": "4"
      },
      "itinerary": {
        "S": "Day 1: Ooty Lake. Day 2: Doddabetta Peak. Day 3: Coonoor. Day 4: Departure."
      }
    }' \
    >/dev/null

###############################################################################
# 17. GATEWAY LAMBDA DEPLOYMENT
###############################################################################

log "Creating or updating Gateway Lambda"

rm -f gateway-lambda.zip

(
    cd gateway_lambda
    zip -q ../gateway-lambda.zip lambda_function.py
)

GATEWAY_LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${GATEWAY_LAMBDA_NAME}"

GATEWAY_LAMBDA_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${GATEWAY_LAMBDA_ROLE_NAME}"

if aws lambda get-function \
    --function-name "$GATEWAY_LAMBDA_NAME" \
    >/dev/null 2>&1
then

    info "Updating Gateway Lambda code"

    aws lambda update-function-code \
        --function-name "$GATEWAY_LAMBDA_NAME" \
        --zip-file fileb://gateway-lambda.zip \
        >/dev/null

    aws lambda wait function-updated \
        --function-name "$GATEWAY_LAMBDA_NAME"

    aws lambda update-function-configuration \
        --function-name "$GATEWAY_LAMBDA_NAME" \
        --environment "Variables={TRAVEL_TABLE_NAME=$TRAVEL_TABLE_NAME}" \
        >/dev/null

else

    info "Creating Gateway Lambda: $GATEWAY_LAMBDA_NAME"

    aws lambda create-function \
        --function-name "$GATEWAY_LAMBDA_NAME" \
        --runtime python3.12 \
        --architectures arm64 \
        --handler lambda_function.lambda_handler \
        --role "$GATEWAY_LAMBDA_ROLE_ARN" \
        --zip-file fileb://gateway-lambda.zip \
        --timeout 30 \
        --memory-size 256 \
        --environment "Variables={TRAVEL_TABLE_NAME=$TRAVEL_TABLE_NAME}" \
        >/dev/null

    aws lambda wait function-active \
        --function-name "$GATEWAY_LAMBDA_NAME"

fi

###############################################################################
# 18. AGENTCORE GATEWAY IAM ROLE
###############################################################################

log "Configuring AgentCore Gateway IAM role"

cat > .gateway-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "bedrock-agentcore.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

ensure_role \
    "$GATEWAY_ROLE_NAME" \
    ".gateway-trust.json"

###############################################################################
# 19. GATEWAY -> LAMBDA IAM PERMISSION
###############################################################################

log "Configuring Gateway -> Lambda IAM permission"

cat > .gateway-lambda-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lambda:InvokeFunction"
      ],
      "Resource": "${GATEWAY_LAMBDA_ARN}"
    }
  ]
}
EOF

aws iam put-role-policy \
    --role-name "$GATEWAY_ROLE_NAME" \
    --policy-name InvokeGatewayLambda \
    --policy-document file://.gateway-lambda-policy.json

###############################################################################
# 20. COGNITO USER POOL
###############################################################################

log "Creating or locating Cognito User Pool"

POOL_ID="$(
    aws cognito-idp list-user-pools \
        --max-results 60 \
        --region "$AWS_REGION" \
        --query "UserPools[?Name=='${COGNITO_POOL_NAME}'].Id | [0]" \
        --output text
)"

if [[ -z "$POOL_ID" || "$POOL_ID" == "None" ]]; then

    info "Creating Cognito User Pool: $COGNITO_POOL_NAME"

    POOL_ID="$(
        aws cognito-idp create-user-pool \
            --pool-name "$COGNITO_POOL_NAME" \
            --region "$AWS_REGION" \
            --query UserPool.Id \
            --output text
    )"

else

    info "Using existing Cognito User Pool: $POOL_ID"

fi

###############################################################################
# 21. COGNITO DOMAIN
###############################################################################

log "Configuring Cognito domain"

if aws cognito-idp describe-user-pool-domain \
    --domain "$COGNITO_DOMAIN_PREFIX" \
    --region "$AWS_REGION" \
    >/dev/null 2>&1
then

    info "Cognito domain already exists: $COGNITO_DOMAIN_PREFIX"

else

    info "Creating Cognito domain: $COGNITO_DOMAIN_PREFIX"

    aws cognito-idp create-user-pool-domain \
        --user-pool-id "$POOL_ID" \
        --domain "$COGNITO_DOMAIN_PREFIX" \
        --region "$AWS_REGION" \
        >/dev/null

fi

###############################################################################
# 22. COGNITO RESOURCE SERVER
###############################################################################

log "Configuring Cognito Resource Server"

RESOURCE_SERVER_IDENTIFIER="$(
    aws cognito-idp list-resource-servers \
        --user-pool-id "$POOL_ID" \
        --max-results 50 \
        --region "$AWS_REGION" \
        --query "ResourceServers[?Identifier=='${COGNITO_RESOURCE_SERVER_IDENTIFIER}'].Identifier | [0]" \
        --output text
)"

if [[ -z "$RESOURCE_SERVER_IDENTIFIER" || "$RESOURCE_SERVER_IDENTIFIER" == "None" ]]; then

    info "Creating Cognito resource server"

    aws cognito-idp create-resource-server \
        --user-pool-id "$POOL_ID" \
        --identifier "$COGNITO_RESOURCE_SERVER_IDENTIFIER" \
        --name TravelPlanner \
        --scopes \
            "ScopeName=${COGNITO_SCOPE_NAME},ScopeDescription=Read travel plans" \
        --region "$AWS_REGION" \
        >/dev/null

else

    info "Cognito resource server already exists: $RESOURCE_SERVER_IDENTIFIER"

fi

###############################################################################
# 23. COGNITO M2M CLIENT
###############################################################################

log "Creating or locating Cognito M2M client"

CLIENT_ID="$(
    aws cognito-idp list-user-pool-clients \
        --user-pool-id "$POOL_ID" \
        --region "$AWS_REGION" \
        --query "UserPoolClients[?ClientName=='${COGNITO_CLIENT_NAME}'].ClientId | [0]" \
        --output text
)"

if [[ -z "$CLIENT_ID" || "$CLIENT_ID" == "None" ]]; then

    info "Creating Cognito M2M client"

    CLIENT_JSON="$(
        aws cognito-idp create-user-pool-client \
            --user-pool-id "$POOL_ID" \
            --client-name "$COGNITO_CLIENT_NAME" \
            --generate-secret \
            --allowed-o-auth-flows client_credentials \
            --allowed-o-auth-scopes "$GATEWAY_SCOPE" \
            --allowed-o-auth-flows-user-pool-client \
            --region "$AWS_REGION"
    )"

    CLIENT_ID="$(
        echo "$CLIENT_JSON" |
        python3 -c '
import json
import sys
print(json.load(sys.stdin)["UserPoolClient"]["ClientId"])
'
    )"

    CLIENT_SECRET="$(
        echo "$CLIENT_JSON" |
        python3 -c '
import json
import sys
print(json.load(sys.stdin)["UserPoolClient"]["ClientSecret"])
'
    )"

else

    info "Cognito M2M client already exists"

    CLIENT_SECRET="$(
        aws cognito-idp describe-user-pool-client \
            --user-pool-id "$POOL_ID" \
            --client-id "$CLIENT_ID" \
            --region "$AWS_REGION" \
            --query UserPoolClient.ClientSecret \
            --output text
    )"

fi

###############################################################################
# 24. COGNITO OIDC DISCOVERY URL
###############################################################################

DISCOVERY_URL="https://cognito-idp.${AWS_REGION}.amazonaws.com/${POOL_ID}/.well-known/openid-configuration"

TOKEN_URL="https://${COGNITO_DOMAIN_PREFIX}.auth.${AWS_REGION}.amazoncognito.com/oauth2/token"

###############################################################################
# 25. AGENTCORE GATEWAY
###############################################################################

log "Creating or locating AgentCore Gateway"

GATEWAY_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${GATEWAY_ROLE_NAME}"

GATEWAY_ID="$(
    aws bedrock-agentcore-control list-gateways \
        --region "$AWS_REGION" \
        --query "items[?name=='${GATEWAY_NAME}'].gatewayId | [0]" \
        --output text
)"

if [[ -z "$GATEWAY_ID" || "$GATEWAY_ID" == "None" ]]; then

    info "Creating AgentCore Gateway: $GATEWAY_NAME"

    GATEWAY_ID="$(
        aws bedrock-agentcore-control create-gateway \
            --region "$AWS_REGION" \
            --name "$GATEWAY_NAME" \
            --role-arn "$GATEWAY_ROLE_ARN" \
            --protocol-type MCP \
            --authorizer-type CUSTOM_JWT \
            --authorizer-configuration \
            "{
              \"customJWTAuthorizer\": {
                \"discoveryUrl\": \"${DISCOVERY_URL}\",
                \"allowedScopes\": [
                  \"${GATEWAY_SCOPE}\"
                ]
              }
            }" \
            --query gatewayId \
            --output text
    )"

else

    info "AgentCore Gateway already exists: $GATEWAY_ID"

fi

###############################################################################
# 26. GATEWAY TARGET
#
# IMPORTANT:
#
# Lambda target authentication:
#
#     GATEWAY_IAM_ROLE
#
# NOT:
#
#     OAUTH
#
# Cognito OAuth is used for inbound client -> Gateway authentication.
###############################################################################

log "Creating or validating Gateway -> Lambda target"

TOOL_SCHEMA="$(tr -d '\n' < gateway_tools.json)"

TARGET_ID="$(
    aws bedrock-agentcore-control list-gateway-targets \
        --region "$AWS_REGION" \
        --gateway-identifier "$GATEWAY_ID" \
        --query "items[?name=='${GATEWAY_TARGET_NAME}'].targetId | [0]" \
        --output text
)"

if [[ -z "$TARGET_ID" || "$TARGET_ID" == "None" ]]; then

    info "Creating Gateway Lambda target"

    TARGET_ID="$(
        aws bedrock-agentcore-control create-gateway-target \
            --region "$AWS_REGION" \
            --gateway-identifier "$GATEWAY_ID" \
            --name "$GATEWAY_TARGET_NAME" \
            --target-configuration \
            "{
              \"mcp\": {
                \"lambda\": {
                  \"lambdaArn\": \"${GATEWAY_LAMBDA_ARN}\",
                  \"toolSchema\": {
                    \"inlinePayload\": ${TOOL_SCHEMA}
                  }
                }
              }
            }" \
            --credential-provider-configurations \
            '[
              {
                "credentialProviderType": "GATEWAY_IAM_ROLE"
              }
            ]' \
            --query targetId \
            --output text
    )"

    info "Gateway target created: $TARGET_ID"

else

    info "Gateway target already exists: $TARGET_ID"

    TARGET_DETAILS="$(
        aws bedrock-agentcore-control get-gateway-target \
            --region "$AWS_REGION" \
            --gateway-identifier "$GATEWAY_ID" \
            --target-id "$TARGET_ID" \
            --output json
    )"

    TARGET_STATUS="$(
        echo "$TARGET_DETAILS" |
        python3 -c '
import json
import sys
d=json.load(sys.stdin)
print(d.get("status","UNKNOWN"))
'
    )"

    TARGET_PROVIDER="$(
        echo "$TARGET_DETAILS" |
        python3 -c '
import json
import sys
d=json.load(sys.stdin)
p=d.get("credentialProviderConfigurations",[])
if p:
    print(p[0].get("credentialProviderType","UNKNOWN"))
else:
    print("UNKNOWN")
'
    )"

    info "Target status           : $TARGET_STATUS"
    info "Credential provider     : $TARGET_PROVIDER"

    if [[ "$TARGET_PROVIDER" != "GATEWAY_IAM_ROLE" ]]; then

        warn "Existing target does not use GATEWAY_IAM_ROLE."
        warn "Deleting and recreating target with correct Lambda authentication."

        if [[ "$TARGET_STATUS" == "CREATE_PENDING_AUTH" ||
              "$TARGET_STATUS" == "UPDATE_PENDING_AUTH" ||
              "$TARGET_STATUS" == "SYNCHRONIZE_PENDING_AUTH" ]]
        then

            die "Gateway target is in $TARGET_STATUS. Wait for authorization to complete before rerunning."

        fi

        aws bedrock-agentcore-control delete-gateway-target \
            --region "$AWS_REGION" \
            --gateway-identifier "$GATEWAY_ID" \
            --target-id "$TARGET_ID" \
            >/dev/null

        info "Waiting for target deletion"

        for _ in {1..30}; do

            if aws bedrock-agentcore-control get-gateway-target \
                --region "$AWS_REGION" \
                --gateway-identifier "$GATEWAY_ID" \
                --target-id "$TARGET_ID" \
                >/dev/null 2>&1
            then

                sleep 2

            else

                break

            fi

        done

        info "Creating corrected Gateway Lambda target"

        TARGET_ID="$(
            aws bedrock-agentcore-control create-gateway-target \
                --region "$AWS_REGION" \
                --gateway-identifier "$GATEWAY_ID" \
                --name "$GATEWAY_TARGET_NAME" \
                --target-configuration \
                "{
                  \"mcp\": {
                    \"lambda\": {
                      \"lambdaArn\": \"${GATEWAY_LAMBDA_ARN}\",
                      \"toolSchema\": {
                        \"inlinePayload\": ${TOOL_SCHEMA}
                      }
                    }
                  }
                }" \
                --credential-provider-configurations \
                '[
                  {
                    "credentialProviderType": "GATEWAY_IAM_ROLE"
                  }
                ]' \
                --query targetId \
                --output text
        )"

    else

        info "Gateway target authentication is correct"

    fi

fi

###############################################################################
# 27. SAVE INTEGRATION SECRET
###############################################################################

log "Saving integration configuration"

GATEWAY_URL="https://${GATEWAY_ID}.gateway.bedrock-agentcore.${AWS_REGION}.amazonaws.com/mcp"

SECRET_JSON="$(
    python3 - <<PY
import json

data = {
    "agentcore_gateway_url": "${GATEWAY_URL}",
    "agentcore_gateway_tool_name": "${GATEWAY_TARGET_NAME}___get_travel_plan",
    "agentcore_gateway_tool_input_key": "city",
    "cognito_token_url": "${TOKEN_URL}",
    "cognito_client_id": "${CLIENT_ID}",
    "cognito_client_secret": "${CLIENT_SECRET}",
    "cognito_scope": "${GATEWAY_SCOPE}"
}

print(json.dumps(data))
PY
)"

if aws secretsmanager describe-secret \
    --secret-id "$INTEGRATION_SECRET_NAME" \
    --region "$AWS_REGION" \
    >/dev/null 2>&1
then

    info "Updating Secrets Manager secret"

    aws secretsmanager put-secret-value \
        --secret-id "$INTEGRATION_SECRET_NAME" \
        --secret-string "$SECRET_JSON" \
        --region "$AWS_REGION" \
        >/dev/null

else

    info "Creating Secrets Manager secret"

    aws secretsmanager create-secret \
        --name "$INTEGRATION_SECRET_NAME" \
        --secret-string "$SECRET_JSON" \
        --region "$AWS_REGION" \
        >/dev/null

fi

###############################################################################
# 28. CLEANUP
###############################################################################

log "Cleaning temporary deployment files"

rm -f \
    .lambda-trust.json \
    .agentcore-trust.json \
    .gateway-lambda-trust.json \
    .gateway-trust.json \
    .lambda-policy.json \
    .gateway-lambda-dynamodb-policy.json \
    .gateway-lambda-policy.json \
    travel-planner-lambda.zip \
    gateway-lambda.zip

###############################################################################
# 29. FINAL SUMMARY
###############################################################################

log "DEPLOYMENT COMPLETE"

echo
echo "AWS Region"
echo "  $AWS_REGION"

echo
echo "AWS Account"
echo "  $AWS_ACCOUNT_ID"

echo
echo "AgentCore Runtime"
echo "  $RUNTIME_NAME"
echo "  $RUNTIME_ARN"

echo
echo "Planner Lambda"
echo "  $LAMBDA_NAME"

echo
echo "Gateway Lambda"
echo "  $GATEWAY_LAMBDA_NAME"
echo "  $GATEWAY_LAMBDA_ARN"

echo
echo "DynamoDB"
echo "  $TRAVEL_TABLE_NAME"

echo
echo "Cognito User Pool"
echo "  $POOL_ID"

echo
echo "Cognito Client"
echo "  $CLIENT_ID"

echo
echo "Cognito Scope"
echo "  $GATEWAY_SCOPE"

echo
echo "Cognito Discovery URL"
echo "  $DISCOVERY_URL"

echo
echo "Cognito Token URL"
echo "  $TOKEN_URL"

echo
echo "AgentCore Gateway"
echo "  $GATEWAY_ID"

echo
echo "AgentCore Gateway URL"
echo "  $GATEWAY_URL"

echo
echo "Gateway Target"
echo "  $TARGET_ID"

echo
echo "Gateway Target Authentication"
echo "  GATEWAY_IAM_ROLE"

echo
echo "Secrets Manager"
echo "  $INTEGRATION_SECRET_NAME"

echo
echo "============================================================"
echo "Deployment finished successfully."
echo "============================================================"