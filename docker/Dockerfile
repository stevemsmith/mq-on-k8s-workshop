# The base image is selected by ./build.sh based on the host CPU:
#   linux/amd64 -> icr.io/ibm-messaging/mq:9.4.5.0-r2  (published by IBM)
#   linux/arm64 -> ibm-mqadvanced-server-dev:<version>-arm64
#                  (built locally by mq-container/make build-devserver -
#                  IBM does not publish an arm64 image; see
#                  https://github.com/ibm-messaging/mq-container/issues/562)
ARG BASE_IMAGE=icr.io/ibm-messaging/mq:9.4.5.0-r2
FROM ${BASE_IMAGE}

USER root

# install the unofficial Prometheus exporter built by build-mq-prometheus.sh
COPY mq_prometheus      /usr/local/bin/mq_prometheus
COPY mq_prometheus.sh   /usr/local/bin/mq_prometheus.sh
RUN  chmod +x /usr/local/bin/mq_prometheus /usr/local/bin/mq_prometheus.sh

# install the poison-message/DLQ demo consumer built by build-poison-consumer.sh
COPY amqspoisonc        /usr/local/bin/amqspoisonc
RUN  chmod +x /usr/local/bin/amqspoisonc

USER 1001
