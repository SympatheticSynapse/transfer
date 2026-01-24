#!/bin/bash

# Script to mirror one or more Git repos to Gitea
set -e

# Load environment variables from .env if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Configuration
GITEA_URL="http://localhost:3000"
GITEA_USER="${GITEA_USER:-renovate-test}"
GITEA_TOKEN="${GITEA_TOKEN:-}"

# Check if token is provided
if [ -z "$GITEA_TOKEN" ]; then
    echo "Error: GITEA_TOKEN not set"
    echo "Make sure .env file exists with GITEA_TOKEN, or run:"
    echo "GITEA_TOKEN=xxx ./mirror-repo.sh <git-clone-url> [git-clone-url2] ..."
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: ./mirror-repo.sh <git-clone-url> [git-clone-url2] [git-clone-url3] ..."
    echo "Example: ./mirror-repo.sh git@bitbucket.org:workspace/repo1.git https://bitbucket.org/workspace/repo2.git"
    echo ""
    echo "Or provide a file with one URL per line:"
    echo "./mirror-repo.sh @repos.txt"
    exit 1
fi

# Detect if using podman or docker
if command -v podman &> /dev/null; then
    DOCKER_CMD="podman"
elif command -v docker &> /dev/null; then
    DOCKER_CMD="docker"
else
    echo "Error: Neither docker nor podman found"
    exit 1
fi

# Function to extract repo name from git URL
extract_repo_name() {
    local url="$1"
    # Remove .git suffix and extract last part
    basename "$url" .git
}

# Function to extract org/workspace from git URL
extract_org_name() {
    local url="$1"
    # Handle different URL formats
    if [[ "$url" =~ git@[^:]+:([^/]+)/ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$url" =~ https?://[^/]+/([^/]+)/ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$GITEA_USER"
    fi
}

# Function to mirror a single repository
mirror_repo() {
    local GIT_URL="$1"
    local GITEA_ORG="${2:-$(extract_org_name "$GIT_URL")}"
    local REPO_NAME=$(extract_repo_name "$GIT_URL")

    echo ""
    echo "=== Mirroring Repository ==="
    echo "Source: $GIT_URL"
    echo "Gitea Org: $GITEA_ORG"
    echo "Repo Name: $REPO_NAME"
    echo ""

    # Clone from source
    TEMP_DIR="/tmp/renovate-mirror-$$-$(date +%s)"

    echo "Cloning from source..."
    if ! git clone --bare "$GIT_URL" "$TEMP_DIR" 2>&1; then
        echo "Error: Failed to clone $GIT_URL"
        return 1
    fi

    # Create organization if it doesn't exist (and it's not the user)
    if [ "$GITEA_ORG" != "$GITEA_USER" ]; then
        echo "Creating organization: $GITEA_ORG"
        curl -X POST "${GITEA_URL}/api/v1/orgs" \
            -H "Authorization: token ${GITEA_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"${GITEA_ORG}\"}" \
            2>/dev/null || echo "(Organization may already exist)"
    fi

    # Create repo in Gitea
    echo "Creating repo in Gitea..."
    if [ "$GITEA_ORG" != "$GITEA_USER" ]; then
        API_ENDPOINT="${GITEA_URL}/api/v1/org/${GITEA_ORG}/repos"
    else
        API_ENDPOINT="${GITEA_URL}/api/v1/user/repos"
    fi

    curl -X POST "$API_ENDPOINT" \
        -H "Authorization: token ${GITEA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\":\"${REPO_NAME}\",
            \"private\":false,
            \"auto_init\":false
        }" 2>/dev/null || echo "(Repo may already exist)"

    # Push to Gitea
    GITEA_REPO_URL="${GITEA_URL}/${GITEA_ORG}/${REPO_NAME}.git"
    echo "Pushing to Gitea..."
    cd "$TEMP_DIR"

    # Use token auth for push
    GITEA_AUTH_URL="http://${GITEA_USER}:${GITEA_TOKEN}@localhost:3000/${GITEA_ORG}/${REPO_NAME}.git"
    if git push --mirror "$GITEA_AUTH_URL" 2>&1; then
        echo "✓ Successfully mirrored: ${GITEA_ORG}/${REPO_NAME}"
    else
        echo "✗ Failed to mirror: ${GITEA_ORG}/${REPO_NAME}"
        cd /
        rm -rf "$TEMP_DIR"
        return 1
    fi

    # Cleanup
    cd /
    rm -rf "$TEMP_DIR"

    # Add to repos list
    MIRRORED_REPOS+=("${GITEA_ORG}/${REPO_NAME}")
}

# Parse arguments
REPOS=()
GITEA_ORG_OVERRIDE=""

for arg in "$@"; do
    if [[ "$arg" == @* ]]; then
        # Read from file
        REPOS_FILE="${arg:1}"
        if [ ! -f "$REPOS_FILE" ]; then
            echo "Error: File not found: $REPOS_FILE"
            exit 1
        fi
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            REPOS+=("$line")
        done < "$REPOS_FILE"
    else
        REPOS+=("$arg")
    fi
done

# Mirror all repositories
MIRRORED_REPOS=()
FAILED_COUNT=0

for repo_url in "${REPOS[@]}"; do
    if ! mirror_repo "$repo_url" "$GITEA_ORG_OVERRIDE"; then
        ((FAILED_COUNT++))
    fi
done

# Summary
echo ""
echo "=== Mirror Summary ==="
echo "Total attempted: ${#REPOS[@]}"
echo "Successful: $((${#REPOS[@]} - FAILED_COUNT))"
echo "Failed: $FAILED_COUNT"
echo ""

if [ ${#MIRRORED_REPOS[@]} -gt 0 ]; then
    echo "Mirrored repositories:"
    for repo in "${MIRRORED_REPOS[@]}"; do
        echo "  - ${GITEA_URL}/${repo}"
    done
    echo ""

    # Generate comma-separated list for .env
    REPO_LIST=$(IFS=,; echo "${MIRRORED_REPOS[*]}")
    echo "Add to your .env file:"
    echo "REPOSITORIES=${REPO_LIST}"
    echo ""

    # Offer to update .env automatically
    if [ -f .env ] && [ ${#MIRRORED_REPOS[@]} -gt 0 ]; then
        read -p "Update .env with these repositories? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if grep -q "^REPOSITORIES=" .env; then
                sed -i "s|^REPOSITORIES=.*|REPOSITORIES=${REPO_LIST}|" .env
            else
                echo "REPOSITORIES=${REPO_LIST}" >> .env
            fi
            echo "✓ Updated .env file"
        fi
    fi
fi

echo "Then run: docker-compose up renovate"
