#!/bin/bash
set -e

# Wait for Docker daemon to be ready (DinD)
echo "Waiting for Docker daemon to be ready..."
for i in {1..30}; do
    if docker info >/dev/null 2>&1; then
        echo "Docker daemon is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "Error: Docker daemon did not become ready in time"
        exit 1
    fi
    echo "Waiting for Docker daemon... (attempt $i/30)"
    sleep 2
done

# Check required environment variables
if [ -z "$GITHUB_TOKEN" ]; then
    echo "Error: GITHUB_TOKEN environment variable is required"
    exit 1
fi

if [ -z "$GITHUB_REPOSITORY" ]; then
    echo "Error: GITHUB_REPOSITORY environment variable is required"
    exit 1
fi

# Extract unique identifier from container ID (last 6 characters)
CONTAINER_ID=$(hostname)
UNIQUE_ID=$(echo "$CONTAINER_ID" | tail -c 7 | head -c 6)  # Get last 6 chars

# Build runner name: {prefix}-gh-runner-{unique-id} or gh-runner-{unique-id} if prefix is empty
if [ -z "$RUNNER_PREFIX" ]; then
    RUNNER_NAME="gh-runner-${UNIQUE_ID}"
else
    RUNNER_NAME="${RUNNER_PREFIX}-gh-runner-${UNIQUE_ID}"
fi

if [ -z "$RUNNER_WORKDIR" ]; then
    RUNNER_WORKDIR="_work"
fi

if [ -z "$RUNNER_LABELS" ]; then
    RUNNER_LABELS="self-hosted,linux,docker"
fi

# Default to repo scope if not specified
if [ -z "$RUNNER_SCOPE" ]; then
    RUNNER_SCOPE="repo"
fi

echo "Configuring GitHub Actions Runner..."
if [ "$RUNNER_SCOPE" = "org" ]; then
    echo "Organization: $GITHUB_REPOSITORY"
    echo "Scope: Organization-level runner"
else
    echo "Repository: $GITHUB_REPOSITORY"
    echo "Scope: Repository-level runner"
fi
echo "Runner Name: $RUNNER_NAME"
echo "Runner Labels: $RUNNER_LABELS"

# Get registration token based on scope
if [ "$RUNNER_SCOPE" = "org" ]; then
    # Organization-level runner
    API_URL="https://api.github.com/orgs/${GITHUB_REPOSITORY}/actions/runners/registration-token"
    RUNNER_URL="https://github.com/${GITHUB_REPOSITORY}"
else
    # Repository-level runner
    API_URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runners/registration-token"
    RUNNER_URL="https://github.com/${GITHUB_REPOSITORY}"
fi

REGISTRATION_TOKEN=$(curl -s -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "${API_URL}" | jq -r .token)

if [ -z "$REGISTRATION_TOKEN" ] || [ "$REGISTRATION_TOKEN" = "null" ]; then
    echo "Error: Failed to get registration token"
    echo "API URL: ${API_URL}"
    echo "Make sure your token has the correct permissions:"
    if [ "$RUNNER_SCOPE" = "org" ]; then
        echo "  - For organization runners: 'admin:org' scope"
    else
        echo "  - For repository runners: 'repo' scope with admin access"
    fi
    exit 1
fi

# Remove any existing runner configuration (in case of container restart)
if [ -f ".runner" ]; then
    echo "Existing runner configuration found, removing..."
    ./config.sh remove --token "${REGISTRATION_TOKEN}" 2>/dev/null || true
    rm -f .runner .credentials .credentials_rsaparams
fi

# Configure the runner
./config.sh \
    --url "${RUNNER_URL}" \
    --token "${REGISTRATION_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --work "${RUNNER_WORKDIR}" \
    --labels "${RUNNER_LABELS}" \
    --unattended \
    --replace

# Cleanup function
cleanup() {
    echo "Removing runner..."
    ./config.sh remove --token "${REGISTRATION_TOKEN}"
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Start the runner
echo "Starting GitHub Actions Runner..."
./run.sh & wait $!
