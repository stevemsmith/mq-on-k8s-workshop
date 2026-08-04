# Drives every step of the tutorial in README.md.
#
# Typical use:
#   make            # print available targets
#   make all        # build image, generate certs, deploy, spin up client pod
#   make put get    # send one message; read it back
#   make loop       # push 200 messages through the SDR/RCVR pair
#   make grafana    # open Grafana on http://localhost:3000
#   make clean      # tear down everything, back to a fresh checkout
#
# Overridable variables:
#   NAMESPACE=mq        Kubernetes namespace the module deploys into
#   QMGR=qm1            queue manager name (must match terraform.tfvars)
#   KUBE_CTX=docker-desktop  kube context to talk to
#   IMAGE=moov-mq:local the tag build.sh produces

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

NAMESPACE   ?= mq
QMGR        ?= qm1
KUBE_CTX    ?= docker-desktop
IMAGE       ?= moov-mq:local

DOCKER_DIR   := docker
CERTS_DIR    := certs
CERTS_OUT    := $(CERTS_DIR)/out
OPENTOFU_DIR := opentofu
CLIENT_DIR   := client

CA_CRT       := $(CERTS_OUT)/ca.crt
CLIENT_P12   := $(CERTS_OUT)/mq-client.p12
IMAGE_STAMP  := $(DOCKER_DIR)/.image-stamp
DEPLOY_STAMP := $(OPENTOFU_DIR)/.deploy-stamp

KUBECTL := kubectl --context=$(KUBE_CTX)
TOFU    := tofu

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN { FS = ":.*##"; printf "Usage: make <target>\n\nTargets:\n" } \
		/^[a-zA-Z0-9_-]+:.*## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)

# ---------------------------------------------------------------------------
# End-to-end flow
# ---------------------------------------------------------------------------
.PHONY: all
all: image certs deploy secret client ## Run the whole tutorial up to a ready client pod.

# ---------------------------------------------------------------------------
# Step 1 - build the moov-mq image
# ---------------------------------------------------------------------------
.PHONY: image
image: $(IMAGE_STAMP) ## Build moov-mq:local (arch-aware; may build an arm64 base first).

$(IMAGE_STAMP): $(DOCKER_DIR)/Dockerfile \
                $(DOCKER_DIR)/build.sh \
                $(DOCKER_DIR)/build-mq-prometheus.sh \
                $(DOCKER_DIR)/mq_prometheus.sh \
                $(DOCKER_DIR)/build-poison-consumer.sh \
                $(DOCKER_DIR)/poison-consumer/Dockerfile \
                $(DOCKER_DIR)/poison-consumer/amqspoison.c
	cd $(DOCKER_DIR) && ./build.sh
	@touch $@

# ---------------------------------------------------------------------------
# Step 2 - TLS material
# ---------------------------------------------------------------------------
.PHONY: certs
certs: $(CA_CRT) ## Generate the CA, queue manager, and client certificates.

$(CA_CRT) $(CLIENT_P12): $(CERTS_DIR)/create-certs.sh
	cd $(CERTS_DIR) && ./create-certs.sh

# ---------------------------------------------------------------------------
# Steps 3-6 - deploy MQ + Prometheus + Grafana with OpenTofu
# ---------------------------------------------------------------------------
.PHONY: init
init: ## Initialise OpenTofu providers (safe to re-run).
	cd $(OPENTOFU_DIR) && $(TOFU) init -input=false -upgrade

.PHONY: deploy
deploy: $(DEPLOY_STAMP) ## Apply the OpenTofu module and wait for the qmgr to be Ready.

$(DEPLOY_STAMP): $(IMAGE_STAMP) $(CA_CRT) \
                 $(OPENTOFU_DIR)/main.tf \
                 $(OPENTOFU_DIR)/observability.tf \
                 $(OPENTOFU_DIR)/variables.tf \
                 $(OPENTOFU_DIR)/terraform.tf \
                 $(OPENTOFU_DIR)/terraform.tfvars \
                 $(OPENTOFU_DIR)/config/mq.mqsc \
                 $(OPENTOFU_DIR)/config/mq.ini
	cd $(OPENTOFU_DIR) && $(TOFU) init -input=false && $(TOFU) apply -auto-approve
	$(KUBECTL) -n $(NAMESPACE) rollout status statefulset/ibm-mq --timeout=5m
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/prometheus --timeout=2m
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/grafana    --timeout=2m
	@touch $@

.PHONY: reload-mqsc
reload-mqsc: ## Re-run /etc/mqm/mq.mqsc on the existing qmgr + bounce the exporter (no data loss).
	$(KUBECTL) -n $(NAMESPACE) exec ibm-mq-0 -- bash -lc \
	  'runmqsc $(QMGR) < /etc/mqm/mq.mqsc'
	$(KUBECTL) -n $(NAMESPACE) exec ibm-mq-0 -- bash -lc \
	  'echo "STOP SERVICE(MQPROMETHEUS); START SERVICE(MQPROMETHEUS)" | runmqsc $(QMGR)'

# ---------------------------------------------------------------------------
# Step 5 - kubernetes Secret holding the client's keystore + CCDT
# ---------------------------------------------------------------------------
.PHONY: secret
secret: $(DEPLOY_STAMP) $(CLIENT_P12) ## Create/refresh the mq-client Secret in-cluster.
	$(KUBECTL) -n $(NAMESPACE) create secret generic mq-client \
	  --from-file=mq-client.p12=$(CERTS_OUT)/mq-client.p12 \
	  --from-file=ca.crt=$(CERTS_OUT)/ca.crt \
	  --from-file=ccdt.json=$(CLIENT_DIR)/ccdt.json \
	  --dry-run=client -o yaml \
	  | $(KUBECTL) apply -f -

