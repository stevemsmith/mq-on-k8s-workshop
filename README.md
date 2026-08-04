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
     (a cloud cluster, `minikube`, etc.), switch to the docker-desktop context:

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
| `kubernetes_secret.mq_admin_password` | Password for the MQ Web Console's `admin` user (mounted at `/run/secrets/mqAdminPassword`) |
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
| `APP.OUT` | Local queue | What the application reads from; `APP.IN`'s alias target |
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

### Open the MQ Web Console

Grafana shows you metrics, but sometimes you just want to click on a
queue and look at what's on it. IBM MQ ships a browser-based admin UI
for exactly that - it's a much friendlier way to poke around than
MQ Explorer or `runmqsc`, and needs nothing installed locally.

The queue manager container starts the console by default; the only
thing missing out of the box is a login. `opentofu/main.tf` creates a
`mq-admin-password` Secret from the `mq_admin_password` variable
(default `workshopadmin1` - a workshop-only value, not meant to be
reused anywhere real) and mounts it at
`/run/secrets/mqAdminPassword`, which is where `mq-container` reads
the `admin` user's password from (the older `MQ_ADMIN_PASSWORD` env
var was deprecated in MQ 9.4).

```bash
kubectl -n mq port-forward svc/ibm-mq 9443:9443 &
open https://localhost:9443/ibmmq/console
```

> **Make shortcut:** `make console` — foreground port-forward, ^C to
> exit.

Accept the self-signed certificate warning (the console generates its
own cert, unrelated to the client TLS material from Step 2), then log
in as:

- **User:** `admin`
- **Password:** `workshopadmin1` (or whatever you set
  `mq_admin_password` to in `terraform.tfvars`)

From **Manage → Queue managers → qm1 → Queues** you can see live
queue depth, browse message payloads without the CLI, and PUT a test
message from the browser - handy for a workshop audience that's more
comfortable clicking around than typing `runmqsc` commands.

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

## Step 8 - Dead-letter queue: decode the error header

When IBM MQ cannot deliver a message to its destination it does not throw
it away - it places it on the **dead-letter queue (DLQ)** wrapped in an
**MQ dead-letter header (MQDLH)**. The header records *why* delivery
failed as a numeric reason code. Tools like `amqsbcg` decode that code
for you; the raw bytes on the wire do not, so this step is a chance to
read the header by hand.

One subtlety worth understanding first: a *local* `MQPUT` that fails
(queue full, put-inhibited, …) just returns the reason code straight to
the application - the message is **not** dead-lettered. Dead-lettering is
done by the queue manager when it delivers on *your* behalf. The easiest
way to trigger that on a single queue manager is publish/subscribe, so
`mq.mqsc` defines:

| Object | Type | Purpose |
|---|---|---|
| `DEAD.LETTER.QUEUE` | Local queue | The queue manager's DLQ (wired up with `ALTER QMGR DEADQ`) |
| `DLQ.TARGET` | Local queue | A subscriber's destination, deliberately `PUT(DISABLED)` |
| `DLQ.TOPIC` | Topic | Topic string `dlq/demo`, with `USEDLQ(YES)` so undeliverable publications are dead-lettered |
| `DLQ.SUB` | Subscription | Durable admin subscription whose destination is `DLQ.TARGET` |
| `DLQ.TEST` | Queue alias | An alias over `DLQ.TOPIC` (`TARGTYPE(TOPIC)`) - putting to it *publishes* |

so a single put travels:

```
amqsput DLQ.TEST  ─►  DLQ.TOPIC (dlq/demo)  ─►  deliver to DLQ.SUB's dest
                                                 DLQ.TARGET  [PUT(DISABLED)]
                                              ─►  DEAD.LETTER.QUEUE
                                                  (MQDLH, reason 2051)
```

> A sender/receiver channel "loopback" would *not* work here: a channel
> name is unique per queue manager, so an inbound sender connection can
> never find a receiver of the same name on the same qmgr. Publish/
> subscribe dead-letters entirely locally, with no channel involved.

### 8a. Produce a dead-lettered message

The DLQ is an operator resource, so inspect it from the queue manager pod
(server bindings, admin authority) rather than the `app` client. The MQ
sample and control programs live under `/opt/mqm`:

```bash
kubectl -n mq exec ibm-mq-0 -- bash -lc '
  export PATH=$PATH:/opt/mqm/bin:/opt/mqm/samp/bin
  echo "hello dead letter" | amqsput DLQ.TEST qm1
  printf "DISPLAY QLOCAL(DLQ.TARGET) CURDEPTH\nDISPLAY QLOCAL(DEAD.LETTER.QUEUE) CURDEPTH\n" \
    | runmqsc qm1 | grep CURDEPTH'
```

