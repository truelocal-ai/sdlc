#!/bin/bash
set -e

echo "=== Claude Code Runner Entrypoint ==="

# Load nvm to ensure node/npm are available
export NVM_DIR="/home/claude/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# Ensure npm global bin directory is in PATH
if command -v npm > /dev/null 2>&1; then
    NPM_GLOBAL_BIN=$(npm root -g)/../bin
    export PATH="$NPM_GLOBAL_BIN:$PATH"
fi

# Required environment variables
: "${GITHUB_TOKEN:?Error: GITHUB_TOKEN is required}"
: "${GITHUB_REPOSITORY:?Error: GITHUB_REPOSITORY is required}"
: "${CLAUDE_CODE_OAUTH_TOKEN:?Error: CLAUDE_CODE_OAUTH_TOKEN is required}"

# Optional environment variables with defaults
GITHUB_REF="${GITHUB_REF:-}"  # If empty, will use default branch
CLAUDE_BRANCH_NAME="${CLAUDE_BRANCH_NAME:?Error: CLAUDE_BRANCH_NAME is required}"
USER_PROMPT="${USER_PROMPT:?Error: USER_PROMPT is required}"

# Validate CLAUDE_BRANCH_NAME is not just "claude--"
if [[ "$CLAUDE_BRANCH_NAME" == "claude--" ]] || [[ "$CLAUDE_BRANCH_NAME" =~ ^claude--$ ]]; then
    echo ""
    echo "=========================================="
    echo "ERROR: Invalid CLAUDE_BRANCH_NAME"
    echo "=========================================="
    echo ""
    echo "CLAUDE_BRANCH_NAME is set to: '$CLAUDE_BRANCH_NAME'"
    echo ""
    echo "This indicates that the issue/PR number was not properly extracted."
    echo "The branch name should be in format: claude-{type}-{number}"
    echo "  Examples: claude-issue-123, claude-pr-456"
    echo ""
    echo "Possible causes:"
    echo "  1. Workflow context extraction failed"
    echo "  2. Issue/PR number is missing from the event"
    echo "  3. Environment variable not properly passed to Docker"
    echo ""
    echo "=========================================="
    echo ""
    exit 1
fi

# Workspace directories
WORKSPACE_DIR="/workspace"
CLAUDE_STATE_DIR="/home/claude/.claude/projects/-workspace"
CLAUDE_OUTPUT_FILE="/tmp/claude-output.txt"

# Function to commit and push Claude state changes
commit_claude_state() {
    cd "$CLAUDE_STATE_DIR"
    
    if [[ -n $(git status -s) ]]; then
        echo "Changes detected in Claude state"
        git add .
        git commit -m "Claude Code state update" 2>&1 | grep -v "x-access-token" || true
        git push -u origin "$CLAUDE_BRANCH_NAME" 2>&1 | grep -v "x-access-token" || true
        echo "Claude state committed and pushed to branch: $CLAUDE_BRANCH_NAME"
    fi
}

# Background function to periodically commit Claude state
background_commit_loop() {
    while true; do
        sleep 30
        commit_claude_state
    done
}

echo "Configuration:"
echo "  Repository: $GITHUB_REPOSITORY"
echo "  GitHub Ref: ${GITHUB_REF:-<default branch>}"
echo "  Claude Branch: $CLAUDE_BRANCH_NAME"
echo ""

# Setup git credentials
echo "=== Setting up Git credentials ==="
git config --global credential.helper store
echo "https://x-access-token:${GITHUB_TOKEN}@github.com" > /home/claude/.git-credentials
git config --global user.name "github-actions[bot]"
git config --global user.email "github-actions[bot]@users.noreply.github.com"
echo "Git credentials configured"
echo ""

# Setup Claude state directory and clone/create branch
echo "=== Setting up Claude state branch ==="
mkdir -p "$(dirname "$CLAUDE_STATE_DIR")"

if git ls-remote --heads "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$CLAUDE_BRANCH_NAME" 2>&1 | grep -v "x-access-token" | grep -q "$CLAUDE_BRANCH_NAME"; then
    echo "Claude branch exists, cloning: $CLAUDE_BRANCH_NAME"
    git clone --depth 1 --branch "$CLAUDE_BRANCH_NAME" "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$CLAUDE_STATE_DIR" 2>&1 | grep -v "x-access-token" || true
else
    echo "Claude branch does not exist, creating: $CLAUDE_BRANCH_NAME"
    git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$CLAUDE_STATE_DIR" 2>&1 | grep -v "x-access-token" || true
    cd "$CLAUDE_STATE_DIR"
    git checkout -b "$CLAUDE_BRANCH_NAME"
