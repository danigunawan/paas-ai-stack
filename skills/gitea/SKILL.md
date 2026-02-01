---
name: gitea
description: Manage Gitea repositories - create repos, branches, files, PRs, and webhooks.
metadata: {"moltbot":{"emoji":"📦","requires":{"env":["GITEA_TOKEN","GITEA_URL"]}}}
---

# Gitea Repository Management Skill

This skill enables managing Git repositories hosted on Gitea.

## Quick Reference

```bash
# List repositories
curl -s "$GITEA_URL/api/v1/user/repos" \
  -H "Authorization: token $GITEA_TOKEN" | jq '.[] | {name, clone_url}'

# Create repository
curl -X POST "$GITEA_URL/api/v1/user/repos" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "my-repo", "auto_init": true}'
```

**Required env vars**: `GITEA_TOKEN`, `GITEA_URL`

## Repository Operations

### List All Repositories

```bash
curl -s "$GITEA_URL/api/v1/user/repos" \
  -H "Authorization: token $GITEA_TOKEN" | jq '.[] | {name, html_url, clone_url, private}'
```

### Create Repository

```bash
curl -X POST "$GITEA_URL/api/v1/user/repos" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "REPO_NAME",
    "description": "Repository description",
    "private": false,
    "auto_init": true,
    "default_branch": "main"
  }'
```

### Get Repository Details

```bash
curl -s "$GITEA_URL/api/v1/repos/OWNER/REPO" \
  -H "Authorization: token $GITEA_TOKEN" | jq
```

### Delete Repository

```bash
curl -X DELETE "$GITEA_URL/api/v1/repos/OWNER/REPO" \
  -H "Authorization: token $GITEA_TOKEN"
```

## Branch Operations

### List Branches

```bash
curl -s "$GITEA_URL/api/v1/repos/OWNER/REPO/branches" \
  -H "Authorization: token $GITEA_TOKEN" | jq '.[] | .name'
```

### Create Branch

```bash
curl -X POST "$GITEA_URL/api/v1/repos/OWNER/REPO/branches" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "new_branch_name": "feature-branch",
    "old_branch_name": "main"
  }'
```

### Delete Branch

```bash
curl -X DELETE "$GITEA_URL/api/v1/repos/OWNER/REPO/branches/BRANCH_NAME" \
  -H "Authorization: token $GITEA_TOKEN"
```

## File Operations

### Get File Contents

```bash
curl -s "$GITEA_URL/api/v1/repos/OWNER/REPO/contents/PATH/TO/FILE" \
  -H "Authorization: token $GITEA_TOKEN" | jq -r '.content' | base64 -d
```

### Create/Update File

```bash
# Content must be base64 encoded
CONTENT=$(echo -n "file content here" | base64)

curl -X POST "$GITEA_URL/api/v1/repos/OWNER/REPO/contents/PATH/TO/FILE" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"message\": \"Add/update file\",
    \"content\": \"$CONTENT\",
    \"branch\": \"main\"
  }"
```

### Delete File

```bash
curl -X DELETE "$GITEA_URL/api/v1/repos/OWNER/REPO/contents/PATH/TO/FILE" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "message": "Delete file",
    "sha": "FILE_SHA",
    "branch": "main"
  }'
```

## Pull Request Operations

### List Pull Requests

```bash
curl -s "$GITEA_URL/api/v1/repos/OWNER/REPO/pulls" \
  -H "Authorization: token $GITEA_TOKEN" | jq '.[] | {number, title, state}'
```

### Create Pull Request

```bash
curl -X POST "$GITEA_URL/api/v1/repos/OWNER/REPO/pulls" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "PR Title",
    "body": "PR description",
    "head": "feature-branch",
    "base": "main"
  }'
```

### Merge Pull Request

```bash
curl -X POST "$GITEA_URL/api/v1/repos/OWNER/REPO/pulls/PR_NUMBER/merge" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "do": "merge",
    "merge_message_field": "Merge PR #PR_NUMBER"
  }'
```

## Deploy Key Operations (for CI/CD)

Deploy keys allow read-only access to repositories for CI/CD systems like Coolify.

### List Deploy Keys

```bash
curl -sf "$GITEA_URL/api/v1/repos/OWNER/REPO/keys" \
  -H "Authorization: token $GITEA_TOKEN" | jq '.[] | {id, title, read_only}'
```

### Add Deploy Key

