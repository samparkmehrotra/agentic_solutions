                         ┌─────────────────────┐
                         │      Cognito        │
                         │                     │
                         │ M2M Client          │
                         │ Scope:              │
                         │ travel-planner/read │
                         └──────────┬──────────┘
                                    │
                              OAuth2 JWT
                                    │
                                    ▼
                     ┌──────────────────────────┐
                     │   AgentCore Gateway      │
                     │                          │
                     │ CUSTOM_JWT               │
                     │ Cognito Discovery URL    │
                     └────────────┬─────────────┘
                                  │
                       GATEWAY_IAM_ROLE
                                  │
                                  ▼
                     ┌──────────────────────────┐
                     │   Gateway Lambda         │
                     │                          │
                     │ get_travel_plan(city)    │
                     └────────────┬─────────────┘
                                  │
                                  ▼
                     ┌──────────────────────────┐
                     │       DynamoDB           │
                     │       travel-plans       │
                     └──────────────────────────┘


Separately:

                     ┌──────────────────────────┐
                     │   Planner Lambda         │
                     └────────────┬─────────────┘
                                  │
                                  │ IAM
                                  ▼
                     ┌──────────────────────────┐
                     │   AgentCore Runtime      │
                     │   CrewAI Travel Planner  │
                     └──────────────────────────┘