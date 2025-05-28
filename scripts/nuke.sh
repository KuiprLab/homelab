#!/usr/bin/env bash
set -euo pipefail

# CONFIGURATION
CONTROL_PLANE_CONFIG="../../talos/sol/controlplane.yaml"
WORKER_CONFIG="../../talos/sol/worker.yaml"
BOOTSTRAP_NODE="192.168.1.159" # Set to one of your control plane IPs (if not detected automatically)

NODES="192.168.1.160 192.168.1.159"

# STEP 1: Detect all nodes
echo "🔍 Detecting Talos nodes..."
echo "📋 Found nodes: $NODES"

# STEP 2: Force reset and reboot all nodes
echo "💣 Resetting and rebooting all nodes..."
for node in $NODES; do
    echo "⚠️ Resetting $node..."
    talosctl reset --nodes "$node" --reboot || true
done

# Wait for nodes to reboot
echo "⏳ Waiting 60s for nodes to come back up..."
sleep 60

# STEP 3: Re-apply machine configs
echo "⚙️ Re-applying Talos configs..."
for node in $NODES; do
    if [[ -z "$BOOTSTRAP_NODE" ]]; then
        BOOTSTRAP_NODE="$node"
    fi

    echo "📡 Applying config to $node..."
    if [[ $node == "$BOOTSTRAP_NODE" ]]; then
        talosctl apply-config --insecure --nodes "$node" --file "$CONTROL_PLANE_CONFIG"
    else
        talosctl apply-config --insecure --nodes "$node" --file "$WORKER_CONFIG"
    fi
done

# STEP 4: Bootstrap the cluster (only once, only control plane)
echo "🚀 Bootstrapping cluster with node $BOOTSTRAP_NODE..."
talosctl bootstrap --nodes "$BOOTSTRAP_NODE"

echo "✅ Talos cluster reset complete!"
