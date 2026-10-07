# Génère des fichiers .shp et .kml factices (avec erreurs volontaires) dans un dossier
suppressPackageStartupMessages({library(sf); library(dplyr)})
out <- commandArgs(TRUE)[1]; dir.create(out, recursive = TRUE, showWarnings = FALSE)

# --- Gares (shapefile, noms tronqués à 10 caractères comme Mapit/QGIS) ---------------
g <- st_sf(
  id_fichega = c("G001", "G002", "G003", "G003", "G005"),
  nom_gare_d = c("Yaoundé", "Eséka", "Bélabo", "Bélabo", "Ngaoundéré"),
  axe_ferrov = c("Douala-Yaoundé", "Douala-Yaoundé", "Yaoundé-Ngaoundéré", "Yaoundé-Ngaoundéré", "Axe inventé"),
  type_gare  = c("Gare terminus", "Gare secondaire", "Gare principale (bifurcation)", "Gare principale (bifurcation)", "Halte-arrêt"),
  etat_fonct = c("Fonctionnelle", "fonctionnelle", "En réhabilitation", "En réhabilitation", "Fonctionnelle"),
  mode_acces = c("A pied; Moto-taxi", "Moto-taxi", "Vélo", "Vélo", "Hélicoptère"),
  presence_m = c("Oui", "Non", "Oui", "Oui", "Non"),
  type_magas = c(NA, "Boutique-commerce", NA, NA, NA),
  capacite_s = c("100-500 t", NA, "< 100 t", "100-500 t", "Non applicable"),
  geometry = st_sfc(st_point(c(11.52, 3.85)), st_point(c(10.77, 3.65)), st_point(c(13.30, 4.93)),
                    st_point(c(13.30, 4.93)), st_point(c(48.0, 7.3)), crs = 4326))
st_write(g, file.path(out, "Gares_20261001.shp"), quiet = TRUE, delete_dsn = TRUE)

# --- Réseau routier (KML façon Mapit : ExtendedData/Data) -----------------------------------
mk <- function(name, cat, surf, blocage, pt, pluie, coords, largeur, coupure) sprintf(
'<Placemark><name>%s</name><ExtendedData>
<Data name="id_troncon"><value>%s</value></Data><Data name="categorie_voie"><value>%s</value></Data>
<Data name="type_surface"><value>%s</value></Data><Data name="largeur_m"><value>%s</value></Data>
<Data name="pt_critique"><value>%s</value></Data><Data name="type_blocage"><value>%s</value></Data>
<Data name="praticabilite_pluie"><value>%s</value></Data><Data name="duree_coupure_jours"><value>%s</value></Data>
<Data name="enumerator"><value>AGENT_A</value></Data><Data name="created"><value>2026-10-01 09:15:00</value></Data>
</ExtendedData><LineString><coordinates>%s</coordinates></LineString></Placemark>',
  name, name, cat, surf, largeur, pt, blocage, pluie, coupure, coords)
kml <- paste0('<?xml version="1.0" encoding="UTF-8"?><kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Reseau_Routier_Pistes</name>',
  mk("T001", "Route Nationale (RN)", "Bitume", "Aucun", "Non", "Accessible toute année (Toutes voitures)", "11.5,3.8 11.6,3.9 11.7,4.0", "7", "0"),
  mk("T002", "Piste rurale aménagée", "Latérite", "Aucun", "Oui", "Accessible saison sèche uniquement", "12.0,4.0 12.1,4.1", "4", "45"),
  mk("T003", "Piste informelle", "Boue", "Zone d'embourbement", "Oui", "Coupé / Impraticable en pluie", "12.2,4.2 12.2001,4.2001", "abc", "400"),
  '</Document></kml>')
writeLines(kml, file.path(out, "Reseau_Routier_Pistes_2026-10-01.kml"), useBytes = TRUE)

# --- Services sociaux (shapefile) : incohérence domaine/équipement + hors liste --------------
s <- st_sf(id_service = c("S1", "S2"), nom_etabli = c("CSI Nkol", "École Bidou"),
           domaine_ac = c("Santé", "Santé"), type_equip = c("Santé – CSI", "Éducation – École primaire (EP)"),
           etat_fonct = c("Fonctionnel", "Fonctionnel"), geometry = st_sfc(st_point(c(11.5, 3.9)), st_point(c(11.6, 3.95)), crs = 4326))
st_write(s, file.path(out, "Services_Sociaux_Bases.shp"), quiet = TRUE, delete_dsn = TRUE)
cat("fake data in", out, "\n")