`DLQ.TARGET` stays at `CURDEPTH(0)` (put is disabled) while
`DEAD.LETTER.QUEUE` climbs to `CURDEPTH(1)` - the publication was
dead-lettered.

### 8b. Let MQ decode the header for you

```bash
kubectl -n mq exec ibm-mq-0 -- bash -lc \
  'export PATH=$PATH:/opt/mqm/samp/bin; amqsbcg DEAD.LETTER.QUEUE qm1'
```

`amqsbcg` recognises the `MQDEAD` format and prints a decoded
**Dead Letter Header** block:

```
  StrucId  : 'DLH '  Version : 1
  Reason   : 2051 [MQRC_PUT_INHIBITED]
  DestQName      : 'DLQ.TARGET                                      '
```

### 8c. Decode the hex yourself

The convenience of `amqsbcg` hides what is actually stored. Dump the same
message as raw bytes with `dmpmqmsg`, which treats the MQDLH as ordinary
message data (`-d N` suppresses the MQMD, `-d a` adds an ASCII column):

```bash
kubectl -n mq exec ibm-mq-0 -- bash -lc \
  'export PATH=$PATH:/opt/mqm/bin; dmpmqmsg -m qm1 -i DEAD.LETTER.QUEUE -d aN -f stdout' \
  | grep '^X '
```

The first line is the start of the MQDLH:

```
X 444C48200100000003080000444C512E54415247455420...  <DLH ........DLQ.TARGET   >
```

Walk the `MQDLH` structure (defined in IBM MQ's `cmqc.h`) byte by byte:

| Offset | Bytes | Field | Meaning |
|---|---|---|---|
| 0 | `44 4C 48 20` | `StrucId` | ASCII `"DLH "` |
| 4 | `01 00 00 00` | `Version` | 1 |
| **8** | **`03 08 00 00`** | **`Reason`** | **the error code** |
| 12 | `44 4C 51 2E …` | `DestQName` | ASCII `"DLQ.TARGET"` (padded to 48) |

The `Reason` field is a 4-byte `MQLONG`. Earlier in the header the
`Encoding` field is `0x00000222` (`MQENC_NATIVE` on this amd64 pod), which
means integers are **little-endian** - so read the four bytes in reverse:

```
bytes on the wire : 03 08 00 00
reversed (LE)     : 00 00 08 03   →   0x00000803
hex → decimal     : 0x803 = 8×256 + 3 = 2051
```

Resolve `2051` with the `mqrc` utility (it accepts decimal or hex):

```bash
kubectl -n mq exec ibm-mq-0 -- /opt/mqm/bin/mqrc 0x803
#       2051  0x00000803  MQRC_PUT_INHIBITED
```

**`MQRC_PUT_INHIBITED`** - the queue manager could not deliver the
publication because `DLQ.TARGET` (the ASCII name immediately after the
reason code) is `PUT(DISABLED)`.

### 8d. Try a different reason code

To decode a different hex value, make delivery to `DLQ.TARGET` fail a
different way. Apply the change directly with `runmqsc` (editing
`mq.mqsc` + `make reload-mqsc` re-runs the whole mounted file, so a
one-off `ALTER` is simpler here). For example, force a **queue-full**
failure - enable puts but cap the depth at one, then publish twice:

```bash
kubectl -n mq exec ibm-mq-0 -- bash -lc '
  export PATH=$PATH:/opt/mqm/bin:/opt/mqm/samp/bin
  printf "CLEAR QLOCAL(DEAD.LETTER.QUEUE)\nALTER QLOCAL(DLQ.TARGET) PUT(ENABLED) MAXDEPTH(1)\nCLEAR QLOCAL(DLQ.TARGET)\n" | runmqsc qm1 >/dev/null
  echo "msg one" | amqsput DLQ.TEST qm1 >/dev/null   # fills DLQ.TARGET
  echo "msg two" | amqsput DLQ.TEST qm1 >/dev/null   # overflows -> dead-lettered
  amqsbcg DEAD.LETTER.QUEUE qm1 | grep "Reason "'
#   Reason   : 2053 [MQRC_Q_FULL]
```

Repeat 8c on this message and you will find `05 08 00 00` at offset 8 -
little-endian `0x00000805` = **2053** = `MQRC_Q_FULL`.

Restore the queue to its shipped state when you are done:

```bash
kubectl -n mq exec ibm-mq-0 -- bash -lc '
  printf "CLEAR QLOCAL(DLQ.TARGET)\nCLEAR QLOCAL(DEAD.LETTER.QUEUE)\nALTER QLOCAL(DLQ.TARGET) PUT(DISABLED) MAXDEPTH(5000)\n" | runmqsc qm1'
```

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
