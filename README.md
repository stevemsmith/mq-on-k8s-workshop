# Deploying IBM MQ to Kubernetes

A walkthrough that takes you from "I have Docker Desktop installed" to a
running IBM MQ queue manager in Kubernetes that you can authenticate to
with a client certificate and exchange messages with using the MQ
sample programs (`amqsput` / `amqsbcg`).

The tutorial is built to run on a single laptop using:

- Docker Desktop (with Kubernetes enabled)
- OpenTofu (or Terraform - the configuration is compatible)
- `kubectl`
- OpenSSL

Nothing in this guide requires a paid IBM entitlement: it uses the
publicly available **IBM MQ Advanced for Developers** image as a base.

## Repository layout

```
.
├── Makefile               # top-level entry point wrapping every step
├── docker/                # build.sh (arch-aware) + Dockerfile + scripts to build moov-mq:local
├── opentofu/              # OpenTofu config that deploys MQ, Prometheus, Grafana
│   ├── config/            # mq.mqsc and mq.ini mounted into the qmgr pod
│   └── dashboards/        # Grafana dashboards loaded via ConfigMap
├── certs/                 # OpenSSL script that produces the TLS material
├── client/                # Pod manifest and CCDT used for the end-to-end test
├── iso20022/              # Sample pacs.008 payment messages (valid + oversized)
└── README.md
```

## Quick start with `make`

A top-level `Makefile` wraps every command in this tutorial. Run
`make help` for the full list; the end-to-end flow reduces to:

```bash
make image        # Step 1 - build moov-mq:local (arch-aware)
make certs        # Step 2 - generate TLS material
make deploy       # Step 3 & Step 6 - apply OpenTofu, wait for pods
make secret       # Step 5 - push the client keystore Secret
make client       # Step 7 - start the mq-client pod

make put          # send one message on APP.IN
make get          # destructively read from APP.OUT
make loop         # keep a persistent connection sending 1 msg/sec (^C to stop)
make put-pacs008            # send a real ISO 20022 pacs.008 credit transfer
make put-pacs008-oversized  # send a pacs.008 that exceeds MAXMSGL - MQ rejects the MQPUT
make grafana      # port-forward Grafana to http://localhost:3000
make prometheus   # port-forward Prometheus to http://localhost:9090
```

Two convenience aggregators:

```bash
make all          # image + certs + deploy + secret + client, in order
make clean        # tear down k8s resources, remove certs, remove images
```

Every make target is idempotent (safe to re-run) and only rebuilds
what has changed - stamp files under `docker/.image-stamp` and
`opentofu/.deploy-stamp` short-circuit already-done work.

The rest of this document walks through each step in detail. Each
step's manual commands appear first; a `make` shortcut is called out
alongside so you can pick either style.

## Prerequisites

1. Docker Desktop running, with **Kubernetes enabled** in
   Settings → Kubernetes. Confirm with `kubectl config current-context`
   - it should print `docker-desktop`. If it prints something else
     (a cloud cluster, `minikube`, etc.), switch to it:

     ```bash
     kubectl config use-context docker-desktop
     ```
2. `openssl`, `kubectl`, `git`, `bash`, and either `tofu` or `terraform`
   on your `PATH`.
3. Roughly 4 GB of free RAM allocated to Docker Desktop.

---

## Step 1 - Build the IBM MQ image locally

