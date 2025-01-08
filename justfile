# Justfile for prometheus learning environment

# Set some default variables
vm_name := "prometheus"
vm_cpu := "2"
vm_memory := "4GB"
prom_version := "2.49.1"  # Latest stable as of now
node_exporter_version := "1.7.0"
prom_dir := "/opt/prometheus"
rules_dir := "config/rules"
ssh_opts := "-q -l ubuntu -i .ssh/prometheus_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
scp_opts := "-q -i .ssh/prometheus_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Default network settings - can be overridden by .env file or environment variables
default_ip := "10.196.3.153"
vm_ip := env_var_or_default("PROMETHEUS_VM_IP", default_ip)

# List available recipes
default:
    @just --list

# Generate a new IP address in the LXD bridge network range
generate-ip:
    #!/usr/bin/env bash
    bridge_ip=$(lxc network get lxdbr0 ipv4.address | cut -d'/' -f1)
    # Get first three octets of bridge IP
    prefix=$(echo $bridge_ip | cut -d'.' -f1-3)
    # Generate random last octet (avoiding .1 which is usually the bridge)
    last_octet=$((RANDOM % 250 + 2))
    suggested_ip="$prefix.$last_octet"
    echo "Suggested IP: $suggested_ip"
    echo "To use this IP, run: export PROMETHEUS_VM_IP=$suggested_ip"
    # Check if IP is available
    if ping -c 1 -W 1 $suggested_ip >/dev/null 2>&1; then
        echo "Warning: IP $suggested_ip appears to be in use"
    else
        echo "IP $suggested_ip appears to be available"
    fi

# Show current network configuration
show-network-config:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    echo "Current configuration:"
    echo "VM IP: $VM_IP"
    echo "LXD bridge configuration:"
    lxc network show lxdbr0 | grep -E "ipv4.address|ipv4.nat|ipv4.range"

# # Validate IP address format and availability
# check-ip ip=vm_ip:
#     #!/usr/bin/env bash
#     if [[ ! {{ip}} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
#         echo "Error: Invalid IP address format: {{ip}}"
#         exit 1
#     fi
#     if ping -c 1 -W 1 {{ip}} >/dev/null 2>&1; then
#         echo "Warning: IP {{ip}} appears to be in use"
#         exit 1
#     fi
#     echo "IP {{ip}} appears to be valid and available"

# Setup SSH keys for the project
setup-keys:
    #!/usr/bin/env bash
    echo "Setting up SSH keys for Prometheus project..."
    mkdir -p .ssh
    if [ ! -f .ssh/prometheus_ed25519 ]; then
        ssh-keygen -t ed25519 -f .ssh/prometheus_ed25519 -N '' -C "prometheus@local"
        echo "SSH keys generated in .ssh/prometheus_ed25519"
    else
        echo "SSH keys already exist in .ssh/prometheus_ed25519"
    fi
    # Create cloud-init directory if it doesn't exist
    mkdir -p cloud-init
    # Create cloud-init/user-data file
    echo "#cloud-config" > cloud-init/user-data
    echo "users:" >> cloud-init/user-data
    echo "  - default" >> cloud-init/user-data
    echo "  - name: ubuntu" >> cloud-init/user-data
    echo "    gecos: ubuntu" >> cloud-init/user-data
    echo "    shell: /bin/bash" >> cloud-init/user-data
    echo "    sudo: ['ALL=(ALL) NOPASSWD:ALL']" >> cloud-init/user-data
    echo "    ssh_authorized_keys:" >> cloud-init/user-data
    echo "      - $(cat .ssh/prometheus_ed25519.pub)" >> cloud-init/user-data
    echo "cloud-init/user-data created with new SSH key"

# Create IP profile
create-profile:
    #!/usr/bin/env bash
    echo "Creating network profile on br0"
    lxc profile create prometheus-net || true
    lxc profile device add prometheus-net root disk pool=default path=/ || true
    lxc profile device add prometheus-net eth0 nic \
        nictype=bridged \
        parent=br0 || true

# Delete profile if it exists
delete-profile:
    #!/usr/bin/env bash
    if lxc profile show prometheus-net >/dev/null 2>&1; then \
        echo "Deleting profile prometheus-net." && \
        lxc profile delete prometheus-net; \
    else \
        echo "No profile prometheus-net found to delete"; \
    fi

