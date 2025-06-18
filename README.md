# Docker Deployments to DigitalOcean via GitHub Actions

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Docker-required-blue)](https://www.docker.com/)
[![DigitalOcean](https://img.shields.io/badge/DigitalOcean-required-blue)](https://www.digitalocean.com/)
[![GitHub Actions](https://img.shields.io/badge/GitHub%20Actions-ready-blue)](https://github.com/features/actions)

## 📋 Table of Contents
- [Docker Deployments to DigitalOcean via GitHub Actions](#docker-deployments-to-digitalocean-via-github-actions)
  - [📋 Table of Contents](#-table-of-contents)
  - [🚀 Quick Start](#-quick-start)
  - [🚀 Features](#-features)
  - [⚙️ Prerequisites](#️-prerequisites)
  - [🔧 Environment Variables](#-environment-variables)
    - [Required Variables](#required-variables)
    - [Optional Variables](#optional-variables)
  - [📜 Workflow Breakdown](#-workflow-breakdown)
  - [📦 Usage in GitHub Actions](#-usage-in-github-actions)
  - [🛠️ Key Functions Explained](#️-key-functions-explained)
  - [⚠️ Error Handling and Rollback](#️-error-handling-and-rollback)
  - [🎨 Customization](#-customization)
  - [🔧 Troubleshooting](#-troubleshooting)
    - [Common Issues](#common-issues)
    - [Getting Help](#getting-help)
  - [🤝 Contributing](#-contributing)
    - [Development Setup](#development-setup)
    - [Code Style](#code-style)
  - [📄 License](#-license)

## 🚀 Quick Start

1. Set up your environment variables:
```bash
export DO_REGISTRY="your-registry-name"
export DO_ACCESS_TOKEN="your-do-token"
export CONTAINER_NAME="your-app-name"
```

2. Clone and run the deployment script:
```bash
git clone https://github.com/Hino9LLC/docker-digitalocean-deploy.git
cd docker-digitalocean-deploy
chmod +x entrypoint.sh
./entrypoint.sh
```

For more detailed instructions, see the sections below.

This script automates the deployment of Docker containers to DigitalOcean's Container Registry and a DigitalOcean Droplet. It's designed to work seamlessly with GitHub Actions workflows but can also be run directly on any Linux server with Docker installed. The script implements a blue/green-like deployment strategy by first deploying a new version of the container with a temporary name, health-checking it, and then switching traffic. It includes features for rollback, image cleanup, and SSL configuration.

## 🚀 Features

* **DigitalOcean Container Registry Integration**: Logs in, pulls images, and pushes a `:previous` tag.
* **Robust Error Handling and Retries**:
    * Checks DigitalOcean API connectivity before starting
    * Implements retry logic with exponential backoff for:
        * Image pulls
        * Image pushes
        * Registry operations
    * Provides detailed error messages and troubleshooting guidance
* **Blue/Green-like Deployment**:
    * Pulls the `latest` image.
    * Starts the new image as a temporary container (e.g., `your-container-name-new`).
    * Performs health checks on the new temporary container.
    * If the temporary container fails health checks, it is simply removed and the original container continues running.
    * Only if the temporary container passes health checks, the original container is stopped and the new one becomes production.
* **Health Checks**: Customizable health checks to ensure container readiness before switching.
* **Automatic Rollback**: Only triggered in the rare case where:
    * The temporary container passed all health checks
    * The original container was stopped
    * The new production container failed its health check
    * In this case, the script attempts to roll back to the previously running version (tagged as `:previous`)
    * Note: This is an edge case that should rarely occur if health checks are properly configured
* **Image Tag Preservation**: Saves the currently active production image by tagging it as `:previous` in the registry before deploying a new version.
    * Gracefully handles first-time deployments where no previous image exists
* **Image Cleanup**:
    * Removes old image tags from the DigitalOcean Container Registry, keeping only `latest` and `previous`.
    * Prunes dangling local Docker images.
* **Optional SSL Support**: 
    * Containers can run with or without SSL
    * When SSL is configured, exposes HTTP/HTTPS ports
    * When SSL is not configured, uses internal network only
    * SSL configuration is validated when provided
    * Deployment will fail if SSL validation fails (only runs without SSL if `DO_DOMAIN`, `SSL_CERT_PATH`, `SSL_KEY_PATH` are not provided)
    * Modern SSL validation approach:
        * Tries OpenSSL pkey first (supports various key formats)
        * Falls back to RSA validation if needed
        * Validates certificate domain matches DO_DOMAIN
        * Checks both CN and Subject Alternative Names
* **Network Management**: Creates a dedicated Docker network (`do-internal-network`) if it doesn't exist.
* **Resource Optimization**: Configures logging (max size, max files) and ulimits for the container.
* **Minimal Downtime**: Aims to minimize downtime during the switchover (though not strictly zero-downtime).
* **Detailed Logging**: Provides informative output for each step of the deployment process.

## ⚙️ Prerequisites

1.  **Docker**: Installed and running on the GitHub Actions runner or the deployment server.
2.  **DigitalOcean Account**:
    * A DigitalOcean Container Registry.
    * A DigitalOcean Personal Access Token with `read` and `write` scopes.
3.  **`curl`**: Used for interacting with the DigitalOcean API for image cleanup.
4.  **`jq`** (optional but recommended): For robust JSON parsing. Install using:
    * Ubuntu/Debian: `sudo apt-get install jq`
    * CentOS/RHEL: `sudo yum install jq`
    * macOS: `brew install jq`
    * If not installed, the script will fall back to basic grep/sed parsing
5.  **`openssl`** (optional but recommended): For SSL certificate validation. Install using:
    * Ubuntu/Debian: `sudo apt-get install openssl`
    * CentOS/RHEL: `sudo yum install openssl`
    * macOS: `brew install openssl`
    * If not installed, the script will skip certificate format validation
6.  **Image Naming**: Your Docker images in the registry should follow a consistent naming convention, using the `latest` tag for the newest version.

## 🔧 Environment Variables

The script relies on several environment variables for its configuration. These should be set in your GitHub Actions workflow secrets or environment.

### Required Variables

* **`DO_REGISTRY`**: The name of your DigitalOcean Container Registry.
    * *Example*: `your-registry-name`
* **`DO_ACCESS_TOKEN`**: Your DigitalOcean API access token with read/write permissions for the registry.
    * *Example*: `dop_v1_xxxxxxxxxxxxxxxxxxxxxxxxxx`
* **`CONTAINER_NAME`**: The name of the container to deploy (should match the image name).
    * *Example*: `my-awesome-app`

### Optional Variables

* **`HEALTH_CHECK_CMD`**: The command used by Docker to check the container's health.
    * *Default*: `"curl -f http://localhost/ || exit 1"`
    * *Example*: `"curl -f http://localhost:3000/healthz || exit 1"`
* **`DO_DOMAIN`**: The domain name for your application. Required only if using SSL.
    * *Default*: `""` (empty)
    * *Example*: `example.com`
    * *Note*: Must match the Common Name (CN) in your SSL certificate
* **`SSL_CERT_PATH`**: Absolute path to the SSL certificate file on the deployment server. Required only if using SSL.
    * *Default*: `""` (empty)
    * *Example*: `/etc/letsencrypt/live/example.com/fullchain.pem`
    * *Note*: Must be a valid X.509 certificate file in PEM format
    * *Note*: Must be an absolute path
* **`SSL_KEY_PATH`**: Absolute path to the SSL private key file on the deployment server. Required only if using SSL.
    * *Default*: `""` (empty)
    * *Example*: `/etc/letsencrypt/live/example.com/privkey.pem`
    * *Note*: Must be a valid private key file in PEM format
    * *Note*: Must be an absolute path
* **`APP_ENV_VARS_STRING`**: Comma-separated list of environment variables to pass to the container.
    * *Default*: `""` (empty)
    * *Example*: `"DATABASE_URL=postgres://user:pass@db:5432/mydb,API_KEY=secret123"`
    * *Note*: Only the variables explicitly listed here will be passed to the container
    * *Note*: Each variable should be in the format `KEY=VALUE`
    * *Note*: In GitHub Actions, you can use secrets: `"${{ secrets.DATABASE_URL }},${{ secrets.API_KEY }}"`
    * *Note*: Variables are validated for proper format and empty values are skipped
    * *Note*: See `sample_deploy.yml` for a comprehensive example of environment variable configuration

## 📜 Workflow Breakdown

The script executes the following steps in order:

1.  **Process Environment Variables**: Validates and processes the `APP_ENV_VARS_STRING` into Docker environment arguments.
2.  **Check DigitalOcean Connectivity**: Verifies API access before proceeding.
3.  **Login to DigitalOcean Registry**: Authenticates Docker with your `DO_ACCESS_TOKEN`.
4.  **Pull Latest Image**: Pulls `registry.digitalocean.com/${DO_REGISTRY}/${CONTAINER_NAME}:latest` with retry logic.
5.  **Cleanup Temporary Containers**: Stops and removes any leftover containers named `${CONTAINER_NAME}-new`.
6.  **Save Previous Image**:
    * If a container named `${CONTAINER_NAME}` is running, its image is tagged as `registry.digitalocean.com/${DO_REGISTRY}/${CONTAINER_NAME}:previous`.
    * This `:previous` tag is then pushed to the DigitalOcean Container Registry.
7.  **Start New Temporary Container**:
    * A new container is started with the name `${CONTAINER_NAME}-new` using the `latest` image.
    * If SSL variables (`DO_DOMAIN`, `SSL_CERT_PATH`, `SSL_KEY_PATH`) are set, it's configured with temporary non-standard ports (e.g., 8080 for HTTP, 8443 for HTTPS) and SSL volume mounts. Deployment will fail if SSL validation fails. Otherwise, ports are not exposed for this temporary container.
8.  **Wait for New Temporary Container Health**: The script polls the health status of `${CONTAINER_NAME}-new` until it's `healthy` or a timeout is reached.
    * If it fails to become healthy, temporary containers are cleaned up, and the script exits with an error.
9.  **Switch to New Container**: Stops and removes the old production container.
10. **Start Production Container**:
    * The `latest` image is started as the main production container with the name `${CONTAINER_NAME}`.
    * If SSL variables are set, it's configured with standard ports (80 for HTTP, 443 for HTTPS) and SSL volume mounts. Otherwise, ports are not exposed directly by this script (assuming a reverse proxy might be in use or no external access is needed).
11. **Wait for Production Container Health**: The script polls the health status of `${CONTAINER_NAME}`.
    * If it fails to become healthy, the `rollback` function is triggered.
12. **Calculate Downtime**: Calculates the approximate downtime between stopping the old container and the new production container becoming healthy.
13. **Image Housekeeping**:
    * Calls `cleanup_temp_containers` again.
    * Calls `cleanup_images` to remove old tags (except `latest` and `previous`) from the DigitalOcean Container Registry and prune local dangling images.
    * Prints a "Deployment complete!" message.

## 📦 Usage in GitHub Actions

Here's an example of how to use this `entrypoint.sh` script in a GitHub Actions workflow. For a complete example with environment variables, see `sample_deploy.yml`:

```yaml
name: Build and Deploy to DigitalOcean

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # ... test steps ...

  build-and-push:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # ... build and push steps ...

  deploy-to-droplet:
    needs: build-and-push
    runs-on: ubuntu-latest
    steps:
      - name: Deploy to DigitalOcean Droplet
        uses: appleboy/ssh-action@master
        with:
          host: ${{ secrets.DO_HOST }}
          username: ${{ secrets.DO_USERNAME }}
          key: ${{ secrets.DO_SSH_KEY }}
          script: |
            rm -rf docker-digitalocean-deploy
            git clone https://github.com/Hino9LLC/docker-digitalocean-deploy.git
            cd docker-digitalocean-deploy
            chmod +x entrypoint.sh

            # Export Host-side Environment Variables
            export DO_REGISTRY="${{ secrets.DO_REGISTRY }}"
            export DO_ACCESS_TOKEN="${{ secrets.DO_ACCESS_TOKEN }}"
            export CONTAINER_NAME="${{ secrets.CONTAINER_NAME }}"
            export HEALTH_CHECK_CMD="curl -f http://localhost:8000/health || exit 1"

            # Construct APP_ENV_VARS_STRING for the container's environment
            APP_ENV_VARS_STRING=""
            APP_ENV_VARS_STRING+="DATABASE_URL=${{ secrets.DATABASE_URL }}"
            APP_ENV_VARS_STRING+=",API_KEY=${{ secrets.API_KEY }}"
            APP_ENV_VARS_STRING+=",REDIS_HOST=${{ secrets.REDIS_HOST }}"
            APP_ENV_VARS_STRING+=",REDIS_PORT=${{ secrets.REDIS_PORT }}"
            APP_ENV_VARS_STRING+=",REDIS_PASSWORD=${{ secrets.REDIS_PASSWORD }}"

            export APP_ENV_VARS_STRING

            ./entrypoint.sh
```

For a complete example with all environment variables and configuration options, see `sample_deploy.yml` in the repository.

## 🛠️ Key Functions Explained

Within the `entrypoint.sh` script:

* **`extract_json_value()`**: Extracts values from JSON responses with graceful fallback.
    ```bash
    # Example usage:
    # extract_json_value '{"name":"test","value":123}' "name"  # Returns: test
    # extract_json_value '{"name":"test","value":123}' "value" # Returns: 123
    ```
    * Uses `jq` if available for robust JSON parsing
    * Falls back to grep/sed if `jq` is not installed
    * Handles basic JSON structures in both modes
    * Returns empty string for non-existent keys
* **`validate_ssl_config()`**: Validates SSL configuration with graceful fallback.
    * Checks required environment variables (`DO_DOMAIN`, `SSL_CERT_PATH`, `SSL_KEY_PATH`)
    * Validates certificate and key file existence and readability
    * Uses OpenSSL if available to validate certificate and key formats
    * Falls back to basic file checks if OpenSSL is not installed
    * Provides clear warnings when validation is limited
* **`cleanup_temp_containers()`**: Ensures no stale `-new` suffixed containers are left running or existing.
* **`network_exists()`**: Checks if the `do-internal-network` Docker network is present.
* **`run_container()`**: The core function for running Docker containers. It dynamically builds the `docker run` command based on provided arguments, including SSL configuration, health checks, logging, and resource limits.
* **`wait_for_container()`**: Polls Docker for the container's health status, retrying several times before declaring a failure.
* **`cleanup_images()`**: Interacts with the DigitalOcean API to list all tags for a repository, then deletes all tags except `latest` and `previous`. Also prunes local dangling Docker images.
* **`rollback()`**: Stops the failed new container and attempts to restart the container using the `:previous` image tag.
* **`save_previous()`**: Tags the image of the current running production container as `:previous` and pushes this tag to the registry. This serves as the rollback target.

## ⚠️ Error Handling and Rollback

* The script uses `set -euo pipefail` to ensure it exits immediately if any command fails, an undefined variable is used, or a command in a pipe fails.
    ```bash
    set -euo pipefail
    ```
* Specific error messages are printed for common failure points (e.g., missing environment variables, image pull failure).
* Deployment failure handling:
    * If the temporary container fails health checks:
        * The temporary container is removed
        * The original container continues running unchanged
        * No rollback is needed as the original container was never stopped
    * If the new production container fails after switchover (rare):
        * The `rollback` function is invoked
        * Attempts to restore the previous version
        * This is an edge case that should be extremely rare with proper health checks
* The rollback process (only used in the edge case above):
    * First checks for a previous image locally
    * If not found locally, attempts to pull from the registry
    * Provides clear guidance if no previous image is available
    * Exits with helpful messages if rollback is not possible
* First-time deployment considerations:
    * No previous image will be available for rollback
    * The script will provide appropriate warnings and guidance
    * Ensure your first deployment is thoroughly tested before running

## 🎨 Customization

* **Health Check**: Modify the `HEALTH_CHECK_CMD` environment variable for your application's specific health endpoint and criteria.
    ```bash
    # Example:
    # HEALTH_CHECK_CMD="curl --fail http://localhost:8000/health_status || exit 1"
    ```
* **Ports**: The script uses standard 80/443 for production SSL. If your application uses different internal ports, you'll need to adjust the `-p` mappings within the `run_container` function (inside `entrypoint.sh`) for the final production container start, or ensure your container correctly exposes port 80/443 internally. The temporary container uses 8080/8443 to avoid conflicts.
* **Docker Run Options**: The `run_container` function in `entrypoint.sh` has many common Docker options (logging, ulimits, restart policy). You can extend this function to add more specific options your application might require.
* **Image Cleanup Logic**: The `cleanup_images` function can be adapted if you have a different tag retention policy.

## 🔧 Troubleshooting

### Common Issues

1. **Container Health Check Fails**
   - Verify your application is listening on the correct port
   - Check if the health check endpoint is accessible
   - Review container logs for application errors

2. **SSL Configuration Issues**
   - SSL is optional - containers can run without it using internal network only
   - If using SSL, ensure all SSL-related environment variables are set (`DO_DOMAIN`, `SSL_CERT_PATH`, `SSL_KEY_PATH`)
   - If using SSL, verify certificate and key files exist and are readable
   - If using SSL and OpenSSL is installed, it will validate:
     * Certificate and key formats (tries pkey first, then RSA)
     * Certificate domain matches DO_DOMAIN (checks both CN and SAN)
     * Paths are absolute
   - If using SSL and OpenSSL is not available, ensure your files are in valid PEM format
   - If using SSL, check file permissions on SSL files
   - For Nginx containers with SSL:
     * Ensure SSL paths are correctly mounted
     * Verify SSL configuration in your Nginx config
     * Check that certificate and key paths match your Nginx config
   - Common SSL validation errors:
     * "Invalid key format" - Try converting your key to PEM format
     * "Certificate domain does not match" - Check CN and SAN in your certificate
     * "SSL certificate not readable" - Check file permissions and path

3. **Registry Authentication Failures**
   - Verify DO_ACCESS_TOKEN has correct permissions
   - Check if the token is expired
   - Ensure DO_REGISTRY name is correct
   - Check DigitalOcean API status at https://status.digitalocean.com
   - Verify your internet connection
   - The script will automatically retry failed operations with exponential backoff

4. **Deployment Rollback**
   - Check if the :previous tag exists in the registry
   - Verify the previous image is still available
   - Check container logs for specific errors

5. **DigitalOcean API Connectivity Issues**
   - The script checks API connectivity before starting
   - Implements automatic retries with exponential backoff
   - Provides detailed error messages and troubleshooting steps
   - Common causes:
     * Internet connectivity issues
     * DigitalOcean API outages
     * Invalid or expired access token
     * Rate limiting

### Getting Help

If you encounter issues not covered here:
1. Check the [GitHub Issues](https://github.com/Hino9LLC/docker-digitalocean-deploy/issues)
2. Create a new issue with:
   - Detailed error message
   - Steps to reproduce
   - Environment information
   - Relevant logs
   - DigitalOcean API status at the time of the error

## 🤝 Contributing

We welcome contributions! Here's how you can help:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Setup

1. Clone the repository
2. Make your changes
3. Test locally:
   ```bash
   # Test with a sample container
   export DO_REGISTRY="test-registry"
   export DO_ACCESS_TOKEN="test-token"
   export CONTAINER_NAME="test-container"
   ./entrypoint.sh
   ```
4. Ensure all tests pass
5. Update documentation if needed

### Code Style

- Follow the existing code style
- Add comments for complex logic
- Update documentation for new features
- Add tests for new functionality

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.