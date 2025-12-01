#!/bin/bash

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config file if it exists
if [ -f "$SCRIPT_DIR/config.env" ]; then
    echo "Loading configuration from config.env..."
    source "$SCRIPT_DIR/config.env"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Rook version
ROOK_VERSION=${ROOK_VERSION:-"v1.18.7"}

BUILD_REGISTRY=${BUILD_REGISTRY:-"local"}

# Ceph version (image tag)
CEPH_VERSION=${CEPH_VERSION:-"v19.2.3"}

# Rook namespace
ROOK_CEPH_NAMESPACE=${ROOK_CEPH_NAMESPACE:-"rook-ceph"}

# Rook source directory
ROOK_SOURCE_DIR=${ROOK_SOURCE_DIR:-"$HOME/dev/go/src/github.com/rook/rook"}

# Custom build flag
USE_CUSTOM_BUILD=${USE_CUSTOM_BUILD:-"false"}

# Custom image tag
CUSTOM_IMAGE_TAG=${CUSTOM_IMAGE_TAG:-"local-build"}

# Build Registry to build local images labeled as local/ceph-<arch>
BUILD_REGISTRY=${BUILD_REGISTRY:-"local"}

# Container runtime (docker or podman)
CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-"podman"}

# OSD type (disk or pvc)
# - disk: OSDs use raw disks (requires MINIKUBE_EXTRA_DISKS)
# - pvc: OSDs use PersistentVolumeClaims
OSD_TYPE=${OSD_TYPE:-"disk"}

# Minikube configuration
MINIKUBE_NODES=${MINIKUBE_NODES:-1}
MINIKUBE_MEMORY=${MINIKUBE_MEMORY:-4096}
MINIKUBE_CPUS=${MINIKUBE_CPUS:-2}
MINIKUBE_DISK_SIZE=${MINIKUBE_DISK_SIZE:-20g}
MINIKUBE_EXTRA_DISKS=${MINIKUBE_EXTRA_DISKS:-2}
MINIKUBE_DRIVER=${MINIKUBE_DRIVER:-qemu}
MINIKUBE_NETWORK=${MINIKUBE_NETWORK:-""}

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."

    if ! command -v minikube &> /dev/null; then
        print_error "minikube is not installed. Please install minikube first."
        exit 1
    fi

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi

    if [ "$USE_CUSTOM_BUILD" = "true" ]; then
        if ! command -v $CONTAINER_RUNTIME &> /dev/null; then
            print_error "$CONTAINER_RUNTIME is not installed. Please install $CONTAINER_RUNTIME for custom builds."
            exit 1
        fi

        if ! command -v go &> /dev/null; then
            print_error "Go is not installed. Please install Go for custom builds."
            exit 1
        fi
    fi

    print_info "Prerequisites check passed!"
}

# Build custom Rook operator from source

# Build custom Rook operator from source
build_custom_rook_operator() {
    print_info "Building custom Rook operator from source..."

    # Check if source directory exists
    if [ ! -d "$ROOK_SOURCE_DIR" ]; then
        print_error "Rook source directory not found: $ROOK_SOURCE_DIR"
        exit 1
    fi

    # Detect architecture
    ARCH=$(uname -m)
    if [ "$ARCH" = "arm64" ]; then
        print_info "Detected ARM64 architecture (Mac M2)"
        GOARCH="arm64"
        PLATFORM="linux/arm64"
    else
        print_info "Detected AMD64 architecture"
        GOARCH="amd64"
        PLATFORM="linux/amd64"
    fi

    print_info "Building Rook operator for ${PLATFORM}..."
    cd "$ROOK_SOURCE_DIR"

    # Build using podman
    print_info "Building rook-ceph operator image using $CONTAINER_RUNTIME..."
    make BUILD_REGISTRY=${BUILD_REGISTRY} IMAGES="ceph" build.all || {
        # If that fails, try the manual approach
        print_warn "Automated build failed, trying manual build..."

        # Build the Go binary
        print_info "Building Rook binary..."
        GOOS=linux GOARCH=${GOARCH} CGO_ENABLED=0 go build \
            -o _output/bin/linux_${GOARCH}/rook \
            cmd/rook/main.go || {
            print_error "Failed to build Rook binary"
            exit 1
        }

        # Build the container image
        print_info "Building container image..."
        cd images/ceph
        $CONTAINER_RUNTIME build --platform=${PLATFORM} \
            -t rook/ceph:${CUSTOM_IMAGE_TAG} \
            -f Dockerfile ../../ || {
            print_error "Failed to build container image"
            exit 1
        }
        cd ../..
    }

    $CONTAINER_RUNTIME tag "$BUILD_REGISTRY/ceph-$ARCH" rook/ceph:${CUSTOM_IMAGE_TAG}

    print_info "Custom Rook operator built successfully with tag: rook/ceph:${CUSTOM_IMAGE_TAG}"

    # Save the image to a tar file
    print_info "Saving image to tar file..."
    $CONTAINER_RUNTIME save rook/ceph:${CUSTOM_IMAGE_TAG} -o /tmp/rook-ceph-custom.tar

    print_info "Loading image into Minikube..."
    minikube image load /tmp/rook-ceph-custom.tar

    cd - > /dev/null
}

