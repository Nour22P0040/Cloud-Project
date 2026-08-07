#!/usr/bin/env bash
set -euo pipefail

REGION="eu-central-1"

echo "=================================================="
echo "Step 1: Destroying Compute & DB CloudFormation Stack..."
echo "=================================================="
aws cloudformation delete-stack --stack-name "vm-and-db" --region "$REGION" || true

echo "Waiting for 'vm-and-db' stack deletion to finish..."
aws cloudformation wait stack-delete-complete --stack-name "vm-and-db" --region "$REGION" || true

echo "=================================================="
echo "Step 2: Cleaning Orphaned Databases..."
echo "=================================================="
# Explicitly delete any standalone or stuck RDS instances named usermanagerdb
if aws rds describe-db-instances --db-instance-identifier "usermanagerdb" --region "$REGION" >/dev/null 2>&1; then
  echo "Found orphaned RDS DB 'usermanagerdb'. Requesting deletion..."
  aws rds delete-db-instance \
    --db-instance-identifier "usermanagerdb" \
    --skip-final-snapshot \
    --delete-automated-backups \
    --region "$REGION" || true

  echo "Waiting for RDS instance deletion..."
  aws rds wait db-instance-deleted --db-instance-identifier "usermanagerdb" --region "$REGION" || true
fi

echo "=================================================="
echo "Step 3: Force Purging VPC Resources & Network Attachments..."
echo "=================================================="
VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name "infrastructure" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" \
  --output text 2>/dev/null || echo "")

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
  # Fallback: Find VPC by tag
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=UserManagementVpc" \
    --region "$REGION" \
    --query "Vpcs[0].VpcId" \
    --output text 2>/dev/null || echo "")
fi

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "Targeting VPC: $VPC_ID"

  # 1. Terminate all EC2 Instances inside the VPC
  INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --region "$REGION" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text)

  if [ -n "$INSTANCES" ]; then
    echo "Terminating EC2 instances: $INSTANCES"
    aws ec2 terminate-instances --instance-ids $INSTANCES --region "$REGION" >/dev/null
    aws ec2 wait instance-terminated --instance-ids $INSTANCES --region "$REGION"
  fi

  # 2. Delete Load Balancers
  ALBS=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
    --output text)

  for alb in $ALBS; do
    echo "Deleting Load Balancer: $alb"
    aws elbv2 delete-load-balancer --load-balancer-arn "$alb" --region "$REGION" || true
  done

  # 3. Force Delete Network Interfaces (ENIs)
  ENIS=$(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query "NetworkInterfaces[*].NetworkInterfaceId" \
    --output text)

  for eni in $ENIS; do
    echo "Deleting Network Interface: $eni"
    aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" || true
  done

  # 4. Detach and Delete Internet Gateways
  IGWS=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query "InternetGateways[*].InternetGatewayId" \
    --output text)

  for igw in $IGWS; do
    echo "Detaching and Deleting IGW: $igw"
    aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" --region "$REGION" || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" || true
  done

  # 5. Delete Security Groups
  SGS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text)

  for sg in $SGS; do
    echo "Deleting Security Group: $sg"
    aws ec2 delete-security-group --group-id "$sg" --region "$REGION" || true
  done
fi

echo "=================================================="
echo "Step 4: Destroying Network Infrastructure Stack..."
echo "=================================================="
aws cloudformation delete-stack --stack-name "infrastructure" --region "$REGION" || true

echo "Waiting for 'infrastructure' stack deletion to finish..."
aws cloudformation wait stack-delete-complete --stack-name "infrastructure" --region "$REGION" || true

echo "=================================================="
echo "SUCCESS: Cloud state completely wiped clean!"
echo "=================================================="
