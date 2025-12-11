#!/usr/bin/env python3
"""
COSI S3 Test Application

This application demonstrates how to consume a bucket created via COSI (Container Object Storage Interface).
It reads bucket credentials from the COSI secret mounted at /data/cosi/BucketInfo and performs basic S3 operations.
"""

import json
import os
import sys
import boto3
from botocore.client import Config
from botocore.exceptions import ClientError


def load_cosi_bucket_info():
    """
    Load bucket information from COSI secret mounted at /data/cosi/BucketInfo.
    The BucketInfo file contains JSON with endpoint, credentials, and bucket name.
    """
    bucket_info_path = "/data/cosi/BucketInfo"

    print(f"Loading COSI bucket information from {bucket_info_path}...")

    try:
        with open(bucket_info_path, 'r') as f:
            bucket_info = json.load(f)

        print("Successfully loaded bucket information:")
        print(json.dumps(bucket_info, indent=2))

        # Extract S3 credentials from the nested structure
        # Expected format: {"spec": {"bucketName": "...", "secretS3": {...}}}
        # or direct format: {"endpoint": "...", "accessKeyID": "...", ...}

        if 'spec' in bucket_info:
            # Newer COSI format with spec
            spec = bucket_info['spec']
            bucket_name = spec.get('bucketName', '')
            secret_s3 = spec.get('secretS3', {})

            endpoint = secret_s3.get('endpoint', '')
            region = secret_s3.get('region', 'us-east-1')
            access_key = secret_s3.get('accessKeyID', '')
            secret_key = secret_s3.get('accessSecretKey', '')
        else:
            # Direct format
            bucket_name = bucket_info.get('bucketName', '')
            endpoint = bucket_info.get('endpoint', '')
            region = bucket_info.get('region', 'us-east-1')
            access_key = bucket_info.get('accessKeyID', '')
            secret_key = bucket_info.get('accessSecretKey', '')

        return {
            'bucket_name': bucket_name,
            'endpoint': endpoint,
            'region': region,
            'access_key': access_key,
            'secret_key': secret_key
        }

    except FileNotFoundError:
        print(f"ERROR: COSI BucketInfo file not found at {bucket_info_path}")
        print("Make sure the COSI secret is properly mounted to the pod")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"ERROR: Failed to parse BucketInfo JSON: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: Unexpected error loading bucket info: {e}")
        sys.exit(1)


def create_s3_client(bucket_info):
    """
    Create and configure boto3 S3 client with COSI bucket information.
    """
    print("\nCreating S3 client...")
    print(f"  Endpoint: {bucket_info['endpoint']}")
    print(f"  Region: {bucket_info['region']}")
    print(f"  Bucket: {bucket_info['bucket_name']}")

    # Create S3 client with path-style addressing (required for Ceph RGW)
    s3_client = boto3.client(
        's3',
        endpoint_url=bucket_info['endpoint'],
        aws_access_key_id=bucket_info['access_key'],
        aws_secret_access_key=bucket_info['secret_key'],
        region_name=bucket_info['region'],
        config=Config(signature_version='s3v4', s3={'addressing_style': 'path'}),
        verify=False  # Skip SSL verification for self-signed certs
    )

    print("S3 client created successfully!")
    return s3_client


