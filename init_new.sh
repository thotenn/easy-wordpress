#!/bin/bash

# WordPress Docker Installation Script
# For Ubuntu 24.04 LTS
# This script sets up a WordPress site with Docker, Nginx, and SSL

# Error handling
set -e
set -o pipefail

# Global variables
REQUIRED_SPACE=5242880  # 5GB in KB
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

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

# Pre-flight checks
preflight_checks() {
    if [ "$EUID" -ne 0 ]; then 
        log "Error: This script must be run as root"
        exit 1
    fi

    # Load environment variables
    source "$PROJECT_ROOT/load_env.sh"
    load_env

    if [ -z "${APP_PATH:-}" ] || [ -z "${DOMAIN:-}" ]; then
        log "Error: APP_PATH or DOMAIN variables are not set"
        exit 1
    fi

    # Required environment variables check
    local required_vars=(
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

    # Check disk space
    local free_space
    free_space=$(df -k "$(dirname "$APP_PATH")" | tail -1 | awk '{print $4}')
    if [ "$free_space" -lt "$REQUIRED_SPACE" ]; then
        log "Error: At least 5GB of free space is required"
        exit 1
    fi
}

# Create necessary directories with proper permissions
create_directories() {
    log "Creating necessary directories..."
    mkdir -p "$APP_PATH"/{nginx,db_data,wp_data,certbot/conf,certbot/www}
    chmod 755 "$APP_PATH"
    chmod 700 "$APP_PATH"/db_data
    chmod 755 "$APP_PATH"/{nginx,wp_data,certbot}
    log "✓ Directories created successfully"
}

# Create SSL renewal script
create_ssl_renewal() {
    log "Creating SSL renewal script..."
    cat > "$APP_PATH/ssl-renew.sh" << 'EOL'
#!/bin/bash
docker-compose -f "$APP_PATH/docker-compose.yml" run --rm certbot renew
docker-compose -f "$APP_PATH/docker-compose.yml" restart webserver
EOL
    chmod 700 "$APP_PATH/ssl-renew.sh"
}

# Create initial Nginx configuration
create_nginx_config() {
    log "Creating Nginx configuration..."
    
    if [ "${USE_SSL:-false}" = "true" ]; then
        log "Creating initial Nginx configuration for SSL certificate acquisition..."
        cat > "$APP_PATH/nginx/default.conf" << EOL
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 64M;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

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

        log "Waiting for initial configuration to take effect..."
        sleep 10

        log "Creating SSL-enabled Nginx configuration..."
        cat > "$APP_PATH/nginx/default.conf" << EOL
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";
    
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

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    # HSTS (uncomment if you're sure)
    # add_header Strict-Transport-Security "max-age=63072000" always;

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
        
        client_max_body_size 64M;
    }
}
EOL
    chmod 644 "$APP_PATH/nginx/default.conf"
}

# Install Docker and dependencies
install_docker() {
    log "Updating system packages..."
    apt update && apt upgrade -y

    log "Installing dependencies..."
    apt install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        ufw

    log "Adding Docker repository..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    log "Installing Docker and required packages..."
    apt update
    apt install -y docker-ce docker-ce-cli docker-compose containerd.io certbot python3-certbot-nginx

    if ! docker --version; then
        log "Error: Docker installation failed"
        exit 1
    fi
}

# Copy configuration files
copy_config_files() {
    log "Copying configuration files..."
    cp "$SCRIPT_DIR/docker-compose.yml" "$APP_PATH/"
    cp "$SCRIPT_DIR/.env" "$APP_PATH/"
    cp "$SCRIPT_DIR/load_env.sh" "$APP_PATH/"
    cp "$SCRIPT_DIR/restart.sh" "$APP_PATH/"
    cp "$SCRIPT_DIR/monitor.sh" "$APP_PATH/"
    chmod 600 "$APP_PATH/.env"
    chmod 700 "$APP_PATH"/{restart.sh,monitor.sh}
}

# Configure firewall
configure_firewall() {
    log "Configuring firewall..."
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
}

# Start Docker containers
start_containers() {
    log "Starting Docker containers..."
    cd "$APP_PATH" || exit 1
    docker-compose down -v 2>/dev/null || true
    docker-compose up -d

    local retries=0
    local max_retries=12
    while [ "$(docker ps -q --filter name=webserver | wargs docker inspect -f '{{.State.Running}}' 2>/dev/null)" != "true" ]; do
        if [ $retries -ge $max_retries ]; then
            log "Error: Webserver container failed to start"
            exit 1
        fi
        log "Waiting for webserver container..."
        sleep 5
        ((retries++))
    done
}

# Configure SSL
configure_ssl() {
    if [ "${USE_SSL:-false}" = "true" ]; then
        log "Obtaining SSL certificate..."
        docker-compose run --rm certbot certonly \
            --webroot \
            --webroot-path /var/www/certbot \
            --agree-tos \
            --no-eff-email \
            -d "$DOMAIN"

        # Set up auto-renewal
        (crontab -l 2>/dev/null; echo "0 12 1,15 * * $APP_PATH/ssl-renew.sh >> /var/log/le-renew.log 2>&1") | crontab -
        log "SSL configured successfully"
    else
        log "Skipping SSL configuration as USE_SSL is not enabled"
    fi
}

# Create systemd service
create_systemd_service() {
    log "Creating systemd service..."
    cat > /etc/systemd/system/wordpress-docker.service << EOL
[Unit]
Description=WordPress Docker Service
After=docker.service network-online.target
Requires=docker.service network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=$APP_PATH
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

    chmod 644 /etc/systemd/system/wordpress-docker.service
    systemctl daemon-reload
    systemctl enable wordpress-docker.service
}

# Set up monitoring
setup_monitoring() {
    log "Setting up monitoring..."
    echo "alias wp-monitor='sudo $APP_PATH/monitor.sh'" >> /etc/bash.bashrc
    echo "alias wp-restart='sudo $APP_PATH/restart.sh'" >> /etc/bash.bashrc
    source /etc/bash.bashrc
}

# Main installation process
main() {
    log "=== Starting WordPress with Docker installation process ==="
    
    preflight_checks
    create_directories
    copy_config_files
    if [ "${USE_SSL:-false}" = "true" ]; then
        create_ssl_renewal
    fi
    create_nginx_config
    install_docker
    configure_firewall
    start_containers
    configure_ssl
    create_systemd_service
    setup_monitoring

    log "=== Installation completed successfully! ==="
    log "WordPress site is available at https://$DOMAIN"
    log "SSL certificates will automatically renew on the 1st and 15th of each month"
    log "Use 'wp-monitor' to check installation status"
    log "Use 'wp-restart' to restart the installation"
}

# Start installation
main "$@"