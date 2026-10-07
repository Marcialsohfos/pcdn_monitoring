# Exports : GeoPackage, Excel (données + qualité), suivi quotidien -------------------------

suppressPackageStartupMessages(library(openxlsx))

flat_for_export <- function(x) {
  x <- x %>% mutate(across(where(is.logical), ~ ifelse(is.na(.x), NA_character_, ifelse(.x, "Oui", "Non"))))
  x
}

summarise_quality <- function(res, schema) {
  tibble(couche = names(res$data), entites = vapply(res$data, nrow, 1L)) %>%
    left_join(res$issues_all %>% group_by(couche = layer) %>%
                summarise(erreurs = sum(severity == "error"), avertissements = sum(severity == "warning"), .groups = "drop"), by = "couche") %>%
    left_join(imap_dfr(res$data, ~ tibble(couche = .y, entites_avec_erreur = sum(.x$.n_err > 0), entites_aujourdhui = sum(.x$.date == Sys.Date(), na.rm = TRUE))), by = "couche") %>%
    mutate(across(c(erreurs, avertissements), ~ coalesce(.x, 0L)),
           taux_conformite_pct = round(100 * (1 - entites_avec_erreur / pmax(entites, 1)), 1)) %>%
    arrange(desc(entites))
}

export_all <- function(res, schema, settings, run_date = Sys.Date()) {
  out_latest <- file.path(settings$dir_output, "latest")
  out_arch   <- file.path(settings$dir_output, "archive", format(run_date))
  for (d in c(out_latest, out_arch)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  if (length(res$data) == 0) { log_msg("Aucune donnée à exporter", level = "WARN"); return(invisible(NULL)) }

  # --- GeoPackage : une couche par thème
  gpkg <- file.path(out_latest, "pcdn_donnees.gpkg"); if (file.exists(gpkg)) file.remove(gpkg)
  for (l in names(res$data)) {
    g <- flat_for_export(res$data[[l]]); g$.date <- as.character(g$.date); g$.file_date <- as.character(g$.file_date)
    names(g)[names(g) %in% c(".date", ".agent", ".file_date", ".source_file", ".n_err", ".n_warn")] <-
      c("date_collecte", "agent", "date_fichier", "fichier_source", "nb_erreurs", "nb_avertissements")[match(
        names(g)[names(g) %in% c(".date", ".agent", ".file_date", ".source_file", ".n_err", ".n_warn")], c(".date", ".agent", ".file_date", ".source_file", ".n_err", ".n_warn"))]
    g <- g[, !grepl("^(x_|\\.dup_|\\.multigeom)", names(g)) | names(g) == "geometry"]
    st_write(g, gpkg, layer = l, delete_layer = TRUE, quiet = TRUE)
  }

  # --- Excel des données consolidées (une feuille par couche, coordonnées en colonnes)
  wb <- createWorkbook()
  for (l in names(res$data)) {
    d <- res$data[[l]]; cen <- suppressWarnings(st_coordinates(st_centroid(st_geometry(d))))
    t <- flat_for_export(st_drop_geometry(d)); t <- t[, !grepl("^(x_|\\.dup_|\\.multigeom)", names(t))]
    t$longitude <- round(cen[, 1], 6); t$latitude <- round(cen[, 2], 6)
    addWorksheet(wb, substr(l, 1, 31)); writeData(wb, substr(l, 1, 31), t)
    freezePane(wb, substr(l, 1, 31), firstRow = TRUE); setColWidths(wb, substr(l, 1, 31), 1:ncol(t), "auto")
  }
  saveWorkbook(wb, file.path(out_latest, "pcdn_donnees.xlsx"), overwrite = TRUE)

  # --- Excel de contrôle qualité
  q <- summarise_quality(res, schema); iss <- res$issues_all %>% mutate(date = as.character(date))
  by_agent <- iss %>% group_by(agent, couche = layer) %>%
    summarise(erreurs = sum(severity == "error"), avertissements = sum(severity == "warning"), .groups = "drop") %>% arrange(desc(erreurs))
  by_type <- iss %>% count(layer, severity, type, name = "nombre") %>% arrange(desc(nombre))
  wq <- createWorkbook()
  sheets <- list(Resume = q, Par_type_anomalie = by_type, Par_agent = by_agent, Anomalies = iss, Journal_fichiers = res$file_log)
  hs <- createStyle(textDecoration = "bold", fgFill = "#D9E1F2")
  for (s in names(sheets)) {
    addWorksheet(wq, s); writeData(wq, s, sheets[[s]], headerStyle = hs); freezePane(wq, s, firstRow = TRUE)
    setColWidths(wq, s, seq_len(max(1, ncol(sheets[[s]]))), "auto")
  }
  if (nrow(iss) > 0) conditionalFormatting(wq, "Anomalies", cols = 2, rows = 2:(nrow(iss) + 1), rule = '=="error"', style = createStyle(fontColour = "#9C0006", bgFill = "#FFC7CE"))
  # un classeur par agent : prêt à renvoyer à chaque équipe pour correction
  ag_dir <- file.path(out_latest, "corrections_par_agent"); unlink(ag_dir, recursive = TRUE); dir.create(ag_dir)
  for (a in unique(iss$agent)) {
    rio_name <- file.path(ag_dir, paste0(gsub("[^A-Za-z0-9_-]+", "_", a), ".xlsx"))
    write.xlsx(iss %>% filter(agent == a), rio_name, headerStyle = hs, colWidths = "auto", firstRow = TRUE)
  }
  saveWorkbook(wq, file.path(out_latest, "controle_qualite.xlsx"), overwrite = TRUE)

  # --- Suivi quotidien (historique cumulé : une ligne par jour et par couche)
  hist_path <- file.path(settings$dir_output, "suivi_quotidien.csv")
  today <- q %>% transmute(date_execution = as.character(run_date), couche, entites, entites_aujourdhui, erreurs, avertissements, taux_conformite_pct)
  hist <- if (file.exists(hist_path)) utils::read.csv(hist_path, stringsAsFactors = FALSE) else today[0, ]
  hist <- bind_rows(hist %>% filter(date_execution != as.character(run_date)), today) %>% arrange(date_execution, couche)
  utils::write.csv(hist, hist_path, row.names = FALSE, fileEncoding = "UTF-8")

  # --- Archive datée (copie des livrables du jour)
  file.copy(list.files(out_latest, full.names = TRUE), out_arch, recursive = TRUE, overwrite = TRUE)
  log_msg("Exports écrits dans ", out_latest, " (archive : ", out_arch, ")")
  invisible(q)
}
