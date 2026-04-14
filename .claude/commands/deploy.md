---
description: Déploie le projet courant sur l'infra Proxmox/K3s. Utilise la memory locale, sinon invoque la skill create-deployment.
---

# /deploy

## RÈGLE N°1 — ÉCONOMIE DE TOKENS

**AVANT TOUTE AUTRE ACTION**, lis `.claude/deploy-memory.md` à la racine du projet courant :

```bash
cat .claude/deploy-memory.md 2>/dev/null
```

### Cas A — La memory EXISTE

Tu **NE DOIS PAS** re-analyser le projet (pas de lecture de `package.json`, `Dockerfile`, pas de `ls` récursifs, pas d'agent d'analyse).

Fais UNIQUEMENT ce que la memory décrit :
1. Build + push de la nouvelle image (tag = short SHA git)
2. `kubectl set image` + `kubectl rollout status`
3. Si route Traefik modifiée : `ansible-playbook playbooks/gateway.yml`
4. `curl -I https://<domaine>` pour vérifier
5. STOP. Une phrase de résumé, pas plus.

### Cas B — La memory N'EXISTE PAS

Premier déploiement → invoque la skill **`create-deployment`** qui fait le setup complet et écrit la memory pour les prochaines fois.

```
skill: create-deployment
```

---

## Rappel

- Cas A = rollout uniquement. Pas d'analyse.
- Cas B = délègue à la skill `create-deployment`.
- Pas de récap verbeux. Économise les tokens.
