#!/usr/bin/env bash
set -euo pipefail

REGION="eu-central-1"

echo "=================================================="
echo "Step 1: Destroying Compute & Database Stack (vm-and-db)..."
echo "=================================================="
aws cloudformation delete-stack \
  --stack-name "vm-and-db" \
  --region "$REGION"

echo "Waiting for 'vm-and-db' stack to finish deletion..."
aws cloudformation wait stack-delete-complete \
  --stack-name "vm-and-db" \
  --region "$REGION" || true

echo "=================================================="
echo "Step 2: Force-clearing lingering resources in VPC..."
echo "=================================================="

# Get the VPC ID from the infrastructure stack if it exists
VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name "infrastructure" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" \
  --output text 2>/dev/null || echo "")

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "Found VPC: $VPC_ID. Cleaning up attached resources..."

  # 1. Terminate all running/stopped EC2 instances in this VPC
  INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --region "$REGION" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text)

  if [ -n "$INSTANCE_IDS" ]; then
    echo "Terminating lingering EC2 instances: $INSTANCE_IDS"
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION" > /dev/null
    echo "Waiting for EC2 instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$REGION"
  fi

  # 2. Detach and delete lingering Network Interfaces (ENIs)
  ENI_IDS=$(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query "NetworkInterfaces[?Status=='available'].NetworkInterfaceId" \
    --output text)

  for eni in $ENI_IDS; do
    echo "Deleting leftover ENI: $eni"
    aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" || true
  done
fi

echo "=================================================="
echo "Step 3: Destroying Infrastructure Stack (infrastructure)..."
echo "=================================================="
aws cloudformation delete-stack \
  --stack-name "infrastructure" \
  --region "$REGION"

echo "Waiting for 'infrastructure' stack to finish deletion..."
aws cloudformation wait stack-delete-complete \
  --stack-name "infrastructure" \
  --region "$REGION"

echo "=================================================="
echo "SUCCESS: Everything destroyed automatically!"
echo "=================================================="
