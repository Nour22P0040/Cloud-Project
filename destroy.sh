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
echo "Step 2: Force-clearing ALL lingering VPC dependencies..."
echo "=================================================="

# Retrieve VPC ID directly from the infrastructure stack
VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name "infrastructure" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" \
  --output text 2>/dev/null || echo "")

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "Cleaning dependencies for VPC: $VPC_ID..."

  # 1. Terminate any running/stopped EC2 instances in this VPC
  INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --region "$REGION" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text)

  if [ -n "$INSTANCE_IDS" ]; then
    echo "Terminating EC2 instances: $INSTANCE_IDS"
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION" > /dev/null
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$REGION"
  fi

  # 2. Delete all non-default Network Interfaces (ENIs)
  ENI_IDS=$(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query "NetworkInterfaces[*].NetworkInterfaceId" \
    --output text)

  for eni in $ENI_IDS; do
    echo "Deleting ENI: $eni"
    aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" || true
  done

  # 3. Detach and delete Internet Gateways
  IGW_IDS=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query "InternetGateways[*].InternetGatewayId" \
    --output text)

  for igw in $IGW_IDS; do
    echo "Detaching and deleting IGW: $igw"
    aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" --region "$REGION" || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" || true
  done

  # 4. Delete custom Security Groups (excluding default)
  SG_IDS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text)

  for sg in $SG_IDS; do
    echo "Deleting Security Group: $sg"
    aws ec2 delete-security-group --group-id "$sg" --region "$REGION" || true
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
echo "SUCCESS: VPC and all infrastructure destroyed!"
echo "=================================================="
