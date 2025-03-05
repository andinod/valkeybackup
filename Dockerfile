# Use an existing image as a base
FROM ubuntu:24.04

# Install the required dependencies
RUN apt-get update && \
    apt-get install -y netcat-openbsd && \
    apt-get install -y curl vim unzip jq && \
    apt-get install -y restic && \
    apt-get install -y redis-tools && \
    apt-get install -y ca-certificates

WORKDIR /backup

# Download and install kubectl
RUN curl -LO "https://dl.k8s.io/release/stable.txt"
RUN curl -LO "https://dl.k8s.io/$(cat stable.txt)/bin/linux/amd64/kubectl"
RUN chmod +x kubectl
RUN mv kubectl /usr/local/bin/

COPY backup/env_vars.env /backup
COPY backup/backup.bash /backup/backup.bash

# Adding default certificates
RUN update-ca-certificates

# Make the script executable
RUN chmod +x /backup/backup.bash
