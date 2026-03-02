#!/usr/bin/env bash
# delete_eks_cloudformation.sh
#
# Deletes leftover CloudFormation stacks (and their VPC resources) for an EKS
# cluster that was already removed from the console.
#
# Usage:
#   ./delete_eks_cloudformation.sh --region us-east-1 --name <cluster-name>
#
# The script:
#   1. Lists all CloudFormation stacks whose names contain the cluster name.
#   2. For each stack, attempts a normal deletion.
#   3. If deletion fails due to non-empty VPC resources, it drains those
#      resources recursively before retrying.

set -euo pipefail

# ── argument parsing ────────────────────────────────────────────────────────
REGION=""
CLUSTER_NAME=""

usage() {
    echo "Usage: $0 --region <region> --name <cluster-name>" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --region) REGION="$2"; shift 2 ;;
        --name)   CLUSTER_NAME="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -z "$REGION" || -z "$CLUSTER_NAME" ]] && usage

AWS="aws --region $REGION"

echo "==> Region:  $REGION"
echo "==> Cluster: $CLUSTER_NAME"

# ── helpers ─────────────────────────────────────────────────────────────────

wait_for_stack_delete() {
    local stack_name="$1"
    echo "    Waiting for stack '$stack_name' to finish deleting..."
    $AWS cloudformation wait stack-delete-complete --stack-name "$stack_name" 2>/dev/null \
        || echo "    Warning: wait timed-out or stack already gone for '$stack_name'"
}

