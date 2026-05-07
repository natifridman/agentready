#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:?REPO_URL is required}"
REPO_BRANCH="${REPO_BRANCH:-}"
REPO_DEPTH="${REPO_DEPTH:-1}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-json}"
S3_BUCKET="${S3_BUCKET:-}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_PREFIX="${S3_PREFIX:-agentready/}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

CLONE_DIR="/tmp/repo"
OUTPUT_DIR="/tmp/output"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
START_TIME="$(date +%s)"

export GIT_TERMINAL_PROMPT=0

log() { echo "[agentready-job $(date +%H:%M:%S)] $*"; }

# --- Install agentready ---
log "Installing agentready from PyPI..."
PIP_PACKAGES="agentready"
if [[ -n "${S3_BUCKET}" ]]; then
    PIP_PACKAGES="${PIP_PACKAGES} boto3"
fi
pip install --no-cache-dir --quiet ${PIP_PACKAGES}
log "Installed: $(agentready --version)"

# --- Clone repository ---
REPO_NAME="$(basename "${REPO_URL}" .git)"

CLONE_URL="${REPO_URL}"
if [[ -n "${GIT_TOKEN:-}" ]]; then
    CLONE_URL="${REPO_URL/https:\/\//https://oauth2:${GIT_TOKEN}@}"
fi

CLONE_ARGS=(clone --depth "${REPO_DEPTH}")
if [[ -n "${REPO_BRANCH}" ]]; then
    CLONE_ARGS+=(--branch "${REPO_BRANCH}")
fi

log "Cloning ${REPO_URL} (depth=${REPO_DEPTH})..."
git "${CLONE_ARGS[@]}" "${CLONE_URL}" "${CLONE_DIR}"
git config --global safe.directory "${CLONE_DIR}"

HEAD_SHA="$(git -C "${CLONE_DIR}" rev-parse --short HEAD)"
log "Cloned ${REPO_NAME} at ${HEAD_SHA}"

# --- Run assessment ---
mkdir -p "${OUTPUT_DIR}"
log "Running assessment..."
agentready assess "${CLONE_DIR}" --output-dir "${OUTPUT_DIR}"

# --- Output to stdout ---
case "${OUTPUT_FORMAT}" in
    json)     cat "${OUTPUT_DIR}/assessment-latest.json" ;;
    html)     cat "${OUTPUT_DIR}/report-latest.html" ;;
    markdown) cat "${OUTPUT_DIR}/report-latest.md" ;;
    *)        log "Unknown OUTPUT_FORMAT: ${OUTPUT_FORMAT}"; cat "${OUTPUT_DIR}/assessment-latest.json" ;;
esac

# --- S3 upload (optional) ---
if [[ -n "${S3_BUCKET}" ]]; then
    log "Uploading results to s3://${S3_BUCKET}/${S3_PREFIX}${REPO_NAME}/${TIMESTAMP}/..."
    python3 -c "
import boto3, os, glob

endpoint = os.environ.get('S3_ENDPOINT')
kwargs = {'endpoint_url': endpoint} if endpoint else {}
s3 = boto3.client('s3', region_name='${AWS_DEFAULT_REGION}', **kwargs)

bucket = '${S3_BUCKET}'
prefix = '${S3_PREFIX}${REPO_NAME}/${TIMESTAMP}'
output_dir = '${OUTPUT_DIR}'

files = {
    'assessment-latest.json': 'application/json',
    'report-latest.html': 'text/html',
    'report-latest.md': 'text/markdown',
}

for filename, content_type in files.items():
    filepath = os.path.join(output_dir, filename)
    if os.path.exists(filepath):
        # Follow symlinks to get the timestamped filename
        real_name = os.path.basename(os.path.realpath(filepath))
        key = f'{prefix}/{real_name}'
        s3.upload_file(filepath, bucket, key, ExtraArgs={'ContentType': content_type})
        print(f'  Uploaded s3://{bucket}/{key}')
"
    log "S3 upload complete"
fi

ELAPSED=$(( $(date +%s) - START_TIME ))
log "Done in ${ELAPSED}s"
