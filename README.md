# Mattermost na k3s z ArgoCD i Longhorn

GitOps deployment Mattermost z PostgreSQL na k3s (ARM64), zarządzany przez ArgoCD z Kustomize.

## Stos technologiczny

- **k3s** — lekka dystrybucja Kubernetes ze wsparciem ARM64
- **ArgoCD** — GitOps, automatyczny sync klastra z repozytorium
- **Kustomize** — zarządzanie manifestami
- **Longhorn** — distributed block storage (RWO)
- **rheens/mattermost-app:v11.3.0** — oficjalny obraz ARM64
- **postgres:16-alpine** — baza danych

## Architektura

```
├── argocd-app.yaml                  # Rejestracja aplikacji w ArgoCD
├── kustomization.yaml               # Punkt wejścia Kustomize
├── namespace.yaml                   # Namespace: mattermost
├── postgres/
│   ├── deployment.yaml              # postgres:16-alpine
│   ├── pvc.yaml                     # 10Gi RWO longhorn
│   ├── secret.env.example           # Szablon secretów
│   └── service.yaml                 # ClusterIP :5432
└── mattermost/
    ├── deployment.yaml              # rheens/mattermost-app:v11.3.0
    ├── entrypoint-configmap.yaml    # Custom entrypoint (omija busybox su)
    ├── pvc.yaml                     # 10Gi RWO longhorn (data/logs/plugins via subPath)
    ├── secret.env.example           # Szablon secretów
    └── service.yaml                 # LoadBalancer :8065
```

### Dlaczego custom entrypoint?

Oryginalny `priv-entrypoint.sh` obrazu używa busybox `su`, który czyści środowisko przy zmianie użytkownika. Powoduje to, że zmienne środowiskowe (`MM_SQLSETTINGS_DATASOURCE` i inne) nie docierają do procesu Mattermost — serwer łączy się do bazy jako OS user zamiast skonfigurowanego użytkownika.

`entrypoint-configmap.yaml` wstrzykuje własny skrypt, który:
- uruchamia się bezpośrednio jako root (z `runAsUser: 0`)
- generuje `config.json` z poprawnymi wartościami z env varów
- uruchamia `mattermost server` bez zmiany użytkownika

## Deployment

### 1. Stwórz Secrets

Sekrety nie są przechowywane w repo. Przed pierwszym deploymentem utwórz je w klastrze:

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
  --from-literal=MM_SERVICESETTINGS_SITEURL="http://<EXTERNAL-IP>:8065"
```

### 2. Zarejestruj aplikację w ArgoCD

```bash
kubectl apply -f argocd-app.yaml
```

ArgoCD pobierze repo i zastosuje wszystkie manifesty. Każdy `git push` wyzwala sync.

### 3. Sprawdź status

```bash
kubectl get pods -n mattermost
kubectl get svc mattermost -n mattermost   # → EXTERNAL-IP
```

Mattermost dostępny pod `http://EXTERNAL-IP:8065`.

### 4. Pierwszy admin

Po starcie serwera utwórz konto administratora przez mmctl:

```bash
kubectl exec -n mattermost deployment/mattermost -- \
  /mattermost/bin/mmctl user create \
  --email admin@example.com \
  --username admin \
  --password 'TwojeHaslo!' \
  --system-admin --local
```

## Zarządzanie użytkownikami

Local mode (socket) jest domyślnie włączony, więc mmctl działa bez uwierzytelnienia:

```bash
# Dodaj użytkownika
kubectl exec -n mattermost deployment/mattermost -- \
  /mattermost/bin/mmctl user create \
  --email user@example.com --username user --password 'Haslo123!' --local

# Dodaj do teamu
kubectl exec -n mattermost deployment/mattermost -- \
  /mattermost/bin/mmctl team users add <team-name> <username> --local
```

## Reset bazy danych

```bash
# Scale down mattermost
kubectl scale deployment mattermost -n mattermost --replicas=0

# Usuń i odtwórz bazę
kubectl exec -n mattermost deployment/postgres -- \
  psql -U mmuser -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='mattermost' AND pid <> pg_backend_pid();"
kubectl exec -n mattermost deployment/postgres -- psql -U mmuser -d postgres -c "DROP DATABASE mattermost;"
kubectl exec -n mattermost deployment/postgres -- psql -U mmuser -d postgres -c "CREATE DATABASE mattermost;"

# Scale up
kubectl scale deployment mattermost -n mattermost --replicas=1
```

## Debugowanie

```bash
# Logi Mattermost
kubectl logs -n mattermost -l app=mattermost -f

# Logi PostgreSQL
kubectl logs -n mattermost -l app=postgres -f

# Status podów
kubectl get pods -n mattermost

# Zdarzenia (crashe, probe failures)
kubectl describe pod -n mattermost -l app=mattermost
```

### Typowe problemy

**`role "root" does not exist` w logach postgresa**
Env var `MM_SQLSETTINGS_DATASOURCE` nie dociera do procesu. Sprawdź czy ConfigMap entrypoint jest zsyncowany i pod ma nową wersję.

**Connection refused na :8065**
Sprawdź `ServiceSettings.ListenAddress` w config.json — powinno być `:8065`. Env var `MM_SERVICESETTINGS_LISTENADDRESS=:8065` jest ustawiony w deployment.yaml jako override.

**ImagePullBackOff**
Obraz `mattermost/mattermost-team-edition:latest` nie ma manifesu ARM64. Używaj `rheens/mattermost-app:v11.3.0`.

**PVC Pending**
```bash
kubectl describe pvc -n mattermost mattermost-data-pvc
kubectl get storageclass   # upewnij się że longhorn istnieje
```

## Zarządzanie secretami

Sekrety nie trafiają do repo (repo jest publiczne). Secret nie przeżywa usunięcia namespace — wymaga ręcznego odtworzenia.

Na produkcję zalecane: [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets).

## Usunięcie

```bash
kubectl delete -f argocd-app.yaml
kubectl delete namespace mattermost   # usuwa również PVC i dane!
```