```bash
# Generate key pair first
ssh-keygen -t ed25519 -f my-deploy-key -N "" -C "deploy-key"

# Add public key to repository
PUBLIC_KEY=$(cat my-deploy-key.pub)

curl -sf -X POST "$GITEA_URL/api/v1/repos/OWNER/REPO/keys" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"title\": \"coolify-deploy-key\",
    \"key\": \"$PUBLIC_KEY\",
    \"read_only\": true
  }"
```

### Delete Deploy Key

```bash
curl -X DELETE "$GITEA_URL/api/v1/repos/OWNER/REPO/keys/KEY_ID" \
  -H "Authorization: token $GITEA_TOKEN"
```

## Webhook Operations

### List Webhooks

```bash
curl -s "$GITEA_URL/api/v1/repos/OWNER/REPO/hooks" \
  -H "Authorization: token $GITEA_TOKEN" | jq '.[] | {id, type, active, config}'
```

### Create Webhook

```bash
curl -X POST "$GITEA_URL/api/v1/repos/OWNER/REPO/hooks" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "active": true,
    "type": "gitea",
    "config": {
      "url": "https://example.com/webhook",
      "content_type": "json",
      "secret": "your-webhook-secret"
    },
    "events": ["push", "pull_request"],
    "branch_filter": "*"
  }'
```

### Create Webhook for Coolify CI/CD

```bash
# APP_UUID is the Coolify application UUID
# WEBHOOK_SECRET must match manual_webhook_secret_gitea in Coolify app

WEBHOOK_URL="https://coolify.digpulsepi.com/webhooks/source/gitea/events/manual?app=APP_UUID"

curl -X POST "$GITEA_URL/api/v1/repos/OWNER/REPO/hooks" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"active\": true,
    \"type\": \"gitea\",
    \"config\": {
      \"url\": \"$WEBHOOK_URL\",
      \"content_type\": \"json\",
      \"secret\": \"YOUR_WEBHOOK_SECRET\"
    },
    \"events\": [\"push\"],
    \"branch_filter\": \"*\"
  }"
```

### Delete Webhook

```bash
curl -X DELETE "$GITEA_URL/api/v1/repos/OWNER/REPO/hooks/HOOK_ID" \
  -H "Authorization: token $GITEA_TOKEN"
```

## User & Organization

### Get Current User

```bash
curl -s "$GITEA_URL/api/v1/user" \
  -H "Authorization: token $GITEA_TOKEN" | jq '{login, email, is_admin}'
```

### List Organizations

```bash
curl -s "$GITEA_URL/api/v1/user/orgs" \
  -H "Authorization: token $GITEA_TOKEN" | jq '.[] | .username'
```

## Actions (CI/CD)

### List Repository Actions Runs

```bash
curl -s "$GITEA_URL/api/v1/repos/OWNER/REPO/actions/runs" \
  -H "Authorization: token $GITEA_TOKEN" | jq '.workflow_runs[] | {id, status, conclusion}'
```

### List Secrets

```bash
curl -s "$GITEA_URL/api/v1/repos/OWNER/REPO/actions/secrets" \
  -H "Authorization: token $GITEA_TOKEN" | jq '.secrets[] | .name'
```

### Create Secret

```bash
curl -X PUT "$GITEA_URL/api/v1/repos/OWNER/REPO/actions/secrets/SECRET_NAME" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"data": "secret-value"}'
```

## Common Patterns

### Clone URL with Token

```bash
# For private repos, use token in URL
git clone https://TOKEN@${GITEA_URL#https://}/OWNER/REPO.git
```

### Create Repo + Add Workflow

```bash
# 1. Create repo
curl -X POST "$GITEA_URL/api/v1/user/repos" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "my-app", "auto_init": true}'

# 2. Add workflow file
WORKFLOW=$(cat << 'EOF' | base64
name: CI
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "Hello"
EOF
)

curl -X POST "$GITEA_URL/api/v1/repos/OWNER/my-app/contents/.gitea/workflows/ci.yml" \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"message\": \"Add CI workflow\", \"content\": \"$WORKFLOW\"}"
```

## Troubleshooting

### Test API Connection

```bash
curl -s "$GITEA_URL/api/v1/user" \
  -H "Authorization: token $GITEA_TOKEN" -w "\nHTTP: %{http_code}\n"
```

### Check Health

```bash
curl -s "$GITEA_URL/api/healthz"
```

## API Documentation

Full API docs available at: `$GITEA_URL/api/swagger`
