#!/usr/bin/env bash
set -euo pipefail

REGION="eu-central-1"

echo "Step 1: Deleting compute, database, and load balancer stack (vm-and-db)..."
aws cloudformation delete-stack \
  --stack-name "vm-and-db" \
  --region "$REGION"

echo "Waiting for stack 'vm-and-db' to be fully deleted..."
aws cloudformation wait stack-delete-complete \
  --stack-name "vm-and-db" \
  --region "$REGION"

echo "Step 2: Deleting networking infrastructure stack (infrastructure)..."
aws cloudformation delete-stack \
  --stack-name "infrastructure" \
  --region "$REGION"

echo "Waiting for stack 'infrastructure' to be fully deleted..."
aws cloudformation wait stack-delete-complete \
  --stack-name "infrastructure" \
  --region "$REGION"

echo "All stacks successfully destroyed! Charges have stopped."