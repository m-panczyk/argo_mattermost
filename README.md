# Mattermost na k3s z ArgoCD i Longhorn

GitOps deployment Mattermost z PostgreSQL na k3s, zarządzany przez ArgoCD z Kustomize.

## Stos technologiczny

- **k3s** — lekka dystrybucja Kubernetes (wspiera ARM64)
- **ArgoCD** — GitOps, automatyczny sync klastra z repozytorium
- **Kustomize** — zarządzanie manifestami
- **Longhorn** — distributed block storage (RWO)
- **mattermost/mattermost-team-edition:latest** — oficjalny obraz z wsparciem ARM64 (AMD64 + ARM64)

## Architektura

**Uproszczona** w stosunku do poprzedniej wersji:
- ✅ **1 PVC** zamiast 3 (data, logs, plugins wszystko w jednym)
- ✅ **Brak custom Dockerfile** — używamy oficjalnego obrazu Mattermost
- ✅ **Brak duplicate ConfigMap** — Mattermost obsługuje zmienne środowiskowe
- ✅ **Logs do stdout** — zamiast na dysk (Kubernetes best practice)
- ✅ **ARM64-ready** — działa na macOS (Apple Silicon), M4 i innych ARM64

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
    ├── pvc.yaml             # Pojedynczy 10Gi dla all data/logs/plugins
    └── service.yaml         # LoadBalancer :8065
```

## Wymagania wstępne

- k3s z działającym Longhorn
- ArgoCD zainstalowany w namespace `argocd`
- `kubectl` skonfigurowany z dostępem do klastra
- Dla macOS/Apple Silicon: upewnij się, że węzły k3s wspierają ARM64

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

## Debugowanie

### Logi Mattermost
```bash
kubectl logs -n mattermost -l app=mattermost -f
```

### Sprawdź status PostgreSQL
```bash
kubectl exec -n mattermost -it <postgres-pod> -- psql -U mmuser -d mattermost -c "\dt"
```

### Jeśli pod się nie startuje
```bash
kubectl describe pod -n mattermost <pod-name>
kubectl logs -n mattermost <pod-name> --previous  # poprzedni kontener
```

## Zarządzanie secretami

Sekrety **nie trafiają do repo**. Podejście świadome:

| Zaleta | Wada |
|--------|------|
| Zero ryzyka wycieku w publicznym repo | Secret nie przeżywa usunięcia namespace |
| Brak zależności od dodatkowych narzędzi | Wymaga ręcznego odtworzenia po resecie klastra |

Na produkcję zalecane jest [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) — zaszyfrowany YAML bezpieczny do commitowania.

## Zmienne środowiskowe Mattermost

Wszystkie zmienne ustawiane są jako `MM_*` env vars w deployment.yaml.
Pełna lista dostępnych zmiennych: https://docs.mattermost.com/configure/environment-variables.html

Przykłady często używanych:

```yaml
MM_LOGSETTINGS_ENABLECONSOLE: "true"
MM_LOGSETTINGS_CONSOLELEVEL: "ERROR"  # DEBUG, INFO, WARN, ERROR
MM_FILESETTINGS_DRIVERNAME: "local"
MM_SQLSETTINGS_MAXIDLECONNS: "10"
```

## Troubleshooting

### Mattermost nie łączy się z bazą
1. Sprawdź czy postgres pod jest running: `kubectl get pods -n mattermost`
2. Sprawdź secret: `kubectl get secret -n mattermost mattermost-app -o yaml`
3. Sprawdź logi: `kubectl logs -n mattermost -l app=mattermost`

### PVC stuck pending
```bash
kubectl describe pvc -n mattermost mattermost-data-pvc
# Jeśli storageClass: longhorn nie istnieje:
kubectl get storageclass
```

### Pod evicted (out of memory/disk)
Zwiększ `storage` w `mattermost/pvc.yaml` i zastosuj ponownie.

## Usunięcie

```bash
kubectl delete -f argocd-app.yaml
# Jeśli chcesz usunąć również namespace i dane:
kubectl delete namespace mattermost
```

**UWAGA**: Usunięcie namespace spowoduje usunięcie wszystkich PVC i danych!
