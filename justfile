# Justfile for prometheus learning environment

# Set some default variables
vm_name := "prometheus"
vm_cpu := "2"
vm_memory := "4GB"
prom_version := "2.49.1"  # Latest stable as of now
prom_dir := "/opt/prometheus"
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
    echo "Current configuration:"
    echo "VM IP: {{vm_ip}}"
    echo "LXD bridge configuration:"
    lxc network show lxdbr0 | grep -E "ipv4.address|ipv4.nat|ipv4.range"

# Validate IP address format and availability
check-ip ip=vm_ip:
    #!/usr/bin/env bash
    if [[ ! {{ip}} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Error: Invalid IP address format: {{ip}}"
        exit 1
    fi
    if ping -c 1 -W 1 {{ip}} >/dev/null 2>&1; then
        echo "Warning: IP {{ip}} appears to be in use"
        exit 1
    fi
    echo "IP {{ip}} appears to be valid and available"

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

# Create static IP profile
create-profile: (check-ip vm_ip)
    #!/usr/bin/env bash
    echo "Creating network profile with IP {{vm_ip}}"
    lxc profile create prometheus-net || true
    lxc profile device add prometheus-net root disk pool=default path=/ || true
    lxc profile device add prometheus-net eth0 nic \
        nictype=bridged \
        parent=lxdbr0 \
        ipv4.address={{vm_ip}} || true

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

    echo "VM IP address: {{vm_ip}}"

    echo "Waiting for SSH to be available on {{vm_ip}}"
    while ! nc -zv {{vm_ip}} 22 2>/dev/null; do
        sleep 1
    done
    echo "SSH is now available on {{vm_ip}}"

# Install Prometheus on the VM
install-prometheus:
    #!/usr/bin/env bash
    ssh {{ssh_opts}} {{vm_ip}} "sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y wget tar >/dev/null 2>&1" && \
    ssh {{ssh_opts}} {{vm_ip}} "wget -q https://github.com/prometheus/prometheus/releases/download/v{{prom_version}}/prometheus-{{prom_version}}.linux-amd64.tar.gz" && \
    ssh {{ssh_opts}} {{vm_ip}} "sudo mkdir -p {{prom_dir}} && sudo tar xzf prometheus-{{prom_version}}.linux-amd64.tar.gz -C {{prom_dir}} --strip-components=1" && \
    ssh {{ssh_opts}} {{vm_ip}} "sudo useradd -rs /bin/false prometheus || true" && \
    ssh {{ssh_opts}} {{vm_ip}} "sudo chown -R prometheus:prometheus {{prom_dir}}" && \
    echo "Prometheus installed in {{prom_dir}}"


# Upload and setup Prometheus config
setup-config:
    #!/usr/bin/env bash
    scp {{scp_opts}} config/prometheus.yml "ubuntu@{{vm_ip}}:/tmp/prometheus.yml" >/dev/null && \
    ssh {{ssh_opts}} {{vm_ip}} 'sudo mv /tmp/prometheus.yml {{prom_dir}}/prometheus.yml' && \
    ssh {{ssh_opts}} {{vm_ip}} 'sudo chown prometheus:prometheus {{prom_dir}}/prometheus.yml'

# Start the Prometheus server
start-prometheus:
    #!/usr/bin/env bash
    echo "Creating systemd service." && \
    scp {{scp_opts}} templates/prometheus.service "ubuntu@{{vm_ip}}:/tmp/prometheus.service" >/dev/null && \
    ssh {{ssh_opts}} {{vm_ip}} 'sudo mv /tmp/prometheus.service /etc/systemd/system/prometheus.service' && \
    ssh {{ssh_opts}} {{vm_ip}} "sudo systemctl daemon-reload" && \
    ssh {{ssh_opts}} {{vm_ip}} "sudo systemctl start prometheus" && \
    ssh {{ssh_opts}} {{vm_ip}} "sudo systemctl enable prometheus" && \
    echo "Prometheus started and enabled"

# Show Prometheus status
prom-status:
    ssh {{ssh_opts}} {{vm_ip}} "sudo systemctl status prometheus"

# Show Prometheus logs
prom-logs:
    ssh {{ssh_opts}} {{vm_ip}} "sudo journalctl -u prometheus -f"

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
    ssh {{ssh_opts}} {{vm_ip}}

# Check the status of the VM 
vm-status:
    lxc list {{vm_name}}

# Add proxy device to forward port 9090
setup-proxy:
    #!/usr/bin/env bash
    HOST_IP=$(ip route get 1 | awk '{print $(NF-2);exit}') && \
    lxc config device add {{vm_name}} prometheus-ui proxy \
        listen=tcp:$HOST_IP:9090 \
        connect=tcp:{{vm_ip}}:9090 \
        nat=true \
        bind=host
        echo "" && \
    echo "Proxy setup complete! You can now access Prometheus at:" && \
    echo "  • http://${HOST_IP}:9090" && \
    echo "  • http://localhost:9090    (if accessing from the host machine)" && \
    echo "" && \
    echo "Note: To remove the proxy later, run: just remove-proxy"

# Remove proxy device
remove-proxy:
    #!/usr/bin/env bash
    if lxc config device show {{vm_name}} prometheus-ui >/dev/null 2>&1; then
        echo "Removing proxy device from {{vm_name}}"
        lxc config device remove {{vm_name}} prometheus-ui
    else
        echo "No proxy device 'prometheus-ui' found on {{vm_name}}"
    fi

# Show proxy configuration
show-proxy:
    lxc config device show {{vm_name}}

# Show VM network info
show-net:
    lxc list {{vm_name}} -c n --format json | jq '.[0].state.network'

# Show VM network info in a more readable format
show-ip-info:
    lxc list {{vm_name}} -f json | jq -r '.[0].state.network | to_entries[] | .key as $interface | .value.addresses[] | select(.family=="inet") | "\($interface): \(.address)"'

# Update the setup recipe to include proxy setup
setup: setup-keys deploy-vm install-prometheus setup-config start-prometheus 
    #!/usr/bin/env bash
    echo "Prometheus setup complete!"
    # Get the host IP address that's reachable
    HOST_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
    echo "Access the web interface at:"
    echo "  - http://localhost:9090"
    echo "  - http://${HOST_IP}:9090"
    # Verify Prometheus is responding
    echo "Waiting for Prometheus to become available..."
    for i in {1..30}; do
        if curl -s http://localhost:9090/-/healthy >/dev/null; then
            echo "✓ Prometheus is up and running"
            exit 0
        fi
        sleep 1
    done
    echo "! Warning: Prometheus is not responding. Check 'just prom-status' for details"

cleanup: remove-proxy delete-vm delete-profile

# Show setup help
help:
    @echo "Prometheus Learning Environment Setup Help"
    @echo ""
    @echo "Default IP: {{default_ip}}"
    @echo "Current IP: {{vm_ip}}"
    @echo ""
    @echo "To use a different IP address:"
    @echo "  1. Run 'just generate-ip' to get a suggested IP"
    @echo "  2. Run 'export PROMETHEUS_VM_IP=<ip>' before running setup"
    @echo "  3. Or create a .env file with PROMETHEUS_VM_IP=<ip>"
    @echo ""
    @echo "To see available commands, run 'just' or 'just --list'"

# Document network access setup
help-network:
    @echo "Prometheus Network Access Guide"
    @echo ""
    @echo "Current VM IP: {{vm_ip}}"
    @echo ""
    @echo "Standard Access (Local Development):"
    @echo "  - Direct access via VM IP: http://{{vm_ip}}:9090"
    @echo ""
    @echo "Remote Access Setup:"
    @echo "  If you're accessing this machine via SSH and cannot reach {{vm_ip}}:"
    @echo "  1. Run 'just setup-proxy' to create a port forward"
    @echo "  2. Access via http://<< IP of LXC host machine>>:9090"
    @echo "  3. When done, run 'just remove-proxy' to clean up"