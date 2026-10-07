# Contrôles de cohérence, géométrie et doublons ----------------------------------------

blank_or <- function(x, ...) is.na(x) | x %in% c(...)

# Règles inter-champs propres à chaque couche : chaque règle renvoie un vecteur logique (TRUE = anomalie)
layer_rules <- function(layer) {
  R <- function(severity, type, vars, msg, fn) list(severity = severity, type = type, vars = vars, msg = msg, fn = fn)
  switch(layer,
    Gares = list(
      R("error", "incoherence", "type_magasin", "Présence de magasin = Oui mais type de magasin non renseigné",
        function(d) isTRUE_vec(d$presence_magasin_gare) & is.na(d$type_magasin)),
      R("warning", "incoherence", "type_magasin", "Présence de magasin = Non mais un type de magasin est renseigné",
        function(d) isFALSE_vec(d$presence_magasin_gare) & !is.na(d$type_magasin)),
      R("warning", "incoherence", "capacite_stockage_gare", "Pas de magasin mais capacité de stockage renseignée (autre que « Non applicable »)",
        function(d) isFALSE_vec(d$presence_magasin_gare) & !blank_or(d$capacite_stockage_gare, "Non applicable"))
    ),
    Points_Vente_Marches = list(
      R("warning", "incoherence", "capacite_stockage", "Pas de magasin de stockage mais capacité renseignée (autre que « Non applicable »)",
        function(d) isFALSE_vec(d$presence_magasin_stockage) & !blank_or(d$capacite_stockage, "Non applicable")),
      R("error", "incoherence", "capacite_stockage", "Magasin de stockage présent mais capacité absente",
        function(d) isTRUE_vec(d$presence_magasin_stockage) & is.na(d$capacite_stockage)),
      R("error", "incoherence", "type_aire_chargement", "Aire de chargement présente mais type non renseigné",
        function(d) isTRUE_vec(d$presence_aire_chargement) & is.na(d$type_aire_chargement)),
      R("warning", "incoherence", "type_aire_chargement", "Pas d'aire de chargement mais un type est renseigné",
        function(d) isFALSE_vec(d$presence_aire_chargement) & !is.na(d$type_aire_chargement))
    ),
    Reseau_Routier_Pistes = list(
      R("error", "incoherence", "type_blocage", "Point critique = Oui mais aucun type de blocage",
        function(d) isTRUE_vec(d$pt_critique) & blank_or(d$type_blocage, "Aucun")),
      R("warning", "incoherence", "type_blocage", "Point critique = Non mais un blocage est indiqué",
        function(d) isFALSE_vec(d$pt_critique) & !blank_or(d$type_blocage, "Aucun")),
      R("warning", "incoherence", "duree_coupure_jours", "Praticable toute l'année mais durée de coupure > 0",
        function(d) !is.na(d$duree_coupure_jours) & d$duree_coupure_jours > 0 & grepl("toute ann", norm_val(d$praticabilite_pluie)))
    ),
    Services_Sociaux_Bases = list(
      R("error", "incoherence", "type_equipement", "Le type d'équipement ne correspond pas au domaine d'activité",
        function(d) {
          pref <- norm_val(sub(" [–-] .*$", "", d$type_equipement)); dom <- norm_val(d$domaine_activite)
          !is.na(d$type_equipement) & !is.na(d$domaine_activite) & !grepl("^autre", pref) &
            !grepl("^autre", dom) & pref != dom
        })
    ),
    Activites_autour_gare = list(
      R("warning", "incoherence", "type_culture", "Type de culture renseigné alors que l'activité n'est pas agricole",
        function(d) !is.na(d$type_culture) & !grepl("agricult", norm_val(d$type_activite))),
      R("warning", "incoherence", "type_elevage", "Type d'élevage renseigné alors que l'activité n'est pas pastorale",
        function(d) !is.na(d$type_elevage) & !grepl("paturage|elevage", norm_val(d$type_activite)))
    ),
    Ouvrage_franchissement = list(
      R("warning", "incoherence", "presence_gardien", "Passage à niveau gardé mais gardien-barrières = Non",
        function(d) grepl("pn gare", norm_val(d$type_ouvrage)) & !grepl("non gare", norm_val(d$type_ouvrage)) & norm_val(d$presence_gardien) == "non"),
      R("warning", "incoherence", "dispositif_securite", "Passage à niveau non gardé/informel avec « gardien-barrières présent »",
        function(d) grepl("non gare|informel", norm_val(d$type_ouvrage)) & grepl("gardien barrieres present", norm_val(d$dispositif_securite))),
      R("warning", "incoherence", "etat_ouvrage", "Ouvrage « Impraticable » mais réhabilitation jugée non nécessaire",
        function(d) grepl("impraticable", norm_val(d$etat_ouvrage)) & grepl("non necessaire", norm_val(d$necessite_rehab)))
    ),
    Gouvernance_Services_Securite = list(
      R("warning", "incoherence", "moyens_mobilite", "« Aucun moyen propre » combiné avec d'autres moyens de mobilité",
        function(d) grepl("aucun moyen propre", norm_val(d$moyens_mobilite)) & grepl(";", d$moyens_mobilite)),
      R("warning", "incoherence", "source_energie_securite", "« Aucune » combinée avec d'autres sources d'énergie",
        function(d) grepl("(^| )aucune( |$)", norm_val(d$source_energie_securite)) & grepl(";", d$source_energie_securite))
    ),
    list())
}
isTRUE_vec  <- function(x) !is.na(x) & x
isFALSE_vec <- function(x) !is.na(x) & !x

