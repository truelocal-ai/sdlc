# SDLC - Software Development Lifecycle with Claude Code

A self-hosted GitHub Actions infrastructure that integrates Claude Code AI assistant directly into your development workflow. Simply mention `@claude` in GitHub issues or pull requests, and Claude will autonomously work on your tasks.

## Features

- **AI-Powered Development**: Mention `@claude` in issues or PRs to get AI assistance
- **Self-Hosted Runners**: Run GitHub Actions runners on your own infrastructure
- **Docker-Based**: Containerized solution for easy deployment and scaling
- **Scalable**: Configure multiple parallel runners for concurrent tasks
- **Secure**: Uses GitHub Personal Access Tokens with proper scopes
- **Flexible**: Works with both repository-level and organization-level runners
- **GLM 4.6 Support (Experimental)**: Option to use Z.AI's GLM models as a drop-in replacement

## Prerequisites

- Docker (v20.10 or later)
- docker-compose (v1.29 or later)
- GitHub repository with admin access
- **Either:**
  - Claude Code OAuth token (for standard Anthropic Claude), OR
  - Z.AI API key (for experimental GLM 4.6 support)
- GitHub Personal Access Token with appropriate scopes:
  - For repository runners: `repo` (Full control of private repositories)
  - For organization runners: `admin:org` (Full control of orgs and teams)

## Quick Start

### 1. Initial Setup

Run the setup script to configure your environment:

```bash
./sdlc.sh --setup
```

This will:
- Build the Claude Code Docker container
- Prompt for your GitHub token
- Configure your repository or organization
- Set up runner preferences (prefix, number of runners)
- Create the necessary `.env` configuration file

### 2. Configure GitHub Secrets

In your GitHub repository settings:
1. Go to **Settings → Secrets and variables → Actions**
2. Add the following secret:
   - `CLAUDE_CODE_OAUTH_TOKEN`: Your Claude Code OAuth token

Optional:
   - `GH_PAT`: A GitHub Personal Access Token with `repo` and `workflow` scopes

### 3. Start the Runners

```bash
./sdlc.sh
```

This starts the self-hosted GitHub Actions runners using docker-compose.

### 4. Verify Runners

Check that your runners are online:
1. Go to **Settings → Actions → Runners** in your GitHub repository
2. You should see your configured number of runners (default: 5) online

### 5. Use Claude Code

Create an issue or comment on a PR and mention `@claude` with your request:

```
@claude add unit tests for the authentication module
```

Claude will:
- Create a feature branch following the pattern `issue-{number}-{description}`
- Work on your request autonomously
- Create a pull request with the changes
- Post updates and ask questions as needed

## Usage

### Start Runners

```bash
./sdlc.sh
```

### Stop Runners

```bash
./sdlc.sh --stop
```

### View Runner Status

```bash
cd .github/sdlc/github-runner
docker-compose -p sdlc ps
```

### View Logs

```bash
cd .github/sdlc/github-runner
docker-compose -p sdlc logs -f
```

### Reconfigure

To change your configuration:
1. Delete the existing configuration file:
   ```bash
   rm .github/sdlc/github-runner/.env
   ```
2. Run setup again:
   ```bash
   ./sdlc.sh --setup
   ```

## How It Works

1. **Trigger**: When you mention `@claude` in an issue or PR, the GitHub Actions workflow is triggered
2. **Permission Check**: The workflow verifies the user has write access or higher
3. **Context Extraction**: The workflow extracts the issue/PR context
4. **Claude Execution**: Claude Code runs in a Docker container with access to your repository
5. **Autonomous Work**: Claude analyzes, makes changes, runs tests, and creates pull requests

## Configuration

### Basic Runner Configuration

The `.env` file in `.github/sdlc/github-runner/` contains basic runner settings:

```env
# Your GitHub Personal Access Token
GITHUB_TOKEN=ghp_...

# Repository (owner/repo) or Organization name
GITHUB_REPOSITORY=owner/repo-name

# Runner scope: 'repo' or 'org'
RUNNER_SCOPE=repo

# Prefix for runner names
RUNNER_PREFIX=my-hostname

# Number of parallel runners
RUNNER_REPLICATIONS=5
```

### Advanced Configuration (Router)

Advanced configuration is now managed via a **single GitHub Secret** called `SDLC_RUNNER_CONFIG`. This JSON-based configuration allows you to:

- Configure router settings centrally (GLM, Ollama, OpenRouter, etc. are all configured via router)
- Set **runner-specific configurations** (different configs for different runners)
- Control everything from GitHub without modifying local files

