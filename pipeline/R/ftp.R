# Synchronisation FTP ------------------------------------------------------------
# Les identifiants viennent de .Renviron : PCDN_FTP_HOST, PCDN_FTP_USER, PCDN_FTP_PWD,
# (optionnels) PCDN_FTP_PROTO (ftp|ftps), PCDN_FTP_PORT, PCDN_FTP_PATH.

ftp_cfg <- function() {
  cfg <- list(host = Sys.getenv("PCDN_FTP_HOST"), user = Sys.getenv("PCDN_FTP_USER"),
              pwd = Sys.getenv("PCDN_FTP_PWD"), proto = tolower(Sys.getenv("PCDN_FTP_PROTO", "ftp")),
              port = Sys.getenv("PCDN_FTP_PORT", ""))
  if (!nzchar(cfg$host) || !nzchar(cfg$user) || !nzchar(cfg$pwd))
    stop("Accès FTP incomplets : renseignez PCDN_FTP_HOST, PCDN_FTP_USER et PCDN_FTP_PWD dans .Renviron")
  cfg
}

ftp_url <- function(cfg, path) {
  path <- paste0("/", gsub("^/+|/+$", "", path)); if (path != "/") path <- paste0(path, "/")
  host <- if (nzchar(cfg$port)) paste0(cfg$host, ":", cfg$port) else cfg$host
  paste0(cfg$proto, "://", host, path)
}

ftp_handle <- function(cfg, ...) {
  curl::new_handle(userpwd = paste0(cfg$user, ":", cfg$pwd), ftp_use_epsv = FALSE,
                   connecttimeout = 30, timeout = 600, ...)
}

# Liste un dossier -> tibble(name, is_dir, size, mtime)
ftp_list <- function(cfg, path) {
  res <- curl::curl_fetch_memory(ftp_url(cfg, path), handle = ftp_handle(cfg))
  lines <- strsplit(rawToChar(res$content), "\r?\n")[[1]]; lines <- lines[nzchar(trimws(lines))]
  unix <- "^([d-])[rwxsStT-]{9}\\s+\\d+\\s+\\S+\\s+\\S+\\s+(\\d+)\\s+(\\w{3}\\s+\\d+\\s+[\\d:]+)\\s+(.+)$"
  m <- stringr::str_match(lines, unix)
  if (all(!is.na(m[, 1]))) {            # listing de type "ls -l"
    out <- tibble(name = trimws(m[, 5]), is_dir = m[, 2] == "d", size = as.numeric(m[, 3]), mtime = m[, 4])
  } else {                               # repli : noms seuls (dossier = pas d'extension)
    nm <- trimws(lines)
    out <- tibble(name = nm, is_dir = !grepl("\\.[A-Za-z0-9]{2,4}$", nm), size = NA_real_, mtime = NA_character_)
  }
  filter(out, !name %in% c(".", ".."))
}

ftp_walk <- function(cfg, path, depth, max_depth, recursive) {
  items <- ftp_list(cfg, path)
  files <- items %>% filter(!is_dir) %>% mutate(remote_dir = path)
  if (recursive && depth < max_depth) {
    for (d in items$name[items$is_dir])
      files <- bind_rows(files, tryCatch(
        ftp_walk(cfg, file.path(path, d), depth + 1, max_depth, recursive),
        error = function(e) { log_msg("Dossier illisible ", file.path(path, d), " : ", conditionMessage(e), level = "WARN"); NULL }))
  }
  files
}

# Télécharge uniquement les fichiers nouveaux ou modifiés (manifeste local)
ftp_sync <- function(settings) {
  cfg <- ftp_cfg()
  dir.create(settings$dir_ftp, recursive = TRUE, showWarnings = FALSE)
  manifest_path <- file.path(settings$dir_ftp, "_manifest.csv")
  manifest <- if (file.exists(manifest_path)) utils::read.csv(manifest_path, stringsAsFactors = FALSE) else
    data.frame(remote = character(), size = numeric(), mtime = character(), local = character(), downloaded_at = character())

  remote <- ftp_walk(cfg, settings$ftp_path, 0, settings$ftp_max_depth, settings$ftp_recursive) %>%
    filter(tolower(tools::file_ext(name)) %in% settings$extensions) %>%
    mutate(remote = file.path(remote_dir, name))
  log_msg("FTP : ", nrow(remote), " fichier(s) pertinent(s) sur le serveur")

  n_new <- 0
  for (i in seq_len(nrow(remote))) {
    r <- remote[i, ]
    known <- manifest[manifest$remote == r$remote, ]
    unchanged <- nrow(known) == 1 && isTRUE(known$size == r$size || is.na(r$size)) &&
      isTRUE(known$mtime == r$mtime || is.na(r$mtime)) && file.exists(known$local)
    if (unchanged) next
    # sous-dossier local = chemin distant aplati (évite les collisions de noms)
    sub <- gsub("[^A-Za-z0-9_-]+", "_", gsub("^/+|/+$", "", r$remote_dir))
    ldir <- if (nzchar(sub)) file.path(settings$dir_ftp, sub) else settings$dir_ftp
    dir.create(ldir, recursive = TRUE, showWarnings = FALSE)
    local <- file.path(ldir, r$name)
    ok <- tryCatch({
      curl::curl_download(paste0(ftp_url(cfg, r$remote_dir), utils::URLencode(r$name)), local,
                          handle = ftp_handle(cfg), quiet = TRUE); TRUE
    }, error = function(e) { log_msg("Échec téléchargement ", r$remote, " : ", conditionMessage(e), level = "ERROR"); FALSE })
    if (ok) {
      n_new <- n_new + 1
      manifest <- manifest[manifest$remote != r$remote, ]
      manifest <- rbind(manifest, data.frame(remote = r$remote, size = r$size, mtime = r$mtime,
                                              local = local, downloaded_at = format(Sys.time())))
      log_msg("Téléchargé : ", r$remote)
    }
  }
  utils::write.csv(manifest, manifest_path, row.names = FALSE)
  log_msg("FTP : ", n_new, " fichier(s) nouveau(x) ou modifié(s) téléchargé(s)")
  invisible(n_new)
}
