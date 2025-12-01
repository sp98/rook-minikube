# Quick TLS Reference

## Deploy with TLS

```bash
ENABLE_TLS=true ./deploy-object-store.sh
```

## Certificate Location

After deployment, the CA certificate is saved to:
```
./rgw-ca-cert.pem
```

## Common Commands

### AWS CLI

```bash
# Skip verification (development only)
aws s3 ls --endpoint-url https://localhost:8443 --no-verify-ssl

# With CA bundle (recommended)
aws s3 ls --endpoint-url https://localhost:8443 --ca-bundle ./rgw-ca-cert.pem
```

### curl

```bash
# Skip verification
curl -k https://localhost:8443

# With CA bundle
curl --cacert ./rgw-ca-cert.pem https://localhost:8443
```

### Port Forward

```bash
# For HTTPS (TLS enabled)
kubectl -n rook-ceph port-forward svc/rook-ceph-rgw-my-store 8443:443

# For HTTP (TLS disabled)
kubectl -n rook-ceph port-forward svc/rook-ceph-rgw-my-store 8080:80
```

## Extract Certificate from Kubernetes

If you lost the `rgw-ca-cert.pem` file:

```bash
kubectl -n rook-ceph get secret my-store-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > rgw-ca-cert.pem
```

## View Certificate Details

```bash
openssl x509 -in rgw-ca-cert.pem -text -noout
```

## Trust Certificate System-Wide

### macOS
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ./rgw-ca-cert.pem
```

### Linux (Ubuntu/Debian)
```bash
sudo cp ./rgw-ca-cert.pem /usr/local/share/ca-certificates/rgw-ca-cert.crt
sudo update-ca-certificates
```

### Linux (RHEL/CentOS/Fedora)
```bash
sudo cp ./rgw-ca-cert.pem /etc/pki/ca-trust/source/anchors/rgw-ca-cert.crt
sudo update-ca-trust
```

## Configuration Variables

```bash
# Enable/disable TLS
ENABLE_TLS="true"

# Certificate domain
TLS_CERT_DOMAIN="rook-ceph-rgw-my-store.rook-ceph.svc"

# Certificate validity (days)
TLS_CERT_DAYS="365"
```

## Full Documentation

- Setup Guide: [TLS_SETUP.md](./TLS_SETUP.md)
- Troubleshooting: [TLS_TROUBLESHOOTING.md](./TLS_TROUBLESHOOTING.md)
