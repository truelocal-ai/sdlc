# Docker-in-Docker (DinD) Security Implementation

## Overview

This implementation uses Docker-in-Docker (DinD) instead of mounting the host's Docker socket to improve security isolation for GitHub Actions runners.

## Security Improvements

### Previous Approach (Socket Mounting)
- **Risk**: Mounting `/var/run/docker.sock` gave containers root-equivalent access to the host
- **Attack Vector**: Compromised runner could break out of container and access host system
- **Blast Radius**: Full host compromise possible

### Current Approach (Docker-in-Docker)
- **Isolation**: Separate Docker daemon runs inside a privileged container
- **Containment**: Even if runner is compromised, attacker only accesses the DinD daemon, not the host
- **Blast Radius**: Limited to DinD container and its child containers

## Architecture

```
┌─────────────────────────────────────────┐
│           Host System                    │
│                                          │
│  ┌────────────────────────────────────┐ │
│  │  DinD Container (privileged)       │ │
│  │  ┌──────────────────────────────┐  │ │
│  │  │   Docker Daemon (isolated)   │  │ │
│  │  └──────────────────────────────┘  │ │
│  │         ▲                           │ │
│  │         │ TCP:2376 (TLS)            │ │
│  │         │                           │ │
│  │  ┌──────┴───────────────────────┐  │ │
│  │  │  Runner Containers (x5)      │  │ │
│  │  │  - No host socket access     │  │ │
│  │  │  - Connect via network       │  │ │
│  │  └──────────────────────────────┘  │ │
│  └────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

## Components

### 1. DinD Service (`docker:27-dind`)
- Runs Docker daemon in a container
- **Privileged**: Required for nested containerization
- **TLS-enabled**: Secure communication between runner and daemon
- **Isolated storage**: Separate volume for Docker data

### 2. GitHub Runner Service
- Connects to DinD daemon via TCP (port 2376)
- Uses TLS certificates for authentication
- No direct access to host Docker socket
- Runs as non-root `runner` user

## Configuration

### Environment Variables
- `DOCKER_HOST=tcp://dind:2376` - Points to DinD daemon
- `DOCKER_TLS_VERIFY=1` - Enables TLS verification
- `DOCKER_CERT_PATH=/certs/client` - Path to TLS certificates

### Volumes
- `docker-certs`: Shared TLS certificates between DinD and runners
- `dind-storage`: Persistent storage for Docker images/containers

## Trade-offs

### Advantages
✅ Better isolation from host system
✅ Attackers cannot directly access host Docker daemon
✅ Blast radius limited to DinD container
✅ Easier to monitor/audit container activity

### Considerations
⚠️ DinD container still requires `privileged` mode
⚠️ Additional resource overhead (separate daemon)
⚠️ Slightly more complex setup
⚠️ Shared kernel with host (use VMs for full isolation)

## Further Security Enhancements

For even stronger security, consider:

1. **Rootless Docker**: Run Docker daemon without root privileges
2. **Podman**: Daemonless container runtime (no privileged container needed)
3. **Sysbox Runtime**: Enhanced container-in-container isolation
4. **VM-based Runners**: Full kernel isolation (e.g., Firecracker, gVisor)

## Testing

To verify the DinD setup:

```bash
# Stop existing runners
./sdlc.sh --stop

# Rebuild with new configuration
./sdlc.sh --setup

# Start runners
./sdlc.sh

# Check that DinD is running
cd .github/sdlc/github-runner
docker-compose -p sdlc ps

# Verify runner can access Docker
docker-compose -p sdlc exec github-runner docker info
```

## Maintenance

- **DinD storage**: Monitor `dind-storage` volume size
- **Image cleanup**: Periodically prune unused images in DinD
- **TLS certificates**: Auto-managed by DinD, stored in `docker-certs` volume
