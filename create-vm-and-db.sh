#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="vm-and-db"
REGION="eu-central-1"
KEY_PAIR_NAME="YourKeyPairName"   # <-- change to the KeyPair you created

if [ -z "${DB_PASSWORD:-}" ]; then
  echo "Set DB_PASSWORD env var first, e.g.: export DB_PASSWORD='SuperSecret123'"
  exit 1
fi

aws cloudformation deploy \
  --template-file vm-and-db-stack.yml \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --parameter-overrides \
      NetworkStackName=infrastructure \
      KeyPairName="$KEY_PAIR_NAME" \
      DBPass="$DB_PASSWORD" \
      Region="$REGION" \
  --capabilities CAPABILITY_NAMED_IAM

aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs"