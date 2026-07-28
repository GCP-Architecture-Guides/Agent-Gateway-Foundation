#!/bin/bash
MAX_RETRIES=15
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  echo "Running terraform destroy..."
  terraform destroy -auto-approve
  if [ $? -eq 0 ]; then
    echo "Destroy successful!"
    exit 0
  fi
  echo "Terraform destroy failed. Retrying in 60 seconds (Attempt $((RETRY_COUNT+1)) of $MAX_RETRIES)..."
  sleep 60
  RETRY_COUNT=$((RETRY_COUNT+1))
done
echo "Max retries reached. Exiting."
exit 1
