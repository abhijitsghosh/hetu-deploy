#!/usr/bin/env bash
#
# Hetu in-place upgrade for AWS.
#
#   curl -sL https://hetu.run/upgrade.sh | bash -s -- --region ap-southeast-2
#
# Moves the App Runner service to the latest published version. Your RDS database — where the
# saved policy drafts live — is untouched, and the app runs its Flyway migrations on boot, so
# code AND schema upgrade with zero data loss. It deliberately does NOT recreate the
# CloudFormation stack, so nothing is torn down or given a fresh empty database.
#
# The bundled AWS action catalog ships inside the image, so this is also how the catalog is
# refreshed — there is no separate data update, and your account still makes no outbound call.
#
# Designed for AWS CloudShell (works the same from Windows, macOS or Linux) — open
# https://console.aws.amazon.com/cloudshell and run the one-liner above.
#
set -euo pipefail

STACK="hetu"
REGION=""; TARGET=""
IMAGE_REPO="public.ecr.aws/w4o8p5x9/hetu"
VERSION_URLS=(
  "https://hetu.run/version.json"
  "https://raw.githubusercontent.com/abhijitsghosh/hetu-deploy/main/version.json"
)

resolve_version() {
  local v=""
  for url in "${VERSION_URLS[@]}"; do
    v=$(curl -fsS "$url" 2>/dev/null | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [[ -n "$v" && "$v" != "0.0.0" ]] && { echo "$v"; return 0; }
  done
  return 1
}

usage() {
  echo "Usage: upgrade.sh --region <aws-region> [--stack <name>] [--version <x.y.z>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region)  REGION="${2:-}"; shift 2;;
    -s|--stack)   STACK="${2:-}"; shift 2;;
    -v|--version) TARGET="${2:-}"; shift 2;;
    -h|--help)    usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done
[[ -z "$REGION" ]] && usage
aws sts get-caller-identity >/dev/null 2>&1 || { echo "ERROR: not signed in to AWS (CloudShell signs you in automatically)."; exit 1; }

ARN="$(aws cloudformation describe-stack-resources --region "$REGION" --stack-name "$STACK" \
  --query "StackResources[?ResourceType=='AWS::AppRunner::Service'].PhysicalResourceId | [0]" \
  --output text 2>/dev/null || true)"
[[ -z "$ARN" || "$ARN" == "None" ]] && {
  echo "ERROR: App Runner service not found in stack '$STACK' (region $REGION). Is Hetu installed there?"
  exit 1
}

CURRENT="$(aws apprunner describe-service --region "$REGION" --service-arn "$ARN" \
  --query 'Service.SourceConfiguration.ImageRepository.ImageIdentifier' --output text)"
echo "▶ Currently running: ${CURRENT}"

if [[ -z "$TARGET" ]]; then
  TARGET="$(resolve_version)" || { echo "ERROR: could not read the published version feed."; exit 1; }
fi
NEW_IMAGE="${IMAGE_REPO}:${TARGET}"

if [[ "$CURRENT" == "$NEW_IMAGE" ]]; then
  echo "✅ Already on ${TARGET} — nothing to do."
  exit 0
fi

# An install pins an exact version, so moving versions means pointing the service at a new
# tag. update-service replaces the whole SourceConfiguration, so every injected setting — the
# database URL, the Cognito client secret, the Secrets Manager reference — has to be carried
# over explicitly. Read them back and pass them through rather than letting them drop.
echo "▶ Upgrading to ${TARGET}…"
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found (AWS CloudShell has it preinstalled)."; exit 1; }
CONFIG="$(aws apprunner describe-service --region "$REGION" --service-arn "$ARN" \
  --query 'Service.SourceConfiguration' --output json)"
UPDATED="$(jq -c --arg img "$NEW_IMAGE" \
  '.ImageRepository.ImageIdentifier = $img | .AutoDeploymentsEnabled = false' <<< "$CONFIG")"
[[ -n "$UPDATED" && "$UPDATED" != "null" ]] || { echo "ERROR: could not read the service configuration."; exit 1; }

aws apprunner update-service --region "$REGION" --service-arn "$ARN" \
  --source-configuration "$UPDATED" >/dev/null

URL="$(aws apprunner describe-service --region "$REGION" --service-arn "$ARN" \
  --query 'Service.ServiceUrl' --output text)"
echo "▶ Waiting for the new version to become healthy…"
# /actuator/health is the one endpoint left unauthenticated, precisely so the platform (and
# this script) can probe it.
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "https://${URL}/actuator/health" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    RUNNING="$(curl -fsS "https://${URL}/api/meta" 2>/dev/null | sed -n 's/.*"app"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
    echo "✅ Upgraded${RUNNING:+ — now running $RUNNING}. Saved drafts preserved."
    echo "   Open: https://${URL}"
    exit 0
  fi
  sleep 6
done
echo "⚠ Upgrade triggered, but health didn't return 200 in time. Check the App Runner console."
exit 1
