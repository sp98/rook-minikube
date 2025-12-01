#!/usr/bin/env python3
"""
S3 Test Script for Rook Ceph Object Store
Tests basic S3 operations using boto3
"""

import os
import sys
import boto3
from botocore.exceptions import ClientError
import urllib3

# Disable SSL warnings when using self-signed certificates
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


def main():
    # Get credentials from environment
    endpoint = os.getenv("S3_ENDPOINT")
    access_key = os.getenv("S3_ACCESS_KEY")
    secret_key = os.getenv("S3_SECRET_KEY")
    use_tls = os.getenv("S3_USE_TLS", "false").lower() == "true"

    if not all([endpoint, access_key, secret_key]):
        print("✗ Missing required environment variables")
        print("  Required: S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY")
        sys.exit(1)

    print(f"Connecting to S3 endpoint: {endpoint}")
    print(f"TLS enabled: {use_tls}")

    # Create S3 client
    try:
        s3_client = boto3.client(
            's3',
            endpoint_url=endpoint,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
            region_name='us-east-1',
            use_ssl=use_tls,
            verify=False  # Skip certificate verification for self-signed certs
        )
    except Exception as e:
        print(f"✗ Failed to create S3 client: {e}")
        sys.exit(1)

    bucket_name = "test-bucket"

    # Create bucket
    print(f"Creating bucket: {bucket_name}")
    try:
        s3_client.create_bucket(Bucket=bucket_name)
        print("✓ Bucket created successfully!")
    except ClientError as e:
        if e.response['Error']['Code'] == 'BucketAlreadyOwnedByYou':
            print("✓ Bucket already exists (owned by you)")
        else:
            print(f"✗ Failed to create bucket: {e}")
            sys.exit(1)

    # Upload a test file
    print("Uploading test file...")
    test_content = "Hello from Rook Ceph Object Store!"
    try:
        s3_client.put_object(
            Bucket=bucket_name,
            Key="test.txt",
            Body=test_content.encode('utf-8')
        )
        print("✓ File uploaded successfully!")
    except ClientError as e:
        print(f"✗ Failed to upload file: {e}")
        sys.exit(1)

    # List buckets
    print("\nListing all buckets:")
    try:
        response = s3_client.list_buckets()
        for bucket in response.get('Buckets', []):
            print(f"  - {bucket['Name']}")
    except ClientError as e:
        print(f"✗ Failed to list buckets: {e}")
        sys.exit(1)

    # List objects in bucket
    print(f"\nListing objects in {bucket_name}:")
    try:
        response = s3_client.list_objects_v2(Bucket=bucket_name)
        for obj in response.get('Contents', []):
            print(f"  - {obj['Key']} ({obj['Size']} bytes)")
    except ClientError as e:
        print(f"✗ Failed to list objects: {e}")
        sys.exit(1)

    # Download and verify
    print("\nDownloading and verifying file...")
    try:
        response = s3_client.get_object(Bucket=bucket_name, Key="test.txt")
        content = response['Body'].read().decode('utf-8')
        print(f"Content: {content}")

        if content == test_content:
            print("✓ Content verified successfully!")
        else:
            print("✗ Content verification failed!")
            print(f"  Expected: {test_content}")
            print(f"  Got: {content}")
            sys.exit(1)
    except ClientError as e:
        print(f"✗ Failed to download file: {e}")
        sys.exit(1)

    print("\n" + "=" * 50)
    print("All S3 operations completed successfully!")
    print("=" * 50)


if __name__ == "__main__":
    main()