# Deploy the LXC VM for Prometheus
deploy-vm: create-profile
    #!/usr/bin/env bash
    echo "Deploying Prometheus VM"
    lxc launch ubuntu:22.04 {{vm_name}} \
        --vm \
        -c limits.cpu={{vm_cpu}} \
        -c limits.memory={{vm_memory}} \
        --profile prometheus-net \
        --config=user.user-data="$(cat cloud-init/user-data)"

    echo "Waiting for VM to get IP address..."
    while ! lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' > /dev/null; do
        sleep 1
    done

    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    echo "VM IP address: $VM_IP"

    echo "Waiting for SSH to be available on $VM_IP"
    while ! nc -zv $VM_IP 22 2>/dev/null; do
        sleep 1
    done
    echo "SSH is now available on $VM_IP"

# Install Prometheus on the VM
install-prometheus:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    ssh {{ssh_opts}} $VM_IP "sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y wget tar >/dev/null 2>&1" && \
    ssh {{ssh_opts}} $VM_IP "wget -q https://github.com/prometheus/prometheus/releases/download/v{{prom_version}}/prometheus-{{prom_version}}.linux-amd64.tar.gz" && \
    ssh {{ssh_opts}} $VM_IP "sudo mkdir -p {{prom_dir}} && sudo tar xzf prometheus-{{prom_version}}.linux-amd64.tar.gz -C {{prom_dir}} --strip-components=1" && \
    ssh {{ssh_opts}} $VM_IP "sudo mkdir -p {{prom_dir}}/rules" && \
    ssh {{ssh_opts}} $VM_IP "sudo useradd -rs /bin/false prometheus || true" && \
    ssh {{ssh_opts}} $VM_IP "sudo chown -R prometheus:prometheus {{prom_dir}}" && \
    echo "Prometheus installed in {{prom_dir}}"


# Upload and setup Prometheus config
setup-config:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    scp {{scp_opts}} config/prometheus.yml "ubuntu@$VM_IP:/tmp/prometheus.yml" >/dev/null && \
    ssh {{ssh_opts}} $VM_IP 'sudo mv /tmp/prometheus.yml {{prom_dir}}/prometheus.yml' && \
    ssh {{ssh_opts}} $VM_IP 'sudo chown prometheus:prometheus {{prom_dir}}/prometheus.yml'

# Upload and setup Prometheus config
setup-node-config:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    scp {{scp_opts}} config/node-prometheus.yml "ubuntu@$VM_IP:/tmp/prometheus.yml" >/dev/null && \
    ssh {{ssh_opts}} $VM_IP 'sudo mv /tmp/prometheus.yml {{prom_dir}}/prometheus.yml' && \
    ssh {{ssh_opts}} $VM_IP 'sudo chown prometheus:prometheus {{prom_dir}}/prometheus.yml'

# Start the Prometheus server
start-prometheus:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    echo "Creating systemd service." && \
    echo "Creating systemd service." && \
    scp {{scp_opts}} templates/prometheus.service "ubuntu@$VM_IP:/tmp/prometheus.service" >/dev/null && \
    ssh {{ssh_opts}} $VM_IP 'sudo mv /tmp/prometheus.service /etc/systemd/system/prometheus.service' && \
    ssh {{ssh_opts}} $VM_IP "sudo systemctl daemon-reload" && \
    ssh {{ssh_opts}} $VM_IP "sudo systemctl start prometheus" && \
    ssh {{ssh_opts}} $VM_IP "sudo systemctl enable prometheus" && \
    echo "Prometheus started and enabled"

# Show Prometheus status
prom-status:
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    ssh {{ssh_opts}} $VM_IP "sudo systemctl status prometheus"

# Show Prometheus logs
prom-logs:
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    ssh {{ssh_opts}} $VM_IP "sudo journalctl -u prometheus -f"

# Debug Prometheus configuration and logs
debug-prometheus:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    echo "1. Current Prometheus configuration:"
    ssh {{ssh_opts}} $VM_IP "cat {{prom_dir}}/prometheus.yml"
    echo -e "\n2. Last 10 lines of Prometheus logs:"
    ssh {{ssh_opts}} $VM_IP "sudo journalctl -u prometheus -n 10 --no-pager"
    echo -e "\n3. Checking Prometheus API targets:"
    ssh {{ssh_opts}} $VM_IP "curl -s localhost:9090/api/v1/targets | jq '.'"

# Install debug tools and restart Prometheus
fix-prometheus:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    echo "1. Installing jq..."
    ssh {{ssh_opts}} $VM_IP "sudo apt-get update -qq && sudo apt-get install -y jq >/dev/null 2>&1"

    echo "2. Restarting Prometheus..."
    ssh {{ssh_opts}} $VM_IP "sudo systemctl restart prometheus"
    echo "Waiting for Prometheus to start..."
    sleep 5

    echo "3. Checking targets status:"
    ssh {{ssh_opts}} $VM_IP 'curl -s localhost:9090/api/v1/targets | jq -r ".data.activeTargets[] | .labels.job + \": \" + .health"'

