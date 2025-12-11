# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This project provides automated scripts to install and manage Rook Ceph storage on Minikube. Rook is a cloud-native storage orchestrator for Kubernetes, and Ceph is a distributed storage system. This setup creates a local development environment for testing Ceph storage features including block storage, object storage (S3-compatible), and file storage.

## Key Scripts and Their Usage

### Installation and Setup

**Install Rook Ceph:**
```bash
./install-rook-ceph.sh
```
This is the main installation script. It:
- Checks prerequisites (minikube, kubectl, optionally podman and Go)
- Starts Minikube with configured resources
- Deploys Rook operator
- Deploys Ceph cluster (automatically selects cluster manifest based on OSD_TYPE and node count)
- Deploys toolbox for debugging

**Configuration:**
Configuration can be provided via:
1. Environment variables on command line
2. `config.env` file (copy from `config.env.example`)

Environment variables override config.env values.

**OSD Storage Type:**
Choose between disk-based or PVC-based OSDs:
```bash
# Use PVC-based OSDs (default storage class)
OSD_TYPE=pvc ./install-rook-ceph.sh

# Use disk-based OSDs (requires extra disks on Minikube)
OSD_TYPE=disk ./install-rook-ceph.sh
```

**Enable Prometheus Monitoring:**
```bash
# Install with Prometheus monitoring enabled
ENABLE_PROMETHEUS=true ./install-rook-ceph.sh
```
When enabled, this will:
- Deploy Prometheus Operator in the default namespace
- Deploy Rook monitoring resources (ServiceMonitors, Prometheus instance, PrometheusRules)
- Enable the Prometheus module in the CephCluster CR to expose Ceph metrics

**Deploy Object Store:**
```bash
./deploy-object-store.sh
```
Deploys an S3-compatible CephObjectStore with:
- CephObjectStore resource
- Object store user with credentials
- Sample Python application (manifests/sample-apps/python-s3-test/) that tests S3 operations using boto3
- Curl test pod for manual testing

**Note**: The sample app was migrated from Go to Python for simpler dependencies and better readability.

**Cleanup Object Store:**
```bash
./cleanup-object-store.sh
```

**Deploy COSI (Container Object Storage Interface):**
```bash
./deploy-cosi.sh
```
Deploys COSI support for Rook Ceph object storage with:
- COSI API and Controller (CRDs and controller from kubernetes-sigs/container-object-storage-interface)
- CephCOSIDriver for Rook integration
- COSI user for bucket provisioning
- BucketClass and BucketAccessClass for bucket configuration
- BucketClaim to provision a bucket
- BucketAccess to generate access credentials
- Sample Python application (manifests/sample-apps/python-cosi-test/) that demonstrates COSI bucket consumption

The sample app shows how applications consume COSI-provisioned buckets by:
- Mounting the COSI secret at `/data/cosi/BucketInfo`
- Parsing the JSON to extract endpoint, credentials, and bucket name
- Using boto3 to perform S3 operations

**Cleanup COSI:**
```bash
./cleanup-cosi.sh
```

**Uninstall Rook Ceph:**
```bash
./uninstall-rook-ceph.sh
```
Removes all Rook Ceph resources and optionally deletes Minikube cluster.

**Alternative Uninstall (thorough cleanup):**
```bash
./uninstall-rook-ceph-2.sh
```
Enhanced uninstall script that provides more comprehensive cleanup:
- Deletes CephFilesystems, CephObjectStores, and CephBlockPools
- Enables cleanup policy on CephCluster CRD before deletion
- Waits for cleanup jobs to complete
- Removes finalizers from stuck namespaces
- Cleans up Rook data directories on Minikube nodes
- Force-deletes terminating pods
- Deletes all persistent volumes

### Common Verification Commands

**Check cluster status:**
```bash
kubectl -n rook-ceph get pods
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph health
```

**Access Ceph dashboard:**
```bash
kubectl -n rook-ceph port-forward service/rook-ceph-mgr-dashboard 8443:8443
# Get password:
kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{['data']['password']}" | base64 --decode
```

**Access S3 endpoint from outside cluster:**
```bash
kubectl -n rook-ceph port-forward svc/rook-ceph-rgw-my-store 8080:80
```

## Architecture

### Script Flow

The `install-rook-ceph.sh` script follows this flow:
1. **Prerequisite Check** - Verifies minikube, kubectl (and podman/Go if custom build)
2. **Start Minikube** - Creates cluster with extra disks for Ceph OSDs
3. **Custom Build (optional)** - Builds Rook operator from local source if USE_CUSTOM_BUILD=true
4. **Deploy Rook Operator** - Applies CRDs, common resources, CSI operator, and operator deployment
5. **Deploy Ceph Cluster** - Applies cluster manifest (cluster-test.yaml or cluster.yaml based on node count), enables Prometheus module if ENABLE_PROMETHEUS=true
6. **Deploy Toolbox** - Deploys debugging toolbox
7. **Deploy Prometheus (optional)** - If ENABLE_PROMETHEUS=true, deploys Prometheus Operator and Rook monitoring resources
8. **Show Status** - Displays cluster health

