#!/usr/bin/env bash
# list_eks_cloudformation.sh
#
# Lists EKS-related CloudFormation stacks (eksctl-* naming convention).
#
# Usage:
#   ./list_eks_cloudformation.sh --region <region>

set -euo pipefail

REGION=""

usage() {
    echo "Usage: $0 --region <region>" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --region) REGION="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -z "$REGION" ]] && usage

aws --region "$REGION" cloudformation list-stacks \
    --stack-status-filter \
        CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
        ROLLBACK_COMPLETE DELETE_FAILED \
    --query "StackSummaries[?starts_with(StackName, 'eksctl-')].StackName" \
    --output text | tr '\t' '\n'
