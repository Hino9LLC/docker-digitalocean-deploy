#!/bin/bash

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Validate required environment variables
REQUIRED_VARS=("DO_REGISTRY" "DO_ACCESS_TOKEN" "CONTAINER_NAME")

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "❌ Error: Required environment variable '$var' is not set."
        exit 1
    fi
done

# Set default health check command if not specified
HEALTH_CHECK_CMD=${HEALTH_CHECK_CMD:-"curl -f http://localhost/ || exit 1"}


# Validate required application environment variables
validate_required_app_vars() {
    IFS=',' read -ra VARS <<< "${REQUIRED_APP_VARS:-}"
    for var in "${VARS[@]}"; do
        if [ -z "${!var:-}" ]; then
            echo "❌ Error: Required application environment variable '$var' is not set."
            return 1
        fi
    done
    echo "✅ All required application environment variables are set."
    return 0
}

# Function to validate SSL configuration
validate_ssl_config() {
    # If any SSL-related variable is not set, SSL is not being used
    if [ -z "${DO_DOMAIN:-}" ] || [ -z "${SSL_CERT_PATH:-}" ] || [ -z "${SSL_KEY_PATH:-}" ]; then
        echo "ℹ️ SSL configuration not provided - running without SSL"
        return 1
    fi

    # If we get here, SSL variables are present, so validation must pass
    echo "🔒 Validating SSL configuration..."
    echo "📝 SSL Configuration:"
    echo "   - DO_DOMAIN: ${DO_DOMAIN}"
    echo "   - SSL_CERT_PATH: ${SSL_CERT_PATH}"
    echo "   - SSL_KEY_PATH: ${SSL_KEY_PATH}"

    # Validate files exist and are readable
    [ -r "${SSL_CERT_PATH}" ] || {
        echo "❌ SSL certificate not readable: ${SSL_CERT_PATH}"
        echo "   - File exists: $([ -e "${SSL_CERT_PATH}" ] && echo "Yes" || echo "No")"
        echo "   - File permissions: $(ls -l "${SSL_CERT_PATH}" 2>/dev/null | awk '{print $1, $3, $4}' || echo "Cannot read permissions")"
        echo "   - Directory permissions: $(ls -ld "$(dirname "${SSL_CERT_PATH}")" 2>/dev/null | awk '{print $1, $3, $4}' || echo "Cannot read directory permissions")"
        echo "   - OpenSSL version: $(openssl version 2>/dev/null || echo 'Not available')"
        exit 1
    }
    [ -r "${SSL_KEY_PATH}" ] || {
        echo "❌ SSL key not readable: ${SSL_KEY_PATH}"
        echo "   - File exists: $([ -e "${SSL_KEY_PATH}" ] && echo "Yes" || echo "No")"
        echo "   - File permissions: $(ls -l "${SSL_KEY_PATH}" 2>/dev/null | awk '{print $1, $3, $4}' || echo "Cannot read permissions")"
        echo "   - Directory permissions: $(ls -ld "$(dirname "${SSL_KEY_PATH}")" 2>/dev/null | awk '{print $1, $3, $4}' || echo "Cannot read directory permissions")"
        echo "   - OpenSSL version: $(openssl version 2>/dev/null || echo 'Not available')"
        exit 1
    }

    # Try to validate certificate and key formats if openssl is available
    if command -v openssl >/dev/null 2>&1; then
        # Validate certificate format
        if ! openssl x509 -in "${SSL_CERT_PATH}" -text -noout >/dev/null 2>&1; then
            echo "❌ Invalid certificate format"
            echo "   - Certificate validation failed"
            echo "   - OpenSSL version: $(openssl version 2>/dev/null || echo 'Not available')"
            exit 1
        fi

        # Validate key format
        if ! openssl pkey -in "${SSL_KEY_PATH}" -check -noout >/dev/null 2>&1; then
            if ! openssl rsa -in "${SSL_KEY_PATH}" -check -noout >/dev/null 2>&1; then
                echo "❌ Invalid key format"
                echo "   - Key validation failed"
                echo "   - OpenSSL version: $(openssl version 2>/dev/null || echo 'Not available')"
                exit 1
            fi
        fi

        # Validate certificate matches domain
        local cert_domain=""
        # Try CN
        cert_domain=$(openssl x509 -in "${SSL_CERT_PATH}" -noout -subject -nameopt RFC2253 2>/dev/null | grep -o "CN=[^,]*" | cut -d= -f2)
        # If no CN, try the first DNS name from SAN
        if [ -z "$cert_domain" ]; then
            cert_domain=$(openssl x509 -in "${SSL_CERT_PATH}" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | grep "DNS:" | head -n1 | sed 's/.*DNS://' | tr -d ' ')
        fi

        if [ -z "$cert_domain" ]; then
            echo "❌ Could not extract domain from certificate"
            echo "   - Certificate validation failed: No domain found in certificate"
            echo "   - OpenSSL version: $(openssl version 2>/dev/null || echo 'Not available')"
            exit 1
        fi

        if [[ "${cert_domain}" != "${DO_DOMAIN}" ]]; then
            echo "❌ Certificate domain does not match DO_DOMAIN"
            echo "   - Expected domain: ${DO_DOMAIN}"
            echo "   - Certificate domain: ${cert_domain}"
            echo "   - OpenSSL version: $(openssl version 2>/dev/null || echo 'Not available')"
            exit 1
        fi
    else
        echo "⚠️ OpenSSL not available - skipping certificate and key format validation"
    fi

    return 0
}

