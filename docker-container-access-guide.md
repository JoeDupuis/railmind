# Docker Container Access Guide for SummonCircle

## Current Container Configuration

Based on my investigation, here's how Docker containers are configured in SummonCircle:

### 1. Container Creation

Both agent containers (in `Run` model) and dev containers (in `BuildDockerContainerJob`) are created without explicit port binding to the host. They only have **exposed ports** but no host port mapping (`-p` flag).

**Agent Containers** (from `app/models/run.rb`):
```ruby
Docker::Container.create(
  "Image" => agent.docker_image,
  "Cmd" => command,
  "Env" => env_vars,
  "User" => agent.user_id.to_s,
  "WorkingDir" => task.agent.workplace_path,
  "HostConfig" => {
    "Binds" => binds  # Only volume binds, no port bindings
  }
)
```

**Dev Containers** (from `app/jobs/build_docker_container_job.rb`):
```ruby
container_config = {
  "name" => container_name,
  "Image" => image_name,
  "WorkingDir" => task.agent.workplace_path,
  "Env" => env_vars,
  "ExposedPorts" => {
    "#{container_port}/tcp" => {}  # Only exposed, not bound to host
  },
  "HostConfig" => {
    "Binds" => binds  # Only volume binds, no port bindings
  }
}
```

### 2. Network Configuration

All containers are using Docker's default `bridge` network. This means:
- Containers can communicate with each other using their internal IP addresses
- Containers cannot be accessed directly from the host via localhost
- No custom Docker networks are created

### 3. How to Access Containers

Since containers are not bound to host ports, here are the ways to access them:

#### Option 1: Using Container IP Address
```bash
# Get container IP
docker inspect task-13-dev-container | jq -r '.[0].NetworkSettings.IPAddress'
# Returns something like: 172.17.0.56

# Access the service
curl http://172.17.0.56:8000
```

#### Option 2: Using Container Name (from another container)
Containers on the same network can communicate using container names:
```bash
# From inside another container
docker exec -it <another-container> curl http://task-13-dev-container:8000
```

#### Option 3: Using Docker Exec
Access the container directly:
```bash
docker exec -it task-13-dev-container curl http://localhost:8000
```

#### Option 4: Using host.docker.internal (from container to host)
The Rails app is configured to accept connections from Docker containers:
```ruby
# config/environments/development.rb
config.hosts << "host.docker.internal"
```

This allows containers to access the Rails app running on the host:
```bash
# From inside a container
curl http://host.docker.internal:3000
```

### 4. Current Container Status

As of the inspection:
- `task-13-dev-container`: Exposes port 8000/tcp, IP: 172.17.0.56
- `task-12-dev-container`: Exposes port 80/tcp
- `task-10-dev-container`: Has port binding 0.0.0.0:8000->80/tcp (accessible via localhost:8000)
- `task-6-dev-container`: Exposes port 80/tcp

### 5. Recommendations for Container Access

1. **For Development**: If you need to access dev containers from the host frequently, consider adding port bindings in `BuildDockerContainerJob`:
   ```ruby
   "HostConfig" => {
     "Binds" => binds,
     "PortBindings" => {
       "#{container_port}/tcp" => [{"HostPort" => "0"}]  # Auto-assign host port
     }
   }
   ```

2. **For Container-to-Container Communication**: Use container names or create a custom Docker network for better isolation and DNS resolution.

3. **For Debugging**: Use `docker exec` to run commands inside containers or access services via their internal IPs.

### 6. Example Access Commands

```bash
# Get all container IPs
docker ps -q | xargs -I {} docker inspect {} | jq -r '.[] | "\(.Name[1:]) - \(.NetworkSettings.IPAddress)"'

# Access a service in a container
CONTAINER_IP=$(docker inspect task-13-dev-container | jq -r '.[0].NetworkSettings.IPAddress')
curl http://$CONTAINER_IP:8000

# Check if service is running inside container
docker exec task-13-dev-container curl -I http://localhost:8000
```