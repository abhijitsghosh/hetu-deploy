#!/usr/bin/env bash
#
# Hetu one-shot installer for AWS.
#
# Designed for AWS CloudShell, so it works the same from Windows, macOS or Linux —
# open https://console.aws.amazon.com/cloudshell and run:
#
#   curl -sL https://raw.githubusercontent.com/abhijitsghosh/hetu-deploy/main/install-aws.sh | bash -s -- --region ap-southeast-2
#
# What this installs, and what it can do:
#   * Everything in ONE CloudFormation stack you can inspect or delete as a unit: an
#     App Runner service, an RDS Postgres holding your saved policy drafts, a Cognito
#     user pool for sign-in, and a private VPC for the database.
#   * The service's role is scoped to reading *authorization configuration* — IAM
#     identities and their policies, the organisation's SCPs and RCPs, and the resource
#     policies on buckets, keys, queues, topics, functions and secrets. It is deliberately
#     NOT the managed ReadOnlyAccess policy: Hetu can tell you who could read a secret,
#     but it cannot read the secret. It never writes to your account.
#
# Hetu runs in your account rather than as a SaaS because service control policies live
# in your organisation's management account. Without them, "can this principal do that" is
# wrong in exactly the cases that matter — so the product goes where the data is.
#
# App Runner (rather than ECS behind a load balancer) because it gives a managed HTTPS
# endpoint with no certificate or domain of your own — and Cognito will not accept a
# plain-HTTP callback URL.
#
# Prerequisites:
#   * Permission to create CloudFormation stacks, IAM roles, RDS, Cognito and App Runner.
#
set -euo pipefail

STACK="hetu"
REGION=""; IMAGE=""; IMAGE_TYPE="ECR_PUBLIC"; DB_PASSWORD=""; ADMIN_EMAIL=""
# Published image. App Runner cannot pull from GHCR, so AWS installs use ECR Public.
DEFAULT_IMAGE="public.ecr.aws/w4o8p5x9/hetu:latest"

usage() {
  echo "Usage: install-aws.sh --region <aws-region> [--stack <name>] [--image <uri>] [--image-type ECR|ECR_PUBLIC] [--admin-email <you@org.com>] [--db-password <pw>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region)      REGION="${2:-}"; shift 2;;
    -s|--stack)       STACK="${2:-}"; shift 2;;
    -i|--image)       IMAGE="${2:-}"; shift 2;;
    --image-type)     IMAGE_TYPE="${2:-}"; shift 2;;
    -e|--admin-email) ADMIN_EMAIL="${2:-}"; shift 2;;
    -p|--db-password) DB_PASSWORD="${2:-}"; shift 2;;
    -h|--help)        usage;;
    *) echo "Unknown option: $1"; usage;;
  esac
done
[[ -z "$REGION" ]] && usage
[[ -z "$IMAGE" ]] && IMAGE="$DEFAULT_IMAGE"

command -v aws >/dev/null 2>&1 || { echo "ERROR: AWS CLI not found. Run this in AWS CloudShell."; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || { echo "ERROR: not signed in to AWS."; exit 1; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "▶ Installing Hetu into AWS account: $ACCOUNT (region $REGION)"
echo "  stack: $STACK   image: $IMAGE"
[[ -z "$DB_PASSWORD" ]] && DB_PASSWORD="Ad$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 22)9"

TEMPLATE_URL="https://raw.githubusercontent.com/abhijitsghosh/hetu-deploy/main/hetu-aws.yaml"
TEMPLATE=$(mktemp); curl -sL "$TEMPLATE_URL" -o "$TEMPLATE"

# ---------- [1/3] Stack ----------
echo "▶ [1/3] Deploying the stack — 10–15 min (the database is the slow part)…"
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides ContainerImage="$IMAGE" ImageRepositoryType="$IMAGE_TYPE" \
                        DbPassword="$DB_PASSWORD" \
  --no-fail-on-empty-changeset
rm -f "$TEMPLATE"

out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
          --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
APP_URL=$(out AppUrl); POOL_ID=$(out UserPoolId); CLIENT_ID=$(out UserPoolClientId)
echo "    app url: $APP_URL"

# ---------- [2/3] Sign-in callback ----------
# Only known once App Runner has a hostname, so it is set after the stack. Spring's OAuth2
# client uses /login/oauth2/code/{registrationId}, and the OIDC registration id is "oidc".
echo "▶ [2/3] Registering the sign-in callback…"
aws cognito-idp update-user-pool-client \
  --region "$REGION" --user-pool-id "$POOL_ID" --client-id "$CLIENT_ID" \
  --callback-urls "$APP_URL/login/oauth2/code/oidc" \
  --logout-urls "$APP_URL" \
  --allowed-o-auth-flows code --allowed-o-auth-scopes openid profile email \
  --allowed-o-auth-flows-user-pool-client \
  --supported-identity-providers COGNITO >/dev/null

# ---------- [3/3] First operator ----------
echo "▶ [3/3] Inviting the first operator…"
if [[ -n "$ADMIN_EMAIL" ]]; then
  aws cognito-idp admin-create-user --region "$REGION" --user-pool-id "$POOL_ID" \
    --username "$ADMIN_EMAIL" --user-attributes Name=email,Value="$ADMIN_EMAIL" \
                                                Name=email_verified,Value=true \
    --desired-delivery-mediums EMAIL >/dev/null 2>&1 \
    && echo "    invited $ADMIN_EMAIL (check your inbox for the temporary password)" \
    || echo "    (user already exists)"
else
  echo "    no --admin-email given. Invite yourself with:"
  echo "      aws cognito-idp admin-create-user --region $REGION --user-pool-id $POOL_ID \\"
  echo "        --username you@org.com --user-attributes Name=email,Value=you@org.com \\"
  echo "        Name=email_verified,Value=true --desired-delivery-mediums EMAIL"
fi

cat <<EOF

✅ Hetu is installed — everything is in CloudFormation stack '$STACK'.

   Open:   $APP_URL
   Sign in with the Cognito account invited above.

   Hetu holds a read-only, policy-configuration-scoped role in this account —
   not ReadOnlyAccess. It reads who can do what; it never changes anything, and it
   never reads the contents of your data.

   Upgrade later (rolls the image, keeps your saved drafts):
     curl -sL https://raw.githubusercontent.com/abhijitsghosh/hetu-deploy/main/upgrade-aws.sh | bash -s -- --region $REGION

   Tear down later (removes the whole stack in one go):
     aws cloudformation delete-stack --region $REGION --stack-name $STACK
EOF