### Cluster Configuration Selection

The installation automatically selects cluster configuration based on OSD_TYPE and MINIKUBE_NODES:
- **OSD on PVC** (OSD_TYPE=pvc): Uses `cluster-on-pvc.yaml` from Rook examples (PersistentVolumeClaim-based OSDs)
- **OSD on disk, single node** (OSD_TYPE=disk, MINIKUBE_NODES=1): Uses `cluster-test.yaml` from Rook examples (minimal config with raw disks)
- **OSD on disk, multi-node** (OSD_TYPE=disk, MINIKUBE_NODES>1): Uses `cluster.yaml` from Rook examples (production-like config with raw disks)

### Custom Build Process

When USE_CUSTOM_BUILD=true, the script:
1. Detects OS (macOS or Linux) and architecture (ARM64/aarch64 or AMD64/x86_64)
2. Sets TARGET_IMAGE variable and exports CONTAINER_MANAGER for Makefile
3. Attempts to build via Makefile: `make BUILD_CONTAINER_IMAGE="${TARGET_IMAGE}" IMAGES="ceph" GOARCH="${GOARCH}" build.all`
4. If Makefile build fails, falls back to manual build:
   - Builds Rook operator binary for Linux using Go
   - Builds container image directly using configured container runtime
5. Verifies the image was created successfully
6. Saves image to tar file and loads into Minikube
7. Cleans up temporary tar file
8. Patches operator.yaml to use custom image with imagePullPolicy: Never

The container runtime can be configured via CONTAINER_RUNTIME variable (supports "docker" or "podman"). The script works on both macOS (including M1/M2) and Linux (x86_64/amd64 and aarch64/arm64).

### Manifest Templates

Manifests in `manifests/` directory use placeholder substitution:
- Scripts use `sed` to replace placeholders like NAMESPACE, OBJECT_STORE_NAME, etc.
- Temporary files created in /tmp before applying to cluster
- ConfigMap for Python app embeds Python source files using awk substitution

## Configuration Variables

All configuration is sourced from `config.env` (if exists) then overridden by environment variables:

**Rook Settings:**
- ROOK_VERSION (default: v1.18.7)
- CEPH_VERSION (default: v18.2.0) - Ceph container image version
- ROOK_CEPH_NAMESPACE (default: rook-ceph)
- ROOK_SOURCE_DIR (default: ~/dev/go/src/github.com/rook/rook)
- USE_CUSTOM_BUILD (default: false)
- CUSTOM_IMAGE_TAG (default: local-build)
- CONTAINER_RUNTIME (default: podman) - Container runtime to use for custom builds (docker or podman)
- OSD_TYPE (default: disk) - OSD storage type: "disk" for raw disks, "pvc" for PersistentVolumeClaims

**Minikube Settings:**
- MINIKUBE_NODES (default: 1)
- MINIKUBE_MEMORY (default: 4096 MB)
- MINIKUBE_CPUS (default: 2)
- MINIKUBE_DISK_SIZE (default: 20g)
- MINIKUBE_EXTRA_DISKS (default: 2) - Extra disks for Ceph OSDs
- MINIKUBE_DRIVER (default: qemu) - Recommended for Mac M1/M2
- MINIKUBE_NETWORK (optional)

**Object Store Settings:**
- OBJECT_STORE_NAME (default: my-store)
- OBJECT_STORE_USER (default: my-user)
- SAMPLE_APP_NAMESPACE (default: default)

## Important Implementation Details

### Wait Conditions

The install script uses helper functions for waiting on cluster readiness:

**wait_for_osd_pods()**
- Calculates expected OSD count: `MINIKUBE_NODES × MINIKUBE_EXTRA_DISKS`
- Waits up to 10 minutes (600 seconds) for all OSDs to be ready
- Shows progress updates every 30 seconds
- Returns diagnostic information on timeout

**wait_for_ceph_health()**
- First waits for toolbox pod to be ready (up to 2 minutes)
- Checks `ceph health` status via toolbox
- Waits up to 10 minutes (600 seconds) for HEALTH_OK
- Shows current health status every 30 seconds
- Shows full `ceph status` every 60 seconds for detailed diagnostics
- Returns diagnostic information on timeout

These helper functions provide better visibility into the cluster initialization process compared to simple kubectl wait commands.

### Ceph Version Substitution

When deploying cluster, the script downloads the cluster manifest from Rook GitHub and substitutes the Ceph image version:
```bash
sed -i.bak "s|image: quay.io/ceph/ceph:v[0-9.]*|image: quay.io/ceph/ceph:${CEPH_VERSION}|g" /tmp/cluster.yaml
```

### Prometheus Module Enablement