# Start Minikube
start_minikube() {
    if [ "$MINIKUBE_NODES" -gt 1 ]; then
        print_info "Starting Minikube with ${MINIKUBE_NODES} nodes..."
    else
        print_info "Starting Minikube with single node..."
    fi

    # Check if minikube is already running
    if minikube status &> /dev/null; then
        print_warn "Minikube is already running"

        # Check current node count
        current_nodes=$(kubectl get nodes --no-headers | wc -l)
        print_info "Current cluster has ${current_nodes} node(s)"

        if [ "$current_nodes" -ne "$MINIKUBE_NODES" ]; then
            print_warn "Current node count (${current_nodes}) differs from requested (${MINIKUBE_NODES})"
            print_warn "To change node count, delete the cluster first: minikube delete"
        fi
    else
        # Start minikube with extra disks for Rook
        print_info "Configuration: ${MINIKUBE_MEMORY}MB RAM, ${MINIKUBE_CPUS} CPUs, ${MINIKUBE_DISK_SIZE} disk, ${MINIKUBE_EXTRA_DISKS} extra disks"
        print_info "Driver: ${MINIKUBE_DRIVER}"

        if [ -n "$MINIKUBE_NETWORK" ]; then
            print_info "Network: ${MINIKUBE_NETWORK}"
        fi

        # Build minikube start command
        MINIKUBE_CMD="minikube start \
            --nodes=${MINIKUBE_NODES} \
            --memory=${MINIKUBE_MEMORY} \
            --cpus=${MINIKUBE_CPUS} \
            --disk-size=${MINIKUBE_DISK_SIZE} \
            --extra-disks=${MINIKUBE_EXTRA_DISKS} \
            --driver=${MINIKUBE_DRIVER}"

        # Add network option if specified
        if [ -n "$MINIKUBE_NETWORK" ]; then
            MINIKUBE_CMD="$MINIKUBE_CMD --network=${MINIKUBE_NETWORK}"
        fi

        # Execute the command
        eval $MINIKUBE_CMD

        print_info "Minikube started successfully!"
    fi

    # Wait for cluster to be ready
    print_info "Waiting for all nodes to be ready..."
    kubectl wait --for=condition=ready node --all --timeout=300s

    # Show node status
    print_info "Cluster nodes:"
    kubectl get nodes
}