# ---------------------------------------------------------------------------
# Step 7 - client pod + message flow
# ---------------------------------------------------------------------------
.PHONY: client
client: secret ## Apply the mq-client pod and wait for it to be Ready.
	$(KUBECTL) apply -f $(CLIENT_DIR)/client-pod.yaml
	$(KUBECTL) -n $(NAMESPACE) wait --for=condition=Ready pod/mq-client --timeout=120s

.PHONY: put
put: ## Put one message on APP.IN (routes to APP.OUT via QALIAS).
	$(KUBECTL) -n $(NAMESPACE) exec -i mq-client -- bash -c \
	  'echo "hello from make at $$(date)" | amqsputc APP.IN $(QMGR)'

.PHONY: browse
browse: ## Browse messages on APP.OUT without removing them.
	$(KUBECTL) -n $(NAMESPACE) exec -it mq-client -- amqsbcgc APP.OUT $(QMGR)

.PHONY: get
get: ## Destructive read from APP.OUT.
	$(KUBECTL) -n $(NAMESPACE) exec -it mq-client -- amqsgetc APP.OUT $(QMGR)

.PHONY: put-pacs008
put-pacs008: ## Put a real ISO 20022 pacs.008 credit-transfer message on APP.IN.
	tr -d '\n' < iso20022/pacs.008-valid.xml \
	  | $(KUBECTL) -n $(NAMESPACE) exec -i mq-client -- amqsputc APP.IN $(QMGR)

.PHONY: put-pacs008-oversized
put-pacs008-oversized: ## Put a pacs.008 message that exceeds APP.OUT's MAXMSGL - MQ refuses the MQPUT.
	tr -d '\n' < iso20022/pacs.008-oversized.xml \
	  | $(KUBECTL) -n $(NAMESPACE) exec -i mq-client -- amqsputc APP.IN $(QMGR)

# ---------------------------------------------------------------------------
# Poison messages and the dead-letter queue
# ---------------------------------------------------------------------------
.PHONY: put-poison
put-poison: ## Put one message on APP.POISON for the poison-message/DLQ exercise.
	$(KUBECTL) -n $(NAMESPACE) exec -i mq-client -- bash -c \
	  'echo "a message no consumer can ever process" | amqsputc APP.POISON $(QMGR)'

.PHONY: run-poison-consumer
run-poison-consumer: ## Run amqspoisonc against APP.POISON (backs the message out until BOTHRESH reroutes it to the DLQ).
	$(KUBECTL) -n $(NAMESPACE) exec -it mq-client -- amqspoisonc APP.POISON $(QMGR)

.PHONY: browse-dlq
browse-dlq: ## Browse DEV.DEAD.LETTER.QUEUE without removing messages.
	$(KUBECTL) -n $(NAMESPACE) exec -it mq-client -- amqsbcgc DEV.DEAD.LETTER.QUEUE $(QMGR)

.PHONY: loop
loop: ## Stream 1 msg/sec into APP.IN over a persistent SVRCONN (^C to stop; needed for Channel Status).
	@# One long-lived amqsputc process keeps the SVRCONN instance
	@# RUNNING for the whole session, so ibmmq_channel_bytes_sent /
	@# _messages / cur_inst accumulate visibly between Prometheus
	@# scrapes instead of vanishing between short-lived connections.
	$(KUBECTL) -n $(NAMESPACE) exec -it mq-client -- bash -lc '\
	  { while sleep 1; do echo "loop msg $$(date +%T)"; done; } \
	    | amqsputc APP.IN $(QMGR)'

# ---------------------------------------------------------------------------
# Grafana / Prometheus port-forwards (blocking; ^C to exit)
# ---------------------------------------------------------------------------
.PHONY: grafana
grafana: ## Port-forward Grafana to http://localhost:3000 (admin/admin).
	$(KUBECTL) -n $(NAMESPACE) port-forward svc/grafana 3000:3000

.PHONY: prometheus
prometheus: ## Port-forward Prometheus to http://localhost:9090.
	$(KUBECTL) -n $(NAMESPACE) port-forward svc/prometheus 9090:9090

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
.PHONY: status
status: ## Show all Kubernetes objects in the mq namespace.
	$(KUBECTL) -n $(NAMESPACE) get all

.PHONY: logs
logs: ## Tail the queue manager pod logs.
	$(KUBECTL) -n $(NAMESPACE) logs -f ibm-mq-0

# ---------------------------------------------------------------------------
# Clean - reset to a fresh checkout
# ---------------------------------------------------------------------------
.PHONY: clean
clean: clean-k8s clean-certs clean-image ## Full reset - equivalent to `git clean` + destroying the deployment.

.PHONY: clean-k8s
clean-k8s: ## Tear down the client pod, Secret, and everything OpenTofu created.
	-$(KUBECTL) delete -f $(CLIENT_DIR)/client-pod.yaml --ignore-not-found
	-$(KUBECTL) -n $(NAMESPACE) delete secret mq-client --ignore-not-found
	-cd $(OPENTOFU_DIR) && $(TOFU) destroy -auto-approve || true
	rm -f $(DEPLOY_STAMP)

.PHONY: clean-certs
clean-certs: ## Remove generated TLS material.
	cd $(CERTS_DIR) && ./clean.sh

.PHONY: clean-image
clean-image: ## Remove the built Docker images and cloned source trees.
	cd $(DOCKER_DIR) && ./clean.sh
	rm -f $(IMAGE_STAMP)