fi

echo "Claude state directory: $CLAUDE_STATE_DIR"
echo ""

# Navigate to workspace directories
cd "$WORKSPACE_DIR"

# Clone main repository
echo "=== Cloning main repository ==="
if [ -n "$GITHUB_REF" ]; then
    echo "Cloning with specific ref: $GITHUB_REF"
    git clone --depth 1 --branch "$GITHUB_REF" "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$WORKSPACE_DIR" 2>&1 | grep -v "x-access-token" || true
else
    echo "Cloning default branch"
    git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$WORKSPACE_DIR" 2>&1 | grep -v "x-access-token" || true
fi

echo "Repository cloned to: $WORKSPACE_DIR"
echo ""

# Configure Claude Code Router if enabled
USE_ROUTER="${USE_ROUTER:-false}"
MODEL_OVERRIDE="${MODEL_OVERRIDE:-}"
ROUTER_CONFIG_DIR="/home/claude/.claude-code-router"
ROUTER_CONFIG_FILE="$ROUTER_CONFIG_DIR/config.json"
CLAUDE_CMD="claude"

if [ "$USE_ROUTER" = "true" ]; then
    echo "=== Configuring Claude Code Router ==="
    
    # Create router config directory
    mkdir -p "$ROUTER_CONFIG_DIR"
    
    # Write router configuration
    # Decode base64-encoded ROUTER_CONFIG if provided, otherwise use ROUTER_CONFIG directly
    if [ -n "$ROUTER_CONFIG_B64" ]; then
        echo "Using provided router configuration from ROUTER_CONFIG_B64 (base64 encoded)"
        ROUTER_CONFIG=$(echo "$ROUTER_CONFIG_B64" | base64 -d 2>/dev/null)
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to decode ROUTER_CONFIG_B64"
            exit 1
        fi
    fi
    
    if [ -n "$ROUTER_CONFIG" ]; then
        echo "Using provided router configuration from ROUTER_CONFIG environment variable"
        
        # Validate JSON before writing to file
        if ! echo "$ROUTER_CONFIG" | jq empty > /dev/null 2>&1; then
            echo "ERROR: ROUTER_CONFIG is not valid JSON"
            echo "First 200 chars of config:"
            echo "$ROUTER_CONFIG" | head -c 200
            exit 1
        fi
        
        echo "$ROUTER_CONFIG" > "$ROUTER_CONFIG_FILE"
        
        # Apply model override if specified
        if [ -n "$MODEL_OVERRIDE" ]; then
            echo "Applying model override: $MODEL_OVERRIDE"
            # Update the Router.default field with the override
            if ! jq --arg override "$MODEL_OVERRIDE" '.Router.default = $override' "$ROUTER_CONFIG_FILE" > "$ROUTER_CONFIG_FILE.tmp" 2>/dev/null; then
                echo "ERROR: Failed to apply model override to router config"
                echo "Config file content (first 200 chars):"
                head -c 200 "$ROUTER_CONFIG_FILE"
                exit 1
            fi
            mv "$ROUTER_CONFIG_FILE.tmp" "$ROUTER_CONFIG_FILE"
            echo "✓ Router default model set to: $MODEL_OVERRIDE"
        fi
    else
        echo "WARNING: USE_ROUTER is true but ROUTER_CONFIG is not set"
        echo "Creating default router configuration. Please configure providers and models."
        # Create a minimal default config
        jq -n '{
            "Providers": [],
            "Router": {
                "default": "anthropic,claude-3.5-sonnet"
            }
        }' > "$ROUTER_CONFIG_FILE"
    fi
    
    # Validate router config file
    if [ ! -s "$ROUTER_CONFIG_FILE" ]; then
        echo "ERROR: Failed to create router configuration file"
        exit 1
    fi
    
    # Validate JSON syntax
    if ! jq empty "$ROUTER_CONFIG_FILE" 2>/dev/null; then
        echo "ERROR: Invalid JSON in router configuration"
        exit 1
    fi
    
    # Use ccr (claude-code-router) command instead of claude
    CLAUDE_CMD="ccr code"
    
    echo "Claude Code Router configuration complete"
    echo "  - Config file: $ROUTER_CONFIG_FILE"
    echo "  - Using command: $CLAUDE_CMD"
    if [ -n "$MODEL_OVERRIDE" ]; then
        echo "  - Model override: $MODEL_OVERRIDE"
    fi
    echo ""
else
    echo "=== Router Support Disabled ==="
    echo "Using standard Claude Code CLI directly (Anthropic)."
    echo ""
fi

# Prepare prompts
echo "=== Preparing prompts ==="

