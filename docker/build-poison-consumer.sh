#!/bin/bash
#
# Build amqspoisonc, the poison-message/dead-letter-queue demo consumer,
# from docker/poison-consumer/amqspoison.c.
#
# There is no MQ client compiler+headers in the moov-mq runtime image
# (or the base MQ server image it's built from), so this compiles the
# program in a throwaway builder image that installs the MQ client SDK
# first - amd64 gets it via IBM's Redistributable Client (curl); arm64
# has no redistributable, so it reuses the same MQ Advanced for
# Developers archive docker/build.sh downloads for the base image build.
#
# Result: ./amqspoisonc, a native binary for the requested TARGETARCH,
# ready for the "docker build" step to COPY into the moov-mq image.
#
# Usage:
#   ./build-poison-consumer.sh              # auto-detect host arch
#   ./build-poison-consumer.sh amd64
#   ./build-poison-consumer.sh arm64

set -eux

# ---------------------------------------------------------------------------
# Argument / architecture handling
# ---------------------------------------------------------------------------
case "${1:-}" in
  amd64|arm64) TARGETARCH="$1" ;;
  "")
    case "$(uname -m)" in
      x86_64|amd64)  TARGETARCH=amd64 ;;
      aarch64|arm64) TARGETARCH=arm64 ;;
      *) echo "unsupported host architecture: $(uname -m)"; exit 1 ;;
    esac
    ;;
  *) echo "unsupported TARGETARCH: $1 (want amd64 or arm64)"; exit 1 ;;
esac

export MQ_VERSION=9.4.5.0
export DOCKER_DEFAULT_PLATFORM="linux/${TARGETARCH}"

# ---------------------------------------------------------------------------
# arm64: seed MQINST/ with the developer MQ archive downloaded by the
# base-image build (docker/build.sh downloads it via mq-container/make).
# ---------------------------------------------------------------------------
if [ "$TARGETARCH" = "arm64" ]; then
  mkdir -p poison-consumer/MQINST
  archive="mq-container/downloads/${MQ_VERSION}-IBM-MQ-Advanced-for-Developers-Non-Install-LinuxARM64.tar.gz"
  if [ ! -f "$archive" ]; then
    echo
    echo "ERROR: arm64 build needs the MQ Advanced for Developers archive at:"
    echo "  $archive"
    echo
    echo "Run docker/build.sh (which downloads it) first."
    exit 1
  fi
  cp "$archive" poison-consumer/MQINST/
fi

# ---------------------------------------------------------------------------
# Build the consumer for TARGETARCH.
# ---------------------------------------------------------------------------
cd poison-consumer
docker buildx build --load \
  --platform "linux/${TARGETARCH}" \
  -t "poisonbuild:${TARGETARCH}" \
  -f Dockerfile \
  .
cd -

# ---------------------------------------------------------------------------
# Extract the compiled binary from the throwaway image
# ---------------------------------------------------------------------------
docker run --rm --platform "linux/${TARGETARCH}" \
  --entrypoint /bin/bash \
  -v "$PWD:/pwd" -w /pwd \
  "poisonbuild:${TARGETARCH}" \
  -c "install -m 755 /build/amqspoisonc ."

file amqspoisonc || true
