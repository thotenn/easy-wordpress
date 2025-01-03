#!/bin/bash

# WordPress Docker Installation Script
# For Ubuntu 24.04 LTS
# This script sets up a WordPress site with Docker, Nginx, and SSL

# Error handling
set -e
set -o pipefail

# Global variables
# REQUIRED_SPACE=3000000  # 3GB in KB
REQUIRED_SPACE=3000  # This is temporary for testing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Cleanup function for errors
cleanup() {
    local exit_code=$?
    log "Error occurred (Exit code: $exit_code). Cleaning up..."
    if [ -d "$APP_PATH" ]; then
        docker-compose -f "$APP_PATH/docker-compose.yml" down 2>/dev/null || true
    fi
    exit "$exit_code"
}

# Set up error handling
trap cleanup ERR

# Function to check if we are in a container
is_container() {
    [ -f /.dockerenv ] || grep -q '/docker/' /proc/1/cgroup || grep -q '/lxc/' /proc/1/cgroup
}

# Function to start services
start_service() {
    local service_name="$1"
    if is_container; then
        service "$service_name" start 2>/dev/null || true
    else
        systemctl start "$service_name" 2>/dev/null || true
    fi
}

# Function for enabling services
enable_service() {
    local service_name="$1"
    if ! is_container; then
        systemctl enable "$service_name" 2>/dev/null || true
    fi
}

# Function to check Docker service status
check_docker_running() {
    local max_attempts=5
    local attempt=1
    
    log "Checking Docker connectivity..."
    
    # Asegurarse de que el socket tiene los permisos correctos
    if [ -S "/var/run/docker.sock" ]; then
        chmod 666 /var/run/docker.sock
    fi
    
    while [ $attempt -le $max_attempts ]; do
        if docker version >/dev/null 2>&1; then
            log "✓ Docker is accessible"
            return 0
        fi
        
        log "Waiting for Docker to become accessible (attempt $attempt/$max_attempts)..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    log "Error: Cannot connect to Docker. Debugging information:"
    log "Socket permissions:"
    ls -l /var/run/docker.sock
    log "Current user and groups:"
    id
    log "Docker socket group:"
    stat -c '%g' /var/run/docker.sock
    
    return 1
}

# Pre-flight checks
preflight_checks() {
    if [ "$EUID" -ne 0 ]; then 
        log "Error: This script must be run as root"
        exit 1
    fi

    # Load environment variables
    source "$SCRIPT_DIR/load_env.sh" || { log "Error: Could not load environment variables"; exit 1; }
    # source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/load_env.sh"
    load_env

    # Required environment variables check
    local required_vars=(
        "LOG_FILE"
        "USE_WEBSERVER"
        "USE_SSL"
        "DOMAIN"
        "MYSQL_ROOT_PASSWORD"
        "MYSQL_DATABASE"
        "MYSQL_USER"
        "MYSQL_PASSWORD"
    )

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            log "Error: Required environment variable $var is not set"
            exit 1
        fi
    done
}

# Create necessary directories with proper permissions
create_directories() {
    if [ ! -d "$APP_PATH" ]; then
        echo "Creating directory $APP_PATH"
        mkdir -p $APP_PATH
        if [ $? -ne 0 ]; then
            echo "Error: Failed to create $APP_PATH"
            exit 1
        fi
    fi
    mkdir -p "$APP_PATH"/{nginx,db_data,wp_data,certbot/conf,certbot/www}
    chmod 755 "$APP_PATH"
    chmod 700 "$APP_PATH"/db_data
    chmod 755 "$APP_PATH"/{nginx,wp_data,certbot}
    # Check disk space
    local free_space
    free_space=$(df -k "$(dirname "$APP_PATH")" | tail -1 | awk '{print $4}')
    if [ "$free_space" -lt "$REQUIRED_SPACE" ]; then
        log "Error: At least 3GB of free space is required"
        exit 1
    fi
    log "✓ Directories created successfully"
}

# Copy configuration files to the app directory
copy_config_files() {
    cp "$SCRIPT_DIR/docker-compose.yml" "$APP_PATH/"
    cp "$SCRIPT_DIR/.env" "$APP_PATH/"
    cp "$SCRIPT_DIR/load_env.sh" "$APP_PATH/"
    cp "$SCRIPT_DIR/restart.sh" "$APP_PATH/"
    cp "$SCRIPT_DIR/monitor.sh" "$APP_PATH/"
    chmod 600 "$APP_PATH/.env"
    chmod 700 "$APP_PATH"/{restart.sh,monitor.sh}
    log "✓ Configuration files copied"
}

