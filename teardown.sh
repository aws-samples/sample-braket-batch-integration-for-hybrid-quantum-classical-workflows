#!/usr/bin/env bash
#
# teardown.sh — tear down the AFQMC Braket-Batch sample.
#
# Order of operations:
#   1. Empty the two ECR repositories (delete all images).
#   2. Delete all objects from the S3 data bucket.
#   3. Delete the three CloudFormation stacks in REVERSE order of creation.
#
# Steps 1 and 2 are required because CloudFormation refuses to delete an
# ECR repository that still contains images, or an S3 bucket that still
# contains objects — so we clear them first.
#
# Prerequisites: AWS CLI v2, configured credentials with permission to
# delete these resources, and jq is NOT required (pure AWS CLI).
#
# Usage:
#   ./teardown.sh [-r REGION] [-y]
#     -r REGION   AWS region (default: current CLI region, else us-east-1)
#     -y          Skip the confirmation prompt (non-interactive)
#
set -euo pipefail

# ---- Configuration -------------------------------------------------------

# Stack names, in CREATION order (see README and lab-1 / lab-3 notebooks).
STACK_INFRA="AFQMC-labs-infrastructure"   # basic-infrastructure.yaml  (created first)
STACK_BATCH="batch-environment"           # batch-environment.yaml     (created second)
STACK_WORKFLOW="braket-batch-workflow"    # hybrid-workflow.yaml        (created last)

# ECR repositories created by the batch-environment stack.
ECR_REPOS=(
  "amazon-braket-batch-tutorial-batch"
  "amazon-braket-batch-tutorial-lambda"
)

# ---- Parse arguments -----------------------------------------------------

REGION=""
ASSUME_YES="false"
while getopts ":r:y" opt; do
  case "${opt}" in
    r) REGION="${OPTARG}" ;;
    y) ASSUME_YES="true" ;;
    *) echo "Usage: $0 [-r REGION] [-y]" >&2; exit 2 ;;
  esac
done

# Resolve region: explicit flag > configured default > us-east-1.
if [[ -z "${REGION}" ]]; then
  REGION="$(aws configure get region 2>/dev/null || true)"
fi
REGION="${REGION:-us-east-1}"

# Resolve account id (used to build the S3 bucket name).
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# The DataBucket name is !Sub amazon-braket-batch-tutorial-${AWS::AccountId}-${AWS::Region}
DATA_BUCKET="amazon-braket-batch-tutorial-${ACCOUNT_ID}-${REGION}"

echo "============================================================"
echo " AFQMC Braket-Batch sample teardown"
echo "   Account : ${ACCOUNT_ID}"
echo "   Region  : ${REGION}"
echo "   Bucket  : ${DATA_BUCKET}"
echo "   ECR     : ${ECR_REPOS[*]}"
echo "   Stacks  : ${STACK_WORKFLOW}  ->  ${STACK_BATCH}  ->  ${STACK_INFRA}  (delete order)"
echo "============================================================"