# Contrôles géométriques et de doublons (sur l'objet sf de la couche)
geometry_checks <- function(x, layer, schema, settings) {
  iss <- new_issues()
  expected <- schema$layers$geometry[schema$layers$layer == layer]
  gt <- as.character(st_geometry_type(x)); empty <- st_is_empty(x)
  iss <- add_issue(iss, which(empty), "error", "geometrie_vide", "geometry", NA, "Géométrie absente ou illisible")
  ok <- !empty & !is.na(gt)
  want <- toupper(expected)
  mism <- which(ok & !(sub("MULTI", "", gt) %in% want))
  iss <- add_issue(iss, mism, "error", "geometrie_type", "geometry", gt[mism], sprintf("Type de géométrie %s attendu (%s reçu)", expected, gt[mism]))

  inval <- which(ok & !st_is_valid(x))
  iss <- add_issue(iss, inval, "error", "geometrie_invalide", "geometry", NA, "Géométrie invalide (auto-intersection, anneau non fermé…)")

  # emprise du corridor
  bb <- settings$bbox; cen <- suppressWarnings(st_coordinates(st_centroid(st_geometry(x)[ok])))
  if (length(cen) > 0) {
    out <- which(ok)[cen[, 1] < bb["xmin"] | cen[, 1] > bb["xmax"] | cen[, 2] < bb["ymin"] | cen[, 2] > bb["ymax"]]
    iss <- add_issue(iss, out, "error", "hors_emprise", "geometry", NA, "Localisation hors de l'emprise attendue du corridor (coordonnées inversées ou erronées ?)")
    zero <- which(ok)[cen[, 1] == 0 & cen[, 2] == 0]
    iss <- add_issue(iss, zero, "error", "hors_emprise", "geometry", "0,0", "Coordonnées (0,0) : GPS non capté")
  }
  if (identical(toupper(expected), "LINESTRING")) {
    len <- rep(NA_real_, nrow(x)); idx <- which(ok & grepl("LINESTRING", gt))
    if (length(idx)) len[idx] <- as.numeric(st_length(st_transform(x[idx, ], 32633)))
    short <- which(!is.na(len) & len < settings$min_line_length_m)
    iss <- add_issue(iss, short, "warning", "tronçon_court", "geometry", round(len[short], 1), sprintf("Tronçon de %.1f m seulement (< %s m)", len[short], settings$min_line_length_m))
  }
  # doublons de points proches (même couche)
  if (identical(toupper(expected), "POINT") && sum(ok) > 1) {
    pts <- st_transform(x[ok, ], 32633); nb <- st_is_within_distance(pts, pts, dist = settings$dup_point_tolerance_m)
    dupr <- which(lengths(nb) > 1)
    # on ne signale que les voisins ayant le même identifiant ou le même nom
    id_var <- schema$layers$id_var[schema$layers$layer == layer]; nm_var <- schema$layers$name_var[schema$layers$layer == layer]
    key <- paste(st_drop_geometry(pts)[[id_var]], if (!is.na(nm_var) && nzchar(nm_var)) st_drop_geometry(pts)[[nm_var]] else "")
    flag <- vapply(dupr, function(i) any(setdiff(nb[[i]], i) %in% which(key == key[i]) | (norm_val(key[setdiff(nb[[i]], i)]) == norm_val(key[i]))), NA)
    iss <- add_issue(iss, which(ok)[dupr[flag]], "warning", "doublon_spatial", "geometry", NA,
                     sprintf("Point à moins de %s m d'un autre point identique (même id/nom)", settings$dup_point_tolerance_m))
  }
  iss
}

