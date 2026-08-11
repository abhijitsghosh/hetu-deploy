# hetu-deploy

Public deploy artefacts for **[Hetu](https://github.com/abhijitsghosh/hetu)** — a read-only
AWS IAM permission modeller that runs inside your own AWS account.

This repository is public so the installer can be fetched with `curl`. The application source
is private.

## Install

Run this in [AWS CloudShell](https://console.aws.amazon.com/cloudshell) so it works the same
from Windows, macOS or Linux:

```bash
curl -sL https://raw.githubusercontent.com/abhijitsghosh/hetu-deploy/main/install-aws.sh \
  | bash -s -- --region ap-southeast-2 --admin-email you@org.com
```

One CloudFormation stack: an App Runner service, an RDS Postgres for your saved policy
drafts, a Cognito user pool for sign-in, and a private VPC.

## Upgrade

```bash
curl -sL https://raw.githubusercontent.com/abhijitsghosh/hetu-deploy/main/upgrade-aws.sh \
  | bash -s -- --region ap-southeast-2
```

Rolls App Runner to the latest published image. Your database is untouched and Flyway
migrates on boot, so code and schema move together with no data loss. The stack itself is
never modified, so nothing is recreated and no one gets a fresh empty database.

The bundled AWS action catalog ships inside the image, so an upgrade is also how it is
refreshed — there is no separate data update, and your account still makes no outbound call.

## Remove

```bash
aws cloudformation delete-stack --region ap-southeast-2 --stack-name hetu
```

## What Hetu can do in your account

The instance role is **not** the AWS-managed `ReadOnlyAccess`. It is scoped to authorization
configuration: IAM identities and their policies, Organizations SCPs and RCPs, and the
resource policies on buckets, keys, queues, topics, functions and secrets.

Two exclusions are the point of writing it by hand rather than reaching for a managed policy:
`secretsmanager:GetResourcePolicy` is granted and `GetSecretValue` is not;
`s3:GetBucketPolicy` is granted and `GetObject` is not. Hetu can tell you who *could* read a
secret. It cannot read the secret.

Read [hetu-aws.yaml](hetu-aws.yaml) — the whole grant is in one block, in plain sight.

## Why it installs into your account rather than being a SaaS

Service control policies live in your organisation's management account. Nobody grants a SaaS
vendor cross-account Organizations read, and without SCPs the answer to "can this principal do
that" is wrong in exactly the cases that matter. So the product runs where the data is.

## Files

| File | |
|---|---|
| `install-aws.sh` | One-shot installer, for AWS CloudShell |
| `upgrade-aws.sh` | In-place image roll; preserves the database |
| `hetu-aws.yaml` | The CloudFormation stack |
| `version.json` | Release feed. The app's browser-side update check compares against this, so the tenant itself never calls out. Bumped automatically by the release workflow |

## Status

Pre-release: `version.json` reads `0.0.0` because no container image has been published yet.
Until a release runs, `install-aws.sh` has no image to deploy.
