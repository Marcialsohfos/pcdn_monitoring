#!/usr/bin/env python3
"""Génère config/pcdn_layers.csv, config/pcdn_schema.csv et config/pcdn_domains.csv
à partir du dictionnaire Word et des 10 JSON (attribute sets Mapit).

Usage : python3 tools/build_schema.py <dictionnaire.docx> <dossier_json> [dossier_sortie]
"""
import sys, re, json, csv, glob, os, unicodedata, difflib
import docx
from docx.table import Table
from docx.text.paragraph import Paragraph

docx_path, json_dir = sys.argv[1], sys.argv[2]
out_dir = sys.argv[3] if len(sys.argv) > 3 else "config"
os.makedirs(out_dir, exist_ok=True)

def norm(s):
    s = unicodedata.normalize("NFKD", str(s)).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()

TYPE_MAP = {"TEXT": "text", "DOUBLE": "double", "INTEGER (LONG)": "integer",
            "BOOLEAN (natif)": "boolean", "MULTISELECT": "multiselect", "Picture (natif)": "picture"}

# --- 1. Dictionnaire Word -----------------------------------------------------
d = docx.Document(docx_path)
layers, cur = {}, None
for el in d.element.body.iterchildren():
    if el.tag.endswith("}p"):
        m = re.match(r"^\d+\.\s*(\S+)\s*\((\w+)\)", Paragraph(el, d).text.strip())
        if m:
            cur = m.group(1)
            layers[cur] = {"geometry": m.group(2), "vars": []}
    elif el.tag.endswith("}tbl") and cur:
        for r in list(Table(el, d).rows)[1:]:
            c = [x.text.strip() for x in r.cells]
            layers[cur]["vars"].append({"variable": c[0], "label": c[1], "type": TYPE_MAP.get(c[2], "text")})

# --- 2. Correspondances JSON -> variable (couches dont le JSON utilise des codes) ---
MANUAL = {
    "Appui_Production_Valorisation": {"Type_Infrastructure_Socio_Eco": "type_unite", "Etat_Fonctionnement": "etat_fonct",
                                      "Connexion_Corridor": "connexion_corridor"},
    "Infrastructures_Ferroviaires": {"Troncon_Ferroviaire": "troncon", "Type_Infrastructure_Ferroviaire": "type_infra",
                                     "Etat_Fonctionnement": "etat_fonct", "Connexion_Route_Gare": "connexion_route",
                                     "Mode_Apport": "mode_apport"},
    "Ground_Truthing_LandCover": {"Classe_Occupation_Sol": "classe_reelle"},
    "Reseau_Routier_Pistes": {"Categorie_Voie": "categorie_voie", "Type_Revetement": "type_surface",
                              "Type_Blocage": "type_blocage", "Praticabilite_Saison_Pluies": "praticabilite_pluie"},
}
JSON_FILES = {os.path.splitext(os.path.basename(p))[0]: p for p in glob.glob(os.path.join(json_dir, "*.json"))}

domains, json_alias, report = [], {}, []
for layer, info in layers.items():
    jf = JSON_FILES.get(layer)
    if not jf:
        report.append(f"[!] pas de JSON pour {layer}"); continue
    fields = json.load(open(jf, encoding="utf-8"))["fields"]
    byvar = {v["variable"]: v for v in info["vars"]}
    for f in fields:
        var = MANUAL.get(layer, {}).get(f["name"])
        if not var:  # correspondance par libellé normalisé, puis approchée
            cand = {norm(v["label"]): v["variable"] for v in info["vars"]}
            k = norm(f["name"])
            var = cand.get(k)
            if not var:
                best = difflib.get_close_matches(k, list(cand), n=1, cutoff=0.75)
                if best:
                    var = cand[best[0]]; report.append(f"[~] {layer}: '{f['name']}' ≈ '{best[0]}' -> {var}")
        if not var:
            report.append(f"[!] {layer}: champ JSON '{f['name']}' non rattaché"); continue
        json_alias[(layer, var)] = f["name"]
        if f["dataType"] == "MULTISELECT" and byvar[var]["type"] != "multiselect":
            report.append(f"[!] {layer}.{var}: JSON=MULTISELECT / Word={byvar[var]['type']}")
        for i, val in enumerate(f["values"], 1):
            domains.append({"layer": layer, "variable": var, "ordre": i, "value": val})

# --- 3. Paramètres de contrôle (obligatoires, bornes) ---------------------------
IDNAME = {  # id, nom
    "Appui_Production_Valorisation": ("id_infra_prod", "nom_site"),
    "Gouvernance_Services_Securite": ("id_poste", "nom_poste"),
    "Ground_Truthing_LandCover": ("id_point_gt", ""),
    "Infrastructures_Ferroviaires": ("id_infra", "nom_gare"),
    "Points_Vente_Marches": ("id_marche", "nom_marche"),
    "Reseau_Routier_Pistes": ("id_troncon", "nom_voie"),
    "Services_Sociaux_Bases": ("id_service", "nom_etablissement"),
    "Activites_autour_gare": ("id_activite", "nom_designation"),
    "Gares": ("id_fichegare", "nom_gare_detail"),
    "Ouvrage_franchissement": ("id_ouvrage", "nom_repere"),
}
MANDATORY = {
    "Appui_Production_Valorisation": "id_infra_prod nom_site type_unite etat_fonct connexion_corridor",
    "Gouvernance_Services_Securite": "id_poste nom_poste type_service etat_fonct_securite",
    "Ground_Truthing_LandCover": "id_point_gt classe_reelle densite_couvert",
    "Infrastructures_Ferroviaires": "id_infra nom_gare troncon type_infra etat_fonct",
    "Points_Vente_Marches": "id_marche nom_marche zone_implantation type_marche type_marchandise",
    "Reseau_Routier_Pistes": "id_troncon categorie_voie type_surface praticabilite_pluie",
    "Services_Sociaux_Bases": "id_service nom_etablissement domaine_activite type_equipement etat_fonct_service",
    "Activites_autour_gare": "id_activite nom_designation type_activite localisation_gare statut_occupation",
    "Gares": "id_fichegare nom_gare_detail axe_ferroviaire type_gare etat_fonct_garedet",
    "Ouvrage_franchissement": "id_ouvrage nom_repere type_ouvrage etat_ouvrage",
}
RANGES = {"densite_couvert": (0, 100), "largeur_m": (0.5, 40), "vitesse_moy_kmh": (0, 120),
          "duree_coupure_jours": (0, 365), "temps_acces_min": (0, 1440), "capacite_stockage_t": (0, 1000000)}

with open(f"{out_dir}/pcdn_layers.csv", "w", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh); w.writerow(["layer", "geometry", "id_var", "name_var"])
    for l, i in layers.items(): w.writerow([l, i["geometry"], *IDNAME[l]])

with open(f"{out_dir}/pcdn_schema.csv", "w", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh); w.writerow(["layer", "ordre", "variable", "label", "json_name", "type", "obligatoire", "min", "max"])
    for l, i in layers.items():
        mand = set(MANDATORY[l].split())
        for n, v in enumerate(i["vars"], 1):
            lo, hi = RANGES.get(v["variable"], ("", ""))
            w.writerow([l, n, v["variable"], v["label"], json_alias.get((l, v["variable"]), ""), v["type"],
                        "TRUE" if v["variable"] in mand else "FALSE", lo, hi])

with open(f"{out_dir}/pcdn_domains.csv", "w", newline="", encoding="utf-8") as fh:
    w = csv.DictWriter(fh, fieldnames=["layer", "variable", "ordre", "value"]); w.writeheader(); w.writerows(domains)

print(f"{len(layers)} couches, {sum(len(i['vars']) for i in layers.values())} variables, {len(domains)} valeurs de listes")
print("\n".join(report) or "aucune anomalie de correspondance")
for l, i in layers.items():
    seen = {}
    for v in i["vars"]: seen.setdefault(v["variable"][:10], []).append(v["variable"])
    for k, vs in seen.items():
        if len(vs) > 1: print(f"[shp] {l}: noms tronqués à 10 car. en collision -> {vs}")
