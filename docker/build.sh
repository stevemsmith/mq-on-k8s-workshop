#!/bin/bash
#
# Top-level build entry point.
#
# 1. Detect the host CPU architecture.
# 2. Pick / build the appropriate MQ base image:
#      amd64 -> icr.io/ibm-messaging/mq:9.4.5.0-r2 (published by IBM)
#      arm64 -> build ibm-mqadvanced-server-dev locally via IBM's
#               mq-container repo, which is the workflow the maintainer
#               recommends because IBM does not publish an arm64 image:
#               https://github.com/ibm-messaging/mq-container/issues/562
# 3. Build the mq_prometheus exporter for that architecture.
# 4. Build the amqspoisonc poison-message/DLQ demo consumer.
# 5. Build the final moov-mq:local image.

set -euo pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# 1. Detect architecture
# ---------------------------------------------------------------------------
case "$(uname -m)" in
  x86_64|amd64)  TARGETARCH=amd64 ;;
  aarch64|arm64) TARGETARCH=arm64 ;;
  *) echo "unsupported host architecture: $(uname -m)"; exit 1 ;;
esac
echo ">>> Building for linux/${TARGETARCH}"

# ---------------------------------------------------------------------------
# 2. Base image
# ---------------------------------------------------------------------------
if [ "$TARGETARCH" = "amd64" ]; then
  BASE_IMAGE="icr.io/ibm-messaging/mq:9.4.5.0-r2"
  echo ">>> Using published base image: $BASE_IMAGE"
else
  # arm64: build IBM's developer image locally.
  if [ ! -d mq-container ]; then
    echo ">>> Cloning ibm-messaging/mq-container"
    git clone -b v9.4.5.0-r2 --depth 1 https://github.com/ibm-messaging/mq-container.git
  fi

  # build-mq-prometheus.sh needs the raw MQ Advanced for Developers
  # arm64 archive (to seed mq-metric-samples/MQINST/) regardless of
  # whether the base image below is already cached, so make sure it's
  # on disk even on a cache hit - otherwise a stale/missing
  # downloads/ directory with a cached base image silently breaks the
  # exporter build.
  ARCHIVE="mq-container/downloads/9.4.5.0-IBM-MQ-Advanced-for-Developers-Non-Install-LinuxARM64.tar.gz"
  if [ ! -f "$ARCHIVE" ]; then
    echo ">>> Fetching MQ Advanced for Developers arm64 archive"
    (cd mq-container && make "downloads/$(basename "$ARCHIVE")")
  fi

  # "make build-devserver" builds an image tagged
  # ibm-mqadvanced-server-dev:<VERSION>-arm64 from the archive above.
  if ! docker image inspect "ibm-mqadvanced-server-dev:9.4.5.0-arm64" >/dev/null 2>&1 \
    && ! docker images --format '{{.Repository}}:{{.Tag}}' \
         | grep -qE '^ibm-mqadvanced-server-dev:.*-arm64$'; then
    echo ">>> Running mq-container/make build-devserver (may take 15+ minutes)"
    (cd mq-container && make build-devserver)
  fi

  BASE_IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E '^ibm-mqadvanced-server-dev:.*-arm64$' | head -1)
  if [ -z "$BASE_IMAGE" ]; then
    echo "ERROR: could not find an arm64 developer image after build-devserver"
    exit 1
  fi
  echo ">>> Using locally built base image: $BASE_IMAGE"
fi

# ---------------------------------------------------------------------------
# 3. Exporter binary
# ---------------------------------------------------------------------------
./build-mq-prometheus.sh "$TARGETARCH"

# ---------------------------------------------------------------------------
# 4. Poison-message/DLQ demo consumer
# ---------------------------------------------------------------------------
./build-poison-consumer.sh "$TARGETARCH"

# ---------------------------------------------------------------------------
# 5. Final image
# ---------------------------------------------------------------------------
docker buildx build --load \
  --platform "linux/${TARGETARCH}" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  -t moov-mq:local \
  .

echo
echo ">>> Built moov-mq:local for linux/${TARGETARCH} from base ${BASE_IMAGE}"