# Create configuration files for Docker and Nginx
create_config_files() {
    cat > /etc/systemd/system/wordpress-restart.service << EOL
[Unit]
Description=WordPress Docker Restart Service
After=docker.service network.target
Requires=docker.service

[Service]
Type=oneshot
User=root
WorkingDirectory=$APP_PATH
ExecStart=/usr/bin/bash $APP_PATH/restart.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL
    chmod 644 /etc/systemd/system/wordpress-restart.service
    log "✓ Systemd restart wordpress service file created"
    if [ "$USE_SSL" = "true" ] && [ "$USE_WEBSERVER" = "true" ]; then
        cat > $APP_PATH/ssl-renew.sh << 'EOL'
#!/bin/bash
docker-compose -f $APP_PATH/docker-compose.yml run --rm certbot renew
docker-compose -f $APP_PATH/docker-compose.yml restart webserver
EOL
        log "✓ SSL renewal script created"
        if [ "$USE_WEBSERVER" = "true" ]; then
            cat > $APP_PATH/nginx/default.conf << EOL
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 64M;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        proxy_pass http://wordpress_wordpress_1;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
    }
}
EOL
    echo "✓ Nginx initial configuration created"
        fi
    fi
}

# Install Docker and required packages
install_docker() {
    log "Installing Docker client..."
    apt update && apt upgrade -y

    log "Installing dependencies..."
    apt install -y apt-transport-https ca-certificates curl gnupg lsb-release python3-pip

    log "Adding Docker repository..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    log "Installing Docker client packages..."
    apt update
    apt install -y docker-ce docker-ce-cli docker-compose containerd.io docker-compose-plugin certbot python3-certbot-nginx

    # Configure Docker socket permissions
    log "Configuring Docker permissions..."
    DOCKER_SOCKET=/var/run/docker.sock
    if [ -S "$DOCKER_SOCKET" ]; then
        DOCKER_GID=$(stat -c '%g' "$DOCKER_SOCKET")
        GROUP_EXISTS=$(getent group "$DOCKER_GID" || true)
        
        if [ -z "$GROUP_EXISTS" ]; then
            log "Creating docker group..."
            groupadd -g "$DOCKER_GID" docker
        fi
        
        log "Adding current user to docker group..."
        usermod -aG "$DOCKER_GID" root
        
        # Apply new group permissions
        log "Applying new group permissions..."
        chmod 666 "$DOCKER_SOCKET"
        
        log "Testing Docker connectivity..."
        if ! docker version >/dev/null 2>&1; then
            log "Error: Docker is still not accessible after permission changes"
            return 1
        fi
    else
        log "Error: Docker socket not found at $DOCKER_SOCKET"
        return 1
    fi

    log "✓ Docker client installed successfully"
}
install_docker_old() {
    log "Updating system packages..."
    apt update && apt upgrade -y

    log "Installing dependencies..."
    apt install -y apt-transport-https ca-certificates curl gnupg lsb-release python3-pip

    apt remove -y docker docker-engine docker.io containerd runc || true
    rm -rf /var/lib/docker /var/lib/containerd || true

    log "Adding Docker repository..."
    # Add GPG docker key
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add repository
    # deprecated log "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    echo \
        "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    log "Installing Docker and required packages..."
    apt update
    apt install -y docker-ce docker-ce-cli docker-compose containerd.io docker-compose-plugin certbot python3-certbot-nginx

    if [ -f "/etc/init.d/docker" ]; then
        sed -i 's/ulimit -n 1048576/# ulimit -n 1048576/' /etc/init.d/docker
        sed -i 's/ulimit -u 1048576/# ulimit -u 1048576/' /etc/init.d/docker
    fi

    if is_container; then
        # Create minimal Docker configuration
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json <<EOF
{
    "iptables": false,
    "live-restore": true,
    "debug": true
}
EOF
        
        # Trying to start Docker without systemd
        dockerd &>/var/log/dockerd.log &
        DOCKER_PID=$!
        
        # Wait for Docker socket to become available
        log "Waiting for Docker socket to become available..."
        TIMEOUT=30
        COUNTER=0
        while [ ! -S /var/run/docker.sock ] && [ $COUNTER -lt $TIMEOUT ]; do
            sleep 1
            COUNTER=$((COUNTER + 1))
        done

        if [ ! -S /var/run/docker.sock ]; then
            log "Error: Docker failed to start. Check /var/log/dockerd.log for details"
            exit 1
        fi
    else
        systemctl enable docker.service
        systemctl start docker.service
    fi

    # Verify the installation
    timeout 30 sh -c 'until docker version &>/dev/null; do sleep 1; done' || {
        log "Error: Docker installation verification failed"
        exit 1
    }
    
    log "✓ Docker installed and running"
}

