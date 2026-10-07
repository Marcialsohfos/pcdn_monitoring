# Lecture des fichiers .shp / .kml (et .zip contenant des .shp) ----------------------

# Décompresse les .zip non encore traités et renvoie la liste des .shp/.kml à lire
list_sources <- function(settings) {
  zips <- list.files(settings$dir_ftp, "\\.zip$", recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
  for (z in zips) {
    target <- file.path(settings$dir_work, "unzipped", paste0(norm_key(basename(z)), "_", format(file.size(z))))
    if (!dir.exists(target)) {
      dir.create(target, recursive = TRUE)
      tryCatch(utils::unzip(z, exdir = target),
               error = function(e) log_msg("ZIP illisible ", z, " : ", conditionMessage(e), level = "ERROR"))
    }
  }
  roots <- c(settings$dir_ftp, file.path(settings$dir_work, "unzipped"))
  f <- unlist(lapply(roots[dir.exists(roots)], list.files, pattern = "\\.(shp|kml)$",
                     recursive = TRUE, full.names = TRUE, ignore.case = TRUE))
  f <- f[!grepl("__MACOSX", f)]
  tibble(path = f, ext = tolower(tools::file_ext(f)), file_date = as.Date(file.mtime(f)))
}

# ---- KML : lecture XML directe (robuste aux ExtendedData de Mapit) -------------------
parse_coords <- function(txt) {
  tok <- strsplit(trimws(gsub("\\s+", " ", txt)), " ")[[1]]
  m <- do.call(rbind, lapply(tok[nzchar(tok)], function(t) as.numeric(strsplit(t, ",")[[1]][1:2])))
  m
}

read_kml <- function(path) {
  doc <- xml2::read_xml(path); xml2::xml_ns_strip(doc)
  pms <- xml2::xml_find_all(doc, "//Placemark")
  if (length(pms) == 0) return(NULL)
  geoms <- vector("list", length(pms)); rows <- vector("list", length(pms))
  for (i in seq_along(pms)) {
    pm <- pms[[i]]
    nm <- xml2::xml_text(xml2::xml_find_first(pm, "./name"))
    att <- list(placemark_name = nm)
    for (d in xml2::xml_find_all(pm, ".//ExtendedData//Data")) {
      k <- xml2::xml_attr(d, "name"); v <- xml2::xml_text(xml2::xml_find_first(d, "./value"))
      if (!is.na(k)) att[[k]] <- v
    }
    for (d in xml2::xml_find_all(pm, ".//ExtendedData//SimpleData")) att[[xml2::xml_attr(d, "name")]] <- xml2::xml_text(d)
    g <- NULL
    multi <- length(xml2::xml_find_all(pm, ".//Point|.//LineString|.//Polygon")) > 1
    pt <- xml2::xml_find_first(pm, ".//Point/coordinates")
    ln <- xml2::xml_find_first(pm, ".//LineString/coordinates")
    pg <- xml2::xml_find_first(pm, ".//Polygon/outerBoundaryIs//coordinates")
    try({
      if (!is.na(pt)) g <- st_point(parse_coords(xml2::xml_text(pt))[1, ])
      else if (!is.na(ln)) g <- st_linestring(parse_coords(xml2::xml_text(ln)))
      else if (!is.na(pg)) g <- st_polygon(list(parse_coords(xml2::xml_text(pg))))
    }, silent = TRUE)
    att[[".multigeom"]] <- as.character(multi)
    geoms[[i]] <- g %||% st_point()   # géométrie vide si illisible
    rows[[i]] <- att
  }
  keys <- unique(unlist(lapply(rows, names)))
  df <- as_tibble(lapply(setNames(keys, keys), function(k) vapply(rows, function(r) as.character(r[[k]] %||% NA_character_), "")))
  # géométries de types mixtes -> GEOMETRY ; sinon type homogène
  st_sf(df, geometry = st_sfc(geoms, crs = 4326))
}

read_shp <- function(path) {
  x <- tryCatch(st_read(path, quiet = TRUE, stringsAsFactors = FALSE, options = "ENCODING=UTF-8"), error = function(e) NULL)
  bad <- is.null(x) || any(vapply(st_drop_geometry(x), function(c) is.character(c) && any(!validUTF8(c)), NA))
  if (bad) x <- st_read(path, quiet = TRUE, stringsAsFactors = FALSE, options = "ENCODING=LATIN1")
  if (is.na(st_crs(x))) { st_crs(x) <- 4326; attr(x, "crs_assumed") <- TRUE }
  else if (st_crs(x) != st_crs(4326)) x <- st_transform(x, 4326)
  x <- st_zm(x)
  x %>% mutate(across(-geometry, as.character))
}

# Lecture unifiée -> sf (colonnes texte + .source_file + .file_date) ou NULL
read_source <- function(path, file_date) {
  ext <- tolower(tools::file_ext(path))
  x <- tryCatch(if (ext == "kml") read_kml(path) else read_shp(path),
                error = function(e) { log_msg("Lecture impossible ", basename(path), " : ", conditionMessage(e), level = "ERROR"); NULL })
  if (is.null(x) || nrow(x) == 0) return(NULL)
  geom_col <- attr(x, "sf_column")
  if (geom_col != "geometry") x <- rename(x, geometry = all_of(geom_col)) %>% st_set_geometry("geometry")
  x$.source_file <- basename(path); x$.file_date <- file_date
  x
}
