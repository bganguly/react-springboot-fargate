#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/opt/local/bin:$PATH"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REGION="${REGION:-us-east-1}"
BACKEND_STACK="${BACKEND_STACK:-aws-springboot-backend}"
APPRUNNER_STACK="${APPRUNNER_STACK:-aws-springboot-apprunner}"
ADMIN_STACK="${ADMIN_STACK:-aws-springboot-admin}"
FRONTEND_STACK="${FRONTEND_STACK:-aws-springboot-frontend}"
ECR_REPO="aws-springboot-jobs"

ACCOUNT_ID=""
IMAGE_URI=""
API_HTTPS_URL=""
ADMIN_API_URL=""
_GH_REPO=""
_DEPLOY_TAG=""

# ── Credentials ───────────────────────────────────────────────────────────────

_check_credentials() {
  echo "[1/5] Checking AWS credentials..."
  aws sts get-caller-identity >/dev/null 2>&1 || { echo "  Run: aws configure"; exit 1; }
  ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
  printf '  Credentials valid: %s\n' "$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"

  _GH_REPO="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null \
    | sed 's|.*github\.com[:/]\(.*\)\.git$|\1|; s|.*github\.com[:/]\(.*\)$|\1|')"
  if command -v gh >/dev/null 2>&1 && [[ -n "$_GH_REPO" ]]; then
    printf '  Syncing AWS credentials to GitHub Actions secrets (%s)...\n' "$_GH_REPO"
    aws configure get aws_access_key_id     | gh secret set AWS_ACCESS_KEY_ID     --repo "$_GH_REPO"
    aws configure get aws_secret_access_key | gh secret set AWS_SECRET_ACCESS_KEY --repo "$_GH_REPO"
    printf '%s' "$REGION"                   | gh secret set AWS_REGION            --repo "$_GH_REPO"
  fi
}

# ── ECR ───────────────────────────────────────────────────────────────────────

_ecr_image_exists() {
  aws ecr describe-images \
    --repository-name "$ECR_REPO" \
    --image-ids "imageTag=$1" \
    --region "$REGION" >/dev/null 2>&1
}

_ensure_ecr() {
  SITE_BUCKET_NAME="${SITE_BUCKET_NAME:-aws-springboot-frontend-${ACCOUNT_ID}-${REGION}}"

  echo ""
  echo "[2/5] Provisioning ECR repository..."
  aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$ECR_REPO" --region "$REGION" >/dev/null
  printf '  ECR repo ready.\n'
}

_wait_for_image() {
  echo ""
  echo "[3/5] Verifying ECR image..."
  _REMOTE_SHA="$(git -C "$ROOT_DIR" ls-remote origin HEAD 2>/dev/null | cut -c1-7)"
  _DEPLOY_TAG="${_REMOTE_SHA:-$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "latest")}"

  printf '  Checking ECR for image %s...\n' "$_DEPLOY_TAG"
  if ! _ecr_image_exists "$_DEPLOY_TAG"; then
    printf '  Waiting for GitHub Actions to build image %s (up to 15 min)...\n' "$_DEPLOY_TAG"
    _ecr_elapsed=0
    until _ecr_image_exists "$_DEPLOY_TAG"; do
      if (( _ecr_elapsed >= 900 )); then
        printf '  Timed out. Check Actions: https://github.com/%s/actions\n' "$_GH_REPO"
        exit 1
      fi
      sleep 15; _ecr_elapsed=$(( _ecr_elapsed + 15 ))
      printf '  ...%ds\n' "$_ecr_elapsed"
    done
  fi
  printf '  Image %s found in ECR.\n' "$_DEPLOY_TAG"

  IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:${_DEPLOY_TAG}"
}

# ── Backend: App Runner ───────────────────────────────────────────────────────

