# Utilitaires généraux ---------------------------------------------------------

suppressPackageStartupMessages({
  library(sf); library(dplyr); library(tidyr); library(stringr)
  library(purrr); library(tibble); library(lubridate)
})
sf::sf_use_s2(FALSE)   # calculs planaires sur lon/lat (suffisant pour les contrôles)

.log_file <- NULL
log_init <- function(dir) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  .log_file <<- file.path(dir, paste0("run_", format(Sys.Date(), "%Y%m%d"), ".log"))
  invisible(.log_file)
}
log_msg <- function(..., level = "INFO") {
  line <- sprintf("[%s] %-5s %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), level, paste0(...))
  cat(line, "\n", sep = "")
  if (!is.null(.log_file)) cat(line, "\n", file = .log_file, append = TRUE, sep = "")
}

# Normalise un nom de colonne : minuscules, sans accents, [a-z0-9_]
norm_key <- function(x) {
  x <- iconv(as.character(x), to = "ASCII//TRANSLIT")
  x <- tolower(x); x <- gsub("[^a-z0-9]+", "_", x); gsub("^_+|_+$", "", x)
}

# Normalise une valeur de liste pour comparaison (accents, casse, tirets, < >)
norm_val <- function(x) {
  x <- as.character(x)
  x <- gsub("<", " lt ", x, fixed = TRUE); x <- gsub(">", " gt ", x, fixed = TRUE)
  x <- iconv(x, to = "ASCII//TRANSLIT"); x <- tolower(x)
  x <- gsub("[^a-z0-9]+", " ", x); trimws(x)
}

NA_TOKENS <- c("", "n/a", "na", "null", "none", "nan", "-- selectionnez une valeur --", "-- sélectionnez une valeur --")
clean_na <- function(x) {
  x <- str_squish(as.character(x))
  x[tolower(x) %in% NA_TOKENS] <- NA_character_
  x
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || all(is.na(a))) b else a
