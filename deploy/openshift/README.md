# AgentReady OpenShift/Kubernetes Job

Run AgentReady assessments in a Kubernetes or OpenShift cluster without building a custom image.

Uses `registry.access.redhat.com/ubi9/python-312:latest` directly — Python 3.12, pip, and git are pre-installed. The latest AgentReady is fetched from PyPI at job startup.

## Quick Start

```bash
# 1. Create the ConfigMap from the entrypoint script
kubectl create configmap agentready-entrypoint \
  --from-file=entrypoint.sh=deploy/openshift/entrypoint.sh

# 2. Edit job.yaml — set REPO_URL to your target repository
#    Then apply:
kubectl apply -f deploy/openshift/job.yaml

# 3. Watch the logs
kubectl logs -f job/agentready-assess
```

## Private Repositories

Create a Secret with your git token, then the Job picks it up automatically:

```bash
# GitHub (Personal Access Token)
kubectl create secret generic agentready-git-credentials \
  --from-literal=token=ghp_xxxxxxxxxxxx

# GitLab (Project or Personal Access Token)
kubectl create secret generic agentready-git-credentials \
  --from-literal=token=glpat-xxxxxxxxxxxx
```

The token is injected into the clone URL as `https://oauth2:<token>@...` and never logged.

## S3 Upload

Set `S3_BUCKET` in the Job manifest to enable uploading results. All three output formats (JSON, HTML, Markdown) are uploaded.

### AWS S3

```bash
kubectl create secret generic agentready-s3-credentials \
  --from-literal=aws-access-key-id=AKIA... \
  --from-literal=aws-secret-access-key=...
```

Then set in `job.yaml`:

```yaml
- name: S3_BUCKET
  value: "my-bucket"
```

### MinIO / OpenShift Data Foundation

```bash
kubectl create secret generic agentready-s3-credentials \
  --from-literal=aws-access-key-id=minioadmin \
  --from-literal=aws-secret-access-key=minioadmin
```

Then set in `job.yaml`:

```yaml
- name: S3_BUCKET
  value: "agentready-reports"
- name: S3_ENDPOINT
  value: "http://minio.minio-ns.svc.cluster.local:9000"
```

Results are uploaded to: `s3://<bucket>/<S3_PREFIX><repo-name>/<timestamp>/`

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `REPO_URL` | Yes | — | Git repository URL to assess |
| `REPO_BRANCH` | No | default branch | Branch to clone |
| `REPO_DEPTH` | No | `1` | Git clone depth (shallow) |
| `OUTPUT_FORMAT` | No | `json` | Format for stdout output: `json`, `html`, `markdown` |
| `GIT_TOKEN` | No | — | Auth token for private repos (from Secret) |
| `S3_BUCKET` | No | — | S3 bucket name (enables upload) |
| `S3_ENDPOINT` | No | — | Custom S3 endpoint for MinIO/ODF |
| `S3_PREFIX` | No | `agentready/` | S3 key prefix |
| `AWS_ACCESS_KEY_ID` | No | — | S3 credentials (from Secret) |
| `AWS_SECRET_ACCESS_KEY` | No | — | S3 credentials (from Secret) |
| `AWS_DEFAULT_REGION` | No | `us-east-1` | AWS region |

## Retrieving Results

**From pod logs:**

```bash
kubectl logs job/agentready-assess
```

The assessment summary table is always printed. The full report in `OUTPUT_FORMAT` is appended after the summary.

**From S3:**

```bash
aws s3 ls s3://my-bucket/agentready/my-repo/
aws s3 cp s3://my-bucket/agentready/my-repo/20260507-143022/report-20260507-143022.html .
```

## Re-running

Job names must be unique in Kubernetes. Delete the old Job before re-running:

```bash
kubectl delete job agentready-assess
kubectl apply -f deploy/openshift/job.yaml
```

Or use `generateName` instead of `name` in the Job metadata for unique names per run.

## OpenShift Notes

- Works under the default `restricted` SCC — no elevated privileges needed
- UBI9 images handle arbitrary UIDs assigned by OpenShift
- Use `oc` in place of `kubectl` for all commands above

## Troubleshooting

**Git clone fails with "Authentication failed"**
- Verify the token is valid: `kubectl get secret agentready-git-credentials -o yaml`
- For GitHub, ensure the token has `repo` scope

**Job killed (OOMKilled)**
- Increase memory limit in `job.yaml` for very large repositories
- Check: `kubectl describe pod -l app.kubernetes.io/name=agentready`

**"dubious ownership" git error**
- The entrypoint script sets `safe.directory` automatically. If you see this error, verify the entrypoint ConfigMap is mounted correctly

**Large repo aborts (>10,000 files)**
- The CLI prompts for confirmation on large repos and aborts in non-interactive mode. Consider using `--exclude` to skip expensive assessors, or clone with a narrower scope
