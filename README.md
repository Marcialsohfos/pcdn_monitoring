# PCDN – Application de monitoring (Streamlit + pipeline R)

Application web de suivi de la collecte géospatiale du Projet Corridor-Djamena.
Le **pipeline R** (`pipeline/`) télécharge les `.shp`/`.kml` du FTP, les contrôle et produit les livrables ;
l'**interface Streamlit** les présente (synthèse, carte, anomalies, données, corrections par agent, journal)
et permet de relancer le monitoring. Un **planificateur** le lance chaque jour automatiquement.

```
app.py            interface (6 onglets)         scheduler.py   lancement quotidien (PCDN_RUN_TIME)
pcdn_app/         lanceur R, lecture résultats, mot de passe
pipeline/         pipeline R (R/, config/, run_daily.R)   → données dans PCDN_DATA_DIR (/data)
```

## A. Déploiement avec Docker (recommandé)
Prérequis : un serveur (VPS Linux) avec Docker et Docker Compose.

1. Copier le projet sur le serveur, puis : `cp .env.example .env` et renseigner dans `.env` :
   `APP_PASSWORD`, `PCDN_FTP_HOST`, `PCDN_FTP_USER`, `PCDN_FTP_PWD` (+ `PCDN_FTP_PATH`, `PCDN_RUN_TIME`).
2. `docker compose up -d --build` (première construction : plusieurs minutes).
3. Ouvrir `http://<ip-du-serveur>:8501`, se connecter, cliquer sur **▶ Lancer le monitoring**.
4. Les données persistent dans le volume `pcdn_data` (fichiers FTP, résultats, journaux).

Commandes utiles : `docker compose logs -f scheduler` · `docker compose restart` · `docker compose down`.
**HTTPS** : ne pas exposer le port 8501 en clair sur Internet. Placer un proxy inverse (Caddy, Nginx, Traefik)
avec certificat TLS devant l'application ; l'accès FTP, le mot de passe et les données transitent sinon en clair.

## B. Lancement local sans Docker (poste Windows/Linux)
Prérequis : Python ≥ 3.10, R ≥ 4.3 avec les paquets `sf dplyr tidyr stringr purrr tibble lubridate xml2 curl openxlsx digest`.
```bash
pip install -r requirements.txt
# variables (PowerShell) :  $env:APP_PASSWORD="..."; $env:PCDN_FTP_HOST="..." ; $env:PCDN_FTP_USER="..." ; $env:PCDN_FTP_PWD="..."
# si Rscript n'est pas dans le PATH :  $env:PCDN_RSCRIPT="C:\Program Files\R\R-4.4.1\bin\Rscript.exe"
streamlit run app.py
python scheduler.py        # (autre terminal) lancement quotidien
```
Sans mot de passe, l'application refuse de démarrer, sauf `PCDN_ALLOW_NO_AUTH=1` (développement uniquement).

## C. Hébergement : ce qui ne convient pas
**Streamlit Community Cloud** n'est pas adapté : il n'inclut pas R, n'offre pas de stockage persistant
ni de tâche planifiée. Utiliser un hébergeur acceptant une image Docker avec disque persistant
(VPS, Render, Railway, Fly.io…) et monter le disque sur `/data`.

## D. Variables d'environnement
| Variable | Rôle |
|---|---|
| `APP_PASSWORD` | mot de passe de l'application (**obligatoire**) |
| `PCDN_FTP_HOST/USER/PWD/PROTO/PATH/PORT` | accès au FTP (jamais affichés dans l'interface) |
| `PCDN_DATA_DIR` | dossier de données (`/data` dans Docker) |
| `PCDN_RUN_TIME`, `PCDN_RUN_ON_START`, `TZ` | planification quotidienne (défaut 06:00, Africa/Douala) |
| `PCDN_RSCRIPT` | chemin de Rscript si hors PATH |
| `PCDN_LOCK_TIMEOUT_MIN` | durée max d'un lancement avant déverrouillage (défaut 120) |

## E. Tests
`python -m pytest tests/test_app.py` (nécessite des résultats dans `PCDN_DATA_DIR`).
Données factices : `cd pipeline && Rscript tests/make_fake_data.R <dossier>`.

## F. Maintenance du schéma
Si le dictionnaire ou les JSON changent : `python3 pipeline/tools/build_schema.py dico.docx dossier_json pipeline/config`.
Paramètres du contrôle (emprise, colonnes agent/date, format d'ID) : `pipeline/config/settings.R`.
