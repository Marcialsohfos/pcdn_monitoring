# Orchestration : lecture -> reconnaissance -> contrôle -> consolidation ------------------

run_pipeline <- function(settings, schema) {
  src <- list_sources(settings)
  log_msg("Fichiers locaux à traiter : ", nrow(src))
  file_log <- tibble(fichier = character(), couche = character(), n_entites = integer(), statut = character(), detail = character())
  by_layer <- setNames(vector("list", nrow(schema$layers)), schema$layers$layer)

  for (i in seq_len(nrow(src))) {
    f <- src$path[i]; bn <- basename(f)
    x <- read_source(f, src$file_date[i])
    if (is.null(x)) { file_log <- add_row(file_log, fichier = bn, couche = NA, n_entites = 0L, statut = "ERREUR", detail = "Fichier illisible ou vide"); next }
    layer <- detect_layer(x, bn, schema, settings)
    if (is.na(layer)) {
      file_log <- add_row(file_log, fichier = bn, couche = NA, n_entites = nrow(x), statut = "NON RECONNU",
                          detail = paste("Colonnes :", paste(head(setdiff(names(x), c("geometry", ".source_file", ".file_date")), 12), collapse = ", ")))
      log_msg("Couche non reconnue pour ", bn, level = "WARN"); next
    }
    h <- harmonize(x, layer, schema)
    det <- c(if (length(attr(h, "missing_cols"))) paste("colonnes absentes :", paste(attr(h, "missing_cols"), collapse = ", ")),
             if (length(attr(h, "ambiguous_cols"))) paste("colonnes ambiguës (noms tronqués) :", paste(attr(h, "ambiguous_cols"), collapse = ", ")),
             if (isTRUE(attr(x, "crs_assumed"))) "CRS absent : WGS84 supposé")
    file_log <- add_row(file_log, fichier = bn, couche = layer, n_entites = nrow(h),
                        statut = if (length(det)) "OK (avertissements)" else "OK", detail = paste(det, collapse = " | "))
    by_layer[[layer]] <- bind_rows(by_layer[[layer]], h %>% mutate(across(-geometry, as.character)) %>% st_as_sf())
  }

  out <- list(data = list(), issues = list(), file_log = file_log)
  for (layer in names(by_layer)) {
    x <- by_layer[[layer]]; if (is.null(x) || nrow(x) == 0) next
    # les colonnes ont été rendues texte pour pouvoir empiler plusieurs fichiers ; on retype ici
    res <- tryCatch(process_layer(x, layer, schema, settings),
                    error = function(e) { log_msg("Traitement de ", layer, " en échec : ", conditionMessage(e), level = "ERROR"); NULL })
    if (is.null(res)) next
    out$data[[layer]] <- res$data; out$issues[[layer]] <- res$issues
    log_msg(sprintf("%-32s %5d entités | %4d erreurs | %4d avertissements", layer, nrow(res$data),
                    sum(res$issues$severity == "error"), sum(res$issues$severity == "warning")))
  }
  out$issues_all <- bind_rows(out$issues)
  out
}
