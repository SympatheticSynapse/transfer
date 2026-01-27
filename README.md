# Renovate Local Testing Environment

Test your Renovate configuration changes locally using Docker Compose with Gitea as a local Git host.

## Quick Start

**Note:** This setup works with both Docker and Podman. Use `docker-compose`/`docker compose` or `podman-compose`/`podman compose` depending on your setup.

### 1. Initial Setup

```bash
# Make scripts executable
chmod +x setup.sh mirror-repo.sh

# Run setup
./setup.sh
```

### 2. Create Gitea User

```bash
# For Docker
docker exec -u git -it gitea gitea admin user create \
  --username renovate-test \
  --password password123 \
  --email test@renovate.local \
  --admin

# For Podman with podman-compose
podman-compose exec -u git gitea gitea admin user create \
  --username renovate-test \
  --password password123 \
  --email test@renovate.local \
  --admin

# For Podman with podman compose
podman compose exec -u git gitea gitea admin user create \
  --username renovate-test \
  --password password123 \
  --email test@renovate.local \
  --admin
```

### 3. Generate API Token

The setup script automatically creates a user and generates an API token, saving it to your `.env` file.

If you need to manually generate a token:
1. Visit http://localhost:3000
2. Login with `renovate-test` / `password123`
3. Go to Settings → Applications → Generate Token
4. Copy the token and add to `.env`: `GITEA_TOKEN=your-token`

### 4. Mirror Your Git Repositories

```bash
# Single repo
./mirror-repo.sh https://bitbucket.com/scm/PROJECT/repo-name.git

# Multiple repos (can be from different projects)
./mirror-repo.sh \
  https://bitbucket.com/scm/PROJ1/repo1.git \
  https://bitbucket.com/scm/PROJ2/repo2.git \
  git@bitbucket.org:workspace/repo3.git
```

The script automatically updates your `.env` file with the mirrored repositories.

### 5. Configure Private Registries (Optional)

For private Nexus Docker registries, add to `.env`:
```bash
NEXUS_HOST=nexus.example.com
NEXUS_USERNAME=your-username
NEXUS_PASSWORD=your-password
```

For Bitbucket preset access, add to `.env`:
```bash
BITBUCKET_USERNAME=your-username
BITBUCKET_APP_PASSWORD=your-app-password
```

### 6. Run Renovate

```bash
# Dry run (shows what would happen)
docker-compose up renovate
# or
podman-compose up renovate

# View logs
docker-compose logs -f renovate

# Run again after changes
docker-compose up renovate --force-recreate
```

### 7. Test Configuration Changes

1. Make changes to `renovate.json` in your mirrored repo in Gitea
2. Commit changes in Gitea UI or push locally
3. Re-run Renovate: `docker-compose up renovate --force-recreate`
4. Check logs and PRs

### 8. Create Actual PRs (when ready)

```bash
# Update .env
DRY_RUN=null

# Run Renovate
docker-compose up renovate
```

## Useful Commands

```bash
# Start only Gitea
docker-compose up -d gitea

# Run Renovate with fresh logs
docker-compose up renovate --force-recreate

# Stop everything
docker-compose down

# Clean up everything (including all named volumes)
docker-compose down -v

# View Renovate logs
docker-compose logs -f renovate

# Access Gitea container
docker exec -it gitea sh
```

## Directory Structure

```
.
├── docker-compose.yml       # Docker/Podman Compose configuration
├── .env                     # Environment variables (create from .env.example)
├── .env.example            # Example environment file
├── setup.sh                # Setup script (auto-detects Docker/Podman)
└── mirror-repo.sh          # Repo mirroring script
```

**Note:** Both Gitea data and Renovate cache use Docker/Podman managed named volumes, avoiding permission issues entirely.

## Testing Workflow

1. **Make changes** to `renovate.json` in Gitea
2. **Run Renovate** in dry-run mode: `docker-compose up renovate`
3. **Check logs** for what PRs would be created
4. **Iterate** on your configuration
5. **Test actual PR creation** by setting `DRY_RUN=null`
6. **Apply to production** once satisfied

## Multiple Repositories

The mirror script and Renovate support multiple repositories:

```bash
# Mirror multiple repos
./mirror-repo.sh repo1.git repo2.git repo3.git

# Renovate will process all repos listed in .env:
REPOSITORIES=proj1/repo1,proj2/repo2,proj1/repo3
```

## Troubleshooting

### Gitea not starting
```bash
docker-compose logs gitea
```

### Renovate not finding repositories
- Ensure GITEA_TOKEN is correct in .env
- Check repository name format: `owner/repo-name`
- Verify repo exists in Gitea

### Changes not detected
- Commit changes in Gitea
- Use `--force-recreate` when running renovate
- Check renovate.json syntax is valid

### Private registry authentication issues
- Check NO_PROXY includes your registry host
- Verify credentials with: `docker exec renovate sh -c 'curl -u "$NEXUS_USERNAME:$NEXUS_PASSWORD" https://$NEXUS_HOST/v2/_catalog'`
- Check Renovate logs for host rule matching: `docker-compose logs renovate | grep -i hostrule`

## Advanced Configuration

For complex configurations, you can create a `renovate-config.js` file and mount it in the compose file. See [Renovate docs](https://docs.renovatebot.com/) for all options.
