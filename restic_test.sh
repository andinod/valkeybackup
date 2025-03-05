export VALKEY_NAME=valkey-single-ssl
export VALKEY_NAMESPACE=default
export VALKEY_USE_TLS=true
export VALKEY_TYPE=standalone
export JOB_BUCKET_NAME=
export JOB_S3_REGION=
export JOB_S3_HOST=
export JOB_S3_PORT=443
export JOB_S3_SSL_VERIFY_PEER=false
export JOB_S3_USE_SSL=true
export JOB_S3_ACCESS_KEY=
export JOB_S3_SECRET_KEY=
export S3_ENDPOINT=https://${JOB_S3_HOST}:${JOB_S3_PORT}
export AWS_S3_BUCKET=${JOB_BUCKET_NAME}
export AWS_DEFAULT_REGION=${JOB_S3_REGION}
export RESTIC_PASSWORD=
export RESTIC_CACHE_DIR=/tmp/restic_cache
export AWS_ACCESS_KEY_ID=${JOB_S3_ACCESS_KEY}
export AWS_SECRET_ACCESS_KEY=${JOB_S3_SECRET_KEY}
RESTIC_REPOSITORY="s3:${S3_ENDPOINT}/${AWS_S3_BUCKET}/${REDIS_TYPE}-${REDIS_NAME}-${REDIS_NAMESPACE}"



restic -r "$RESTIC_REPOSITORY" snapshots 

echo
echo
#restic init --repo "$RESTIC_REPOSITORY"
#~/restic -r "$RESTIC_REPOSITORY" ls d179d4c0