# Deploy Rook Operator
deploy_rook_operator() {
    if [ "$USE_CUSTOM_BUILD" = "true" ]; then
        print_info "Deploying custom Rook Operator (tag: ${CUSTOM_IMAGE_TAG})..."
    else
        print_info "Deploying Rook Operator (version: ${ROOK_VERSION})..."
    fi

    # Apply CRDs
    if [ "$USE_CUSTOM_BUILD" = "true" ] && [ -f "$ROOK_SOURCE_DIR/deploy/examples/crds.yaml" ]; then
        kubectl apply -f "$ROOK_SOURCE_DIR/deploy/examples/crds.yaml"
    else
        kubectl apply -f https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/crds.yaml
    fi

    # Apply common resources
    if [ "$USE_CUSTOM_BUILD" = "true" ] && [ -f "$ROOK_SOURCE_DIR/deploy/examples/common.yaml" ]; then
        kubectl apply -f "$ROOK_SOURCE_DIR/deploy/examples/common.yaml"
    else
        kubectl apply -f https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/common.yaml
    fi

     # Apply csi operator resources
    if [ "$USE_CUSTOM_BUILD" = "true" ] && [ -f "$ROOK_SOURCE_DIR/deploy/examples/common.yaml" ]; then
        kubectl apply -f "$ROOK_SOURCE_DIR/deploy/examples/csi-operator.yaml"
    else
        kubectl apply -f https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/csi-operator.yaml
    fi

    # Apply operator with custom image if needed
    if [ "$USE_CUSTOM_BUILD" = "true" ]; then
        # Use local operator manifest and patch the image
        if [ -f "$ROOK_SOURCE_DIR/deploy/examples/operator.yaml" ]; then
            cp "$ROOK_SOURCE_DIR/deploy/examples/operator.yaml" /tmp/operator.yaml
        else
            curl -s https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/operator.yaml > /tmp/operator.yaml
        fi

        # Patch the operator manifest to use custom image
        sed -i.bak "s|image: docker.io/rook/ceph:.*|image: localhost/rook/ceph:${CUSTOM_IMAGE_TAG}|g" /tmp/operator.yaml
        # Also update imagePullPolicy to Never since image is loaded locally
        sed -i.bak "s|imagePullPolicy:.*|imagePullPolicy: Never|g" /tmp/operator.yaml

        kubectl apply -f /tmp/operator.yaml
    else
        kubectl apply -f https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/operator.yaml
    fi

    print_info "Waiting for Rook operator to be ready..."
    while [[ $(kubectl get pods -l app=rook-ceph-operator -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' -n $ROOK_CEPH_NAMESPACE) != "True" ]]; do echo "waiting for rook operator pod" && sleep 5; done
    # kubectl -n $ROOK_CEPH_NAMESPACE wait --for=condition=ready pod -l app=rook-ceph-operator --timeout=300s

    print_info "Rook Operator deployed successfully!"
}

# Wait for OSD pods to be ready
wait_for_osd_pods() {
    # Calculate expected OSD count: nodes * disks per node
    local expected_osds=$((MINIKUBE_NODES * MINIKUBE_EXTRA_DISKS))

    print_info "Waiting for $expected_osds OSD pods to be ready (${MINIKUBE_NODES} nodes × ${MINIKUBE_EXTRA_DISKS} disks)..."

    local timeout=600
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        local ready_count=$(kubectl get pods -n $ROOK_CEPH_NAMESPACE -l app=rook-ceph-osd -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | grep -o "True" | wc -l | tr -d ' ')

        if [ "$ready_count" -eq "$expected_osds" ]; then
            echo ""
            print_info "All $expected_osds OSD pods are ready!"
            return 0
        fi

        if [ $((elapsed % 30)) -eq 0 ]; then
            echo ""
            print_info "OSD status: $ready_count/$expected_osds ready"
        else
            echo -n "."
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    print_warn "Timeout waiting for all OSD pods to be ready"
    print_info "Expected: $expected_osds OSDs, Found: $(kubectl get pods -n $ROOK_CEPH_NAMESPACE -l app=rook-ceph-osd -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | grep -o "True" | wc -l | tr -d ' ') ready"
    print_info "Checking pod status..."
    kubectl get pods -n $ROOK_CEPH_NAMESPACE -l app=rook-ceph-osd
    return 1
}

# Wait for Ceph health to be HEALTH_OK
wait_for_ceph_health() {
    print_info "Waiting for Ceph cluster health to be HEALTH_OK..."

    # First, wait for toolbox to be ready
    local toolbox_ready=false
    local toolbox_timeout=120
    local toolbox_elapsed=0

    while [ $toolbox_elapsed -lt $toolbox_timeout ]; do
        if kubectl -n $ROOK_CEPH_NAMESPACE get pod -l app=rook-ceph-tools &> /dev/null; then
            if kubectl -n $ROOK_CEPH_NAMESPACE wait --for=condition=ready pod -l app=rook-ceph-tools --timeout=10s &> /dev/null; then
                toolbox_ready=true
                break
            fi
        fi
        sleep 5
        toolbox_elapsed=$((toolbox_elapsed + 5))
    done

    if [ "$toolbox_ready" = false ]; then
        print_warn "Toolbox pod not ready, skipping health check"
        return 1
    fi

    local timeout=600
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        local health_status=$(kubectl -n $ROOK_CEPH_NAMESPACE exec -it deploy/rook-ceph-tools -- ceph health 2>/dev/null | tr -d '\r' | awk '{print $1}')

        if [ "$health_status" = "HEALTH_OK" ]; then
            echo ""
            print_info "Ceph cluster health is HEALTH_OK!"
            return 0
        fi

        if [ $((elapsed % 30)) -eq 0 ]; then
            echo ""
            if [ -n "$health_status" ]; then
                print_info "Current health status: $health_status"
                # Show more details every minute
                if [ $((elapsed % 60)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                    kubectl -n $ROOK_CEPH_NAMESPACE exec deploy/rook-ceph-tools -- ceph status 2>/dev/null || true
                fi
            else
                print_info "Waiting for Ceph to initialize..."
            fi
        else
            echo -n "."
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    print_warn "Timeout waiting for Ceph health to be HEALTH_OK"
    print_info "Final health status:"
    kubectl -n $ROOK_CEPH_NAMESPACE exec deploy/rook-ceph-tools -- ceph status 2>/dev/null || print_error "Unable to get Ceph status"
    return 1
}

# Deploy Rook Ceph Cluster
deploy_ceph_cluster() {
    # Determine which cluster manifest to use based on OSD type and node count
    if [ "$OSD_TYPE" = "pvc" ] && [ "$MINIKUBE_NODES" -gt 1 ]; then
        print_info "Deploying Rook Ceph Cluster (multi-node, OSD on PVC configuration)..."
        CLUSTER_YAML="cluster-on-pvc.yaml"
    elif [ "$OSD_TYPE" = "pvc" ] && [ "$MINIKUBE_NODES" -eq 1 ]; then
        print_info "Deploying Rook Ceph Cluster (single-node, OSD on pvc configuration)..."
        CLUSTER_YAML="cluster-test.yaml"
    elif [ "$OSD_TYPE" = "disk" ] && [ "$MINIKUBE_NODES" -gt 1 ]; then
        print_info "Deploying Rook Ceph Cluster (multi-node, OSD on disk configuration)..."
        CLUSTER_YAML="cluster.yaml"
    else
        print_info "Deploying Rook Ceph Cluster (single-node, OSD on disk configuration)..."
        CLUSTER_YAML="cluster-test.yaml"
    fi

    # Download cluster manifest
    print_info "Downloading ${CLUSTER_YAML}..."
    curl -s https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/${CLUSTER_YAML} > /tmp/cluster.yaml

    # Replace Ceph image version if specified
    if [ -n "$CEPH_VERSION" ]; then
        print_info "Customizing Ceph image version to: ${CEPH_VERSION}..."
        sed -i.bak "s|image: quay.io/ceph/ceph:v[0-9.]*|image: quay.io/ceph/ceph:${CEPH_VERSION}|g" /tmp/cluster.yaml
    fi

    # Apply the cluster
    print_info "Applying cluster manifest..."
    kubectl apply -f /tmp/cluster.yaml

    print_info "Waiting for Ceph cluster to be ready (this may take a few minutes)..."

    # Wait for operator to create the cluster resources
    sleep 10

    # Wait for OSD pods to be ready
    wait_for_osd_pods

    echo ""

    print_info "Rook Ceph Cluster deployed!"
}

# Deploy toolbox for debugging
deploy_toolbox() {
    print_info "Deploying Rook toolbox..."

    kubectl apply -f https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/toolbox.yaml

    print_info "Waiting for toolbox to be ready..."
    kubectl -n $ROOK_CEPH_NAMESPACE wait --for=condition=ready pod -l app=rook-ceph-tools --timeout=300s

    print_info "Toolbox deployed successfully!"
}

# Show cluster status
show_status() {
    print_info "Cluster Status:"
    echo ""

    print_info "Pods in $ROOK_CEPH_NAMESPACE namespace:"
    kubectl -n $ROOK_CEPH_NAMESPACE get pods
    echo ""

    print_info "Ceph Status:"
    kubectl -n $ROOK_CEPH_NAMESPACE exec -it deploy/rook-ceph-tools -- ceph status || print_warn "Ceph cluster may still be initializing"
    echo ""

    print_info "Installation complete!"
    echo ""
    echo "To check Ceph status, run:"
    echo "  kubectl -n $ROOK_CEPH_NAMESPACE exec -it deploy/rook-ceph-tools -- ceph status"
    echo ""
    echo "To access the Ceph dashboard:"
    echo "  kubectl -n $ROOK_CEPH_NAMESPACE get service rook-ceph-mgr-dashboard"
}

# Main installation flow
main() {
    print_info "Starting Rook Ceph installation on Minikube..."
    echo ""

    check_prerequisites
    start_minikube

    # Build custom operator if requested
    if [ "$USE_CUSTOM_BUILD" = "true" ]; then
        build_custom_rook_operator
    fi

    deploy_rook_operator
    deploy_ceph_cluster
    deploy_toolbox
    wait_for_ceph_health
    show_status
}

# Run main function
main