def test_bucket_operations(s3_client, bucket_name):
    """
    Test basic S3 operations on the COSI-provisioned bucket.
    """
    print(f"\n{'='*60}")
    print("Testing S3 Operations on COSI Bucket")
    print(f"{'='*60}")

    # Test 1: Check if bucket exists
    print(f"\n1. Checking if bucket '{bucket_name}' exists...")
    try:
        s3_client.head_bucket(Bucket=bucket_name)
        print(f"   SUCCESS: Bucket '{bucket_name}' exists!")
    except ClientError as e:
        error_code = e.response['Error']['Code']
        if error_code == '404':
            print(f"   WARNING: Bucket '{bucket_name}' does not exist")
            print("   This is unexpected - COSI should have created it")
            return False
        else:
            print(f"   ERROR: Failed to check bucket: {e}")
            return False

    # Test 2: Upload an object
    test_key = "cosi-test-file.txt"
    test_content = "Hello from COSI! This file was uploaded via the COSI bucket access."

    print(f"\n2. Uploading object '{test_key}'...")
    try:
        s3_client.put_object(
            Bucket=bucket_name,
            Key=test_key,
            Body=test_content.encode('utf-8')
        )
        print(f"   SUCCESS: Object '{test_key}' uploaded!")
    except ClientError as e:
        print(f"   ERROR: Failed to upload object: {e}")
        return False

    # Test 3: List objects
    print(f"\n3. Listing objects in bucket...")
    try:
        response = s3_client.list_objects_v2(Bucket=bucket_name)
        if 'Contents' in response:
            print(f"   SUCCESS: Found {len(response['Contents'])} object(s):")
            for obj in response['Contents']:
                print(f"     - {obj['Key']} ({obj['Size']} bytes)")
        else:
            print("   No objects found in bucket")
    except ClientError as e:
        print(f"   ERROR: Failed to list objects: {e}")
        return False

    # Test 4: Download the object
    print(f"\n4. Downloading object '{test_key}'...")
    try:
        response = s3_client.get_object(Bucket=bucket_name, Key=test_key)
        downloaded_content = response['Body'].read().decode('utf-8')
        print(f"   Downloaded content: '{downloaded_content}'")

        if downloaded_content == test_content:
            print("   SUCCESS: Downloaded content matches uploaded content!")
        else:
            print("   ERROR: Content mismatch!")
            return False
    except ClientError as e:
        print(f"   ERROR: Failed to download object: {e}")
        return False

    # Test 5: Get object metadata
    print(f"\n5. Getting object metadata...")
    try:
        response = s3_client.head_object(Bucket=bucket_name, Key=test_key)
        print(f"   Content-Length: {response['ContentLength']} bytes")
        print(f"   Content-Type: {response['ContentType']}")
        print(f"   Last-Modified: {response['LastModified']}")
        print(f"   ETag: {response['ETag']}")
        print("   SUCCESS: Retrieved object metadata!")
    except ClientError as e:
        print(f"   ERROR: Failed to get object metadata: {e}")
        return False

    # Test 6: Delete the object
    print(f"\n6. Deleting object '{test_key}'...")
    try:
        s3_client.delete_object(Bucket=bucket_name, Key=test_key)
        print(f"   SUCCESS: Object '{test_key}' deleted!")
    except ClientError as e:
        print(f"   ERROR: Failed to delete object: {e}")
        return False

    # Test 7: Verify deletion
    print(f"\n7. Verifying object deletion...")
    try:
        response = s3_client.list_objects_v2(Bucket=bucket_name)
        if 'Contents' in response:
            remaining_objects = [obj['Key'] for obj in response['Contents']]
            if test_key in remaining_objects:
                print(f"   ERROR: Object '{test_key}' still exists after deletion!")
                return False
            else:
                print(f"   SUCCESS: Object successfully deleted!")
        else:
            print("   SUCCESS: Bucket is empty (object successfully deleted)!")
    except ClientError as e:
        print(f"   ERROR: Failed to verify deletion: {e}")
        return False

    return True


def main():
    """
    Main function to test COSI bucket access.
    """
    print("="*60)
    print("COSI S3 Bucket Test Application")
    print("="*60)

    # Load bucket information from COSI secret
    bucket_info = load_cosi_bucket_info()

    # Create S3 client
    s3_client = create_s3_client(bucket_info)

    # Run tests
    success = test_bucket_operations(s3_client, bucket_info['bucket_name'])

    # Print final result
    print(f"\n{'='*60}")
    if success:
        print("ALL TESTS PASSED!")
        print("COSI bucket access is working correctly!")
    else:
        print("SOME TESTS FAILED!")
        print("Please check the error messages above")
        sys.exit(1)
    print(f"{'='*60}\n")


if __name__ == "__main__":
    main()