# System prompt - read from repo
SYSTEM_PROMPT_FILE="$WORKSPACE_DIR/.github/sdlc/claude-system-prompt.md"

if [ -f "$SYSTEM_PROMPT_FILE" ]; then
    echo "System prompt found at: $SYSTEM_PROMPT_FILE"
    SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")
else
    echo ""
    echo "=========================================="
    echo "WARNING: No system prompt file found!"
    echo "=========================================="
    echo ""
    echo "Expected location: $SYSTEM_PROMPT_FILE"
    echo ""
    echo "Using default system prompt instead."
    echo "For better results, create a system prompt file with:"
    echo "  - Project context and guidelines"
    echo "  - Coding standards and conventions"
    echo "  - Repository structure information"
    echo ""
    echo "=========================================="
    echo ""
    SYSTEM_PROMPT="You are Claude Code, an AI assistant helping with software development tasks."
fi

# User prompt - passed via environment variable
echo "User prompt provided via USER_PROMPT environment variable"
echo ""

# Start background commit loop
echo "=== Starting background state commit loop ==="
background_commit_loop &
BACKGROUND_PID=$!
echo "Background commit process started (PID: $BACKGROUND_PID)"

# Trap to ensure background process is killed on exit
trap "kill $BACKGROUND_PID 2>/dev/null || true" EXIT
echo ""

# Run Claude Code
echo "=== Running Claude Code ==="
echo "Working directory: $(pwd)"
echo ""

# Build claude command
# Note: If router is enabled, CLAUDE_CMD is already set to "ccr code"
# The router command doesn't support all flags, so we adjust accordingly
if [ "$USE_ROUTER" = "true" ]; then
    # ccr code doesn't support --dangerously-skip-permissions flag
    # Split the command into array: "ccr code" becomes ["ccr", "code"]
    # Note: ccr might not support --system-prompt, so we'll pass it via stdin or env
    CLAUDE_ARGS=(ccr code --continue --print)
    
    # For ccr, system prompt might need to be passed differently
    # Try passing it as an environment variable or skip it if not supported
    if [ -n "$SYSTEM_PROMPT" ]; then
        # Some versions of ccr support --system-prompt, others don't
        # We'll try it and let it fail gracefully if not supported
        CLAUDE_ARGS+=(--system-prompt "$SYSTEM_PROMPT")
    fi
else
    CLAUDE_ARGS=(claude --continue --print --dangerously-skip-permissions)
    
    # Add system prompt for standard claude
    if [ -n "$SYSTEM_PROMPT" ]; then
        CLAUDE_ARGS+=(--system-prompt "$SYSTEM_PROMPT")
    fi
fi

# Verify ccr is available if using router
if [ "$USE_ROUTER" = "true" ]; then
    if ! command -v ccr > /dev/null 2>&1; then
        echo "ERROR: ccr command not found in PATH"
        echo "PATH: $PATH"
        echo "npm root -g: $(npm root -g 2>/dev/null || echo 'npm not available')"
        which ccr || echo "ccr not found"
        exit 1
    fi
    echo "✓ ccr command found: $(which ccr)"
fi

# Run Claude with user prompt via stdin, capture output
set +e
echo "$USER_PROMPT" | "${CLAUDE_ARGS[@]}" 2>&1 | tee "$CLAUDE_OUTPUT_FILE"
CLAUDE_EXIT_CODE=${PIPESTATUS[0]}
set -e

echo ""
echo "Claude Code exit code: $CLAUDE_EXIT_CODE"
echo ""

# Post response as GitHub comment
echo "=== Posting response to GitHub ==="

if [ ! -s "$CLAUDE_OUTPUT_FILE" ]; then
    echo "Error: Claude Code did not produce output" > "$CLAUDE_OUTPUT_FILE"
fi

COMMENT_BODY=$(jq -n \
    --arg output "$(cat "$CLAUDE_OUTPUT_FILE")" \
    --arg actor "$GITHUB_ACTOR" \
    --arg type "$ISSUE_TYPE" \
    --arg number "$ISSUE_NUMBER" \
    '{
        body: ("## Claude Code Response\n\n" + $output + "\n\n---\n*Triggered by @" + $actor + " on " + $type + " #" + $number + "*")
    }')

curl -sS -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/issues/$ISSUE_NUMBER/comments" \
    -d "$COMMENT_BODY"

echo "Comment posted successfully"
echo ""

# Final commit and push Claude state changes
echo "=== Final commit of Claude state changes ==="
commit_claude_state
echo ""

echo "=== Claude Code Runner Complete ==="
exit $CLAUDE_EXIT_CODE