#### Setting Up SDLC_RUNNER_CONFIG

1. Go to your repository: **Settings → Secrets and variables → Actions**
2. Click **New repository secret**
3. Name: `SDLC_RUNNER_CONFIG`
4. Value: JSON configuration (see example below)

#### Configuration Format

```json
{
  "default": {
    "router": {
      "enabled": false,
      "config": {}
    }
  },
  "runners": {
    "my-hostname-gh-runner-*": {
      "router": {
        "enabled": true,
        "config": {
          "Providers": [
            {
              "name": "openrouter",
              "api_base_url": "https://openrouter.ai/api/v1/chat/completions",
              "api_key": "your-api-key",
              "models": ["anthropic/claude-3.5-sonnet"]
            }
          ],
          "Router": {
            "default": "openrouter,anthropic/claude-3.5-sonnet"
          }
        }
      }
    }
  }
}
```

#### Runner-Specific Configuration

The `runners` object allows you to configure different settings per runner. Runner names are matched using patterns:

- **Exact match**: `"my-runner-abc123"` matches exactly that runner
- **Wildcard pattern**: `"my-hostname-gh-runner-*"` matches all runners starting with that prefix

When a job runs, the workflow:
1. Identifies which runner is executing (via `runner.name`)
2. Checks for matching patterns in the `runners` object
3. Merges runner-specific config with defaults
4. Applies the configuration to the Claude Code container

**Example Scenario:**
- Your runners (`my-hostname-gh-runner-*`) use OpenRouter with custom models
- Your partner's runners (`partner-hostname-gh-runner-*`) use GLM 4.6 via router
- Default runners use standard Claude

Each runner automatically gets the correct configuration when it picks up a job!

See `.github/sdlc/config-example.json` for a complete example.

### Model Override in Prompts

You can override the model selection per-request by using `@override=` in your prompt. This allows you to specify which provider/model to use for a specific task.

**Format:**
- `@override=provider` - Uses the first model from the specified provider
- `@override=provider,model` - Uses the specific model from the provider

**Examples:**
```
@claude @override=ollama add unit tests for the authentication module
@claude @override=zai,glm-4.6 review this pull request
@claude @override=openrouter,anthropic/claude-3.5-sonnet refactor this code
```

**How it works:**
1. You include `@override=provider` or `@override=provider,model` in your request
2. The workflow validates that the runner has that provider/model configured
3. If available, it overrides the default router configuration for that request
4. If not available, it falls back to the runner's default configuration

**Notes:**
- The override is validated against the runner's router configuration
- If the runner doesn't have the requested provider/model, it will use the default
- The override only applies to that specific request
- Works with any configured provider (Ollama, GLM, OpenRouter, etc.)

## Router Configuration Examples

The router supports multiple providers. Here are common configuration examples:

### Example 1: Using GLM 4.6 (Z.AI)

```json
{
  "runners": {
    "my-runner-*": {
      "router": {
        "enabled": true,
        "config": {
          "Providers": [
            {
              "name": "zai",
              "api_base_url": "https://api.z.ai/api/anthropic",
              "api_key": "your-zai-api-key",
              "models": ["glm-4.6", "glm-4.5-air"]
            }
          ],
          "Router": {
            "default": "zai,glm-4.6",
            "background": "zai,glm-4.5-air"
          }
        }
      }
    }
  }
}
```