# Enable and check services
enable_checking_services() {
    if [ "$USE_WEBSERVER" = "true" ]; then
        if ! command -v ufw >/dev/null 2>&1; then
            log "Installing UFW firewall..."
            apt install -y ufw lsof
        fi
        ufw allow 80/tcp
        if [ "$USE_SSL" = "true" ]; then
            ufw allow 443/tcp
        fi
        ufw enable
        log "Firewal status:"
        ufw status
        log "✓ Firewall configured"

        if lsof -i :80 >/dev/null 2>&1; then
            log "Stopping services using port 80..."
            systemctl stop apache2 2>/dev/null || true
            systemctl stop nginx 2>/dev/null || true
        fi
        log "✓ Conflicting services stopped"
    fi
}

# Configure SSL
configure_ssl() {
    if [ "$USE_SSL" = "true" ]; then
        while [ "$(docker ps -q --filter name=wordpress_webserver_1 | xargs docker inspect -f '{{.State.Running}}' 2>/dev/null)" != "true" ]; do
            echo "Waiting for webserver container to be running..."
            sleep 5
        done
        cat > $APP_PATH/nginx/default.conf << EOL
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    client_max_body_size 64M;

    location / {
        proxy_pass http://wordpress:80;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
    }
}
EOL
        log "✓ Nginx ssl configuration created"
        #docker-compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot -d $DOMAIN
        docker-compose run --rm certbot certonly \
            --webroot \
            --webroot-path /var/www/certbot \
            --agree-tos \
            --no-eff-email \
            -d "$DOMAIN"
        log "✓ SSL certificate obtained"
        chmod +x $APP_PATH/ssl-renew.sh
        (crontab -l 2>/dev/null; echo "0 12 1,15 * * $APP_PATH/ssl-renew.sh >> /var/log/le-renew.log 2>&1") | crontab -
        log "✓ SSL auto-renewal configured"
    else
        log "Skipping SSL configuration because USE_SSL is set to false"
    fi
}

# Create systemd services and aliases
create_services() {
    systemctl daemon-reload
    systemctl enable wordpress-restart.service
    systemctl start wordpress-restart.service
    log "✓ Systemd wordpress-restart service created"

    log "alias wp-monitor='$APP_PATH/monitor.sh'" >> /etc/bash.bashrc
    log "alias wp-restart='$APP_PATH/restart.sh'" >> /etc/bash.bashrc
    source /etc/bash.bashrc
    log "✓ Aliases created"
}

start_containers() {
    log "Verifying Docker service..."
    if ! check_docker_running; then
        log "Error: Docker service is not running properly"
        exit 1
    fi
    log "✓ Docker service is running"

    log "Starting Docker containers..."
    cd "$APP_PATH" || exit 1
    docker-compose down 2>/dev/null || true  # Ensure that any existing containers are stopped
    
    PROFILES="--profile always"
    if [ "$USE_WEBSERVER" = "true" ]; then
        PROFILES="--profile always --profile webserver"
        if [ "$USE_SSL" = "true" ]; then
            PROFILES="$PROFILES --profile ssl"
        fi
    fi

    docker-compose $PROFILES up -d
}

# Main installation process
main() {
    log "=== Starting WordPress with Docker installation process ==="
    
    log "Step 1: Performing pre-flight checks..."
    preflight_checks

    log "Step 2: Creating necessary directories..."
    create_directories

    log "Step 3: Copying configuration files..."
    copy_config_files

    log "Step 4: Creating configuration files..."
    create_config_files

    log "Step 5: Installing Docker and required packages..."
    install_docker

    log "Step 6: Enabling and checking services..."
    enable_checking_services

    log "Step 7: Starting Docker containers..."
    start_containers

    log "Step 8: Configuring SSL..."
    configure_ssl

    log "Step 9: Creating services..."
    create_services

    log "=== Installation completed successfully! ==="
    log "WordPress site is available at https://$DOMAIN"
    log "SSL certificates will automatically renew on the 1st and 15th of each month"
    log "Use 'wp-monitor' to check installation status"
    log "Use 'wp-restart' to restart the installation"
}

# Start installation
main "$@"