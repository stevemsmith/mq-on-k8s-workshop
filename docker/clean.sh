#!/bin/bash
#
# Remove every artifact produced by build.sh so the next run starts
# from a clean state. Safe to run repeatedly.
#
# Removes:
#   - the mq_prometheus binary
#   - the amqspoisonc binary and its staged arm64 MQINST/ archive
#   - the cloned mq-metric-samples/ source tree
#   - the cloned mq-container/ source tree (arm64 only)
#   - the throwaway mqprom:* and poisonbuild:* builder images
#   - the moov-mq:local image
#   - any locally-built ibm-mqadvanced-server-dev:*-arm64 base images

set -eu
cd "$(dirname "$0")"

echo ">>> Removing build artifacts under $(pwd)"
rm -rf mq-metric-samples mq-container mq_prometheus amqspoisonc poison-consumer/MQINST

# Any mqprom / poisonbuild builder tags
mqprom_images=$(docker images --format '{{.Repository}}:{{.Tag}}' \
  | grep -E '^(mqprom|poisonbuild):' || true)
if [ -n "$mqprom_images" ]; then
  echo ">>> Removing mqprom/poisonbuild builder images"
  echo "$mqprom_images" | xargs -n1 docker rmi -f
fi

# The final image
if docker image inspect moov-mq:local >/dev/null 2>&1; then
  echo ">>> Removing moov-mq:local"
  docker rmi -f moov-mq:local
fi

# Locally-built arm64 base image(s) from mq-container/make build-devserver
devserver_images=$(docker images --format '{{.Repository}}:{{.Tag}}' \
  | grep -E '^ibm-mqadvanced-server-dev:.*-arm64$' || true)
if [ -n "$devserver_images" ]; then
  echo ">>> Removing locally-built arm64 base images"
  echo "$devserver_images" | xargs -n1 docker rmi -f
fi

# Best-effort dangling-layer sweep for the intermediate build stages.
docker image prune -f >/dev/null

echo ">>> Done."
