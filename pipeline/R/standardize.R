# Schéma, reconnaissance de couche, harmonisation et validation des valeurs -------------

load_schema <- function(dir = "config") {
  rd <- function(f) utils::read.csv(file.path(dir, f), stringsAsFactors = FALSE, fileEncoding = "UTF-8", na.strings = "")
  list(layers = rd("pcdn_layers.csv"), vars = rd("pcdn_schema.csv"), domains = rd("pcdn_domains.csv"))
}

# Table de correspondance : nom de colonne normalisé -> variable du dictionnaire.
# Deux niveaux : clés complètes (prioritaires) et clés tronquées à 10 caractères (shapefile),
# calculées sur le nom de variable, le nom du JSON Mapit ET le libellé du dictionnaire.
trunc10 <- function(k) norm_key(substr(norm_key(k), 1, 10))
column_lookup <- function(schema, layer) {
  v <- schema$vars[schema$vars$layer == layer, ]
  full <- bind_rows(tibble(key = norm_key(v$variable), variable = v$variable),
                    tibble(key = norm_key(v$json_name), variable = v$variable),
                    tibble(key = norm_key(v$label), variable = v$variable)) %>%
    filter(!is.na(key), nzchar(key)) %>% distinct()
  tr <- bind_rows(tibble(key = trunc10(v$variable), variable = v$variable),
                  tibble(key = trunc10(v$json_name), variable = v$variable),
                  tibble(key = trunc10(v$label), variable = v$variable)) %>%
    filter(!is.na(key), nzchar(key)) %>% distinct()
  amb_full <- full %>% count(key) %>% filter(n > 1) %>% pull(key)
  amb_tr   <- tr %>% count(key) %>% filter(n > 1) %>% pull(key)
  ok_full <- full %>% filter(!key %in% amb_full); ok_tr <- tr %>% filter(!key %in% amb_tr)
  list(map = setNames(ok_full$variable, ok_full$key), trunc = setNames(ok_tr$variable, ok_tr$key),
       ambiguous = setdiff(amb_tr, names(setNames(ok_full$variable, ok_full$key))))
}
# Variable correspondant à chaque nom de colonne (NA si inconnue)
match_columns <- function(cols, lk) {
  k <- norm_key(cols)
  out <- unname(lk$map[k])
  need <- is.na(out) & nchar(k) <= 10        # noms courts : tentative sur la table tronquée
  out[need] <- unname(lk$trunc[k[need]])
  out
}

# Quelle couche du dictionnaire correspond au fichier ?
detect_layer <- function(x, filename, schema, settings) {
  cols <- norm_key(setdiff(names(x), c("geometry", ".source_file", ".file_date")))
  fn <- norm_key(tools::file_path_sans_ext(filename))
  gt <- unique(as.character(st_geometry_type(x))); gt <- gt[gt != "GEOMETRYCOLLECTION"]
  scores <- map_dfr(schema$layers$layer, function(l) {
    lk <- column_lookup(schema, l)
    n_match <- sum(!is.na(match_columns(cols, lk)))
    geom_ok <- schema$layers$geometry[schema$layers$layer == l] %in% sub("MULTI", "", toupper(gt), fixed = TRUE) |
               toupper(schema$layers$geometry[schema$layers$layer == l]) %in% sub("MULTI", "", toupper(gt), fixed = TRUE)
    name_hit <- grepl(norm_key(l), fn, fixed = TRUE)
    tibble(layer = l, n_match = n_match, name_hit = name_hit, geom_ok = any(geom_ok),
           score = n_match + 100 * name_hit + 0.5 * any(geom_ok))
  }) %>% arrange(desc(score))
  best <- scores[1, ]
  if (best$name_hit || (best$n_match >= settings$min_match_cols && best$geom_ok)) best$layer else NA_character_
}

# Renomme les colonnes selon le dictionnaire, ajoute les colonnes manquantes
harmonize <- function(x, layer, schema) {
  v <- schema$vars[schema$vars$layer == layer, ] %>% arrange(ordre)
  lk <- column_lookup(schema, layer)
  nm <- names(x); meta <- c("geometry", ".source_file", ".file_date")
  new <- nm
  keep <- !nm %in% meta
  mv <- rep(NA_character_, length(nm)); mv[keep] <- match_columns(nm[keep], lk)
  new[keep] <- ifelse(is.na(mv[keep]), paste0("x_", norm_key(nm[keep])), mv[keep])
  # deux colonnes du fichier vers la même variable : on garde la première renseignée
  dup <- unique(new[duplicated(new) & !new %in% meta])
  for (d in dup) {
    idx <- which(new == d); vals <- st_drop_geometry(x)[idx]
    x[[nm[idx[1]]]] <- coalesce(!!!lapply(vals, clean_na)); new[idx[-1]] <- paste0(".dup_", seq_along(idx[-1]), "_", d)
  }
  names(x) <- make.unique(new)
  missing_cols <- setdiff(v$variable, names(x))
  for (m in missing_cols) x[[m]] <- NA_character_
  attr(x, "missing_cols") <- missing_cols
  attr(x, "ambiguous_cols") <- intersect(norm_key(nm[keep]), lk$ambiguous)
  x <- x %>% mutate(across(all_of(v$variable), clean_na))
  x
}