When `ENABLE_PROMETHEUS=true`, the `deploy_ceph_cluster` function automatically enables the Prometheus module in the CephCluster CR:
1. After downloading the cluster manifest, it checks if a `monitoring:` section exists
2. If the section exists, it changes `enabled: false` to `enabled: true`
3. If no monitoring section exists, it adds one after `spec:` with `enabled: true`
4. This ensures the Ceph mgr Prometheus module is activated to expose metrics for scraping

### Namespace Flexibility

All scripts use ROOK_CEPH_NAMESPACE variable, allowing deployment to custom namespaces. The namespace is used consistently across:
- Operator deployment
- Cluster deployment
- Object store deployment
- All kubectl commands

### Sample App Implementation

The Python S3 test app:
- Uses boto3, the AWS SDK for Python (pip package: boto3)
- Runs as a Kubernetes Job with python:3.11-alpine base image
- Gets credentials from Kubernetes Secret created by deploy-object-store.sh
- Tests: bucket creation, object upload/download, listing, content verification
- Source code (test_s3.py) and requirements.txt are embedded in ConfigMap and mounted into Job pod
- The job installs dependencies via pip before running the test script

### COSI Sample App Implementation

The Python COSI S3 test app (manifests/sample-apps/python-cosi-test/):
- Demonstrates proper COSI bucket consumption as per COSI specification
- Mounts COSI secret at `/data/cosi/BucketInfo` (standard COSI mount point)
- Reads and parses JSON from BucketInfo containing:
  - `spec.bucketName`: The provisioned bucket name
  - `spec.secretS3.endpoint`: S3 endpoint URL
  - `spec.secretS3.accessKeyID`: Access key for authentication
  - `spec.secretS3.accessSecretKey`: Secret key for authentication
  - `spec.secretS3.region`: S3 region (defaults to us-east-1)
- Uses boto3 with path-style addressing (required for Ceph RGW)
- Tests S3 operations on the COSI-provisioned bucket: upload, download, list, delete
- Source code (test_cosi_s3.py) and requirements.txt are embedded in ConfigMap
- The Job manifest demonstrates two volume mounts:
  1. ConfigMap volume with Python scripts at `/scripts`
  2. COSI secret volume at `/data/cosi` (read-only, mode 0400)

Key difference from traditional S3 apps:
- Traditional: Credentials passed via environment variables or explicit secrets
- COSI: Credentials read from standardized BucketInfo JSON at `/data/cosi/BucketInfo`
- COSI provides portable, driver-agnostic bucket provisioning

### Thorough Cleanup Process (uninstall-rook-ceph-2.sh)

The enhanced uninstall script follows a specific order to ensure clean removal:

1. **Delete Dependent Resources First**: CephFilesystems, CephObjectStores, CephBlockPools
2. **Enable Cleanup Policy**: Patches CephCluster with `cleanupPolicy.confirmation: "yes-really-destroy-data"`
3. **Delete CephCluster**: Triggers automatic cleanup jobs
4. **Wait for Cleanup Jobs**: Monitors jobs matching `cluster-cleanup-job` prefix (3-minute timeout)
5. **Remove Rook Artifacts**: Deletes CRDs, common resources, CSI operator, operator
6. **Cleanup Namespace**: Force-deletes namespace and removes finalizers if stuck
7. **Clean Terminating Pods**: Force-deletes any remaining pods
8. **Node Data Cleanup**: SSH into each Minikube node and `rm -rf /var/lib/rook`
9. **Delete PVs**: Force-deletes all persistent volumes

**Important**: This script uses hardcoded ROOK_IMAGE variable that may need updating for different environments.

## Testing

After deployment, verify:
1. All pods are running: `kubectl -n rook-ceph get pods`
2. Ceph cluster is healthy: `kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status`
3. For object store: Check job logs: `kubectl -n default logs -f job/s3-test-job`

## Common Development Patterns

### Adding New Manifests

1. Create manifest in appropriate `manifests/` subdirectory
2. Use placeholder variables (NAMESPACE, OBJECT_STORE_NAME, etc.)
3. Update deployment script to substitute placeholders using sed
4. Document placeholders in manifests/README.md

### Modifying Scripts

- Scripts use bash `set -e` (exit on error)
- Color-coded output functions: print_info, print_warn, print_error
- Configuration loading hierarchy:
  1. Scripts define default values
  2. If `config.env` exists in SCRIPT_DIR, source it (overrides defaults)
  3. Environment variables override both defaults and config.env values
- SCRIPT_DIR determined using: `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)`
- All main scripts (install, deploy, cleanup, uninstall) follow this pattern

### Custom Builds

To develop Rook operator changes:
1. Clone Rook repository to ROOK_SOURCE_DIR
2. Make code changes
3. Run: `USE_CUSTOM_BUILD=true ./install-rook-ceph.sh`
4. The script builds and loads your custom image automatically

To use docker instead of podman for custom builds:
```bash
USE_CUSTOM_BUILD=true CONTAINER_RUNTIME=docker ./install-rook-ceph.sh
```
