#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="infrastructure"
REGION="eu-central-1"

aws cloudformation deploy \
  --template-file infra-stack.yml \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --parameter-overrides Region="$REGION" \
  --capabilities CAPABILITY_NAMED_IAM

aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs"