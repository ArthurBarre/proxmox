# Kubernetes Manifest Patterns

These are structural patterns — adapt every value to the actual project. The number of deployments, ports, health paths, env vars, resource limits, init containers, and volumes all depend on what was detected in Step 1.

Don't blindly apply "simple" or "fullstack" — a project might have 3 services, or a monolith that serves both API and frontend from one container. Match the K8s architecture to the actual project architecture.

All images come from the Gitea container registry: `git.arthurbarre.fr/ordinarthur/<app-name>`

## Table of Contents
- [Simple Pattern (static site, single API)](#simple-pattern)
- [Fullstack Pattern (frontend + backend + proxy)](#fullstack-pattern)
- [Common Components](#common-components)

---

## Simple Pattern

Use for: static sites, SPAs, single APIs, monoliths.
Reference: douzoute (aurelie-portfolio).

### namespace.yml
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: {{NAMESPACE}}
```

### deployment.yml
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{APP_NAME}}
  namespace: {{NAMESPACE}}
  labels:
    app: {{APP_NAME}}
spec:
  replicas: {{REPLICAS}}
  selector:
    matchLabels:
      app: {{APP_NAME}}
  template:
    metadata:
      labels:
        app: {{APP_NAME}}
    spec:
      containers:
        - name: {{APP_NAME}}
          image: git.arthurbarre.fr/ordinarthur/{{APP_NAME}}:latest
          ports:
            - containerPort: {{PORT}}
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "200m"
          readinessProbe:
            httpGet:
              path: {{HEALTH_PATH}}
              port: {{PORT}}
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: {{HEALTH_PATH}}
              port: {{PORT}}
            initialDelaySeconds: 10
            periodSeconds: 30
      imagePullSecrets:
        - name: gitea-registry-secret
```

### service.yml
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{APP_NAME}}
  namespace: {{NAMESPACE}}
spec:
  type: NodePort
  selector:
    app: {{APP_NAME}}
  ports:
    - port: {{PORT}}
      targetPort: {{PORT}}
      nodePort: {{NODEPORT}}
      protocol: TCP
```

---

## Fullstack Pattern

Use for: apps with separate frontend and backend (e.g., React + Fastify).
Reference: freedge.

### namespace.yml
Same as simple pattern.

### deployment.yml
```yaml
# Backend
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{APP_NAME}}-backend
  namespace: {{NAMESPACE}}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {{APP_NAME}}-backend
  template:
    metadata:
      labels:
        app: {{APP_NAME}}-backend
    spec:
      imagePullSecrets:
        - name: gitea-registry-secret
      # Include initContainers ONLY if Prisma/migrations detected:
      # initContainers:
      #   - name: prisma-db-push
      #     image: git.arthurbarre.fr/ordinarthur/{{APP_NAME}}-backend:latest
      #     command: ["sh", "-c", "npx prisma db push --skip-generate"]
      #     envFrom:
      #       - configMapRef:
      #           name: {{APP_NAME}}-config
      #       - secretRef:
      #           name: {{APP_NAME}}-secrets
      containers:
        - name: {{APP_NAME}}-backend
          image: git.arthurbarre.fr/ordinarthur/{{APP_NAME}}-backend:latest
          ports:
            - containerPort: {{BACKEND_PORT}}
          envFrom:
            - configMapRef:
                name: {{APP_NAME}}-config
            - secretRef:
                name: {{APP_NAME}}-secrets
          readinessProbe:
            httpGet:
              path: /health
              port: {{BACKEND_PORT}}
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: {{BACKEND_PORT}}
            initialDelaySeconds: 30
            periodSeconds: 30
          # Include volumeMounts ONLY if PVC needed:
          # volumeMounts:
          #   - name: uploads
          #     mountPath: /app/uploads
      # Include volumes ONLY if PVC needed:
      # volumes:
      #   - name: uploads
      #     persistentVolumeClaim:
      #       claimName: {{APP_NAME}}-uploads
---
# Frontend
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{APP_NAME}}-frontend
  namespace: {{NAMESPACE}}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {{APP_NAME}}-frontend
  template:
    metadata:
      labels:
        app: {{APP_NAME}}-frontend
    spec:
      imagePullSecrets:
        - name: gitea-registry-secret
      containers:
        - name: {{APP_NAME}}-frontend
          image: git.arthurbarre.fr/ordinarthur/{{APP_NAME}}-frontend:latest
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
---
# Nginx Proxy (routes /api/* → backend, / → frontend)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{APP_NAME}}-proxy
  namespace: {{NAMESPACE}}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {{APP_NAME}}-proxy
  template:
    metadata:
      labels:
        app: {{APP_NAME}}-proxy
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: proxy-config
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: proxy.conf
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: proxy-config
          configMap:
            name: {{APP_NAME}}-config