The deployment uses a custom image derived from IBM's publicly
distributed `ibm-mqadvanced-server` image with the
[`mq_prometheus`](https://github.com/ibm-messaging/mq-metric-samples)
binary baked in so the queue manager can expose metrics.

There is one wrinkle worth understanding up front: **IBM does not
publish an arm64 build of the MQ image**, and Docker's amd64 emulation
[has a bug](https://github.com/ibm-messaging/mq-container/issues/562#issuecomment-2134635123)
that prevents the amd64 image from running on Apple Silicon. `build.sh`
handles both cases automatically:

| Host arch | Base image | How it gets built |
|---|---|---|
| `amd64` (Intel / AMD)   | `icr.io/ibm-messaging/mq:9.4.5.0-r2` | Pulled from IBM's registry |
| `arm64` (Apple Silicon) | `ibm-mqadvanced-server-dev:9.4.5.0-arm64` | Built locally via the [`mq-container` repo](https://github.com/ibm-messaging/mq-container/blob/master/docs/building.md#building-a-developer-image) checked out at `v9.4.5.0`, which downloads MQ Advanced for Developers and packages it into an arm64 image |

Kick off the whole build:

```bash
cd docker
./build.sh
```

> **Make shortcut:** `make image` — same effect, plus a stamp file so
> subsequent `make` runs skip the rebuild when nothing has changed.

`build.sh` does three things:

1. **Selects (or builds) the base image.** On arm64 it clones
   `ibm-messaging/mq-container` and runs `make build-devserver`. That
   downloads the MQ Advanced for Developers Linux/ARM64 archive
   (~500 MB) into `mq-container/downloads/` and builds an arm64 image
   tagged `ibm-mqadvanced-server-dev:<version>-arm64`. Expect this step
   to take 15+ minutes the first time; subsequent runs are cached.
2. **Compiles the `mq_prometheus` exporter** by invoking
   `build-mq-prometheus.sh` with the target architecture. That script
   builds the upstream `mq-metric-samples` Dockerfile with
   `docker buildx --platform linux/<arch>`. For arm64 it also seeds the
   MQ tar.gz downloaded in step 1 into `mq-metric-samples/MQINST/`
   because there is no arm64 redistributable MQ client.
3. **Builds `moov-mq:local`** from `docker/Dockerfile`, passing
   `BASE_IMAGE` as a build-arg so the FROM line resolves to whichever
   base image step 1 selected.

The Dockerfile is intentionally tiny - it just copies the exporter
binary and launcher script on top of the base. The `BASE_IMAGE` ARG
default is only a fallback for anyone running `docker build` by hand;
`build.sh` always overrides it via `--build-arg`:

```dockerfile
ARG BASE_IMAGE=icr.io/ibm-messaging/mq:9.4.5.0-r2
FROM ${BASE_IMAGE}

COPY mq_prometheus      /usr/local/bin/mq_prometheus
COPY mq_prometheus.sh   /usr/local/bin/mq_prometheus.sh
```

Verify the image exists locally:

```bash
docker images moov-mq:local
```

Docker Desktop shares its image cache with the embedded Kubernetes
runtime, so no `docker push` is needed - the StatefulSet we deploy next
will resolve `moov-mq:local` directly.

### Rebuilding from scratch

`build.sh` caches everything it can - the `mq-container` clone, the
downloaded MQ archive, the `mq-metric-samples` clone, the intermediate
Docker images. If you need to force a clean rebuild (e.g. after bumping
`MQ_VERSION`), run:

```bash
cd docker
./clean.sh
./build.sh
```

> **Make shortcut:** `make clean-image && make image`.

`clean.sh` is safe to re-run and removes the compiled `mq_prometheus`
binary, the `mq-metric-samples/` and `mq-container/` clones, the
`mqprom:*` builder images, `moov-mq:local`, and any locally-built
`ibm-mqadvanced-server-dev:*-arm64` base images.

---

## Step 2 - Generate TLS material

IBM MQ authenticates clients by matching the subject of the certificate
they present during the TLS handshake against `CHLAUTH` rules of type
`SSLPEERMAP`. We will issue:

- a self-signed CA (used to sign everything else),
- a queue manager cert (`CN=qmgr`),
- a client cert (`CN=mq-client`) - this CN is what the queue manager
  will map to the local user `app`.

The script follows the same shape as the
[mq-helm `createcerts` sample](https://github.com/ibm-messaging/mq-helm/tree/main/samples/genericresources/createcerts),
just expressed as a plain shell + openssl pipeline so you do not need to
install Helm.

> **Make shortcut:** `make certs`. Use `make clean-certs` to wipe and
> regenerate.

```bash
cd ../certs
./create-certs.sh
ls out/
# ca.crt   ca.key
# qmgr.crt qmgr.key
# mq-client.crt mq-client.key mq-client.p12
```

The script also packages `mq-client.{crt,key,ca.crt}` into a
PKCS#12 keystore (`mq-client.p12`) using `mq-client` as the friendly
name. That friendly name becomes the **certificate label** the MQ
client will look up at runtime via `MQCERTLABL`.

---

## Step 3 - Deploy IBM MQ to Kubernetes with OpenTofu

The `opentofu/` directory contains a self-contained module that uses
**only** the standard `hashicorp/kubernetes` provider - no Helm, no
custom modules. The resources created are:

| Resource | Purpose |
|---|---|
| `kubernetes_namespace.mq` | Isolates everything in the `mq` namespace |
| `kubernetes_config_map.mq_mqsc` | Mounts `mq.mqsc` at `/etc/mqm/mq.mqsc` so the container runtime executes it at queue manager creation |
| `kubernetes_config_map.mq_ini` | Mounts `mq.ini` to enable the OS authorisation service |
| `kubernetes_config_map.mq_prometheus` | Lists which queues / channels the exporter scrapes |
| `kubernetes_secret.qmgr_tls` | The queue manager's own TLS key + cert (mounted at `/etc/mqm/pki/keys/default`) |
| `kubernetes_secret.client_ca` | The CA that signed the application client cert (mounted into the qmgr trust store at `/etc/mqm/pki/trust/0`) |
| `kubernetes_service.qmgr` | ClusterIP service exposing 1414 (qmgr) and 9443 (web console) |
| `kubernetes_service.mq_prometheus` | ClusterIP service exposing 9158 (Prometheus exporter) |
| `kubernetes_deployment.prometheus` / `kubernetes_service.prometheus` | Prometheus instance scraping the `mq-prometheus` service |
| `kubernetes_deployment.grafana` / `kubernetes_service.grafana` | Grafana, with the bundled dashboards pre-provisioned |
| `kubernetes_stateful_set.qmgr` | Runs the `moov-mq:local` image with persistent storage |

The IBM MQ container runtime is responsible for finding `/etc/mqm/*.mqsc`
and running it through `runmqsc` automatically the first time the queue
manager is created.

### 3a. Apply the deployment

```bash
cd ../opentofu
tofu init
tofu apply
```

> **Make shortcut:** `make deploy` — runs `tofu init` + `tofu apply -auto-approve`
> and blocks until the StatefulSet, Prometheus, and Grafana deployments
> report Ready. Use `make init` on its own to re-download providers.

The default variables in `terraform.tfvars` target the `docker-desktop`
context and read the certificates from `../certs/out`. Override any of
them by editing the file or passing `-var key=value` to `tofu apply`.

Wait for the queue manager pod to become ready:

```bash
kubectl -n mq rollout status statefulset/ibm-mq --timeout=5m
kubectl -n mq get pods
```

You should see `ibm-mq-0` `Running` and `1/1` ready. Tail the logs to
confirm MQSC ran cleanly:

```bash
kubectl -n mq logs ibm-mq-0 | grep -i mqsc
```

> **Make shortcut:** `make status` prints all objects in the `mq`
> namespace; `make logs` follows the qmgr pod log. If you have edited
> `mq.mqsc` after the qmgr was created, `make reload-mqsc` re-runs the
> mounted file against the existing qmgr and bounces the exporter so
> it re-reads its patterns.

---

## Step 4 - Channels, queues, and the message flow

`opentofu/config/mq.mqsc` is where the messaging topology is defined.
The file is run once when the queue manager is created and sets up:

| Object | Type | Purpose |
|---|---|---|
| `APP.SVRCONN` | SVRCONN channel | Entry point for client applications; `SSLCAUTH(REQUIRED)` forces mutual TLS |
| `CHLAUTH('APP.SVRCONN' SSLPEERMAP)` | Channel auth rule | Maps any client with `CN=mq-client` to the local user `app` |
| `APP.IN` | Queue alias | What the application writes to |
| `APP.OUT` | Local queue | What the application reads from; `APP.IN`'s alias target. `MAXMSGL(4096)` caps how big a message it will accept - see Step 8 |
| `AUTHREC` records | Authorisations | `app` gets `PUT` on `APP.IN`, `GET` on `APP.OUT`, plus `CONNECT` on the qmgr |
| `MQPROMETHEUS` | Service | Starts `mq_prometheus.sh` so the exporter listens on `:9158` |

A message therefore travels:

```
amqsputc  ─►  APP.IN  (QALIAS)  ─►  APP.OUT  (QLOCAL)  ─►  amqsgetc
```

This demonstrates the standard MQ pattern of decoupling the logical send
target from the physical local queue - the application never references
`APP.OUT` directly.

> **Note on the Channel Status dashboard.** The dashboards that ship in
> `source-materials/` were designed for a distributed IBM MQ deployment
> and originally filtered every traffic panel to `type!="SVRCONN"` so
> only real SDR/RCVR/CLUSSDR traffic between queue managers would show
> up. A single-qmgr tutorial has no such channels, so we removed the
> `type!="SVRCONN"` clause from those panels in
> `opentofu/dashboards/channel-status.json`. That lets the traffic your
> `mq-client` pod drives over `APP.SVRCONN` populate the same charts.

---

## Step 5 - Create the cert-based user account

The user `app` was *implicitly* declared in `mq.mqsc` by:

```mqsc
SET CHLAUTH('APP.SVRCONN') TYPE(SSLPEERMAP) +
  SSLPEER('CN=mq-client') USERSRC(MAP) MCAUSER('app') ACTION(REPLACE)

SET AUTHREC PRINCIPAL('app') OBJTYPE(QMGR) AUTHADD(CONNECT,INQ)
SET AUTHREC PROFILE('APP.IN')  PRINCIPAL('app') OBJTYPE(QUEUE) AUTHADD(PUT,INQ,BROWSE)
SET AUTHREC PROFILE('APP.OUT') PRINCIPAL('app') OBJTYPE(QUEUE) AUTHADD(GET,INQ,BROWSE)
```

There is **no OS user** named `app` on the container. The MQ
authorisation service is configured with `SecurityPolicy=UserExternal`
(see `opentofu/config/mq.ini`) which lets `MCAUSER` map to a name that
does not exist as a Linux user - exactly what cert-authenticated
applications need.

To make the client certificate available to a workload running in the
cluster we package the PKCS#12 keystore (and the CCDT the MQ client
uses to find the queue manager) into a Kubernetes Secret:

```bash
cd ..
kubectl -n mq create secret generic mq-client \
  --from-file=mq-client.p12=certs/out/mq-client.p12 \
  --from-file=ca.crt=certs/out/ca.crt \
  --from-file=ccdt.json=client/ccdt.json
```

> **Make shortcut:** `make secret` — uses `kubectl create ... --dry-run=client -o yaml | kubectl apply -f -`
> so it can be re-run safely to refresh the Secret after regenerating certs.

The CCDT (`client/ccdt.json`) tells the MQ client:

- the channel name (`APP.SVRCONN`),
- the queue manager DNS name (the in-cluster service from Step 3),
- the cipher spec to negotiate (`ANY_TLS12_OR_HIGHER`),
- which certificate label to present (`mq-client`).

---

## Step 6 - View metrics in Grafana

The `MQPROMETHEUS` service inside the queue manager exposes Prometheus
metrics on TCP **9158**. From Step 3 we already have a Kubernetes
service that fronts that port:

```
kubernetes_service.mq_prometheus
  name: mq-prometheus
  port: 9158
  → IBM MQ pod :9158
```

`opentofu/observability.tf` adds the rest of the stack:

| Resource | Purpose |
|---|---|
| `kubernetes_config_map.prometheus_config` | `prometheus.yml` with a scrape job that targets the `mq-prometheus` service and stamps each metric with `k8s_instance="ibm-mq-<qmgr>"` |
| `kubernetes_deployment.prometheus` / `kubernetes_service.prometheus` | A single Prometheus instance, reachable inside the cluster at `prometheus.mq.svc.cluster.local:9090` |
| `kubernetes_config_map.grafana_datasource` | Provisions a `Prometheus` datasource whose UID matches the value already baked into the dashboards (`I9N3CCHIz`), so no post-import editing is required |
| `kubernetes_config_map.grafana_dashboard_provider` | Tells Grafana to load every dashboard JSON it finds under `/var/lib/grafana/dashboards` |
| `kubernetes_config_map.grafana_dashboards` | Holds the three dashboards deployed from `opentofu/dashboards/`: **Queue Status**, **Channel Status**, **Queue Manager Status** |
| `kubernetes_deployment.grafana` / `kubernetes_service.grafana` | A single Grafana instance, reachable inside the cluster at `grafana.mq.svc.cluster.local:3000` |

Because we ran `tofu apply` earlier these were already created. Confirm
everything is healthy:

```bash
kubectl -n mq get pods -l 'app.kubernetes.io/name in (prometheus, grafana)'
kubectl -n mq rollout status deployment/prometheus --timeout=2m
kubectl -n mq rollout status deployment/grafana    --timeout=2m
```

### Verify the scrape target

```bash
kubectl -n mq port-forward svc/prometheus 9090:9090 &
open http://localhost:9090/targets   # macOS - or paste the URL in a browser
```

> **Make shortcut:** `make prometheus` — foreground port-forward, ^C to
> exit. The Makefile version does not background, so run it in its own
> terminal.

The `ibm-mq` job should show `up=1` and a single endpoint pointing at
`mq-prometheus.mq.svc.cluster.local:9158`.

### Open Grafana

```bash
kubectl -n mq port-forward svc/grafana 3000:3000 &
open http://localhost:3000           # log in with admin / admin
```

> **Make shortcut:** `make grafana` — same story, foreground.

Under **Dashboards → IBM MQ** you will see the three pre-provisioned
dashboards. Each one exposes an `instance` selector at the top - it is
populated from `label_values(ibmmq_qmgr_status, k8s_instance)` and will
automatically pick up the value that our Prometheus scrape job assigns
(`ibm-mq-qm1` by default). Selecting it makes every panel resolve, since
the dashboard panel queries filter on `k8s_instance="[[instance]]"`.

If you want to populate the dashboards with non-zero data, run the
client steps below and refresh.

---

## Step 7 - Send and receive a message

`client/client-pod.yaml` defines a one-shot pod that uses the same
`moov-mq:local` image (so it already has `amqsput`, `amqsbcg`, and
`runmqakm` installed). An init container converts the PKCS#12 keystore
we just stored in the Secret into the CMS `.kdb` format that the C
sample programs expect.

```bash
kubectl apply -f client/client-pod.yaml
kubectl -n mq wait --for=condition=Ready pod/mq-client --timeout=120s
```

> **Make shortcut:** `make client`.

### Put a message on `APP.IN`

```bash
kubectl -n mq exec -i mq-client -- bash -c \
  'echo "hello from amqsput at $(date)" | amqsputc APP.IN qm1'
```

> **Make shortcut:** `make put`.

`amqsputc` is the *client* variant of `amqsput` - it honours
`MQCCDTURL`, `MQSSLKEYR`, and `MQCERTLABL` from the pod's environment,
which together cause it to:

1. read `ccdt.json` to find `ibm-mq.mq.svc.cluster.local:1414`,
2. open the converted CMS keystore at `/work/mq-client.{kdb,sth}`,
3. complete a mutual TLS handshake using the `mq-client` label,
4. connect to channel `APP.SVRCONN` as user `app`,
5. `MQPUT` the message on `APP.IN` (which the qmgr quietly forwards to
   `APP.OUT` via the queue alias).

### Browse messages on `APP.OUT`

```bash
kubectl -n mq exec -it mq-client -- amqsbcgc APP.OUT qm1
```

> **Make shortcut:** `make browse`.

`amqsbcg` (or its client variant `amqsbcgc`) prints a verbose dump of
every message on the queue. Look for the `MQMD` header followed by your
"hello from amqsput" payload.

To consume (and remove) the message instead of just browsing:

```bash
kubectl -n mq exec -it mq-client -- amqsgetc APP.OUT qm1
```

> **Make shortcut:** `make get`.

### Drive traffic to populate the dashboards

A single PUT / GET produces almost no dashboard signal. Worse: because
`amqsputc` connects, PUTs, and disconnects in under 100 ms and
Prometheus scrapes every 15 s, per-instance traffic counters
(`ibmmq_channel_bytes_sent`, `_messages`, `cur_inst`) never overlap
with a scrape and stay empty. To watch the panels animate, hold a
single SVRCONN connection open and feed it one message per second:

```bash
make loop
```

which is equivalent to:

```bash
kubectl -n mq exec -it mq-client -- bash -lc '\
  { while sleep 1; do echo "loop msg $(date +%T)"; done; } \
    | amqsputc APP.IN qm1'
```

The `while sleep` block keeps stdin open indefinitely, so a single
long-lived `amqsputc` process reads one line per second and does one
MQPUT per line - all over the same MQ connection. Hit ^C when done.

Within one scrape interval (~15 s) the following series populate:

- `ibmmq_channel_bytes_sent{channel="APP.SVRCONN"}` climbs,
- `ibmmq_channel_messages{channel="APP.SVRCONN"}` climbs,
- `ibmmq_channel_status{channel="APP.SVRCONN"} = 3` (RUNNING),
- `ibmmq_channel_cur_inst{channel="APP.SVRCONN"} = 1` (one active client),
- `ibmmq_queue_time_since_put{queue="APP.OUT"}` starts ticking,
- `ibmmq_queue_time_since_get{queue="APP.OUT"}` populates once you run
  `amqsgetc APP.OUT qm1` to drain the queue.

Refresh the **Channel Status** dashboard while the loop is running, then
run a destructive `make get` and refresh **Queue Status** to see the
get-side counters move.

---

## Step 8 - Put a real ISO 20022 payment message

Everything so far has pushed arbitrary text through the queue. Since the
whole point of this stack is standing in for a payments network hop
(think RTP or FedNow), it is worth sending something that actually
looks like a payment: an ISO 20022 `pacs.008.001.08`
(`FIToFICustomerCreditTransfer`) message - the message type a bank
sends to move a credit transfer to the next institution in the chain.

`iso20022/pacs.008-valid.xml` is a hand-built but structurally correct
sample of that message: a group header, one credit transfer
transaction, debtor/creditor parties, and the agents (banks) routing
it. `iso20022/pacs.008-oversized.xml` is the same message with a large
remittance-detail block appended - it is still perfectly valid XML and
a well-formed payment message, but it is too big for MQ to accept onto
`APP.OUT`.

### Put the valid message

`amqsputc` treats **each line of stdin as a separate message**, so a
pretty-printed multi-line XML file would arrive as dozens of tiny,
useless messages instead of one payment. Collapse it to a single line
first:

```bash
tr -d '\n' < iso20022/pacs.008-valid.xml \
  | kubectl -n mq exec -i mq-client -- amqsputc APP.IN qm1
```

> **Make shortcut:** `make put-pacs008`.

Browse it back off `APP.OUT`:

```bash
kubectl -n mq exec -it mq-client -- amqsbcgc APP.OUT qm1
```

> **Make shortcut:** `make browse`.

You are now looking at a real `pacs.008` payload flow through the same
`APP.IN` (QALIAS) → `APP.OUT` (QLOCAL) hop used in Step 7 - the queue
alias is doing the same job a payment gateway does when it hands a
message off to the next hop without the sender needing to know the
physical destination.

### Put the oversized message

`opentofu/config/mq.mqsc` sets `MAXMSGL(4096)` on `APP.OUT` - a stand-in
for the message-size ceilings real payment networks enforce (RTP and
FedNow both cap ISO 20022 message size). If you deployed before this
limit was added, pick it up on the running queue manager:

```bash
make reload-mqsc
```

Now put a message that is well past that ceiling:

```bash
tr -d '\n' < iso20022/pacs.008-oversized.xml \
  | kubectl -n mq exec -i mq-client -- amqsputc APP.IN qm1
```

> **Make shortcut:** `make put-pacs008-oversized`.

This time the `MQPUT` itself fails - MQ never accepts the message onto
`APP.OUT` in the first place. Because `kubectl exec -i` streams the
pod's stdout straight back to your terminal, `amqsputc` reports the
failure right there in the same command you just ran:

```
Sample AMQSPUT0 start
target queue is APP.IN
MQPUT ended with reason code 2030
Sample AMQSPUT0 end
```

**Read that output carefully - it is easy to skim past.** The program
still prints its normal "start" / "end" banner and, more importantly,
`kubectl` still reports a **0 (success) exit code** for the whole
command, because the C sample never turns the failed `MQPUT` into a
nonzero process exit status. The only signal that anything went wrong
is that one line in the middle: `MQPUT ended with reason code 2030`.
This is itself a lesson - a supervising script that only checks `$?`
would see this run as a clean success.

Reason code `2030` is `MQRC_MSG_TOO_BIG_FOR_Q`: the message exceeds the
target queue's `MAXMSGL`. (A message that instead exceeds the queue
*manager's* `MAXMSGL` - the ceiling every queue inherits by default -
fails with `2031`, `MQRC_MSG_TOO_BIG_FOR_Q_MGR`.) Because `APP.IN` is
only an alias, this check happens against `APP.OUT`'s attributes, not
the alias's - reinforcing that an alias has no storage or limits of
its own, it just resolves to the real queue.

To prove nothing actually landed, browse `APP.OUT` right after:

```bash
kubectl -n mq exec -it mq-client -- amqsbcgc APP.OUT qm1
```

> **Make shortcut:** `make browse`.

You should see `No more messages` (or only the messages from earlier
steps, if any) - the oversized payload never made it onto the queue at
all.

Unlike a CHLAUTH or certificate rejection, this failure will **not**
show up in the queue manager's own logs (`kubectl -n mq logs ibm-mq-0`
or `AMQERR01.LOG` inside the pod) - `MQRC_MSG_TOO_BIG_FOR_Q` is an
expected MQI return code handed straight back to the calling
application on the `MQPUT` call, not a queue-manager-level error
event, so there is nothing for the qmgr to log. The `amqsputc` output
and the empty `APP.OUT` browse above are the only two places this
failure is visible.

**What just happened:** this is a queue manager-level rejection, not
an application-level one - no consumer code ever ran and nothing
landed on a dead-letter queue; the sender found out immediately via the
`MQPUT` return code. That is a meaningfully different failure mode
from a payload MQ happily delivers but a downstream parser rejects:
here, the payment never left the building. Real payment gateways rely
on `MAXMSGL` (or an equivalent size gate in front of MQ) for exactly
this reason - reject oversized messages at the front door, where the
sender can retry or split the payload, instead of letting them
overrun the queue manager's own limits or complicate what a receiver
has to handle.

---

## Cleanup

```bash
kubectl delete -f client/client-pod.yaml --ignore-not-found
kubectl -n mq delete secret mq-client --ignore-not-found
cd opentofu && tofu destroy
```

> **Make shortcuts:**
> - `make clean-k8s` — the three commands above, in order.
> - `make clean-certs` — remove the generated TLS material under
>   `certs/out/`.
> - `make clean-image` — drop the built Docker images and cloned source
>   trees.
> - `make clean` — all three in one shot, returning the checkout to a
>   near-fresh state ready for another `make all`.

The `kubernetes_namespace.mq` resource removes the namespace last,
which clears any leftover PersistentVolumeClaims along with it.

---

## Troubleshooting

- **`AMQ9637E: Channel is lacking a certificate.`**  The Secret is
  missing or `MQCERTLABL` doesn't match the label baked into the
  keystore. Re-run `create-certs.sh` and recreate the Secret.
- **`AMQ9633E: Bad SSL certificate.`**  The qmgr's trust store does not
  contain the CA that signed the client cert. Re-apply the OpenTofu
  config so `kubernetes_secret.client_ca` is repopulated, then restart
  the pod (`kubectl -n mq delete pod ibm-mq-0`).
- **`MQRC_NOT_AUTHORIZED (2035)`**  The TLS handshake worked but the
  user `app` has no authority. Confirm the `SET AUTHREC` lines ran by
  checking `kubectl -n mq logs ibm-mq-0 | grep AUTHREC`.
- **`mq_prometheus` not listening**  The exporter is started by an MQSC
  `SERVICE` definition; check `kubectl -n mq exec ibm-mq-0 -- runmqsc
  qm1 <<< 'DISPLAY SVSTATUS(MQPROMETHEUS)'`.
- **`exec format error` / `no matching manifest for linux/arm64/v8`
  when starting the pod on Apple Silicon**  You built the image against
  the amd64 base by hand instead of using `docker/build.sh`. Delete the
  image (`docker rmi moov-mq:local`) and re-run `./build.sh`, which
  detects `arm64` and produces a native image.
- **Channel Status dashboard traffic panels still empty**  Confirm the
  client is actually driving traffic:
  `kubectl -n mq exec deploy/prometheus -- wget -qO- 'localhost:9090/api/v1/query?query=ibmmq_channel_bytes_sent{channel="APP.SVRCONN"}'`.
  If the response is empty, run `make loop` and re-check after a scrape
  interval. If it stays empty, the exporter may be watching a narrower
  set of channels than expected — confirm `monitored-channels` on the
  pod contains `APP.*`:
  `kubectl -n mq exec ibm-mq-0 -- cat /etc/mq-prometheus/monitored-channels`.
- **Grafana dashboards show "No data"**  Confirm Prometheus is scraping
  the exporter:
  `kubectl -n mq exec deploy/prometheus -- wget -qO- localhost:9090/api/v1/query?query=ibmmq_qmgr_status`.
  If the response is empty, check the Prometheus targets page
  (`kubectl -n mq port-forward svc/prometheus 9090:9090`) and verify
  the `mq-prometheus` service has endpoints
  (`kubectl -n mq get endpoints mq-prometheus`).
