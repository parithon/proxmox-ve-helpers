#!/bin/bash

# Proxmox Helper Script for Grafana Alloy Setup with User-Selected Host-Specific Attributes and Generic Hardware Metrics
# This script prompts the user to select host-specific attributes to include, installs Grafana Alloy and node_exporter,
# configures Alloy to collect metrics via OTLP from Proxmox, journald logs from the host (including Proxmox-related entries for LXC/VMs),
# a static gauge metric (host.hardware_info) with selected host-specific attributes, and generic dynamic hardware metrics (CPU, memory, disk, network) via node_exporter.
# It adds resource attributes (node type, service, container), VM-specific attributes (vm.id, vm.name),
# LXC-specific attributes (ct.id, ct.name), and user-selected host-specific attributes to logs and metrics,
# and sends all data (logs and metrics) to an external OTLP collector.
# It also configures the Proxmox datacenter to send metrics to the local Alloy OTLP receiver.
#
# Usage: ./proxmox_alloy_setup.sh <OTLP_ENDPOINT>
# Example: ./proxmox_alloy_setup.sh "collector.example.com:4317"
#
# Notes:
# - Resource attributes include node type ("proxmox"), service name, and container ID.
# - VM-specific attributes (vm.id, vm.name) are extracted from QEMU logs using regex.
# - LXC-specific attributes (ct.id, ct.name) are extracted from LXC logs using regex.
# - Host-specific attributes (user-selected) are added to logs and as labels to static (host.hardware_info) and dynamic (node_exporter) metrics.
# - Dynamic metrics are generic (e.g., node_cpu_seconds_total, node_memory_MemAvailable_bytes, node_disk_io_time_seconds_total, node_network_receive_bytes_total).
# - Proxmox metrics include host, LXC, and VM resource usage (CPU, memory, disk, etc.).
# - Logs are collected from journald, including Proxmox daemon logs, LXC container logs, and QEMU VM logs.
# - The host.hardware_info metric is a static gauge emitted once at Alloy startup.
# - For internal guest application logs, install Alloy inside each LXC/VM to send directly to the OTLP collector.
# - Assumes no authentication for local OTLP (Proxmox, port 4318) or node_exporter (port 9100).
# - Run as root or with sudo.

