# -------------------------------------------------------------------------------
# 1. Cloudflare Tunnel (전체 프로젝트 유일 — eks-a/onprem/eks-b 공용 multi origin)
# -------------------------------------------------------------------------------
module "cloudflared_tunnel" {
  source = "../../shared/modules/cloudflared"

  cloudflare_account_id = var.cloudflare_account_id
  cloudflare_zone_id    = var.cloudflare_zone_id
  tunnel_name             = "jit-hub-tunnel"
  domain_name              = var.domain_name
  #dns_records              = ["@", "argocd", "grafana"]
  dns_records              = ["@", "argocd", "grafana", "prometheus-ingest", "loki-ingest"]

  ingress_rules = [
    # 서비스 트래픽 (평시 eks-a, 장애시 onprem, DR시 eks-b — 오리진은 replica로 스위칭)
    {
      hostname = var.domain_name
      service  = "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80"
    },
    # 관제용 (onprem 고정)
    {
      hostname = "argocd.${var.domain_name}"
      service  = "http://argocd-server.argocd.svc.cluster.local:80"

      #service  = "https://argocd-server.argocd.svc.cluster.local:443"
      #  originRequest = {
      #    noTLSVerify = true
      #  }
    },
    {
      hostname = "grafana.${var.domain_name}"
      #service  = "http://grafana.monitoring.svc.cluster.local:80"
      service  = "http://onprem-monitoring-stack-grafana.monitoring.svc.cluster.local:80"
      
    },
    {
      hostname = "prometheus-ingest.${var.domain_name}"
      service  = "http://onprem-monitoring-stack-ku-prometheus.monitoring.svc.cluster.local:9090"
    },
    {
      hostname = "loki-ingest.${var.domain_name}"
      service  = "http://onprem-monitoring-stack-loki.monitoring.svc.cluster.local:3100"
    }    
  ]
}

# -------------------------------------------------------------------------------
# 2. Cloudflared Connector 배포 (onprem 자체)
#    ⚠ TEMPORARY — ArgoCD(charts/cloudflared) 완성되면 제거
# -------------------------------------------------------------------------------
module "cloudflared_connector" {
  source = "../../shared/modules/cloudflare-prod"

  namespace    = "cloudflared"
  secret_name  = "cloudflared-token"
  tunnel_token = module.cloudflared_tunnel.tunnel_token
  replicas     = 1   # 평시 0, 장애 시 1로 전환

  depends_on = [module.cloudflared_tunnel]
}

# -------------------------------------------------------------------------------
# K8s 코어 인프라 설치 (Ingress 및 ArgoCD)
# -------------------------------------------------------------------------------

# Ingress Nginx 설치
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.11.0"
  namespace        = "ingress-nginx"
  create_namespace = true
}

# ArgoCD 설치
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.1.2"
  namespace        = "argocd"
  create_namespace = true
  values = [
    file("${path.module}/argocd/my-values.yaml")
  ]
    set {
    name  = "configs.secret.argocdServerAdminPassword"
    # htpasswd (bcrypt) 형태로 변환하여 주입
    value = bcrypt("jithub12") 
  }
  depends_on = [helm_release.ingress_nginx]
}

# ArgoCD 프로젝트 구성
resource "kubectl_manifest" "argocd_project" {
  depends_on = [helm_release.argocd]
  yaml_body  = file("${path.module}/../../../gitops/argocd/projects/jit-hub-project.yaml")
}

# Spoke(온프레미스 로컬) 클러스터 등록
resource "kubectl_manifest" "onprem_cluster" {
  depends_on = [helm_release.argocd]
  yaml_body  = file("${path.module}/../../../gitops/argocd/clusters/onprem-cluster.yaml")
}