# Delete every resource inside a VPC so CloudFormation can remove it.
drain_vpc() {
    local vpc_id="$1"
    echo "  --> Draining VPC $vpc_id ..."

    # ── Internet Gateways ────────────────────────────────────────────────────
    local igw_ids
    igw_ids=$($AWS ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$vpc_id" \
        --query 'InternetGateways[*].InternetGatewayId' --output text)
    for igw in $igw_ids; do
        echo "     Detaching & deleting IGW $igw"
        $AWS ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc_id"
        $AWS ec2 delete-internet-gateway --internet-gateway-id "$igw"
    done

    # ── NAT Gateways ─────────────────────────────────────────────────────────
    local nat_ids
    nat_ids=$($AWS ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$vpc_id" "Name=state,Values=available,pending" \
        --query 'NatGateways[*].NatGatewayId' --output text)
    for nat in $nat_ids; do
        echo "     Deleting NAT gateway $nat"
        $AWS ec2 delete-nat-gateway --nat-gateway-id "$nat"
    done
    # Wait for NAT gateways to finish deleting
    if [[ -n "$nat_ids" ]]; then
        echo "     Waiting for NAT gateways to reach 'deleted' state..."
        for nat in $nat_ids; do
            $AWS ec2 wait nat-gateway-deleted --nat-gateway-ids "$nat" 2>/dev/null || true
        done
    fi

    # ── Elastic IPs (associated with NAT gateways or loose) ─────────────────
    local eip_alloc_ids
    eip_alloc_ids=$($AWS ec2 describe-addresses \
        --filters "Name=domain,Values=vpc" \
        --query 'Addresses[?AssociationId==null].AllocationId' --output text)
    for eip in $eip_alloc_ids; do
        # Only release if it was actually in this VPC (NAT GW already gone)
        echo "     Releasing Elastic IP $eip"
        $AWS ec2 release-address --allocation-id "$eip" 2>/dev/null || true
    done

    # ── Load Balancers (ELBv2) ───────────────────────────────────────────────
    local lb_arns
    lb_arns=$($AWS elbv2 describe-load-balancers \
        --query "LoadBalancers[?VpcId=='$vpc_id'].LoadBalancerArn" --output text 2>/dev/null || true)
    for lb in $lb_arns; do
        echo "     Deleting load balancer $lb"
        $AWS elbv2 delete-load-balancer --load-balancer-arn "$lb"
    done
    if [[ -n "$lb_arns" ]]; then
        echo "     Waiting for load balancers to be deleted..."
        $AWS elbv2 wait load-balancers-deleted --load-balancer-arns $lb_arns 2>/dev/null || true
    fi

    # ── Classic Load Balancers ───────────────────────────────────────────────
    local classic_lbs
    classic_lbs=$($AWS elb describe-load-balancers \
        --query "LoadBalancerDescriptions[?VPCId=='$vpc_id'].LoadBalancerName" --output text 2>/dev/null || true)
    for lb in $classic_lbs; do
        echo "     Deleting classic LB $lb"
        $AWS elb delete-load-balancer --load-balancer-name "$lb"
    done

    # ── VPC Endpoints ────────────────────────────────────────────────────────
    # Must be done BEFORE subnets/ENIs: interface endpoints hold ENIs in-use
    # state that prevent subnet and ENI deletion.
    local ep_ids
    ep_ids=$($AWS ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$vpc_id" \
                  "Name=vpc-endpoint-state,Values=available,pending,pending-acceptance,rejected" \
        --query 'VpcEndpoints[*].VpcEndpointId' --output text)
    for ep in $ep_ids; do
        echo "     Deleting VPC endpoint $ep"
        $AWS ec2 delete-vpc-endpoints --vpc-endpoint-ids "$ep" 2>/dev/null || true
    done
    # Poll until all endpoints in this VPC have left (no built-in waiter)
    local ep_wait_secs=0
    while true; do
        local pending_eps
        pending_eps=$($AWS ec2 describe-vpc-endpoints \
            --filters "Name=vpc-id,Values=$vpc_id" \
                      "Name=vpc-endpoint-state,Values=available,pending,pending-acceptance,deleting" \
            --query 'VpcEndpoints[*].VpcEndpointId' --output text)
        [[ -z "$pending_eps" ]] && break
        echo "     Waiting for VPC endpoints to finish deleting ($ep_wait_secs s)..."
        sleep 10
        ep_wait_secs=$((ep_wait_secs + 10))
        if [[ $ep_wait_secs -ge 300 ]]; then
            echo "     WARNING: timed out waiting for VPC endpoints to delete."
            break
        fi
    done

    # ── VPC Peering Connections ──────────────────────────────────────────────
    local peer_ids
    peer_ids=$($AWS ec2 describe-vpc-peering-connections \
        --filters "Name=requester-vpc-info.vpc-id,Values=$vpc_id" \
        --query 'VpcPeeringConnections[*].VpcPeeringConnectionId' --output text)
    for peer in $peer_ids; do
        echo "     Deleting VPC peering $peer"
        $AWS ec2 delete-vpc-peering-connection --vpc-peering-connection-id "$peer" 2>/dev/null || true
    done

    # ── Security Groups (skip default) ───────────────────────────────────────
    # First remove all ingress/egress rules (to break cross-references)
    local sg_ids
    sg_ids=$($AWS ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)
    for sg in $sg_ids; do
        # Strip all ingress rules
        local ingress_rules
        ingress_rules=$($AWS ec2 describe-security-groups --group-ids "$sg" \
            --query 'SecurityGroups[0].IpPermissions' --output json)
        if [[ "$ingress_rules" != "[]" && "$ingress_rules" != "null" ]]; then
            $AWS ec2 revoke-security-group-ingress --group-id "$sg" \
                --ip-permissions "$ingress_rules" 2>/dev/null || true
        fi
        # Strip all egress rules
        local egress_rules
        egress_rules=$($AWS ec2 describe-security-groups --group-ids "$sg" \
            --query 'SecurityGroups[0].IpPermissionsEgress' --output json)
        if [[ "$egress_rules" != "[]" && "$egress_rules" != "null" ]]; then
            $AWS ec2 revoke-security-group-egress --group-id "$sg" \
                --ip-permissions "$egress_rules" 2>/dev/null || true
        fi
    done
    for sg in $sg_ids; do
        echo "     Deleting security group $sg"
        $AWS ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
    done

    # ── Network Interfaces (available, non-endpoint ENIs) ────────────────────
    # Endpoint ENIs are cleaned up automatically once the endpoint is deleted.
    local eni_ids
    eni_ids=$($AWS ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$vpc_id" "Name=status,Values=available" \
        --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text)
    for eni in $eni_ids; do
        echo "     Deleting ENI $eni"
        $AWS ec2 delete-network-interface --network-interface-id "$eni" 2>/dev/null || true
    done

    # ── Subnets ──────────────────────────────────────────────────────────────
    local subnet_ids
    subnet_ids=$($AWS ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'Subnets[*].SubnetId' --output text)
    for subnet in $subnet_ids; do
        echo "     Deleting subnet $subnet"
        $AWS ec2 delete-subnet --subnet-id "$subnet" 2>/dev/null || true
    done

    # ── Route Tables (skip main) ─────────────────────────────────────────────
    local rt_ids
    rt_ids=$($AWS ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text)
    for rt in $rt_ids; do
        # Disassociate first
        local assoc_ids
        assoc_ids=$($AWS ec2 describe-route-tables --route-table-ids "$rt" \
            --query 'RouteTables[0].Associations[*].RouteTableAssociationId' --output text)
        for assoc in $assoc_ids; do
            $AWS ec2 disassociate-route-table --association-id "$assoc" 2>/dev/null || true
        done
        echo "     Deleting route table $rt"
        $AWS ec2 delete-route-table --route-table-id "$rt" 2>/dev/null || true
    done

    # ── Finally: delete the VPC itself ──────────────────────────────────────
    echo "     Deleting VPC $vpc_id"
    $AWS ec2 delete-vpc --vpc-id "$vpc_id"
    echo "  --> VPC $vpc_id deleted."
}

# Try to delete a CloudFormation stack, draining any blocking VPCs on failure.
delete_stack() {
    local stack_name="$1"
    echo ""
    echo "==> Deleting stack: $stack_name"

    $AWS cloudformation update-termination-protection \
        --no-enable-termination-protection \
        --stack-name "$stack_name" 2>/dev/null || true
    $AWS cloudformation delete-stack --stack-name "$stack_name"
    wait_for_stack_delete "$stack_name"

    # Check final status
    local status
    status=$($AWS cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DELETE_COMPLETE")

    if [[ "$status" == "DELETE_COMPLETE" || "$status" == "None" ]]; then
        echo "    Stack '$stack_name' deleted successfully."
        return 0
    fi

    if [[ "$status" == "DELETE_FAILED" ]]; then
        echo "    Stack '$stack_name' DELETE_FAILED. Checking for VPC resources..."

        # Extract VPC IDs from stack resources
        local vpc_ids
        vpc_ids=$($AWS cloudformation describe-stack-resources \
            --stack-name "$stack_name" \
            --query 'StackResources[?ResourceType==`AWS::EC2::VPC`].PhysicalResourceId' \
            --output text 2>/dev/null || true)

        if [[ -z "$vpc_ids" ]]; then
            # Also look for VPCs in the stack events for a hint
            echo "    No VPC resources found in stack. Checking events for clues..."
            $AWS cloudformation describe-stack-events \
                --stack-name "$stack_name" \
                --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
                --output table 2>/dev/null || true
            echo "    Cannot automatically resolve — manual cleanup may be needed."
            return 1
        fi

        for vpc_id in $vpc_ids; do
            drain_vpc "$vpc_id"
        done

        echo "    Retrying delete of stack '$stack_name'..."
        $AWS cloudformation update-termination-protection \
            --no-enable-termination-protection \
            --stack-name "$stack_name" 2>/dev/null || true
        $AWS cloudformation delete-stack --stack-name "$stack_name"
        wait_for_stack_delete "$stack_name"

        status=$($AWS cloudformation describe-stacks \
            --stack-name "$stack_name" \
            --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DELETE_COMPLETE")
        if [[ "$status" == "DELETE_COMPLETE" || "$status" == "None" ]]; then
            echo "    Stack '$stack_name' deleted successfully after VPC drain."
        else
            echo "    ERROR: Stack '$stack_name' still in status '$status' after retry."
            return 1
        fi
    fi
}

# ── main ─────────────────────────────────────────────────────────────────────

echo ""
echo "==> Looking for CloudFormation stacks related to cluster '$CLUSTER_NAME' in $REGION ..."

# eksctl names stacks like:
#   eksctl-<cluster>-cluster
#   eksctl-<cluster>-nodegroup-<name>
# but we match anything containing the cluster name.
STACK_NAMES=$($AWS cloudformation list-stacks \
    --stack-status-filter \
        CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
        ROLLBACK_COMPLETE DELETE_FAILED \
    --query "StackSummaries[?contains(StackName, '$CLUSTER_NAME')].StackName" \
    --output text)

if [[ -z "$STACK_NAMES" ]]; then
    echo "No CloudFormation stacks found containing '$CLUSTER_NAME'. Nothing to do."
    exit 0
fi

echo "Found stacks:"
for s in $STACK_NAMES; do echo "  $s"; done

# Delete nodegroup stacks first, then the cluster stack last.
NODEGROUP_STACKS=()
CLUSTER_STACKS=()
for s in $STACK_NAMES; do
    if echo "$s" | grep -q "nodegroup"; then
        NODEGROUP_STACKS+=("$s")
    else
        CLUSTER_STACKS+=("$s")
    fi
done

for s in "${NODEGROUP_STACKS[@]}"; do
    delete_stack "$s"
done
for s in "${CLUSTER_STACKS[@]}"; do
    delete_stack "$s"
done

echo ""
echo "==> Done."
