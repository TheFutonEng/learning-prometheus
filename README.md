# Introduction

Using this repo to learn all about [Prometheus](https://prometheus.io/docs/prometheus/latest/getting_started/).

# Requirements

This repo was tested using the following tools. 

- Ubuntu 22.04
- `just` 1.36.0 ([installation](https://github.com/casey/just#installation))
- `lxc` ([installation](https://ubuntu.com/server/docs/lxc-containers))

# Usage

The `just` utility is very similar to `make`.  There are targets in the `justfile` at the root of this repo.  Running `just` by itself in this location (or `just --list`) will display all of the available targets to call in the `justfile`:

```bash
$ just
Available recipes:
    cleanup
    create-profile     # Create static IP profile
    default            # List available recipes
    delete-profile     # Delete profile if it exists
    delete-vm          # Delete VM if it exists
    deploy-vm          # Deploy the LXC VM for Prometheus
    get-ip             # Get the VM's IP address (make it silent)
    install-prometheus # Install Prometheus on the VM
    prom-logs          # Show Prometheus logs
    prom-status        # Show Prometheus status
    remove-proxy       # Remove proxy device
    setup              # Update the setup recipe to include proxy setup
    setup-config       # Upload and setup Prometheus config
    setup-keys         # Setup SSH keys for the project
    setup-proxy        # Add proxy device to forward port 9090
    show-ip-info       # Show VM network info in a more readable format
    show-net           # Show VM network info
    show-proxy         # Show proxy configuration
    ssh                # SSH to the LXC VM
    start-prometheus   # Start the Prometheus server
    vm-status          # Check the status of the VM
```

Pass one of the targets in the first column to the `just` command in order to execute the described action:

```bash
$ just vm-status 
lxc list prometheus
+------------+---------+-----------------------+------------------------------------------------+-----------------+-----------+
|    NAME    |  STATE  |         IPV4          |                      IPV6                      |      TYPE       | SNAPSHOTS |
+------------+---------+-----------------------+------------------------------------------------+-----------------+-----------+
| prometheus | RUNNING | 10.196.3.153 (enp5s0) | fd42:72e:f957:5c51:216:3eff:fefb:c26a (enp5s0) | VIRTUAL-MACHINE | 0         |
+------------+---------+-----------------------+------------------------------------------------+-----------------+-----------+
```

# VM IP Address

The `justfile` assumes a default IP address but this may not be suitable for your `lxc` setup.  To determine a suitable IP address, run the below `just` target:

```bash
$ just generate-ip 
Suggested IP: 10.196.3.236
To use this IP, run: export PROMETHEUS_VM_IP=10.196.3.236
IP 10.196.3.236 appears to be available
```

# Accessing the Prometheus UI

If the `lxc` VM is running on the same host as the workstation, the Prometheus UI will be accessible via the VM IP:

- http://<<vm-ip>>:9090

If the `lxc` VM is running on a different host and the LXD bridge interface (`lxdbro`) is not routed on the local network, run the `setup-proxy` target:

```bash
$ just setup-proxy 
Device prometheus-ui added to prometheus
```