# Function to extract JSON value with jq fallback to grep/sed
extract_json_value() {
    local json="$1"
    local key="$2"

    # Try using jq first if available
    if command -v jq >/dev/null 2>&1; then
        echo "$json" | jq -r --arg key "$key" '.[$key] // empty'
        return
    fi

    # Fallback to grep/sed if jq is not available
    echo "$json" | grep -o "\"$key\":[^,}]*" | sed "s/\"$key\":\"//;s/\"//g"
}

# Function to clean up temporary containers
cleanup_temp_containers() {
    echo "🧹 Cleaning up any existing temporary containers..."

    # Stop and remove any containers with -new suffix
    if docker ps -a --format '{{.Names}}' | grep -q -E "${CONTAINER_NAME}-new"; then
        docker ps -a --format '{{.Names}}' | grep -E "${CONTAINER_NAME}-new" | while read container; do
            echo "🗑️ Found container $container, cleaning up..."
            if ! docker stop "$container"; then
                echo "⚠️ Failed to stop container $container"
            fi
            if ! docker rm -f "$container"; then
                echo "⚠️ Failed to remove container $container"
            fi
        done

        # Double check no -new containers exist
        if docker ps -a --format '{{.Names}}' | grep -q -E "${CONTAINER_NAME}-new"; then
            echo "❌ Failed to clean up all temporary containers"
            exit 1
        fi
    else
        echo "✨ No temporary containers found to clean up."
    fi
}

# Function to check if network exists
network_exists() {
    local network_name=$1
    docker network ls --format '{{.Name}}' | grep -q "^${network_name}$"
}

