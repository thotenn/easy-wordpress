#!/bin/bash

source "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/load_env.sh"
load_env

# Colors for better visualization
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging function
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
    echo -e "$1"
}

# Check Docker containers
check_containers() {
    log_message "${BLUE}=== Containers Status ===${NC}"
    docker ps -a
    echo ""
    log_message "${BLUE}=== Active Containers: $(docker ps -q | wc -l) ===${NC}"
}

# Check container logs
check_container_logs() {
    echo -e "${BLUE}Select a container to view its logs:${NC}"
    docker ps --format "{{.Names}}" | nl
    read -p "Enter container number: " container_number
    
    container_name=$(docker ps --format "{{.Names}}" | sed -n "${container_number}p")
    if [ ! -z "$container_name" ]; then
        log_message "${BLUE}=== Logs for container $container_name ===${NC}"
        docker logs --tail 100 $container_name
    else
        log_message "${RED}Invalid container${NC}"
    fi
}

# Check RAM usage
check_ram_usage() {
    log_message "${BLUE}=== RAM Usage by Container ===${NC}"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
}

# Check Nginx status
check_nginx() {
    log_message "${BLUE}=== Webserver Status (Nginx) ===${NC}"
    if docker exec wordpress_webserver_1 nginx -t &> /dev/null; then
        log_message "${GREEN}Nginx is configured correctly${NC}"
    else
        log_message "${RED}Error in Nginx configuration${NC}"
        docker exec wordpress_webserver_1 nginx -t
    fi
    
    log_message "\nNginx service status:"
    docker exec wordpress_webserver_1 service nginx status
}

# Check crontab
check_crontab() {
    log_message "${BLUE}=== Scheduled Tasks (Crontab) ===${NC}"
    if [ -f "/var/spool/cron/crontabs/root" ]; then
        crontab -l
    else
        log_message "${YELLOW}No cron tasks configured${NC}"
    fi
}

# Check SSL certificates
check_ssl() {
    log_message "${BLUE}=== SSL Certificates Status ===${NC}"
    if [ -d "$APP_PATH/certbot/conf/live" ]; then
        for domain in $(ls $APP_PATH/certbot/conf/live); do
            cert_file="$APP_PATH/certbot/conf/live/$domain/cert.pem"
            if [ -f "$cert_file" ]; then
                expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
                log_message "Domain: $domain"
                log_message "Expiration date: $expiry_date"
            fi
        done
    else
        log_message "${YELLOW}No SSL certificates found${NC}"
    fi
}

# Check system logs
check_system_logs() {
    log_message "${BLUE}=== Latest System Logs ===${NC}"
    echo -e "1) WordPress Logs\n2) MySQL Logs\n3) Nginx Logs\n4) SSL renewal Logs"
    read -p "Select log type (1-4): " log_choice
    
    case $log_choice in
        1) docker logs wordpress_wordpress_1 --tail 50 ;;
        2) docker logs wordpress_db_1 --tail 50 ;;
        3) docker logs wordpress_webserver_1 --tail 50 ;;
        4) if [ -f "/var/log/le-renew.log" ]; then
               tail -n 50 /var/log/le-renew.log
           else
               log_message "${YELLOW}SSL renewal log file not found${NC}"
           fi ;;
        *) log_message "${RED}Invalid option${NC}" ;;
    esac
}

# Check systemd service status
check_systemd_service() {
    log_message "${BLUE}=== Systemd Service Status ===${NC}"
    systemctl status wordpress-restart.service
}

# Main menu
show_menu() {
    clear
    echo -e "${BLUE}=== WordPress Docker Monitor ===${NC}"
    echo "1) Container status"
    echo "2) Container logs"
    echo "3) RAM usage"
    echo "4) Nginx status"
    echo "5) Scheduled tasks (Crontab)"
    echo "6) SSL certificates status"
    echo "7) System logs"
    echo "8) Systemd service status"
    echo "9) Exit"
    echo -e "${YELLOW}Select an option (1-9):${NC}"
}

# Main loop
while true; do
    show_menu
    read -r option
    
    case $option in
        1) check_containers ;;
        2) check_container_logs ;;
        3) check_ram_usage ;;
        4) check_nginx ;;
        5) check_crontab ;;
        6) check_ssl ;;
        7) check_system_logs ;;
        8) check_systemd_service ;;
        9) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    
    echo -e "\n${YELLOW}Press ENTER to continue...${NC}"
    read
done