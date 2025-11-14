#!/bin/bash

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
OBJECT_STORE_NAME=${OBJECT_STORE_NAME:-"my-store"}
OBJECT_STORE_USER=${OBJECT_STORE_USER:-"my-user"}
NAMESPACE=${NAMESPACE:-"rook-ceph"}
SAMPLE_APP_NAMESPACE=${SAMPLE_APP_NAMESPACE:-"default"}

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

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# Check if Rook Ceph is running
check_rook_ceph() {
    print_info "Checking if Rook Ceph cluster is running..."

    if ! kubectl get namespace $NAMESPACE &> /dev/null; then
        print_error "Namespace $NAMESPACE not found. Please install Rook Ceph first."
        exit 1
    fi

    if ! kubectl -n $NAMESPACE get deployment rook-ceph-operator &> /dev/null; then
        print_error "Rook Ceph operator not found. Please install Rook Ceph first."
        exit 1
    fi

    # Check if CephCluster is healthy
    cluster_health=$(kubectl -n $NAMESPACE get cephcluster -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$cluster_health" != "Ready" ]; then
        print_warn "CephCluster status: $cluster_health (expected: Ready)"
        print_warn "The object store might not work properly if the cluster is not healthy"
    else
        print_info "CephCluster is healthy!"
    fi
}

# Deploy CephObjectStore
deploy_object_store() {
    print_header "Deploying CephObjectStore: $OBJECT_STORE_NAME"

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing CephObjectStore manifest..."
    sed -e "s/OBJECT_STORE_NAME/$OBJECT_STORE_NAME/g" \
        -e "s/NAMESPACE/$NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/object-store/object-store.yaml" > /tmp/object-store.yaml

    print_info "Applying CephObjectStore manifest..."
    kubectl apply -f /tmp/object-store.yaml

    print_info "Waiting for RGW pods to be ready..."
    sleep 10
    kubectl -n $NAMESPACE wait --for=condition=ready pod -l app=rook-ceph-rgw --timeout=300s || {
        print_warn "RGW pods not ready yet, checking status..."
        kubectl -n $NAMESPACE get pods -l app=rook-ceph-rgw
    }

    print_info "CephObjectStore deployed successfully!"
}

# Create object store user
create_object_store_user() {
    print_header "Creating ObjectStore User: $OBJECT_STORE_USER"

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing CephObjectStoreUser manifest..."
    sed -e "s/OBJECT_STORE_USER/$OBJECT_STORE_USER/g" \
        -e "s/OBJECT_STORE_NAME/$OBJECT_STORE_NAME/g" \
        -e "s/NAMESPACE/$NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/object-store/object-store-user.yaml" > /tmp/object-user.yaml

    print_info "Applying CephObjectStoreUser manifest..."
    kubectl apply -f /tmp/object-user.yaml

    print_info "Waiting for user credentials to be created..."
    sleep 5

    # Wait for secret to be created
    timeout=60
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if kubectl -n $NAMESPACE get secret rook-ceph-object-user-$OBJECT_STORE_NAME-$OBJECT_STORE_USER &> /dev/null; then
            print_info "User credentials created!"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
    done
    echo ""

    print_info "ObjectStore user created successfully!"
}

# Get credentials
get_credentials() {
    print_header "Object Store Credentials"

    # Get S3 endpoint
    print_info "Getting S3 endpoint..."
    ENDPOINT=$(kubectl -n $NAMESPACE get svc rook-ceph-rgw-$OBJECT_STORE_NAME -o jsonpath='{.spec.clusterIP}')
    PORT=$(kubectl -n $NAMESPACE get svc rook-ceph-rgw-$OBJECT_STORE_NAME -o jsonpath='{.spec.ports[0].port}')

    # Get access key and secret key
    print_info "Getting access credentials..."
    ACCESS_KEY=$(kubectl -n $NAMESPACE get secret rook-ceph-object-user-$OBJECT_STORE_NAME-$OBJECT_STORE_USER -o jsonpath='{.data.AccessKey}' | base64 --decode)
    SECRET_KEY=$(kubectl -n $NAMESPACE get secret rook-ceph-object-user-$OBJECT_STORE_NAME-$OBJECT_STORE_USER -o jsonpath='{.data.SecretKey}' | base64 --decode)

    echo ""
    echo -e "${GREEN}S3 Endpoint:${NC} http://${ENDPOINT}:${PORT}"
    echo -e "${GREEN}Access Key:${NC}  ${ACCESS_KEY}"
    echo -e "${GREEN}Secret Key:${NC}  ${SECRET_KEY}"
    echo ""

    # Export for use in sample apps
    export S3_ENDPOINT="http://${ENDPOINT}:${PORT}"
    export S3_ACCESS_KEY="${ACCESS_KEY}"
    export S3_SECRET_KEY="${SECRET_KEY}"
}

# Deploy sample Go S3 app
deploy_sample_app() {
    print_header "Deploying Sample S3 Application (Go)"

    # Create namespace if it doesn't exist
    kubectl create namespace $SAMPLE_APP_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

    # Create secret with S3 credentials
    print_info "Creating secret with S3 credentials..."
    kubectl -n $SAMPLE_APP_NAMESPACE create secret generic s3-credentials \
        --from-literal=endpoint="$S3_ENDPOINT" \
        --from-literal=access-key="$S3_ACCESS_KEY" \
        --from-literal=secret-key="$S3_SECRET_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Read Go source files
    print_info "Reading Go source files..."
    MAIN_GO_CONTENT=$(cat "$SCRIPT_DIR/manifests/sample-apps/go-s3-test/main.go" | sed 's/$/\\n/' | tr -d '\n')
    GO_MOD_CONTENT=$(cat "$SCRIPT_DIR/manifests/sample-apps/go-s3-test/go.mod" | sed 's/$/\\n/' | tr -d '\n')

    # Create ConfigMap from template
    print_info "Creating ConfigMap with Go code..."
    sed -e "s/SAMPLE_APP_NAMESPACE/$SAMPLE_APP_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/sample-apps/s3-test-configmap.yaml" > /tmp/s3-test-configmap-temp.yaml

    # Replace content placeholders with actual Go code
    awk -v main_go="$(cat "$SCRIPT_DIR/manifests/sample-apps/go-s3-test/main.go")" \
        '{gsub(/MAIN_GO_CONTENT/, main_go); print}' /tmp/s3-test-configmap-temp.yaml | \
    awk -v go_mod="$(cat "$SCRIPT_DIR/manifests/sample-apps/go-s3-test/go.mod")" \
        '{gsub(/GO_MOD_CONTENT/, go_mod); print}' > /tmp/s3-test-configmap.yaml

    kubectl apply -f /tmp/s3-test-configmap.yaml

    # Create Job from template
    print_info "Creating Job manifest..."
    sed -e "s/SAMPLE_APP_NAMESPACE/$SAMPLE_APP_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/sample-apps/s3-test-job.yaml" > /tmp/s3-test-job.yaml

    print_info "Deploying sample S3 test application..."
    kubectl apply -f /tmp/s3-test-job.yaml

    print_info "Waiting for job to start..."
    sleep 5

    print_info "Watching job logs (Ctrl+C to exit)..."
    echo ""
    kubectl -n $SAMPLE_APP_NAMESPACE wait --for=condition=ready pod -l job-name=s3-test-job --timeout=60s || true
    kubectl -n $SAMPLE_APP_NAMESPACE logs -f job/s3-test-job 2>/dev/null || {
        print_warn "Job not ready yet. Check logs later with:"
        echo "  kubectl -n $SAMPLE_APP_NAMESPACE logs -f job/s3-test-job"
    }
}

# Create sample curl-based test
create_curl_test() {
    print_header "Creating Curl-based S3 Test Pod"

    # Use manifest from manifests directory and substitute variables
    print_info "Preparing curl test pod manifest..."
    sed -e "s/SAMPLE_APP_NAMESPACE/$SAMPLE_APP_NAMESPACE/g" \
        "$SCRIPT_DIR/manifests/sample-apps/s3-curl-pod.yaml" > /tmp/curl-s3-pod.yaml

    print_info "Deploying curl test pod..."
    kubectl apply -f /tmp/curl-s3-pod.yaml

    print_info "Curl test pod created!"
}

# Show usage instructions
show_usage() {
    print_header "Usage Instructions"

    echo "Object Store Information:"
    echo "  Name: $OBJECT_STORE_NAME"
    echo "  Namespace: $NAMESPACE"
    echo "  User: $OBJECT_STORE_USER"
    echo ""
    echo "To view object store status:"
    echo "  kubectl -n $NAMESPACE get cephobjectstore"
    echo ""
    echo "To view RGW (S3 gateway) pods:"
    echo "  kubectl -n $NAMESPACE get pods -l app=rook-ceph-rgw"
    echo ""
    echo "To get credentials:"
    echo "  kubectl -n $NAMESPACE get secret rook-ceph-object-user-$OBJECT_STORE_NAME-$OBJECT_STORE_USER -o yaml"
    echo ""
    echo "To access S3 endpoint from outside the cluster:"
    echo "  kubectl -n $NAMESPACE port-forward svc/rook-ceph-rgw-$OBJECT_STORE_NAME 8080:80"
    echo "  Then use: http://localhost:8080"
    echo ""
    echo "Sample app logs:"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE logs -f job/s3-test-job"
    echo ""
    echo "To run manual S3 tests with curl pod:"
    echo "  kubectl -n $SAMPLE_APP_NAMESPACE exec -it s3-curl-test -- sh"
    echo ""
}

# Main execution
main() {
    print_info "Starting CephObjectStore deployment..."
    echo ""

    check_rook_ceph
    deploy_object_store
    create_object_store_user
    get_credentials
    deploy_sample_app
    create_curl_test
    show_usage

    print_info "Deployment complete!"
}

# Run main function
main