if [[ "${ASSUME_YES}" != "true" ]]; then
  read -r -p "This will DELETE the resources above. Type 'yes' to continue: " reply
  [[ "${reply}" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

# ---- Helpers -------------------------------------------------------------

# Does a CloudFormation stack exist (in a non-deleted state)?
stack_exists() {
  local name="$1"
  aws cloudformation describe-stacks \
    --stack-name "${name}" --region "${REGION}" >/dev/null 2>&1
}

# ---- 1. Empty the two ECR repositories -----------------------------------

echo
echo "--- Step 1: Emptying ECR repositories ---"
for repo in "${ECR_REPOS[@]}"; do
  if ! aws ecr describe-repositories \
        --repository-names "${repo}" --region "${REGION}" >/dev/null 2>&1; then
    echo "  [skip] repository '${repo}' not found."
    continue
  fi

  # List every image (tagged and untagged) as imageDigest=... tuples.
  # list-images returns both tagged and untagged images.
  mapfile -t IMAGE_IDS < <(
    aws ecr list-images \
      --repository-name "${repo}" --region "${REGION}" \
      --query 'imageIds[*].imageDigest' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d'
  )

  if [[ "${#IMAGE_IDS[@]}" -eq 0 ]]; then
    echo "  [ok]   '${repo}' already empty."
    continue
  fi

  echo "  Deleting ${#IMAGE_IDS[@]} image(s) from '${repo}'..."
  # batch-delete-image accepts up to 100 imageIds per call; chunk to be safe.
  for ((i = 0; i < ${#IMAGE_IDS[@]}; i += 100)); do
    chunk=("${IMAGE_IDS[@]:i:100}")
    ids=""
    for digest in "${chunk[@]}"; do
      ids+="imageDigest=${digest} "
    done
    # shellcheck disable=SC2086
    aws ecr batch-delete-image \
      --repository-name "${repo}" --region "${REGION}" \
      --image-ids ${ids} >/dev/null
  done
  echo "  [ok]   '${repo}' emptied."
done

# ---- 2. Delete all objects from the S3 data bucket -----------------------

echo
echo "--- Step 2: Emptying S3 bucket ---"
if aws s3api head-bucket --bucket "${DATA_BUCKET}" --region "${REGION}" >/dev/null 2>&1; then
  # Remove current objects (recursive).
  echo "  Removing objects from s3://${DATA_BUCKET} ..."
  aws s3 rm "s3://${DATA_BUCKET}" --recursive --region "${REGION}" >/dev/null || true

  # If the bucket ever had versioning enabled, purge versions + delete markers
  # so the bucket can be deleted by CloudFormation. (No-op on unversioned buckets.)
  versions="$(aws s3api list-object-versions \
      --bucket "${DATA_BUCKET}" --region "${REGION}" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
      --output json 2>/dev/null || echo '{"Objects":null}')"
  if [[ "${versions}" != '{"Objects":null}' && "${versions}" != '{"Objects":[]}' ]]; then
    echo "  Removing object versions ..."
    aws s3api delete-objects --bucket "${DATA_BUCKET}" --region "${REGION}" \
      --delete "${versions}" >/dev/null 2>&1 || true
  fi

  markers="$(aws s3api list-object-versions \
      --bucket "${DATA_BUCKET}" --region "${REGION}" \
      --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
      --output json 2>/dev/null || echo '{"Objects":null}')"
  if [[ "${markers}" != '{"Objects":null}' && "${markers}" != '{"Objects":[]}' ]]; then
    echo "  Removing delete markers ..."
    aws s3api delete-objects --bucket "${DATA_BUCKET}" --region "${REGION}" \
      --delete "${markers}" >/dev/null 2>&1 || true
  fi
  echo "  [ok]   s3://${DATA_BUCKET} emptied."
else
  echo "  [skip] bucket '${DATA_BUCKET}' not found."
fi

# ---- 3. Delete the three CloudFormation stacks in reverse order ----------

echo
echo "--- Step 3: Deleting CloudFormation stacks (reverse order) ---"
for stack in "${STACK_WORKFLOW}" "${STACK_BATCH}" "${STACK_INFRA}"; do
  if ! stack_exists "${stack}"; then
    echo "  [skip] stack '${stack}' not found."
    continue
  fi
  echo "  Deleting stack '${stack}' ..."
  aws cloudformation delete-stack --stack-name "${stack}" --region "${REGION}"
  echo "  Waiting for '${stack}' to be deleted ..."
  if aws cloudformation wait stack-delete-complete \
        --stack-name "${stack}" --region "${REGION}"; then
    echo "  [ok]   stack '${stack}' deleted."
  else
    echo "  [ERROR] stack '${stack}' did not reach DELETE_COMPLETE."
    echo "          Check the CloudFormation console for the failure reason"
    echo "          (a resource may still be in use or require manual cleanup)."
    exit 1
  fi
done

echo
echo "============================================================"
echo " Teardown complete."
echo "============================================================"