# Reload Prometheus configuration with verification
reload-prometheus:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    echo "1. Validating configuration..."
    if ! ssh {{ssh_opts}} $VM_IP "{{prom_dir}}/promtool check config {{prom_dir}}/prometheus.yml"; then
        echo "Configuration check failed!"
        exit 1
    fi

    echo "2. Restarting Prometheus to apply changes..."
    ssh {{ssh_opts}} $VM_IP "sudo systemctl restart prometheus"

    echo "3. Waiting for Prometheus to become ready..."
    for i in {1..60}; do
        if ssh {{ssh_opts}} $VM_IP "curl -s -f http://localhost:9090/-/ready > /dev/null"; then
            echo "✓ Prometheus is ready"
            break
        fi
        if [ $i -eq 60 ]; then
            echo "! Timed out waiting for Prometheus to become ready"
            exit 1
        fi
        echo -n "."
        sleep 1
    done

    echo "4. Verifying configuration..."
    sleep 5  # Give Prometheus a moment to attempt scrapes
    ssh {{ssh_opts}} $VM_IP 'curl -s localhost:9090/api/v1/targets | jq -r ".data.activeTargets[] | \"Target: \" + .labels.job + \", State: \" + .health + \", Last Scrape: \" + .lastScrape"'


# Delete VM if it exists
delete-vm:
    #!/usr/bin/env bash
    if lxc info {{vm_name}} >/dev/null 2>&1; then \
        echo "Deleting VM {{vm_name}}." && \
        lxc delete --force {{vm_name}}; \
    else \
        echo "No VM named {{vm_name}} found to delete"; \
    fi

# Get the VM's IP address (make it silent)
get-ip:
    @lxc list {{vm_name}} -f csv -c 4 | cut -d' ' -f1

# SSH to the LXC VM
ssh:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    ssh {{ssh_opts}} $VM_IP

# Check the status of the VM
vm-status:
    lxc list {{vm_name}}

# # Add proxy device to forward port 9090
# setup-proxy:
#     #!/usr/bin/env bash
#     VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
#     HOST_IP=$(ip route get 1 | awk '{print $(NF-2);exit}') && \
#     lxc config device add {{vm_name}} prometheus-ui proxy \
#         listen=tcp:$HOST_IP:9090 \
#         connect=tcp:$VM_IP:9090 \
#         nat=true \
#         bind=host
#         echo "" && \
#     echo "Proxy setup complete! You can now access Prometheus at:" && \
#     echo "  • http://${HOST_IP}:9090" && \
#     echo "  • http://localhost:9090    (if accessing from the host machine)" && \
#     echo "" && \
#     echo "Note: To remove the proxy later, run: just remove-proxy"

# # Remove proxy device
# remove-proxy:
#     #!/usr/bin/env bash
#     if lxc config device show {{vm_name}} prometheus-ui >/dev/null 2>&1; then
#         echo "Removing proxy device from {{vm_name}}"
#         lxc config device remove {{vm_name}} prometheus-ui
#     else
#         echo "No proxy device 'prometheus-ui' found on {{vm_name}}"
#     fi

# # Show proxy configuration
# show-proxy:
#     lxc config device show {{vm_name}}

# Show VM network info
show-net:
    lxc list {{vm_name}} -c n --format json | jq '.[0].state.network'

# Show VM network info in a more readable format
show-ip-info:
    lxc list {{vm_name}} -f json | jq -r '.[0].state.network | to_entries[] | .key as $interface | .value.addresses[] | select(.family=="inet") | "\($interface): \(.address)"'

# Deploy a fresh environment
setup: cleanup setup-keys deploy-vm install-prometheus setup-config start-prometheus
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    echo "Prometheus setup complete!"
    # Get the host IP address that's reachable
    HOST_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
    HOST_NET=$(echo $HOST_IP | cut -d. -f1-3)
    VM_NET=$(echo $VM_IP | cut -d. -f1-3)

    echo "Access the web interface at:"
    echo "  - http://localhost:9090"
    if [ "$HOST_NET" = "$VM_NET" ]; then
        echo "  - http://${VM_IP}:9090    (direct VM access)"
    else
        echo "  - http://${HOST_IP}:9090"
    fi

    # Verify Prometheus is responding
    echo "Waiting for Prometheus to become available..."
    for i in {1..30}; do
        if [ "$HOST_NET" = "$VM_NET" ]; then
            HEALTH_URL="http://${VM_IP}:9090/-/healthy"
        else
            HEALTH_URL="http://localhost:9090/-/healthy"
        fi

        if curl -s $HEALTH_URL >/dev/null; then
            echo "✓ Prometheus is up and running"
            exit 0
        fi
        sleep 1
    done
    echo "! Warning: Prometheus is not responding. Check 'just prom-status' for details"

