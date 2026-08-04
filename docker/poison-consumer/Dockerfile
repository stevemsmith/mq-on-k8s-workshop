# syntax=docker/dockerfile:1
#
# Builds amqspoisonc, a small C program (amqspoison.c) that simulates a
# consumer which can never process a message, so BOTHRESH/BOQNAME poison
# message handling kicks in. There is no redistributable client for
# arm64, so the arm64 leg reuses the same MQ Advanced for Developers
# archive that docker/build.sh downloads for the base image build - see
# docker/build-poison-consumer.sh for how that gets staged into MQINST/.

ARG BASE_IMAGE=gcc:12
FROM $BASE_IMAGE AS builder

ARG TARGETARCH TARGETOS
ENV VRMF=9.4.5.0

RUN mkdir -p /opt/mqm /MQINST
COPY README.md MQINST*/*.tar.gz /MQINST/

ARG RDURL_ARG="https://public.dhe.ibm.com/ibmdl/export/pub/software/websphere/messaging/mqdev/redist"
RUN T="$TARGETOS/$TARGETARCH"; \
      if [ "$T" = "linux/amd64" ]; then \
        MQARCH=X64; \
        RDTAR="IBM-MQC-Redist-Linux${MQARCH}.tar.gz"; \
        cd /opt/mqm \
        && curl -LO "$RDURL_ARG/$VRMF-$RDTAR" \
        && tar -zxf ./*.tar.gz \
        && rm -f ./*.tar.gz \
        && export genmqpkg_incsdk=1 \
        && bin/genmqpkg.sh -b /opt/mqm; \
      elif [ "$T" = "linux/arm64" ]; then \
        cd /MQINST; \
        c=`ls *$VRMF*.tar.gz 2>/dev/null | wc -l`; \
        if [ $c -ne 1 ]; then echo "MQ installation file does not exist in MQINST subdirectory"; exit 1; fi; \
        cd /opt/mqm \
        && tar -zxf /MQINST/*.tar.gz \
        && export genmqpkg_incserver=0 \
        && export genmqpkg_incsdk=1 \
        && bin/genmqpkg.sh -b /opt/mqm; \
      else \
        echo "Unsupported platform $T"; exit 1; \
      fi

WORKDIR /build
COPY amqspoison.c .
RUN gcc -O2 -I/opt/mqm/inc -o amqspoisonc amqspoison.c \
      -L/opt/mqm/lib64 -Wl,-rpath,/opt/mqm/lib64 -lmqic_r
