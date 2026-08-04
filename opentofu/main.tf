locals {
  app_name = "ibm-mq"
  labels = {
    "app.kubernetes.io/name"     = local.app_name
    "app.kubernetes.io/instance" = local.app_name
  }
}

resource "kubernetes_namespace" "mq" {
  metadata {
    name = var.namespace
  }
}

##############################################################################
# ConfigMaps
##############################################################################

resource "kubernetes_config_map" "mq_mqsc" {
  metadata {
    name      = "mq-mqsc"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.labels
  }
  data = {
    # Any *.mqsc file dropped into /etc/mqm/ is run once at queue manager
    # creation time by the IBM MQ container runtime.
    "mq.mqsc" = file("${path.module}/config/mq.mqsc")
  }
}

resource "kubernetes_config_map" "mq_ini" {
  metadata {
    name      = "mq-ini"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.labels
  }
  data = {
    "mq.ini" = file("${path.module}/config/mq.ini")
  }
}

resource "kubernetes_config_map" "mq_prometheus" {
  metadata {
    name      = "mq-prometheus"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.labels
  }
  data = {
    "monitored-queues"   = "APP.*"
    "monitored-channels" = "APP.*"
  }
}

##############################################################################
# Secrets - qmgr TLS material + trusted client CA cert
#
# Files are produced by ../certs/create-certs.sh.
##############################################################################

resource "kubernetes_secret" "qmgr_tls" {
  metadata {
    name      = "qmgr-tls"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.labels
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = file("${var.certs_dir}/qmgr.crt")
    "tls.key" = file("${var.certs_dir}/qmgr.key")
  }
}

resource "kubernetes_secret" "client_ca" {
  metadata {
    name      = "client-ca"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.labels
  }
  data = {
    # Loaded into the qmgr's trust store. Any client whose certificate is
    # signed by this CA can present it during the TLS handshake.
    "ca.crt" = file("${var.certs_dir}/ca.crt")
  }
}

resource "kubernetes_secret" "mq_admin_password" {
  metadata {
    name      = "mq-admin-password"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.labels
  }
  data = {
    # mq-container reads this file to set the 'admin' user's password for
    # the MQ Web Console. Filename must match exactly - it's read from
    # /run/secrets/mqAdminPassword, not from an env var (MQ_ADMIN_PASSWORD
    # was deprecated in MQ 9.4).
    "mqAdminPassword" = var.mq_admin_password
  }
}

##############################################################################
# Services
##############################################################################

resource "kubernetes_service" "qmgr" {
  metadata {
    name      = "ibm-mq"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.labels
  }
  spec {
    type     = "ClusterIP"
    selector = local.labels
    port {
      name        = "qmgr"
      port        = 1414
      target_port = 1414
    }
    port {
      name        = "console"
      port        = 9443
      target_port = 9443
    }
  }
}

resource "kubernetes_service" "mq_prometheus" {
  metadata {
    name      = "mq-prometheus"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.labels
  }
  spec {
    type     = "ClusterIP"
    selector = local.labels
    port {
      name        = "mq-prometheus"
      port        = 9158
      target_port = 9158
    }
  }
}

##############################################################################
# StatefulSet
##############################################################################

resource "kubernetes_stateful_set" "qmgr" {
  metadata {
    name      = "ibm-mq"
    namespace = kubernetes_namespace.mq.metadata[0].name
    labels    = local.labels
  }

  spec {
    service_name = kubernetes_service.qmgr.metadata[0].name
    replicas     = 1

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        termination_grace_period_seconds = 30
        security_context {
          fs_group = 0
        }

        container {
          name              = "qmgr"
          image             = var.image
          image_pull_policy = "IfNotPresent"

          env {
            name  = "LICENSE"
            value = "accept"
          }
          env {
            name  = "MQ_QMGR_NAME"
            value = var.qmgr_name
          }
          env {
            name  = "MQ_ENABLE_METRICS"
            value = "true"
          }
          env {
            name  = "MQ_LOGGING_CONSOLE_FORMAT"
            value = "json"
          }

          port {
            name           = "qmgr"
            container_port = 1414
          }
          port {
            name           = "console"
            container_port = 9443
          }
          port {
            name           = "metrics"
            container_port = 9158
          }

          # The IBM MQ container runtime watches /etc/mqm/*.mqsc and runs
          # any files it finds at queue manager creation time.
          volume_mount {
            name       = "mq-mqsc"
            mount_path = "/etc/mqm/mq.mqsc"
            sub_path   = "mq.mqsc"
            read_only  = true
          }
          volume_mount {
            name       = "mq-ini"
            mount_path = "/etc/mqm/mq.ini"
            sub_path   = "mq.ini"
            read_only  = true
          }

          # Queue manager's own TLS identity.
          # https://github.com/ibm-messaging/mq-container/blob/main/docs/usage.md#supplying-tls-certificates
          volume_mount {
            name       = "qmgr-tls"
            mount_path = "/etc/mqm/pki/keys/default"
            read_only  = true
          }

          # CA cert that signed the application client certificate(s).
          volume_mount {
            name       = "client-ca"
            mount_path = "/etc/mqm/pki/trust/0"
            read_only  = true
          }

          # Password for the Web Console's 'admin' user.
          volume_mount {
            name       = "mq-admin-password"
            mount_path = "/run/secrets/mqAdminPassword"
            sub_path   = "mqAdminPassword"
            read_only  = true
          }

          # mq_prometheus.sh reads its queue / channel patterns from here.
          volume_mount {
            name       = "mq-prometheus"
            mount_path = "/etc/mq-prometheus"
            read_only  = true
          }

          volume_mount {
            name       = "qm-data"
            mount_path = "/mnt/mqm"
          }

          liveness_probe {
            exec {
              command = ["chkmqhealthy"]
            }
            initial_delay_seconds = 60
            period_seconds        = 10
          }
          readiness_probe {
            exec {
              command = ["chkmqready"]
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "mq-mqsc"
          config_map {
            name = kubernetes_config_map.mq_mqsc.metadata[0].name
          }
        }
        volume {
          name = "mq-ini"
          config_map {
            name = kubernetes_config_map.mq_ini.metadata[0].name
          }
        }
        volume {
          name = "mq-prometheus"
          config_map {
            name = kubernetes_config_map.mq_prometheus.metadata[0].name
          }
        }
        volume {
          name = "qmgr-tls"
          secret {
            secret_name = kubernetes_secret.qmgr_tls.metadata[0].name
          }
        }
        volume {
          name = "client-ca"
          secret {
            secret_name = kubernetes_secret.client_ca.metadata[0].name
            items {
              key  = "ca.crt"
              path = "tls.crt"
            }
          }
        }
        volume {
          name = "mq-admin-password"
          secret {
            secret_name = kubernetes_secret.mq_admin_password.metadata[0].name
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "qm-data"
      }
      spec {
        access_modes = ["ReadWriteOnce"]
        resources {
          requests = {
            storage = "2Gi"
          }
        }
      }
    }
  }

  timeouts {
    create = "10m"
    update = "10m"
  }
}