if [ $# -ne 1 ]; then
  echo "Usage: $0 <OTLP_ENDPOINT>"
  exit 1
fi

OTLP_ENDPOINT="$1"

# Step 1: Prompt user to select host-specific attributes
echo "Select host-specific attributes to include in logs and metrics (enter numbers, or 'done' to finish):"

PS3="Enter attribute number (or 'done' to finish): "
options=(
  "host.name"
  "host.os"
  "host.kernel"
  "host.pve_version"
  "host.cpu_model"
  "host.gpu_model"
  "host.memory_total"
  "host.disk_total"
  "host.network_interface"
  "host.proxmox_cluster"
  "host.bios_version"
)
selected_attributes=()

select opt in "${options[@]}" "done"; do
  if [ "$opt" = "done" ]; then
    break
  elif [[ " ${options[*]} " =~ " $opt " ]]; then
    selected_attributes+=("$opt")
    echo "Added $opt to selection."
  else
    echo "Invalid option. Please select a number or 'done'."
  fi
done

if [ ${#selected_attributes[@]} -eq 0 ]; then
  echo "No attributes selected. Proceeding with only required attributes (node.type, service.name, container.id, vm.id, vm.name, ct.id, ct.name)."
fi

# Step 2: Collect selected host-specific information
echo "Collecting selected host-specific information..."

declare -A attribute_values

# Initialize defaults
for attr in "${options[@]}"; do
  attribute_values["$attr"]="none"
done

# Collect values for selected attributes
if [[ " ${selected_attributes[*]} " =~ "host.name" ]]; then
  attribute_values["host.name"]=$(hostname)
fi
if [[ " ${selected_attributes[*]} " =~ "host.os" ]]; then
  attribute_values["host.os"]=$(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2 || echo "unknown")
fi
if [[ " ${selected_attributes[*]} " =~ "host.kernel" ]]; then
  attribute_values["host.kernel"]=$(uname -r)
fi
if [[ " ${selected_attributes[*]} " =~ "host.pve_version" ]]; then
  attribute_values["host.pve_version"]=$(pveversion | cut -d'/' -f2 | cut -d'-' -f1 || echo "unknown")
fi
if [[ " ${selected_attributes[*]} " =~ "host.cpu_model" ]]; then
  attribute_values["host.cpu_model"]=$(lscpu | grep "Model name" | awk -F: '{print $2}' | xargs || echo "unknown")
fi
if [[ " ${selected_attributes[*]} " =~ "host.gpu_model" ]]; then
  attribute_values["host.gpu_model"]=$(lspci | grep -E 'VGA|3D' | awk -F: '{print $3}' | xargs || echo "none")
fi
if [[ " ${selected_attributes[*]} " =~ "host.memory_total" ]]; then
  attribute_values["host.memory_total"]=$(free --giga | grep Mem: | awk '{print $2}' | xargs || echo "unknown")
fi
if [[ " ${selected_attributes[*]} " =~ "host.disk_total" ]]; then
  attribute_values["host.disk_total"]=$(lsblk -b -d -o SIZE | grep -v SIZE | awk '{sum+=$1} END {print int(sum/1024/1024/1024)}' || echo "unknown")
fi
if [[ " ${selected_attributes[*]} " =~ "host.network_interface" ]]; then
  attribute_values["host.network_interface"]=$(ip link | grep 'state UP' | awk -F: '{print $2}' | xargs | tr ' ' ',' || echo "none")
fi
if [[ " ${selected_attributes[*]} " =~ "host.proxmox_cluster" ]]; then
  attribute_values["host.proxmox_cluster"]=$(pvecm status | grep "Cluster name" | awk -F: '{print $2}' | xargs || echo "none")
fi
if [[ " ${selected_attributes[*]} " =~ "host.bios_version" ]]; then
  attribute_values["host.bios_version"]=$(dmidecode -t bios | grep "Version:" | awk -F: '{print $2}' | xargs || echo "unknown")
fi

# Step 3: Install Grafana Alloy and node_exporter
echo "Installing Grafana Alloy and node_exporter..."

# Install dependencies
sudo apt-get update
sudo apt-get install -y prometheus-node-exporter
if [[ " ${selected_attributes[*]} " =~ "host.bios_version" ]]; then
  sudo apt-get install -y dmidecode
fi
if [[ " ${selected_attributes[*]} " =~ "host.gpu_model" ]]; then
  sudo apt-get install -y pciutils
fi
if [[ " ${selected_attributes[*]} " =~ "host.memory_total" ]]; then
  sudo apt-get install -y procps
fi
if [[ " ${selected_attributes[*]} " =~ "host.disk_total" ]]; then
  sudo apt-get install -y util-linux
fi

# Install Alloy
sudo mkdir -p /etc/apt/keyrings/
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt-get update
sudo apt-get install -y alloy

# Ensure node_exporter is running
if ! systemctl is-active --quiet prometheus-node-exporter; then
  echo "Starting node_exporter..."
  sudo systemctl enable prometheus-node-exporter
  sudo systemctl start prometheus-node-exporter
else
  echo "node_exporter already running."
fi

# Step 4: Configure Alloy with selected attributes for logs and metrics, and generic hardware metrics
echo "Configuring Grafana Alloy with selected attributes and generic hardware metrics..."

# Build attribute actions for logs and metrics
LOG_ATTRIBUTE_ACTIONS=""
METRIC_ATTRIBUTE_ACTIONS=""
STATIC_METRIC_ATTRIBUTES=""
for attr in "${selected_attributes[@]}"; do
  LOG_ATTRIBUTE_ACTIONS+="{ key = \"$attr\", value = \"${attribute_values[$attr]}\", action = \"insert\" },"
  METRIC_ATTRIBUTE_ACTIONS+="{ key = \"$attr\", value = \"${attribute_values[$attr]}\", action = \"insert\" },"
  STATIC_METRIC_ATTRIBUTES+="\"$attr\" = \"${attribute_values[$attr]}\","
done
# Add node.type to metrics (required)
METRIC_ATTRIBUTE_ACTIONS+="{ key = \"node.type\", value = \"proxmox\", action = \"insert\" },"
STATIC_METRIC_ATTRIBUTES+="\"node.type\" = \"proxmox\","
# Remove trailing commas
LOG_ATTRIBUTE_ACTIONS=${LOG_ATTRIBUTE_ACTIONS%,}
METRIC_ATTRIBUTE_ACTIONS=${METRIC_ATTRIBUTE_ACTIONS%,}
STATIC_METRIC_ATTRIBUTES=${STATIC_METRIC_ATTRIBUTES%,}

cat << EOF | sudo tee /etc/alloy/config.alloy
// Receive OTLP metrics from Proxmox (via HTTP)
otelcol.receiver.otlp "proxmox" {
  http {
    endpoint = "0.0.0.0:4318"
  }
  output {
    metrics = [otelcol.processor.attributes.metrics.input]
  }
}

// Collect logs from journald (includes Proxmox, LXC, and VM related logs)
otelcol.receiver.journald "journal" {
  output {
    logs = [otelcol.processor.attributes.logs.input]
  }
}

// Scrape generic dynamic hardware metrics from node_exporter
prometheus.scrape "hardware" {
  targets = [
    { "__address__" = "localhost:9100" },
  ]
  scrape_interval = "60s"
  forward_to = [otelcol.processor.attributes.metrics.receiver]
}

// Add selected host-specific attributes to Proxmox and node_exporter metrics
otelcol.processor.attributes "metrics" {
  actions = [
    $METRIC_ATTRIBUTE_ACTIONS
  ]
  output {
    metrics = [otelcol.processor.batch.metrics.input]
  }
}

// Add selected resource, VM-specific, LXC-specific, and host-specific attributes to logs
otelcol.processor.attributes "logs" {
  actions = [
    $(if [ -n "$LOG_ATTRIBUTE_ACTIONS" ]; then echo "$LOG_ATTRIBUTE_ACTIONS,"; fi)
    // General resource attributes
    { key = "node.type", value = "proxmox", action = "insert" },
    { key = "service.name", value = log.body._SYSTEMD_UNIT, action = "insert" },
    { key = "container.id", value = log.body._CONTAINER_ID, action = "insert" },
    // VM-specific attributes
    { key = "vm.id", pattern = "vmid=([0-9]+)", value = "\$1", action = "extract", from = "log.body.MESSAGE" },
    { key = "vm.name", pattern = "vm: ([^ ]+)", value = "\$1", action = "extract", from = "log.body.MESSAGE" },
    // LXC-specific attributes
    { key = "ct.id", pattern = "CT ([0-9]+)", value = "\$1", action = "extract", from = "log.body.MESSAGE" },
    { key = "ct.name", pattern = "lxc-start ([^ ]+)", value = "\$1", action = "extract", from = "log.body.MESSAGE" },
  ]
  output {
    logs = [otelcol.processor.batch.logs.input]
  }
}

// Generate a static gauge metric for selected host hardware attributes
otelcol.receiver.static "hardware_info" {
  metric {
    name = "host.hardware_info"
    type = "gauge"
    unit = "1"
    attributes = {
      $STATIC_METRIC_ATTRIBUTES
    }
    value = 1
  }
  output {
    metrics = [otelcol.processor.batch.hardware_metrics.input]
  }
}

// Batch processor for Proxmox and node_exporter metrics
otelcol.processor.batch "metrics" {
  output {
    metrics = [otelcol.exporter.otlp.external.input]
  }
}

// Batch processor for logs
otelcol.processor.batch "logs" {
  output {
    logs = [otelcol.exporter.otlp.external.input]
  }
}

// Batch processor for static hardware metrics
otelcol.processor.batch "hardware_metrics" {
  output {
    metrics = [otelcol.exporter.otlp.external.input]
  }
}

// Export to external OTLP collector (gRPC)
otelcol.exporter.otlp "external" {
  client {
    endpoint = "$OTLP_ENDPOINT"
    tls {
      insecure = true  // Set to false and configure TLS if needed
    }
  }
}
EOF

# Reload systemd and start/enable Alloy service
sudo systemctl daemon-reload
sudo systemctl enable alloy
sudo systemctl restart alloy

# Step 5: Configure Proxmox datacenter OTLP metrics
echo "Configuring Proxmox datacenter to send metrics to local Alloy OTLP receiver..."

sudo pvesh create /cluster/metrics/server/alloy-otlp --type opentelemetry --server 127.0.0.1:4318 --enabled 1

echo "Setup complete! Grafana Alloy is running and configured with selected attributes, static hardware metrics, and generic dynamic hardware metrics."
echo "Resource attributes added to logs: node.type, service.name, container.id."
if [ ${#selected_attributes[@]} -gt 0 ]; then
  echo "Selected host-specific attributes added to logs and metrics: ${selected_attributes[*]}."
fi
echo "VM-specific attributes added to logs: vm.id, vm.name (extracted from QEMU log patterns)."
echo "LXC-specific attributes added to logs: ct.id, ct.name (extracted from LXC log patterns)."
echo "Static metrics: host.hardware_info gauge with selected host-specific attributes."
echo "Dynamic metrics: node_exporter metrics (e.g., node_cpu_seconds_total, node_memory_MemAvailable_bytes, node_disk_io_time_seconds_total, node_network_receive_bytes_total) with selected host-specific attributes."
echo "Verify with: sudo systemctl status alloy"
echo "Check Alloy logs: journalctl -u alloy"
echo "Check node_exporter: curl http://localhost:9100/metrics"
echo "For full internal logs from LXC/VMs, install Alloy inside each guest and configure it to send to $OTLP_ENDPOINT."
