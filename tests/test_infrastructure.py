import os
import boto3
import pytest
import requests

REGION = os.getenv("AWS_REGION", "eu-central-1")


@pytest.fixture(scope="module")
def cf_client():
    return boto3.client("cloudformation", region_name=REGION)


@pytest.fixture(scope="module")
def ec2_client():
    return boto3.client("ec2", region_name=REGION)


@pytest.fixture(scope="module")
def rds_client():
    return boto3.client("rds", region_name=REGION)


@pytest.fixture(scope="module")
def elbv2_client():
    return boto3.client("elbv2", region_name=REGION)


def test_infrastructure_stack_status(cf_client):
    """Verify that the Network Infrastructure stack exists and is CREATE_COMPLETE or UPDATE_COMPLETE."""
    response = cf_client.describe_stacks(StackName="infrastructure")
    stack = response["Stacks"][0]
    assert stack["StackStatus"] in ["CREATE_COMPLETE", "UPDATE_COMPLETE"]


def test_vm_and_db_stack_status(cf_client):
    """Verify that the Compute/DB stack exists and is healthy."""
    response = cf_client.describe_stacks(StackName="vm-and-db")
    stack = response["Stacks"][0]
    assert stack["StackStatus"] in ["CREATE_COMPLETE", "UPDATE_COMPLETE"]


def test_vpc_is_available(ec2_client):
    """Verify the VPC tagged 'UserManagementVpc' is active."""
    response = ec2_client.describe_vpcs(
        Filters=[{"Name": "tag:Name", "Values": ["UserManagementVpc"]}]
    )
    vpcs = response["Vpcs"]
    assert len(vpcs) == 1
    assert vpcs[0]["State"] == "available"


def test_ec2_instances_running(ec2_client):
    """Verify that expected EC2 instances in the VPC are running."""
    response = ec2_client.describe_instances(
        Filters=[
            {"Name": "instance-state-name", "Values": ["running"]}
        ]
    )
    running_instances = [
        inst
        for res in response["Reservations"]
        for inst in res["Instances"]
    ]
    assert len(running_instances) >= 1, "Expected at least 1 running EC2 instance."


def test_rds_instance_available(rds_client):
    """Verify the RDS database is available."""
    response = rds_client.describe_db_instances()
    instances = response["DBInstances"]
    assert len(instances) >= 1
    assert instances[0]["DBInstanceStatus"] == "available"


def test_load_balancer_health(elbv2_client):
    """Verify that the Application Load Balancer exists and is active."""
    response = elbv2_client.describe_load_balancers()
    albs = response["LoadBalancers"]
    assert len(albs) >= 1
    alb = albs[0]
    assert alb["State"]["Code"] == "active"

    # Ping the ALB DNS Endpoint
    alb_dns = alb["DNSName"]
    try:
        http_res = requests.get(f"http://{alb_dns}", timeout=10)
        # Ensure server responds with valid status code (e.g., 200 OK or 403 Forbidden)
        assert http_res.status_code in [200, 302, 403]
    except requests.exceptions.RequestException as e:
        pytest.fail(f"Could not reach ALB at http://{alb_dns}: {e}")
