#!/usr/bin/env bash
set -euo pipefail

REGION="eu-central-1"

echo "=================================================="
echo "Step 1: Initiating Stack Deletion..."
echo "=================================================="
aws cloudformation delete-stack --stack-name "vm-and-db" --region "$REGION" || true
aws cloudformation delete-stack --stack-name "infrastructure" --region "$REGION" || true

echo "=================================================="
echo "Step 2: Cleaning Orphaned Databases..."
echo "=================================================="
if aws rds describe-db-instances --db-instance-identifier "usermanagerdb" --region "$REGION" >/dev/null 2>&1; then
  echo "Found RDS DB 'usermanagerdb'. Deleting..."
  aws rds delete-db-instance \
    --db-instance-identifier "usermanagerdb" \
    --skip-final-snapshot \
    --delete-automated-backups \
    --region "$REGION" || true

  aws rds wait db-instance-deleted --db-instance-identifier "usermanagerdb" --region "$REGION" || true
fi

echo "=================================================="
echo "Step 3: Force Purging VPC Dependencies..."
echo "=================================================="
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=UserManagementVpc" \
  --region "$REGION" \
  --query "Vpcs[0].VpcId" \
  --output text 2>/dev/null || echo "")

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "Targeting VPC: $VPC_ID"

  # 1. Terminate all EC2 instances
  INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --region "$REGION" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text)

  if [ -n "$INSTANCES" ]; then
    echo "Terminating EC2 instances: $INSTANCES"
    aws ec2 terminate-instances --instance-ids "$INSTANCES" --region "$REGION" >/dev/null
    aws ec2 wait instance-terminated --instance-ids "$INSTANCES" --region "$REGION"
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

  # 3. Delete NAT Gateways and WAIT for status to reach 'deleted'
  NAT_GWS=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=pending,failed,available,deleting" \
    --region "$REGION" \
    --query "NatGateways[*].NatGatewayId" \
    --output text)

  for nat in $NAT_GWS; do
    echo "Deleting NAT Gateway: $nat"
    aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION" || true
  done

  if [ -n "$NAT_GWS" ]; then
    echo "Waiting for NAT Gateways to reach deleted state..."
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_GWS" --region "$REGION" || true
  fi

  # 4. Release EIPs AFTER NAT Gateways are deleted
  EIPS=$(aws ec2 describe-addresses \
    --region "$REGION" \
    --query "Addresses[?VpcId=='$VPC_ID'].AllocationId" \
    --output text)

  for alloc_id in $EIPS; do
    echo "Releasing Elastic IP: $alloc_id"
    aws ec2 release-address --allocation-id "$alloc_id" --region "$REGION" || true
  done

  # 5. Detach and Delete Internet Gateways
  IGWS=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query "InternetGateways[*].InternetGatewayId" \
    --output text)

  for igw in $IGWS; do
    echo "Detaching & Deleting IGW: $igw"
    aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" --region "$REGION" || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" || true
  done

  # 6. Delete lingering ENIs
  ENIS=$(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query "NetworkInterfaces[*].NetworkInterfaceId" \
    --output text)

  for eni in $ENIS; do
    echo "Deleting ENI: $eni"
    aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" || true
  done

  # 7. Strip all ingress/egress rules from non-default security groups
  SGS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region "$REGION" \
    --query "SecurityGroups[?GroupName!='default']" \
    --output json)

  echo "$SGS" | jq -c '.[]' | while read -r sg_json; do
    sg_id=$(echo "$sg_json" | jq -r '.GroupId')
    
    # Revoke all ingress rules
    ingress_rules=$(echo "$sg_json" | jq -c '.IpPermissions')
    if [ "$ingress_rules" != "[]" ]; then
      aws ec2 revoke-security-group-ingress --group-id "$sg_id" --ip-permissions "$ingress_rules" --region "$REGION" 2>/dev/null || true
    fi

    # Revoke all egress rules
    egress_rules=$(echo "$sg_json" | jq -c '.IpPermissionsEgress')
    if [ "$egress_rules" != "[]" ]; then
      aws ec2 revoke-security-group-egress --group-id "$sg_id" --ip-permissions "$egress_rules" --region "$REGION" 2>/dev/null || true
    fi
  done

  # Delete Security Groups
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
echo "Step 4: Confirming CloudFormation Deletion..."
echo "=================================================="
aws cloudformation wait stack-delete-complete --stack-name "vm-and-db" --region "$REGION" || true
aws cloudformation wait stack-delete-complete --stack-name "infrastructure" --region "$REGION" || true

echo "=================================================="
echo "SUCCESS: Environment completely destroyed."
echo "=================================================="