# Function to run container with specified name and ports
run_container() {
    local container_name=$1
    local http_port=$2
    local https_port=$3
    local docker_args=()

    # Add all required app env vars as -e flags
    IFS=',' read -ra VARS <<< "${REQUIRED_APP_VARS:-}"
    for var in "${VARS[@]}"; do
        docker_args+=("-e" "${var}=${!var}")
    done

    echo "🚀 Starting container $container_name..."

    # Create internal network if it doesn't exist
    if ! network_exists "do-internal-network"; then
        echo "🌐 Creating internal network: do-internal-network"
        docker network create \
            --label environment=production \
            do-internal-network
    fi

    # Build docker run command using an array
    docker_args+=(
        "-d"
        "--name" "$container_name"
        "--network" "do-internal-network"
        "--network-alias" "$container_name"
        "--health-cmd" "${HEALTH_CHECK_CMD}"
        "--health-interval=10s"
        "--health-timeout=10s"
        "--health-retries=5"
        "--health-start-period=30s"
        "--restart" "unless-stopped"
        "--log-driver" "json-file"
        "--log-opt" "max-size=10m"
        "--log-opt" "max-file=3"
        "--ulimit" "nofile=65536:65536"
        "--security-opt" "no-new-privileges:true"
    )

    # Only expose ports if SSL is properly configured
    if validate_ssl_config; then
        echo "🔌 Exposing ports for SSL-enabled container"
        if [ -n "$http_port" ] && [ "$http_port" != "0" ]; then
            echo "🔌 Exposing HTTP port ${http_port}:80"
            docker_args+=("-p" "${http_port}:80")
        fi
        if [ -n "$https_port" ] && [ "$https_port" != "0" ]; then
            echo "🔌 Exposing HTTPS port ${https_port}:443"
            docker_args+=("-p" "${https_port}:443")
        fi

        # Ensure SSL paths are absolute and exist
        if [[ ! "${SSL_CERT_PATH}" = /* ]]; then
            echo "❌ SSL_CERT_PATH must be an absolute path"
            return 1
        fi
        if [[ ! "${SSL_KEY_PATH}" = /* ]]; then
            echo "❌ SSL_KEY_PATH must be an absolute path"
            return 1
        fi

        # Add SSL configuration
        docker_args+=(
            "-e" "SSL_CERT_PATH=${SSL_CERT_PATH}"
            "-e" "SSL_KEY_PATH=${SSL_KEY_PATH}"
            "-v" "${SSL_CERT_PATH}:${SSL_CERT_PATH}:ro"
            "-v" "${SSL_KEY_PATH}:${SSL_KEY_PATH}:ro"
            "-e" "DOMAIN=${DO_DOMAIN}"
        )
    else
        echo "ℹ️ Running container without SSL - using internal network only"
    fi

    # Add the image
    docker_args+=("registry.digitalocean.com/${DO_REGISTRY}/${CONTAINER_NAME}:latest")

    # Execute the command and capture output
    echo "📝 Running docker command: docker run ${docker_args[*]}"
    if ! output=$(docker run "${docker_args[@]}" 2>&1); then
        echo "❌ Failed to start container:"
        echo "$output"
        return 1
    fi

    echo "✅ Container started successfully: $output"
    return 0
}

# Function to wait for container to be healthy
wait_for_container() {
    local container_name=$1
    local max_attempts=${2:-10} # Default to 10 attempts if not specified

    echo "🏥 Waiting for container $container_name to become healthy..."
    for i in $(seq 1 $max_attempts); do
        sleep 5

        STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "Starting")
        echo "📊 Health check status: $STATUS"

        if [ "$STATUS" == "healthy" ]; then
            echo "✅ Container $container_name is healthy."
            return 0
        fi

        if [ "$i" -eq "$max_attempts" ]; then
            echo "❌ Container did not become healthy after $max_attempts attempts."
            echo "📜 Container logs:"
            docker logs "$container_name"
            echo "🔍 Container health check details:"
            docker inspect --format='Health: {{.State.Health.Status}}, Failing Streak: {{.State.Health.FailingStreak}}' "$container_name"
            return 1
        fi

        echo "⏳ Waiting 5 seconds before next health check..."
    done
}

# Function to clean up old images
cleanup_images() {
    echo "🧹 Cleaning up all images except 'latest' and 'previous'..."

    # Fetch all tags from the registry
    local page=1
    local all_tags=()

    while true; do
        echo "📄 Fetching page $page..."
        local registry_response=$(curl -s -X GET \
            -H "Authorization: Bearer ${DO_ACCESS_TOKEN}" \
            "https://api.digitalocean.com/v2/registry/${DO_REGISTRY}/repositories/${CONTAINER_NAME}/tags?page=$page&per_page=100")

        if [ $? -ne 0 ]; then
            echo "❌ Failed to fetch registry images"
            return 1
        fi

        # Extract tags, excluding latest and previous
        while read -r tag_data; do
            local tag=$(extract_json_value "$tag_data" "tag")
            if [ -z "$tag" ] || [ "$tag" == "null" ] || { [ "$tag" != "latest" ] && [ "$tag" != "previous" ]; }; then
                all_tags+=("$tag")
            fi
        done < <(echo "$registry_response" | grep -o '{[^}]*}')

        echo "📝 Found ${#all_tags[@]} images on page $page"

        # Check if there are more pages
        local next_page=$(extract_json_value "$registry_response" "next")
        if [ -z "$next_page" ]; then
            break
        fi
        ((page++))
    done

    echo "📝 Found total of ${#all_tags[@]} images to clean up"

    # Remove all tags except 'latest' and 'previous'
    for tag in "${all_tags[@]}"; do
        if [ -n "$tag" ] && [ "$tag" != "null" ]; then
            echo "🗑️ Removing registry image: $tag"
            local delete_response=$(curl -s -X DELETE \
                -H "Authorization: Bearer ${DO_ACCESS_TOKEN}" \
                "https://api.digitalocean.com/v2/registry/${DO_REGISTRY}/repositories/${CONTAINER_NAME}/tags/$tag")

            if [ $? -ne 0 ]; then
                echo "⚠️ Failed to delete image $tag"
                echo "Response: $delete_response"
            fi
        fi
    done

    # Clean up dangling images
    echo "🧹 Cleaning up dangling images..."
    docker image prune -f

    # Verify cleanup
    echo "📊 Current images in registry:"
    docker images registry.digitalocean.com/${DO_REGISTRY}/${CONTAINER_NAME} --format "{{.Repository}}:{{.Tag}}"
}

# Function to check doctl connectivity with retries
check_doctl_connectivity() {
    local max_attempts=3
    local attempt=1
    local wait_time=5

    echo "🔍 Checking DigitalOcean API connectivity..."

    while [ $attempt -le $max_attempts ]; do
        if doctl account get >/dev/null 2>&1; then
            echo "✅ DigitalOcean API is accessible"
            return 0
        fi

        echo "⚠️ Attempt $attempt/$max_attempts: DigitalOcean API is not accessible"
        if [ $attempt -lt $max_attempts ]; then
            echo "⏳ Waiting ${wait_time} seconds before retry..."
            sleep $wait_time
            wait_time=$((wait_time * 2)) # Exponential backoff
        fi
        attempt=$((attempt + 1))
    done

    echo "❌ Failed to connect to DigitalOcean API after $max_attempts attempts"
    echo "Please check:"
    echo "1. Your internet connection"
    echo "2. DigitalOcean API status (https://status.digitalocean.com)"
    echo "3. Your DO_ACCESS_TOKEN is valid"
    return 1
}

# Function to pull image with retries
pull_image_with_retry() {
    local image=$1
    local max_attempts=3
    local attempt=1
    local wait_time=5

    while [ $attempt -le $max_attempts ]; do
        echo "📥 Attempt $attempt/$max_attempts: Pulling image $image..."
        if docker pull "$image"; then
            echo "✅ Successfully pulled image $image"
            return 0
        fi

        echo "⚠️ Failed to pull image on attempt $attempt"
        if [ $attempt -lt $max_attempts ]; then
            echo "⏳ Waiting ${wait_time} seconds before retry..."
            sleep $wait_time
            wait_time=$((wait_time * 2)) # Exponential backoff
        fi
        attempt=$((attempt + 1))
    done

    echo "❌ Failed to pull image after $max_attempts attempts"
    return 1
}

# Function to push image with retries
push_image_with_retry() {
    local image=$1
    local max_attempts=3
    local attempt=1
    local wait_time=5

    while [ $attempt -le $max_attempts ]; do
        echo "📤 Attempt $attempt/$max_attempts: Pushing image $image..."
        if docker push "$image"; then
            echo "✅ Successfully pushed image $image"
            return 0
        fi

        echo "⚠️ Failed to push image on attempt $attempt"
        if [ $attempt -lt $max_attempts ]; then
            echo "⏳ Waiting ${wait_time} seconds before retry..."
            sleep $wait_time
            wait_time=$((wait_time * 2)) # Exponential backoff
        fi
        attempt=$((attempt + 1))
    done

    echo "❌ Failed to push image after $max_attempts attempts"
    return 1
}

# Function to save current container as previous
save_previous() {
    echo "🔖 Checking for existing container to save as :previous..."

    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "📦 Found running container: ${CONTAINER_NAME}"
        CURRENT_IMAGE=$(docker inspect --format='{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null)

        if [[ -n "$CURRENT_IMAGE" ]]; then
            echo "🔁 Tagging $CURRENT_IMAGE as :previous"
            if ! docker tag "$CURRENT_IMAGE" "registry.digitalocean.com/${DO_REGISTRY}/${CONTAINER_NAME}:previous"; then
                echo "❌ Failed to tag image as :previous"
                return 1
            fi

            echo "📤 Pushing :previous tag to the registry..."
            if ! push_image_with_retry "registry.digitalocean.com/${DO_REGISTRY}/${CONTAINER_NAME}:previous"; then
                echo "❌ Failed to push :previous tag to the registry"
                return 1
            fi
        else
            echo "⚠️ Could not determine image from running container. Skipping save."
        fi
    else
        echo "ℹ️ No running container to save. This is normal for first deployment."
    fi
}

# Function to rollback to previous container
rollback() {
    echo "🔄 Attempting rollback..."

    # Stop and remove the failed new container
    docker stop "${CONTAINER_NAME}-new" || true
    docker rm -f "${CONTAINER_NAME}-new" || true

    # Check if we have a previous image locally or in registry
    local has_previous=false

    # Check local images first
    if docker images | grep -q "${CONTAINER_NAME}:previous"; then
        has_previous=true
    else
        # Try to pull from registry
        echo "📥 Attempting to pull previous image from registry..."
        if docker pull "registry.digitalocean.com/${DO_REGISTRY}/${CONTAINER_NAME}:previous"; then
            has_previous=true
        fi
    fi

    if [ "$has_previous" = true ]; then
        echo "⏪ Starting previous container..."
        run_container "${CONTAINER_NAME}" 80 443

        if ! wait_for_container "${CONTAINER_NAME}"; then
            echo "❌ Rollback failed - previous container is not healthy"
            exit 1
        fi

        echo "✅ Rollback successful"
    else
        echo "❌ No previous container image available for rollback"
        echo "ℹ️ This is normal for first deployment or if previous image was not saved"
        echo "ℹ️ Please check your application configuration and try deploying again"
        exit 1
    fi
}

# Step 1: Process environment variables
echo "🚀 Step 1: Processing environment variables..."
if ! validate_required_app_vars; then
    echo "❌ Failed to validate required application environment variables. Exiting."
    exit 1
fi

# Step 2: Check DigitalOcean connectivity
if ! check_doctl_connectivity; then
    echo "❌ Cannot proceed without DigitalOcean API access"
    exit 1
fi

# Step 3: Login to DigitalOcean Container Registry
echo "🔑 Logging into DigitalOcean Container Registry..."
if ! echo "${DO_ACCESS_TOKEN}" | docker login registry.digitalocean.com -u "${DO_ACCESS_TOKEN}" --password-stdin; then
    echo "❌ Failed to login to DigitalOcean Container Registry"
    exit 1
fi

# Step 4: Pull the latest image with retries
echo "📥 Pulling latest image from registry..."
if ! pull_image_with_retry "registry.digitalocean.com/${DO_REGISTRY}/${CONTAINER_NAME}:latest"; then
    echo "❌ Error: Failed to pull image registry.digitalocean.com/${DO_REGISTRY}/${CONTAINER_NAME}:latest"
    echo "Please ensure:"
    echo "1. The image exists in the registry"
    echo "2. You have the correct registry name and container name"
    echo "3. Your access token has the necessary permissions"
    echo "4. This is not your first deployment (in which case you need to push an image first)"
    exit 1
fi

# Step 5: Clean up any existing temporary containers
cleanup_temp_containers

# Step 6: Save current container as previous before starting new one
save_previous

# Step 7: Start new container with temporary name and ports
if validate_ssl_config; then
    echo "🚀 Starting new container with SSL configuration"
    run_container "${CONTAINER_NAME}-new" 8080 8443
else
    echo "⚠️ Starting new container without SSL configuration"
    run_container "${CONTAINER_NAME}-new" 0 0
fi

# Step 8: Wait for new container to be healthy
if ! wait_for_container "${CONTAINER_NAME}-new"; then
    echo "❌ Cleaning up failed container..."
    cleanup_temp_containers
    exit 1
fi

# Step 9: Switch to new container
echo "🔄 Stopping old container and renaming new container..."
OLD_CONTAINER_TIME_OF_DEATH=$(date +%s)
docker stop "${CONTAINER_NAME}" || true
docker rm -f "${CONTAINER_NAME}" || true

# Step 10: Start production container directly (skip the -new container)
if validate_ssl_config; then
    echo "🚀 Starting production container with SSL configuration"
    run_container "${CONTAINER_NAME}" 80 443
else
    echo "⚠️ Starting production container without SSL configuration"
    run_container "${CONTAINER_NAME}" 0 0 # Ports won't be used
fi

# Step 11: Wait for production container to be healthy
if ! wait_for_container "${CONTAINER_NAME}"; then
    echo "❌ Failed to start production container. Rolling back..."
    rollback
    exit 1
fi

# Step 12: Calculate downtime
NEW_CONTAINER_EPOCH=$(docker inspect --format='{{.State.StartedAt}}' "${CONTAINER_NAME}" | date -f - +%s)
DOWNTIME=$((NEW_CONTAINER_EPOCH - OLD_CONTAINER_TIME_OF_DEATH))
echo "⏱️ Total downtime: ${DOWNTIME}s"

# Step 13: Image housekeeping
cleanup_temp_containers
cleanup_images

echo "🎉 Deployment complete! 🚀"