```

### service.yml (fullstack)
```yaml
# Backend (ClusterIP — internal only)
apiVersion: v1
kind: Service
metadata:
  name: {{APP_NAME}}-backend
  namespace: {{NAMESPACE}}
spec:
  selector:
    app: {{APP_NAME}}-backend
  ports:
    - name: http
      port: {{BACKEND_PORT}}
      targetPort: {{BACKEND_PORT}}
---
# Frontend (ClusterIP — internal only)
apiVersion: v1
kind: Service
metadata:
  name: {{APP_NAME}}-frontend
  namespace: {{NAMESPACE}}
spec:
  selector:
    app: {{APP_NAME}}-frontend
  ports:
    - name: http
      port: 80
      targetPort: 80
---
# Proxy (NodePort — external access)
apiVersion: v1
kind: Service
metadata:
  name: {{APP_NAME}}-proxy
  namespace: {{NAMESPACE}}
spec:
  type: NodePort
  selector:
    app: {{APP_NAME}}-proxy
  ports:
    - name: http
      port: 80
      targetPort: 80
      nodePort: {{NODEPORT}}
```

### configmap.yml (fullstack)
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{APP_NAME}}-config
  namespace: {{NAMESPACE}}
data:
  NODE_ENV: "production"
  PORT: "{{BACKEND_PORT}}"
  # Add all non-secret env vars here
  # CORS_ORIGINS: "https://{{DOMAIN}}"
  # FRONTEND_URL: "https://{{DOMAIN}}"
  proxy.conf: |
    server {
      listen 80;
      server_name _;

      client_max_body_size 20M;

      location /api/ {
        rewrite ^/api/(.*) /$1 break;
        proxy_pass http://{{APP_NAME}}-backend:{{BACKEND_PORT}};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
      }

      location / {
        proxy_pass http://{{APP_NAME}}-frontend:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
      }
    }
```

---

## Common Components

### pvc.yml (only if storage needed)
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{APP_NAME}}-uploads
  namespace: {{NAMESPACE}}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: {{STORAGE_SIZE}}
```

### Resource Guidelines

| Type | CPU req | CPU limit | Memory req | Memory limit |
|------|---------|-----------|------------|--------------|
| Static site | 50m | 200m | 64Mi | 128Mi |
| Node.js API | 100m | 500m | 128Mi | 512Mi |
| Python API | 100m | 500m | 128Mi | 512Mi |
| Nginx proxy | 25m | 100m | 32Mi | 64Mi |

Adjust based on expected load. These are defaults for light traffic apps.

---

## TLS Routing: Two Approaches

The infrastructure supports two ways to route external traffic with TLS. Choose based on context:

### Option A: Traefik File Provider (default, recommended)

Create an Ansible Jinja2 template in the proxmox repo at `ansible/roles/traefik/templates/<app-name>.yml.j2`. This is deployed when the Traefik playbook runs. See SKILL.md Step 6 for the template.

Use this when: the app uses a NodePort service (most cases on this infra).

### Option B: K8s Ingress with Traefik annotations

Use a K8s Ingress resource directly. This is useful if Traefik's K8s provider is enabled (currently K3s has Traefik disabled — so only use Option A unless K8s Ingress provider is re-enabled).

Reference (douzoute uses this pattern alongside Traefik file provider as backup):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{APP_NAME}}
  namespace: {{NAMESPACE}}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt
spec:
  rules:
    - host: {{DOMAIN}}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{APP_NAME}}
                port:
                  number: {{PORT}}
    - host: www.{{DOMAIN}}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{APP_NAME}}
                port:
                  number: {{PORT}}
  tls:
    - hosts:
        - {{DOMAIN}}
        - www.{{DOMAIN}}
```

**Current recommendation**: Use **Option A** (Traefik file provider) since K3s was installed with `--disable traefik` (the internal Traefik). The external Traefik on the gateway VM handles all routing via file provider.