# # Install and configure node_exporter
# install-node-exporter:
#     #!/usr/bin/env bash
#     VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
#     echo "Installing node_exporter {{node_exporter_version}}..."
#     # Download and install binary
#     ssh {{ssh_opts}} $VM_IP "\
#         wget -q https://github.com/prometheus/node_exporter/releases/download/v{{node_exporter_version}}/node_exporter-{{node_exporter_version}}.linux-amd64.tar.gz && \
#         tar xzf node_exporter-*.tar.gz && \
#         sudo mv node_exporter-*/node_exporter /usr/local/bin/ && \
#         rm -rf node_exporter-* && \
#         sudo useradd -rs /bin/false node_exporter || true"

#     # Upload and enable service
#     scp {{scp_opts}} templates/node_exporter.service "ubuntu@$VM_IP:/tmp/node_exporter.service" >/dev/null && \
#     ssh {{ssh_opts}} {{vm_ip}} "\
#         sudo mv /tmp/node_exporter.service /etc/systemd/system/ && \
#         sudo systemctl daemon-reload && \
#         sudo systemctl start node_exporter && \
#         sudo systemctl enable node_exporter" && \
#     echo "✓ Node Exporter installed and running on port 9100"

# Install and configure node_exporter
install-node-exporter:
    #!/usr/bin/env bash
    set -e
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    if [ -z "$VM_IP" ]; then
        echo "Error: Could not determine VM IP address"
        exit 1
    fi
    echo "Using VM IP: $VM_IP"

    # Check if node_exporter is already installed and running
    if ssh {{ssh_opts}} $VM_IP "systemctl is-active --quiet node_exporter"; then
        echo "Node Exporter is already running"
        exit 0
    fi

    echo "Installing node_exporter {{node_exporter_version}}..."

    # Create user if doesn't exist
    ssh {{ssh_opts}} $VM_IP "sudo useradd -rs /bin/false node_exporter || true"

    # Only download and install if binary doesn't exist or version is different
    if ! ssh {{ssh_opts}} $VM_IP "test -f /usr/local/bin/node_exporter && /usr/local/bin/node_exporter --version | grep '{{node_exporter_version}}'"; then
        echo "Downloading and installing node_exporter binary..."
        ssh {{ssh_opts}} $VM_IP "\
            wget -q https://github.com/prometheus/node_exporter/releases/download/v{{node_exporter_version}}/node_exporter-{{node_exporter_version}}.linux-amd64.tar.gz && \
            tar xzf node_exporter-*.tar.gz && \
            sudo mv node_exporter-*/node_exporter /usr/local/bin/ && \
            rm -rf node_exporter-*"
    fi

    # Upload and enable service
    echo "Setting up systemd service..."
    scp {{scp_opts}} templates/node_exporter.service "ubuntu@$VM_IP:/tmp/node_exporter.service" >/dev/null
    ssh {{ssh_opts}} $VM_IP "\
        sudo mv /tmp/node_exporter.service /etc/systemd/system/ && \
        sudo systemctl daemon-reload && \
        sudo systemctl start node_exporter && \
        sudo systemctl enable node_exporter"

    echo "✓ Node Exporter installed and running on port 9100"

# Check node_exporter status
node-exporter-status:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    ssh {{ssh_opts}} $VM_IP "sudo systemctl status node_exporter"

# Show node_exporter metrics
node-exporter-metrics:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    @ssh {{ssh_opts}} $VM_IP "curl -s localhost:9100/metrics | head -n 5"
    @echo "..."
    @echo "To see all metrics, run: ssh $VM_IP 'curl localhost:9100/metrics'"

# Verify node_exporter is accessible
verify-node-exporter:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    echo "1. Checking node_exporter service status:"
    ssh {{ssh_opts}} $VM_IP "sudo systemctl status node_exporter --no-pager"
    echo -e "\n2. Testing node_exporter metrics endpoint:"
    ssh {{ssh_opts}} $VM_IP "curl -s localhost:9100/metrics | head -n 1"
    echo -e "\n3. Checking open ports:"
    ssh {{ssh_opts}} $VM_IP "sudo ss -tlnp | grep 9100"

configure-node-exporter: install-node-exporter setup-node-config reload-prometheus
    #!/usr/bin/env bash
    echo "Node exporter setup complete!"