# Dates : future ou antérieure au début de la collecte
date_checks <- function(x, settings) {
  iss <- new_issues(); d <- x$.date
  iss <- add_issue(iss, which(!is.na(d) & d > Sys.Date() + 1), "error", "date_future", ".date", format(d[!is.na(d) & d > Sys.Date() + 1]),
                   "Date de collecte dans le futur (horloge du terminal mal réglée ?)")
  if (!is.na(settings$start_date))
    iss <- add_issue(iss, which(!is.na(d) & d < settings$start_date), "warning", "date_anterieure", ".date", format(d[!is.na(d) & d < settings$start_date]),
                     sprintf("Date antérieure au début de la collecte (%s)", settings$start_date))
  iss
}

# Colonnes .date et .agent d'après les colonnes optionnelles reconnues
add_meta <- function(x, settings) {
  raw <- st_drop_geometry(x); keys <- setNames(names(raw), norm_key(names(raw)))
  pick <- function(cands) { h <- cands[cands %in% names(keys)]; if (length(h)) raw[[keys[[h[1]]]]] else rep(NA_character_, nrow(x)) }
  dt <- suppressWarnings(lubridate::parse_date_time(as.character(pick(settings$date_cols)),
        orders = c("Ymd HMS", "Ymd HM", "Ymd", "dmY HMS", "dmY HM", "dmY", "Y-m-d\\TH:M:S"), quiet = TRUE))
  x$.date <- ifelse(is.na(dt), as.Date(x$.file_date), as.Date(dt)) %>% as.Date(origin = "1970-01-01")
  ag <- clean_na(pick(settings$agent_cols)); x$.agent <- ifelse(is.na(ag), "INCONNU", ag)
  x
}

# Doublons d'identifiant et identifiant mal formé
id_checks <- function(x, layer, schema, settings) {
  iss <- new_issues(); id_var <- schema$layers$id_var[schema$layers$layer == layer]
  ids <- x[[id_var]]
  dup <- which(!is.na(ids) & (duplicated(ids) | duplicated(ids, fromLast = TRUE)))
  iss <- add_issue(iss, dup, "error", "id_duplique", id_var, ids[dup], sprintf("Identifiant « %s » utilisé plusieurs fois dans la couche", ids[dup]))
  if (!is.null(settings$id_pattern)) {
    bad <- which(!is.na(ids) & !grepl(settings$id_pattern, ids))
    iss <- add_issue(iss, bad, "error", "id_format", id_var, ids[bad], sprintf("Identifiant « %s » non conforme au format attendu", ids[bad]))
  }
  iss
}

