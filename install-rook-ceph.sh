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
ROOK_VERSION=${ROOK_VERSION:-"v1.14.9"}

# Rook source directory
ROOK_SOURCE_DIR=${ROOK_SOURCE_DIR:-"$HOME/dev/go/src/github.com/rook/rook"}

# Custom build flag
USE_CUSTOM_BUILD=${USE_CUSTOM_BUILD:-"false"}

# Custom image tag
CUSTOM_IMAGE_TAG=${CUSTOM_IMAGE_TAG:-"local-build"}

# Minikube configuration
MINIKUBE_NODES=${MINIKUBE_NODES:-1}
MINIKUBE_MEMORY=${MINIKUBE_MEMORY:-4096}
MINIKUBE_CPUS=${MINIKUBE_CPUS:-2}
MINIKUBE_DISK_SIZE=${MINIKUBE_DISK_SIZE:-20g}
MINIKUBE_EXTRA_DISKS=${MINIKUBE_EXTRA_DISKS:-2}
MINIKUBE_DRIVER=${MINIKUBE_DRIVER:-qemu}

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
        if ! command -v podman &> /dev/null; then
            print_error "podman is not installed. Please install podman for custom builds."
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
    print_info "Building Docker image using podman..."
    make BUILD_CONTAINER_IMAGE=rook/ceph:${CUSTOM_IMAGE_TAG} IMAGES="ceph" build.all || {
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

        # Build the container image with podman
        print_info "Building container image..."
        cd images/ceph
        podman build --platform=${PLATFORM} \
            -t rook/ceph:${CUSTOM_IMAGE_TAG} \
            -f Dockerfile ../../ || {
            print_error "Failed to build container image"
            exit 1
        }
        cd ../..
    }

    print_info "Custom Rook operator built successfully with tag: rook/ceph:${CUSTOM_IMAGE_TAG}"

    # Save the image to a tar file
    print_info "Saving image to tar file..."
    podman save rook/ceph:${CUSTOM_IMAGE_TAG} -o /tmp/rook-ceph-custom.tar

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

        minikube start \
            --nodes=${MINIKUBE_NODES} \
            --memory=${MINIKUBE_MEMORY} \
            --cpus=${MINIKUBE_CPUS} \
            --disk-size=${MINIKUBE_DISK_SIZE} \
            --extra-disks=${MINIKUBE_EXTRA_DISKS} \
            --driver=${MINIKUBE_DRIVER}

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

    # Apply operator with custom image if needed
    if [ "$USE_CUSTOM_BUILD" = "true" ]; then
        # Use local operator manifest and patch the image
        if [ -f "$ROOK_SOURCE_DIR/deploy/examples/operator.yaml" ]; then
            cp "$ROOK_SOURCE_DIR/deploy/examples/operator.yaml" /tmp/operator.yaml
        else
            curl -s https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/operator.yaml > /tmp/operator.yaml
        fi

        # Patch the operator manifest to use custom image
        sed -i.bak "s|image: rook/ceph:.*|image: rook/ceph:${CUSTOM_IMAGE_TAG}|g" /tmp/operator.yaml
        # Also update imagePullPolicy to Never since image is loaded locally
        sed -i.bak "s|imagePullPolicy:.*|imagePullPolicy: Never|g" /tmp/operator.yaml

        kubectl apply -f /tmp/operator.yaml
    else
        kubectl apply -f https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/operator.yaml
    fi

    print_info "Waiting for Rook operator to be ready..."
    kubectl -n rook-ceph wait --for=condition=ready pod -l app=rook-ceph-operator --timeout=300s

    print_info "Rook Operator deployed successfully!"
}

# Deploy Rook Ceph Cluster
deploy_ceph_cluster() {
    print_info "Deploying Rook Ceph Cluster..."

    # Download and modify cluster manifest for single-node
    curl -s https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/cluster.yaml > /tmp/cluster.yaml

    # Apply the cluster
    kubectl apply -f /tmp/cluster.yaml

    print_info "Waiting for Ceph cluster to be ready (this may take a few minutes)..."

    # Wait for OSDs to be created
    timeout=600
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        osd_count=$(kubectl -n rook-ceph get pods -l app=rook-ceph-osd 2>/dev/null | grep -c Running || echo 0)
        if [ "$osd_count" -gt 0 ]; then
            print_info "OSDs are running!"
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo ""

    print_info "Rook Ceph Cluster deployed!"
}

# Deploy toolbox for debugging
deploy_toolbox() {
    print_info "Deploying Rook toolbox..."

    kubectl apply -f https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/toolbox.yaml

    print_info "Waiting for toolbox to be ready..."
    kubectl -n rook-ceph wait --for=condition=ready pod -l app=rook-ceph-tools --timeout=300s

    print_info "Toolbox deployed successfully!"
}

# Show cluster status
show_status() {
    print_info "Cluster Status:"
    echo ""

    print_info "Pods in rook-ceph namespace:"
    kubectl -n rook-ceph get pods
    echo ""

    print_info "Ceph Status:"
    kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status || print_warn "Ceph cluster may still be initializing"
    echo ""

    print_info "Installation complete!"
    echo ""
    echo "To check Ceph status, run:"
    echo "  kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status"
    echo ""
    echo "To access the Ceph dashboard:"
    echo "  kubectl -n rook-ceph get service rook-ceph-mgr-dashboard"
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
    show_status
}

# Run main function
main
