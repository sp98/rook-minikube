# Kubernetes Manifests

This directory contains YAML manifests used by the deployment scripts.

## Directory Structure

```
manifests/
├── object-store/           # CephObjectStore related manifests
│   ├── object-store.yaml         # CephObjectStore definition
│   └── object-store-user.yaml    # CephObjectStoreUser definition
│
└── sample-apps/           # Sample application manifests
    ├── go-s3-test/              # Go source files for S3 test app
    │   ├── main.go              # Main Go application
    │   └── go.mod               # Go module definition
    ├── s3-test-configmap.yaml   # ConfigMap for Go app
    ├── s3-test-job.yaml         # Job to run S3 tests
    └── s3-curl-pod.yaml         # Curl test pod
```

## Object Store Manifests

### object-store.yaml
Defines a CephObjectStore with:
- Single replica for metadata and data pools
- HTTP gateway on port 80
- Suitable for development environments

### object-store-user.yaml
Creates a user for accessing the object store with S3-compatible credentials.

## Sample Apps

### Go S3 Test Application
A complete Go application that tests S3 operations:
- Creates buckets
- Uploads and downloads objects
- Lists buckets and objects
- Verifies data integrity

**Files:**
- `go-s3-test/main.go` - Main application code
- `go-s3-test/go.mod` - Go module dependencies
- `s3-test-configmap.yaml` - Kubernetes ConfigMap containing the Go code
- `s3-test-job.yaml` - Kubernetes Job to run the tests

### Curl Test Pod
A simple pod with curl for manual S3 API testing.

## Usage

These manifests are used by the `deploy-object-store.sh` script. The script:
1. Substitutes placeholder values (like NAMESPACE, OBJECT_STORE_NAME)
2. Applies the manifests to the cluster

## Customization

You can directly edit these files to customize:
- Replica counts
- Resource limits
- Gateway settings
- Test scenarios

After editing, run `./deploy-object-store.sh` to apply changes.

## Placeholders

The following placeholders are replaced by the deployment script:
- `NAMESPACE` - Kubernetes namespace (default: rook-ceph)
- `OBJECT_STORE_NAME` - Object store name (default: my-store)
- `OBJECT_STORE_USER` - Object store user name (default: my-user)
- `SAMPLE_APP_NAMESPACE` - Sample app namespace (default: default)
- `MAIN_GO_CONTENT` - Content of main.go file
- `GO_MOD_CONTENT` - Content of go.mod file
