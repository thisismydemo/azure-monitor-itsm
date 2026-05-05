FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

# json-server for mock ServiceNow REST API
RUN apt-get update && apt-get install -y nodejs npm curl jq && \
    npm install -g json-server && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