# Découpe une réponse multi-choix en utilisant les valeurs connues de la liste
# (indispensable : certaines valeurs contiennent une virgule, ex. « Deux-roues (moto, vélo) »)
split_multiselect <- function(s, dom_values) {
  if (is.na(s)) return(list(found = character(), unknown = character()))
  ns <- paste0(" ", norm_val(s), " "); found <- character()
  nd <- norm_val(dom_values); ord <- order(-nchar(nd))
  for (i in ord) {
    pat <- paste0(" ", nd[i], " ")
    if (grepl(pat, ns, fixed = TRUE)) { found <- c(found, dom_values[i]); ns <- sub(pat, " ", ns, fixed = TRUE) }
  }
  rest <- trimws(ns); unknown <- if (nzchar(rest)) rest else character()
  list(found = dom_values[dom_values %in% found], unknown = unknown)
}

BOOL_TRUE  <- c("oui", "true", "vrai", "1", "yes", "o", "y", "t")
BOOL_FALSE <- c("non", "false", "faux", "0", "no", "n", "f")

new_issues <- function() tibble(row = integer(), severity = character(), type = character(),
                                variable = character(), value = character(), message = character())
add_issue <- function(tbl, rows, severity, type, variable, value, message) {
  if (length(rows) == 0) return(tbl)
  bind_rows(tbl, tibble(row = rows, severity = severity, type = type, variable = variable,
                        value = as.character(value), message = message))
}

# Valide types / listes / obligatoires ; renvoie données canonisées + anomalies par ligne
canonicalize <- function(x, layer, schema) {
  v <- schema$vars[schema$vars$layer == layer, ] %>% arrange(ordre)
  dom <- schema$domains[schema$domains$layer == layer, ]
  iss <- new_issues(); df <- x

  for (i in seq_len(nrow(v))) {
    var <- v$variable[i]; typ <- v$type[i]; val <- df[[var]]; has <- !is.na(val)
    d <- dom[dom$variable == var, ]
    lab <- v$label[i]
    # --- obligatoire
    if (isTRUE(as.logical(v$obligatoire[i])))
      iss <- add_issue(iss, which(!has), "error", "champ_obligatoire_vide", var, NA,
                       sprintf("Champ obligatoire « %s » (%s) non renseigné", lab, var))
    # --- listes de valeurs
    if (nrow(d) > 0 && typ %in% c("text", "multiselect")) {
      dv <- d$value[order(d$ordre)]
      if (typ == "text") {
        key <- setNames(dv, norm_val(dv)); hit <- key[norm_val(val)]
        bad <- which(has & is.na(hit))
        iss <- add_issue(iss, bad, "error", "valeur_hors_liste", var, val[bad],
                         sprintf("« %s » : valeur « %s » absente de la liste autorisée", lab, val[bad]))
        val[has & !is.na(hit)] <- unname(hit[has & !is.na(hit)])
      } else {
        for (r in which(has)) {
          sp <- split_multiselect(val[r], dv)
          if (length(sp$unknown) > 0)
            iss <- add_issue(iss, r, "error", "valeur_hors_liste", var, val[r],
                             sprintf("« %s » : élément(s) hors liste « %s »", lab, paste(sp$unknown, collapse = " ; ")))
          val[r] <- if (length(sp$found)) paste(sp$found, collapse = "; ") else NA_character_
        }
      }
      df[[var]] <- val
    }
    # --- types
    if (typ %in% c("double", "integer")) {
      num <- suppressWarnings(as.numeric(gsub(",", ".", gsub("\\s", "", val))))
      bad <- which(has & is.na(num))
      iss <- add_issue(iss, bad, "error", "type_invalide", var, val[bad], sprintf("« %s » : « %s » n'est pas un nombre", lab, val[bad]))
      if (typ == "integer") {
        nonint <- which(!is.na(num) & num != round(num))
        iss <- add_issue(iss, nonint, "warning", "type_invalide", var, val[nonint], sprintf("« %s » : entier attendu, reçu %s", lab, val[nonint]))
      }
      lo <- suppressWarnings(as.numeric(v$min[i])); hi <- suppressWarnings(as.numeric(v$max[i]))
      if (!is.na(lo)) { r <- which(!is.na(num) & num < lo); iss <- add_issue(iss, r, "error", "hors_plage", var, num[r], sprintf("« %s » = %s inférieur au minimum plausible (%s)", lab, num[r], lo)) }
      if (!is.na(hi)) { r <- which(!is.na(num) & num > hi); iss <- add_issue(iss, r, "error", "hors_plage", var, num[r], sprintf("« %s » = %s supérieur au maximum plausible (%s)", lab, num[r], hi)) }
      df[[var]] <- num
    } else if (typ == "boolean") {
      nv <- norm_val(val); b <- ifelse(nv %in% BOOL_TRUE, TRUE, ifelse(nv %in% BOOL_FALSE, FALSE, NA))
      bad <- which(has & is.na(b))
      iss <- add_issue(iss, bad, "error", "type_invalide", var, val[bad], sprintf("« %s » : « %s » n'est pas Oui/Non", lab, val[bad]))
      df[[var]] <- b
    }
  }
  attr(df, "issues") <- iss
  df
}