_deploy_apprunner() {
  aws cloudformation deploy \
    --template-file "${ROOT_DIR}/artifacts/aws/apprunner.yaml" \
    --stack-name "${APPRUNNER_STACK}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "${REGION}" \
    --parameter-overrides ContainerImage="${IMAGE_URI}"

  API_HTTPS_URL="$(aws cloudformation describe-stacks \
    --region "${REGION}" --stack-name "${APPRUNNER_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='AppRunnerUrl'].OutputValue" --output text)"

  _AR_ARN="$(aws cloudformation describe-stacks \
    --region "${REGION}" --stack-name "${APPRUNNER_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='ServiceArn'].OutputValue" --output text 2>/dev/null || true)"
  if [[ -n "$_AR_ARN" ]]; then
    aws apprunner start-deployment --service-arn "$_AR_ARN" --region "$REGION" >/dev/null 2>&1 || true
  fi
  printf '  App Runner live: %s\n' "$API_HTTPS_URL"
}

# ── Backend: ALB + ECS Fargate ────────────────────────────────────────────────

_resolve_vpc() {
  if [[ -z "${VPC_ID:-}" || -z "${SUBNET_A:-}" || -z "${SUBNET_B:-}" ]]; then
    _STACK_PARAMS="$(aws cloudformation describe-stacks \
      --stack-name "$BACKEND_STACK" --region "$REGION" \
      --query 'Stacks[0].Parameters' --output json 2>/dev/null || echo '[]')"
    _stack_param() { printf '%s' "$_STACK_PARAMS" | python3 -c \
      "import sys,json; p={x['ParameterKey']:x['ParameterValue'] for x in json.load(sys.stdin)}; print(p.get('$1',''))" 2>/dev/null; }
    VPC_ID="${VPC_ID:-$(_stack_param VpcId)}"
    SUBNET_A="${SUBNET_A:-$(_stack_param PublicSubnetA)}"
    SUBNET_B="${SUBNET_B:-$(_stack_param PublicSubnetB)}"
  fi

  if [[ -z "${VPC_ID:-}" ]]; then
    VPC_ID="$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
      --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null)"
    [[ "$VPC_ID" == "None" ]] && VPC_ID=""
  fi

  if [[ -z "${VPC_ID:-}" ]]; then
    VPC_ID="$(aws ec2 describe-vpcs \
      --query 'Vpcs[*].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output text --region "$REGION" 2>/dev/null \
      | sort -t$'\t' -k2 | head -1 | cut -f1)"
  fi

  [[ -z "${VPC_ID:-}" ]] && { echo "Error: no VPC found. Set VPC_ID manually."; exit 1; }

  if [[ -z "${SUBNET_A:-}" || -z "${SUBNET_B:-}" ]]; then
    mapfile -t _SUBNETS < <(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
      --query 'Subnets[*].SubnetId' --output text --region "$REGION" 2>/dev/null | tr '\t' '\n')
    [[ ${#_SUBNETS[@]} -lt 2 ]] && { echo "Error: need at least 2 public subnets in $VPC_ID."; exit 1; }
    SUBNET_A="${_SUBNETS[0]}"
    SUBNET_B="${_SUBNETS[1]}"
  fi

  printf '  VPC: %s  Subnets: %s, %s\n' "$VPC_ID" "$SUBNET_A" "$SUBNET_B"
}

_deploy_alb_fargate() {
  _resolve_vpc

  aws cloudformation deploy \
    --template-file "${ROOT_DIR}/artifacts/aws/infra.yaml" \
    --stack-name "${BACKEND_STACK}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "${REGION}" \
    --parameter-overrides VpcId="${VPC_ID}" PublicSubnetA="${SUBNET_A}" PublicSubnetB="${SUBNET_B}" ContainerImage="${IMAGE_URI}"

  API_HTTPS_URL="$(aws cloudformation describe-stacks \
    --region "${REGION}" --stack-name "${BACKEND_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='ApiHttpsUrl'].OutputValue" --output text)"

  _CLUSTER_NAME="$(aws cloudformation describe-stacks \
    --region "${REGION}" --stack-name "${BACKEND_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue" --output text)"
  _SERVICE_NAME="$(aws cloudformation describe-stacks \
    --region "${REGION}" --stack-name "${BACKEND_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='ServiceName'].OutputValue" --output text)"
  _ALB_FULL_NAME="$(aws cloudformation describe-stacks \
    --region "${REGION}" --stack-name "${BACKEND_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerFullName'].OutputValue" --output text)"

  aws cloudformation deploy \
    --template-file "${ROOT_DIR}/artifacts/aws/admin-lambdas.yaml" \
    --stack-name "${ADMIN_STACK}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "${REGION}" \
    --parameter-overrides ClusterName="${_CLUSTER_NAME}" ServiceName="${_SERVICE_NAME}" LoadBalancerFullName="${_ALB_FULL_NAME}"

  ADMIN_API_URL="$(aws cloudformation describe-stacks \
    --region "${REGION}" --stack-name "${ADMIN_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='AdminApiUrl'].OutputValue" --output text)"
}

# ── Backend: menu ─────────────────────────────────────────────────────────────

_deploy_backend() {
  echo ""
  echo "[4/5] Deploying backend..."

  printf '\n'
  printf '  Option A — App Runner  (~$6/mo · 0.5 vCPU / 1 GB · DynamoDB + SQS included)\n'
  printf '  Deploy App Runner backend? [y/N]: '
  read -r _DEPLOY_AR

  printf '\n'
  printf '  Option B — Original showcase: ALB + ECS Fargate + Lambda start/stop\n'
  printf '  WARNING: ~$21/mo idle  (ALB $16.21 always-on + VPC IPs $4.53 + Fargate ~$6.80 when running)\n'
  printf '  Provision ALB + Fargate stack? [y/N]: '
  read -r _DEPLOY_ALB

  if [[ "${_DEPLOY_AR:-N}" =~ ^[Yy]$ && "${_DEPLOY_ALB:-N}" =~ ^[Yy]$ ]]; then
    printf '  Both selected — App Runner takes precedence. Answer y to only one option.\n'
    _DEPLOY_ALB=N
  fi

  if [[ "${_DEPLOY_AR:-N}" =~ ^[Yy]$ ]]; then
    _deploy_apprunner
  elif [[ "${_DEPLOY_ALB:-N}" =~ ^[Yy]$ ]]; then
    _deploy_alb_fargate
  else
    printf '  Skipping backend — frontend will deploy without API URL.\n'
  fi
}

# ── Frontend ──────────────────────────────────────────────────────────────────

_deploy_frontend() {
  echo ""
  echo "[5/5] Deploying frontend (CloudFormation + S3 sync)..."
  aws cloudformation deploy \
    --template-file "${ROOT_DIR}/artifacts/aws/frontend-infra.yaml" \
    --stack-name "${FRONTEND_STACK}" \
    --region "${REGION}" \
    --parameter-overrides SiteBucketName="${SITE_BUCKET_NAME}"

  DISTRIBUTION_ID="$(aws cloudformation describe-stacks \
    --region "${REGION}" --stack-name "${FRONTEND_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue" --output text)"

  FRONTEND_URL="$(aws cloudformation describe-stacks \
    --region "${REGION}" --stack-name "${FRONTEND_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='FrontendUrl'].OutputValue" --output text)"

  local ENV_FILE="${ROOT_DIR}/frontend/.env.production.local"
  trap 'rm -f "${ENV_FILE}"' EXIT
  printf 'VITE_API_BASE_URL=%s\nVITE_ADMIN_API_URL=%s\n' "${API_HTTPS_URL}" "${ADMIN_API_URL:-}" > "${ENV_FILE}"
  npm --prefix "${ROOT_DIR}/frontend" install
  npm --prefix "${ROOT_DIR}/frontend" run build
  aws s3 sync "${ROOT_DIR}/frontend/dist" "s3://${SITE_BUCKET_NAME}" --delete --region "${REGION}"
  aws cloudfront create-invalidation --distribution-id "${DISTRIBUTION_ID}" --paths "/*" >/dev/null

  echo ""
  echo "[deploy] Done."
  printf '  API:      %s\n' "$API_HTTPS_URL"
  printf '  Frontend: %s\n' "$FRONTEND_URL"
}

# ── Main ──────────────────────────────────────────────────────────────────────

_check_credentials
_ensure_ecr
_wait_for_image
_deploy_backend
_deploy_frontend
