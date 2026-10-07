#!/usr/bin/env Rscript
# =============================================================================
#  PCDN - Monitoring quotidien des données géospatiales
#  Usage :  Rscript run_daily.R               (FTP + traitement + exports)
#           Rscript run_daily.R --skip-ftp    (retraite uniquement les fichiers déjà téléchargés)
# =============================================================================
args <- if (interactive()) character() else commandArgs(trailingOnly = TRUE)
if (exists("skip_ftp") && isTRUE(skip_ftp)) args <- c(args, "--skip-ftp")

# Se placer dans le dossier du script (utile pour cron / planificateur Windows)
script_dir <- tryCatch(dirname(normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))), error = function(e) ".")
if (!is.na(script_dir) && dir.exists(script_dir)) setwd(script_dir)
if (file.exists(".Renviron")) readRenviron(".Renviron")

for (f in list.files("R", "\\.R$", full.names = TRUE)) source(f, encoding = "UTF-8")
source("config/settings.R", encoding = "UTF-8")
log_init(settings$dir_logs)
log_msg("===== Démarrage du monitoring PCDN =====")

schema <- load_schema("config")
status <- 0

if (!"--skip-ftp" %in% args) {
  ok <- tryCatch({ ftp_sync(settings); TRUE },
                 error = function(e) { log_msg("FTP indisponible : ", conditionMessage(e), " -> traitement des fichiers déjà présents", level = "ERROR"); FALSE })
  if (!ok) status <- 2
}

res <- run_pipeline(settings, schema)
if (length(res$data) > 0) {
  export_all(res, schema, settings)
  e <- sum(res$issues_all$severity == "error"); w <- sum(res$issues_all$severity == "warning")
  log_msg(sprintf("Terminé : %d couche(s), %d erreur(s), %d avertissement(s)", length(res$data), e, w))
} else {
  log_msg("Aucune donnée exploitable trouvée", level = "WARN"); status <- max(status, 1)
}
if (!interactive()) quit(save = "no", status = status)