**Getting a Z.AI API Key:**
1. Visit [Z.AI Open Platform](https://z.ai/model-api)
2. Register or login to your account
3. Create an API key in the [API Keys management page](https://z.ai/manage-apikey/apikey-list)

### Example 2: Using Ollama (Local)

For local development with Ollama running on the host:

```json
{
  "runners": {
    "local-dev-gh-runner-*": {
      "router": {
        "enabled": true,
        "config": {
          "Providers": [
            {
              "name": "ollama",
              "api_base_url": "http://host.docker.internal:11434/v1/chat/completions",
              "api_key": "",
              "models": ["llama3.1", "qwen2.5", "deepseek-r1"]
            }
          ],
          "Router": {
            "default": "ollama,llama3.1",
            "background": "ollama,qwen2.5",
            "think": "ollama,deepseek-r1"
          }
        }
      }
    }
  }
}
```

**Note:** Ensure Ollama is running on the host and accessible from the Docker container.

### Example 3: Using OpenRouter

```json
{
  "runners": {
    "my-runner-*": {
      "router": {
        "enabled": true,
        "config": {
          "Providers": [
            {
              "name": "openrouter",
              "api_base_url": "https://openrouter.ai/api/v1/chat/completions",
              "api_key": "your-openrouter-api-key",
              "models": [
                "anthropic/claude-3.5-sonnet",
                "google/gemini-2.5-pro-preview",
                "deepseek/deepseek-chat"
              ]
            }
          ],
          "Router": {
            "default": "openrouter,anthropic/claude-3.5-sonnet",
            "background": "openrouter,deepseek/deepseek-chat",
            "longContext": "openrouter,google/gemini-2.5-pro-preview"
          }
        }
      }
    }
  }
}
```

### Example 4: Using Multiple Providers

Route different tasks to different providers:

```json
{
  "runners": {
    "my-runner-*": {
      "router": {
        "enabled": true,
        "config": {
          "Providers": [
            {
              "name": "openrouter",
              "api_base_url": "https://openrouter.ai/api/v1/chat/completions",
              "api_key": "your-openrouter-key",
              "models": ["anthropic/claude-3.5-sonnet"]
            },
            {
              "name": "deepseek",
              "api_base_url": "https://api.deepseek.com/chat/completions",
              "api_key": "your-deepseek-key",
              "models": ["deepseek-chat", "deepseek-reasoner"]
            }
          ],
          "Router": {
            "default": "openrouter,anthropic/claude-3.5-sonnet",
            "background": "deepseek,deepseek-chat",
            "think": "deepseek,deepseek-reasoner"
          }
        }
      }
    }
  }
}
```

### Router Features

- **Multiple Providers**: Configure OpenRouter, DeepSeek, Ollama, Gemini, Volcengine, SiliconFlow, Z.AI (GLM), and more
- **Intelligent Routing**: Route different task types to different models
- **Runner-Specific**: Different runners can use different router configurations
- **Dynamic Switching**: Switch models on-the-fly using `/model provider,model_name` commands

### Example Use Cases

- **Cost Optimization**: Route simple tasks to cheaper models, complex tasks to premium models
- **Performance Tuning**: Use fast models for background tasks, powerful models for critical work
- **Multi-Provider**: Leverage different providers' strengths for different scenarios
- **Model Testing**: Easily test and compare different models and providers
- **Local Development**: Use Ollama for local testing without API costs

## Project Structure

```
.
├── sdlc.sh                          # Main setup and control script
├── .github/
│   ├── workflows/
│   │   └── claude.yml              # Claude Code workflow
│   └── sdlc/
│       ├── github-runner/          # GitHub Actions runner setup
│       └── claude-code-runner/     # Claude Code container setup
├── LICENSE                         # MIT License
├── README.md                       # This file
└── .gitignore                      # Git ignore patterns
```

## Branch Naming Convention

Claude automatically creates branches following this pattern:
```
issue-{issue-number}-{description}
```

Examples:
- `issue-42-implement-user-auth`
- `issue-123-fix-login-bug`

## Troubleshooting

### Runners not showing up in GitHub

1. Check runner logs:
   ```bash
   cd .github/sdlc/github-runner
   docker-compose -p sdlc logs github-runner
   ```
2. Verify your GitHub token has correct scopes
3. Ensure the repository/organization name is correct in `.env`

### Claude not responding

1. Verify `CLAUDE_CODE_OAUTH_TOKEN` is set in GitHub Secrets
2. Check the workflow run logs in **Actions** tab
3. Ensure you mentioned `@claude` in the issue/PR
4. Verify you have write access or higher to the repository

### Docker build failures

1. Ensure Docker is running:
   ```bash
   docker ps
   ```
2. Rebuild the Claude Code container:
   ```bash
   ./sdlc.sh --setup
   ```

## Security Considerations

- **Tokens**: Store GitHub tokens and Claude OAuth tokens securely in GitHub Secrets
- **Self-Hosted Runners**: Runners have access to your infrastructure; only use in trusted repositories
- **Permissions**: Claude requires write access to make code changes; review all PRs before merging
- **Environment Files**: Never commit `.env` files with sensitive tokens to version control

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

- **Issues**: [GitHub Issues](https://github.com/vgmello/sdlc/issues)
- **Documentation**: This README and inline code comments

## Acknowledgments

- Built with [Claude Code](https://claude.ai/claude-code) by Anthropic
- Uses GitHub Actions self-hosted runners
- Containerized with Docker

---

**Made with ❤️ and AI assistance**
