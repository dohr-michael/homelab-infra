#!/usr/bin/env python3
"""
Valide les Custom Resources du repo contre le schéma OpenAPI des CRDs vendorisées.

POURQUOI CE SCRIPT EXISTE
    `kubectl kustomize` ne valide QUE la syntaxe YAML : il ne connaît pas les
    CRDs, donc un CR invalide passe la validation locale et n'échoue qu'au sync
    ArgoCD. C'est arrivé le 2026-08-06 : un bloc `pmm: {enabled: false}` sans
    `image` a fait échouer le déploiement de MongoDB, alors que tous les noms de
    champs existaient bien dans le CRD. Le champ manquant était dans une liste
    `required` — que ma vérification précédente ne regardait pas.

CE QU'IL VÉRIFIE
    - champs inconnus (typos)
    - champs `required` manquants, à tous les niveaux d'imbrication
    - types incohérents (objet là où un scalaire est attendu, etc.)
    - valeurs hors `enum`

    Les sous-arbres marqués `x-kubernetes-preserve-unknown-fields` sont ignorés,
    comme le fait l'apiserver.

Usage :  ./infra/validate-crs.py            (depuis la racine du repo)
"""
import sys
import glob
import os

try:
    import yaml
except ImportError:
    sys.exit("PyYAML requis : pip install pyyaml")

# CRDs vendorisées → où trouver le schéma
CRD_SOURCES = ["applications/mongodb-operator/10-crd.yaml"]
# Où chercher les CR à valider (les *.secret.yaml sont chiffrés, donc exclus)
CR_GLOBS = ["applications/*/[0-9]*.yaml"]


def load_schemas():
    """Retourne {(group, kind): {version: schema}} depuis les CRDs vendorisées."""
    schemas = {}
    for src in CRD_SOURCES:
        if not os.path.exists(src):
            continue
        for doc in yaml.safe_load_all(open(src)):
            if not doc or doc.get("kind") != "CustomResourceDefinition":
                continue
            group = doc["spec"]["group"]
            kind = doc["spec"]["names"]["kind"]
            for v in doc["spec"]["versions"]:
                sch = v.get("schema", {}).get("openAPIV3Schema")
                if sch:
                    schemas.setdefault((group, kind), {})[v["name"]] = sch
    return schemas


def walk(obj, sch, path, problems):
    if sch is None:
        problems.append(f"{path}: champ inconnu du schéma")
        return
    # L'apiserver n'inspecte pas ces sous-arbres.
    if sch.get("x-kubernetes-preserve-unknown-fields"):
        return

    t = sch.get("type")
    enum = sch.get("enum")

    if isinstance(obj, dict):
        if t not in (None, "object"):
            problems.append(f"{path}: objet fourni, le schéma attend {t}")
            return
        # C'EST LE CONTRÔLE QUI MANQUAIT : les champs obligatoires.
        for req in sch.get("required", []):
            if req not in obj:
                problems.append(f"{path}.{req}: MANQUANT (required par le CRD)")
        props = sch.get("properties")
        if props is None:
            if sch.get("additionalProperties"):
                ap = sch["additionalProperties"]
                if isinstance(ap, dict):
                    for k, v in obj.items():
                        walk(v, ap, f"{path}.{k}", problems)
                return
            problems.append(f"{path}: objet non décrit par le schéma")
            return
        for k, v in obj.items():
            if k not in props:
                problems.append(f"{path}.{k}: CHAMP INCONNU")
            else:
                walk(v, props[k], f"{path}.{k}", problems)

    elif isinstance(obj, list):
        if t not in (None, "array"):
            problems.append(f"{path}: liste fournie, le schéma attend {t}")
            return
        items = sch.get("items")
        for i, v in enumerate(obj):
            walk(v, items, f"{path}[{i}]", problems)

    else:
        if t == "object":
            problems.append(f"{path}: scalaire fourni, le schéma attend un objet")
        if enum is not None and obj not in enum:
            problems.append(f"{path}: valeur {obj!r} hors enum {enum}")


def main():
    schemas = load_schemas()
    if not schemas:
        sys.exit("aucune CRD vendorisée trouvée — rien à valider")

    files = sorted({f for g in CR_GLOBS for f in glob.glob(g)})
    checked = 0
    failed = 0

    for f in files:
        try:
            docs = list(yaml.safe_load_all(open(f)))
        except Exception as e:
            print(f"FAIL {f}: YAML illisible: {e}")
            failed += 1
            continue

        for doc in docs:
            if not doc or "apiVersion" not in doc:
                continue
            av = doc["apiVersion"]
            if "/" not in av:
                continue  # ressource core, pas un CR
            group, version = av.split("/", 1)
            key = (group, doc.get("kind"))
            if key not in schemas:
                continue
            sch = schemas[key].get(version)
            if sch is None:
                print(f"FAIL {f}: version {version} absente du CRD pour {key[1]}")
                failed += 1
                continue

            problems = []
            spec_sch = sch.get("properties", {}).get("spec")
            walk(doc.get("spec"), spec_sch, "spec", problems)
            checked += 1
            name = doc.get("metadata", {}).get("name", "?")
            if problems:
                print(f"FAIL {f}  {key[1]}/{name}")
                for p in problems:
                    print(f"       {p}")
                failed += 1
            else:
                print(f"OK   {f}  {key[1]}/{name}")

    print(f"\n{checked} CR validé(s), {failed} en échec")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