# Remove node_exporter and cleanup configurations
remove-node-exporter:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    echo "1. Stopping node_exporter service..."
    ssh {{ssh_opts}} $VM_IP "sudo systemctl stop node_exporter || true"
    ssh {{ssh_opts}} $VM_IP "sudo systemctl disable node_exporter || true"

    echo "2. Removing node_exporter files..."
    ssh {{ssh_opts}} $VM_IP "\
        sudo rm -f /etc/systemd/system/node_exporter.service && \
        sudo rm -f /usr/local/bin/node_exporter && \
        sudo systemctl daemon-reload"

    echo "3. Removing node_exporter user..."
    ssh {{ssh_opts}} $VM_IP "sudo userdel -r node_exporter || true"

    echo "4. Restoring original Prometheus config..."
    just setup-config

    echo "5. Restarting Prometheus with new configuration..."
    just reload-prometheus

    echo "6. Verifying cleanup..."
    if ssh {{ssh_opts}} $VM_IP "ss -tlnp | grep 9100"; then
        echo "! Warning: Port 9100 is still in use"
        exit 1
    else
        echo "✓ Port 9100 is free"
    fi

# Setup alert rules
setup-alerts:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')

    # Upload rules file
    echo "Uploading rules..."
    scp {{scp_opts}} {{rules_dir}}/rules.yml ubuntu@$VM_IP:/tmp/rules.yml
    ssh {{ssh_opts}} $VM_IP "sudo mv /tmp/rules.yml {{prom_dir}}/rules/ && sudo chown prometheus:prometheus {{prom_dir}}/rules/rules.yml"

    echo "Validating and reloading configuration..."
    just reload-prometheus

    echo "Verifying alert rules..."
    ssh {{ssh_opts}} $VM_IP "curl -s localhost:9090/api/v1/rules | jq '.'"

# Install stress-ng and trigger CPU load
stress-cpu:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    echo "Installing stress-ng..."
    ssh {{ssh_opts}} $VM_IP "sudo apt-get update -qq && sudo apt-get install -y stress-ng > /dev/null 2>&1"

    echo "Starting CPU stress test..."
    echo "   - Duration: 10 minutes"
    echo "   - CPU Load: 30 workers"
    ssh {{ssh_opts}} $VM_IP "nohup sudo stress-ng --cpu 2 --cpu-load 30 --timeout 10m > /dev/null 2>&1 &"

    echo "Monitoring alert status..."
    echo "   Waiting for alert to trigger (this may take ~5 minutes)..."
    echo "   Check alert status with: just check-alerts"

# Monitor CPU usage
monitor-cpu:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    ssh {{ssh_opts}} $VM_IP "top -b -n 1 | head -n 3"

# Check if stress-ng is running
check-stress:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    echo "Checking stress-ng processes:"
    ssh {{ssh_opts}} $VM_IP "ps aux | grep stress-ng | grep -v grep || echo 'No stress-ng processes found'"

# Kill stress-ng processes
stop-stress:
    #!/usr/bin/env bash
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    echo "Stopping stress-ng processes..."
    ssh {{ssh_opts}} $VM_IP "sudo pkill stress-ng || true"
    echo "Checking for remaining processes..."
    just check-stress

# Delete vm and delete LXC profile
cleanup: delete-vm delete-profile

# Show setup help
help:
    VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    @echo "Prometheus Learning Environment Setup Help"
    @echo ""
    @echo "Default IP: {{default_ip}}"
    @echo "Current IP: $VM_IP"
    @echo ""
    @echo "To use a different IP address:"
    @echo "  1. Run 'just generate-ip' to get a suggested IP"
    @echo "  2. Run 'export PROMETHEUS_VM_IP=<ip>' before running setup"
    @echo "  3. Or create a .env file with PROMETHEUS_VM_IP=<ip>"
    @echo ""
    @echo "To see available commands, run 'just' or 'just --list'"

# # Document network access setup
# help-network:
#     VM_IP=$(lxc list {{vm_name}} -f csv | grep enp | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
#     @echo "Prometheus Network Access Guide"
#     @echo ""
#     @echo "Current VM IP: $VM_IP"
#     @echo ""
#     @echo "Standard Access (Local Development):"
#     @echo "  - Direct access via VM IP: http://$VM_IP:9090"
#     @echo ""
#     @echo "Remote Access Setup:"
#     @echo "  If you're accessing this machine via SSH and cannot reach $VM_IP:"
#     @echo "  1. Run 'just setup-proxy' to create a port forward"
#     @echo "  2. Access via http://<< IP of LXC host machine>>:9090"
#     @echo "  3. When done, run 'just remove-proxy' to clean up"