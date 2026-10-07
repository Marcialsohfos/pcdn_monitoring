# =============================================================================
#  PCDN - Paramètres du monitoring (à adapter si besoin, pas de secrets ici)
#  Les accès FTP se renseignent dans le fichier .Renviron (voir .Renviron.example)
# =============================================================================
settings <- list(
  # --- FTP -------------------------------------------------------------------
  ftp_path      = Sys.getenv("PCDN_FTP_PATH", "/"),   # dossier racine à explorer
  ftp_recursive = TRUE,                               # explorer les sous-dossiers
  ftp_max_depth = 3,
  extensions    = c("shp", "kml", "zip", "dbf", "shx", "prj", "cpg"),  # fichiers à télécharger

  # --- Emprise plausible du corridor (lon/lat WGS84) : Douala -> N'Djamena ----
  # Tout point hors de cette boîte est signalé en anomalie.
  bbox = c(xmin = 8.0, ymin = 2.0, xmax = 17.5, ymax = 14.5),

  # --- Période de collecte ----------------------------------------------------
  start_date = as.Date(NA),     # ex. as.Date("2026-10-01") : ignore les données antérieures

  # --- Colonnes optionnelles reconnues automatiquement (noms normalisés) ------
  date_cols  = c("created", "creation_date", "date_jour", "date_collecte", "date", "change"),
  agent_cols = c("enumerator", "agent", "agent_nom", "collecteur", "enqueteur", "username", "user"),

  # --- Reconnaissance automatique de la couche --------------------------------
  min_match_cols = 3,           # nb mini de colonnes du dictionnaire retrouvées dans un fichier

  # --- Contrôles --------------------------------------------------------------
  id_pattern = NULL,            # ex. "^PCDN_[A-Z]{3}_\\d{4}$" si une convention d'ID est fixée
  min_line_length_m = 5,        # tronçon routier plus court = suspect
  dup_point_tolerance_m = 2,    # deux points de même couche à moins de x m = doublon probable

  # --- Dossiers (racine configurable : variable d'environnement PCDN_DATA_DIR) ----
  dir_ftp    = file.path(Sys.getenv("PCDN_DATA_DIR", "local"), "input", "ftp"),
  dir_work   = file.path(Sys.getenv("PCDN_DATA_DIR", "local"), "work"),
  dir_output = file.path(Sys.getenv("PCDN_DATA_DIR", "local"), "output"),
  dir_logs   = file.path(Sys.getenv("PCDN_DATA_DIR", "local"), "logs")
)