# Chaîne complète pour UNE couche ---------------------------------------------------------
process_layer <- function(x, layer, schema, settings) {
  id_var <- schema$layers$id_var[schema$layers$layer == layer]
  nm_var <- schema$layers$name_var[schema$layers$layer == layer]
  # 1) dédoublonnage exact entre fichiers (même enregistrement renvoyé plusieurs jours)
  raw <- st_drop_geometry(x) %>% select(-.source_file, -.file_date)
  sig <- vapply(do.call(paste, c(unname(as.list(raw)), list(st_as_text(st_geometry(x)), sep = "\u001f"))), digest::digest, "")
  x <- x %>% mutate(.sig = sig) %>% arrange(desc(.file_date)) %>% distinct(.sig, .keep_all = TRUE) %>% select(-.sig)
  x <- add_meta(x, settings)
  # même collecte exportée en .kml ET .shp : même id + même position (~10 cm) -> on garde la version la plus complète
  if (!is.na(id_var) && id_var %in% names(x)) {
    xy <- suppressWarnings(st_coordinates(st_centroid(st_geometry(x))))
    pos <- if (nrow(xy) == nrow(x)) paste(round(xy[, 1], 6), round(xy[, 2], 6)) else rep("", nrow(x))
    comp <- rowSums(!is.na(st_drop_geometry(x)[, schema$vars$variable[schema$vars$layer == layer], drop = FALSE]))
    x$.k <- ifelse(is.na(x[[id_var]]), NA_character_, paste(x[[id_var]], pos)); x$.comp <- comp
    n0 <- nrow(x)
    # fusion uniquement entre FORMATS différents (kml / shp) : un doublon d'id au sein d'un même
    # format reste signalé plus bas (id_duplique). On garde le format le plus complet.
    x$.ext <- tolower(tools::file_ext(x$.source_file))
    x <- x %>% arrange(desc(.comp), desc(.file_date)) %>% group_by(.k) %>%
      mutate(.best = .ext[1]) %>% ungroup() %>%
      filter(is.na(.k) | .ext == .best) %>% select(-.k, -.comp, -.ext, -.best)
    if (nrow(x) < n0) log_msg(layer, " : ", n0 - nrow(x), " doublon(s) kml/shp fusionné(s)")
  }
  # 2) un même id : on garde la version la plus récente, mais on le signale
  x <- x %>% arrange(desc(.date), desc(.file_date))
  x$.row <- seq_len(nrow(x))

  cz <- canonicalize(x, layer, schema); iss <- attr(cz, "issues"); cz <- cz  # types + listes + obligatoires
  iss <- bind_rows(iss, id_checks(cz, layer, schema, settings), date_checks(cz, settings),
                   geometry_checks(cz, layer, schema, settings))
  for (r in layer_rules(layer)) {
    flag <- tryCatch(r$fn(st_drop_geometry(cz)), error = function(e) { log_msg("Règle ignorée (", layer, ") : ", conditionMessage(e), level = "WARN"); rep(FALSE, nrow(cz)) })
    flag[is.na(flag)] <- FALSE
    iss <- add_issue(iss, which(flag), r$severity, r$type, r$vars[1], NA, r$msg)
  }
  # anomalies -> table finale, avec contexte
  ctx <- st_drop_geometry(cz) %>% transmute(row = .row, layer = layer, id = .data[[id_var]],
         nom = if (!is.na(nm_var) && nzchar(nm_var)) .data[[nm_var]] else NA_character_,
         agent = .agent, date = .date, fichier = .source_file)
  issues <- iss %>% left_join(ctx, by = "row") %>% select(-row) %>%
    relocate(layer, severity, type, id, nom, agent, date, variable, value, message, fichier) %>%
    arrange(desc(severity == "error"), agent, id)
  # indicateur par ligne
  cz$.n_err  <- tabulate(iss$row[iss$severity == "error"], nbins = nrow(cz))
  cz$.n_warn <- tabulate(iss$row[iss$severity == "warning"], nbins = nrow(cz))
  list(data = cz %>% select(-.row), issues = issues)
}
