# Mattermost na k3s z ArgoCD i Longhorn

GitOps deployment Mattermost z PostgreSQL na k3s, zarządzany przez ArgoCD z Kustomize.

## Stos technologiczny

- **k3s** — lekka dystrybucja Kubernetes
- **ArgoCD** — GitOps, automatyczny sync klastra z repozytorium
- **Kustomize** — zarządzanie manifestami
- **Longhorn** — distributed block storage (RWO)

## Struktura repo

```
├── argocd-app.yaml          # Rejestracja aplikacji w ArgoCD
├── kustomization.yaml       # Punkt wejścia Kustomize
├── namespace.yaml           # Namespace mattermost
├── postgres/
│   ├── deployment.yaml      # postgres:16-alpine, PGDATA, probes pg_isready
│   ├── pvc.yaml             # 10Gi RWO, storageClass: longhorn
│   ├── secret.env.example   # Szablon zmiennych środowiskowych
│   └── service.yaml         # ClusterIP :5432
└── mattermost/
    ├── deployment.yaml      # mattermost-team-edition:latest, probes /api/v4/system/ping
    ├── pvc.yaml             # 2× PVC: data (5Gi) + logs (2Gi), RWO, longhorn
    └── service.yaml         # LoadBalancer :8065
```

## Wymagania wstępne

- k3s z działającym Longhorn
- ArgoCD zainstalowany w namespace `argocd`
- `kubectl` skonfigurowany z dostępem do klastra

## Deployment

### 1. Stwórz Secrets ręcznie

Sekrety nie są przechowywane w repo (repo jest publiczne). Przed pierwszym deploymentem utwórz je bezpośrednio w klastrze:

```bash
kubectl create namespace mattermost

# Secret dla PostgreSQL
kubectl create secret generic mattermost-db -n mattermost \
  --from-literal=POSTGRES_DB=mattermost \
  --from-literal=POSTGRES_USER=mmuser \
  --from-literal=POSTGRES_PASSWORD='twoje-haslo'

# Secret dla Mattermost
kubectl create secret generic mattermost-app -n mattermost \
  --from-literal=MM_SQLSETTINGS_DATASOURCE="postgres://mmuser:twoje-haslo@postgres:5432/mattermost?sslmode=disable" \
  --from-literal=MM_SERVICESETTINGS_SITEURL="http://<IP-EXTERNAL>:8065"
```

Wymagane klucze znajdziesz w `postgres/secret.env.example` i `mattermost/secret.env.example`.

### 2. Zarejestruj aplikację w ArgoCD

```bash
kubectl apply -f argocd-app.yaml
```

ArgoCD automatycznie pobierze repo i zastosuje wszystkie manifesty. Od tej chwili każdy `git push` wyzwala sync.

### 3. Sprawdź status

```bash
kubectl get application mattermost -n argocd
kubectl get pods -n mattermost
kubectl get svc mattermost -n mattermost   # → EXTERNAL-IP
```

Mattermost będzie dostępny pod `http://EXTERNAL-IP:8065`.

## Zarządzanie secretami

Sekrety **nie trafiają do repo**. Podejście świadome:

| Zaleta | Wada |
|--------|------|
| Zero ryzyka wycieku w publicznym repo | Secret nie przeżywa usunięcia namespace |
| Brak zależności od dodatkowych narzędzi | Wymaga ręcznego odtworzenia po resecie klastra |

Na produkcję zalecane jest [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) — zaszyfrowany YAML bezpieczny do commitowania.

## Runbook — awaria węzła

### Automatyczne odtwarzanie

CronJob `node-recovery` (uruchamiany co minutę) wykrywa węzły w stanie `NotReady` i usuwa ich `VolumeAttachment`. Dzięki temu Longhorn może remontować wolumeny PostgreSQL na działającym węźle bez interwencji ręcznej.

### Ręczna interwencja — stuck pody

Pierwsze co robisz przy awarii węzła:

```bash
# 1. Sprawdź co utknęło
kubectl get pods -n mattermost -o wide

# 2. Force-delete stuck podów (nie czekaj na graceful shutdown martwego węzła)
kubectl delete pod -n mattermost <nazwa-poda> --force --grace-period=0

# 3. Jeśli VolumeAttachment nie zniknął automatycznie
kubectl get volumeattachment | grep <nazwa-węzła>
kubectl delete volumeattachment <nazwa> --force --grace-period=0
```

> `--force --grace-period=0` jest bezpieczne gdy węzeł fizycznie nie odpowiada — Kubernetes normalnie czeka na potwierdzenie od kubelet, które nigdy nie przyjdzie.

### Odtworzenie secretów po utracie namespace

```bash
# mattermost-db
kubectl create secret generic mattermost-db -n mattermost \
  --from-literal=POSTGRES_DB=mattermost \
  --from-literal=POSTGRES_USER=mmuser \
  --from-literal=POSTGRES_PASSWORD='...'

# mattermost-app
kubectl create secret generic mattermost-app -n mattermost \
  --from-literal=MM_SQLSETTINGS_DATASOURCE="postgres://mmuser:...@postgres:5432/mattermost?sslmode=disable" \
  --from-literal=MM_SERVICESETTINGS_SITEURL="http://<IP>:8065"
```

---

## Uwagi operacyjne

**Longhorn RWO** — Mattermost działa na jednej replice z pojedynczym wolumenem danych. Skalowanie poziome wymaga RWX (ReadWriteMany), co z kolei wymaga `nfs-common` na węzłach:
```bash
sudo apt-get install -y nfs-common   # na każdym węźle
```

**ArgoCD `prune: true`** — zasoby usunięte z git są usuwane z klastra. Nie usuwaj PVC z repo przypadkowo — Longhorn skasuje dane.

**Odtworzenie po resecie klastra:**
```bash
# Odtwórz secret (jedyna ręczna czynność)
kubectl create secret generic mattermost-db -n mattermost \
  --from-literal=POSTGRES_DB=mattermost \
  --from-literal=POSTGRES_USER=mmuser \
  --from-literal=POSTGRES_PASSWORD='...'

kubectl create secret generic mattermost-app -n mattermost \
  --from-literal=MM_SQLSETTINGS_DATASOURCE="postgres://mmuser:...@postgres:5432/mattermost?sslmode=disable" \
  --from-literal=MM_SERVICESETTINGS_SITEURL="http://<IP>:8065"

kubectl apply -f argocd-app.yaml
```
