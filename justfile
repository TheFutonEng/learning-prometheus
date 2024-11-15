# Justfile for prometheus learning environment

# Set some default variables
vm_name := "prometheus"
vm_cpu := "2"
vm_memory := "4GB"
prom_version := "2.49.1"  # Latest stable as of now
prom_dir := "/opt/prometheus"
ssh_opts := "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
vm_ip := "10.196.3.153"

# List available recipes
default:
    @just --list

# Create static IP profile
create-profile:
    #!/usr/bin/env bash
    echo "Creating network profile."
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
    ssh -o StrictHostKeyChecking=no {{vm_ip}} "sudo apt-get update && sudo apt-get install -y wget tar" && \
    ssh -o StrictHostKeyChecking=no {{vm_ip}} "wget https://github.com/prometheus/prometheus/releases/download/v{{prom_version}}/prometheus-{{prom_version}}.linux-amd64.tar.gz" && \
    ssh -o StrictHostKeyChecking=no {{vm_ip}} "sudo mkdir -p {{prom_dir}} && sudo tar xzf prometheus-{{prom_version}}.linux-amd64.tar.gz -C {{prom_dir}} --strip-components=1" && \
    ssh -o StrictHostKeyChecking=no {{vm_ip}} "sudo useradd -rs /bin/false prometheus || true" && \
    ssh -o StrictHostKeyChecking=no {{vm_ip}} "sudo chown -R prometheus:prometheus {{prom_dir}}" && \
    echo "Prometheus installed in {{prom_dir}}"


# Upload and setup Prometheus config
setup-config:
    #!/usr/bin/env bash
    scp -o StrictHostKeyChecking=no config/prometheus.yml "{{vm_ip}}:/tmp/prometheus.yml" && \
    ssh -o StrictHostKeyChecking=no {{vm_ip}} 'sudo mv /tmp/prometheus.yml {{prom_dir}}/prometheus.yml' && \
    ssh -o StrictHostKeyChecking=no {{vm_ip}} 'sudo chown prometheus:prometheus {{prom_dir}}/prometheus.yml'

start-prometheus:
    #!/usr/bin/env bash
    echo "Creating systemd service." && \
    scp {{ssh_opts}} templates/prometheus.service "{{vm_ip}}:/tmp/prometheus.service" && \
    ssh {{ssh_opts}} {{vm_ip}} 'sudo mv /tmp/prometheus.service /etc/systemd/system/prometheus.service' && \
    ssh {{ssh_opts}} {{vm_ip}} "sudo systemctl daemon-reload" && \
    ssh {{ssh_opts}} {{vm_ip}} "sudo systemctl start prometheus" && \
    ssh {{ssh_opts}} {{vm_ip}} "sudo systemctl enable prometheus" && \
    echo "Prometheus started and enabled"

# Show Prometheus status
prom-status:
    ssh {{vm_ip}} "sudo systemctl status prometheus"

# Show Prometheus logs
prom-logs:
    ssh {{vm_ip}} "sudo journalctl -u prometheus -f"

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

ssh:
    ssh {{ssh_opts}} {{vm_ip}}

status:
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

# Remove proxy device
remove-proxy:
    lxc config device remove {{vm_name}} prometheus-ui

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
setup: deploy-vm install-prometheus setup-config start-prometheus setup-proxy
    @echo "Prometheus setup complete!"
    @echo "Access the web interface at http://$(hostname):9090"

cleanup: delete-vm delete-profile