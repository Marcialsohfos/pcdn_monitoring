"""PCDN – Application de monitoring des données géospatiales collectées sur le terrain."""
import pandas as pd
import streamlit as st

from pcdn_app import auth, data, runner

st.set_page_config(page_title="PCDN – Monitoring", page_icon="🛤️", layout="wide")
auth.require_login()


# ============================== Barre latérale : lancement ==============================
@st.fragment(run_every=3 if runner.is_running() else None)
def run_status():
    running = runner.is_running()
    if running:
        info = runner.lock_info() or {}
        st.info(f"⏳ Monitoring en cours (démarré {info.get('started', '?')})…")
    elif st.session_state.pop("was_running", False):
        st.rerun()                      # fin de lancement : recharger les données
    st.session_state["was_running"] = running
    last = runner.last_run()
    if last and not running:
        ok = last.get("returncode") in (0, 2)
        (st.success if last.get("returncode") == 0 else st.warning if ok else st.error)(
            f"Dernier lancement ({last.get('trigger', '?')}) : {last.get('message', '')}\n\n"
            f"Fin : {last.get('finished', '?')}")


with st.sidebar:
    st.title("🛤️ PCDN")
    st.caption("Monitoring de la collecte géospatiale")
    ts = data.results_timestamp()
    st.metric("Résultats du", ts or "—")
    skip = st.checkbox("Ne pas interroger le FTP", value=False,
                       help="Retraite uniquement les fichiers déjà téléchargés.")
    if st.button("▶ Lancer le monitoring", type="primary", width="stretch", disabled=runner.is_running()):
        ok, msg = runner.start_background(skip_ftp=skip, trigger="manuel")
        (st.toast if ok else st.warning)(msg)
        st.rerun()
    run_status()
    with st.expander("Configuration"):
        cfg = runner.ftp_configured()
        for k, v in cfg.items():
            st.write(("✅ " if v else "❌ ") + k)
        if not all(cfg.values()):
            st.caption("FTP non configuré : seuls les fichiers déjà présents seront traités.")
        if runner.is_running() and st.button("Forcer le déblocage"):
            runner.force_unlock(); st.rerun()
    if st.button("Se déconnecter", width="stretch") and st.session_state.get("authenticated"):
        st.session_state.clear(); st.rerun()

# ============================== Contenu ==============================
if not data.has_results():
    st.title("PCDN – Monitoring des données géospatiales")
    st.info("Aucun résultat pour l'instant. Cliquez sur **▶ Lancer le monitoring** dans la barre latérale.")
    with st.expander("Journal"):
        st.code(runner.tail_log(), language="text")
    st.stop()

resume = data.quality_sheet("Resume")
anom = data.quality_sheet("Anomalies")
journal = data.quality_sheet("Journal_fichiers")
hist = data.history()

tab_over, tab_map, tab_qual, tab_data, tab_agents, tab_log = st.tabs(
    ["📊 Vue d'ensemble", "🗺️ Carte", "🔎 Qualité", "🗂️ Données", "👥 Corrections par agent", "📜 Journal"])

# ---------------------------------- Vue d'ensemble ----------------------------------
with tab_over:
    if resume.empty:
        st.warning("Le résumé de qualité est vide.")
    else:
        n, e, w = int(resume["entites"].sum()), int(resume["erreurs"].sum()), int(resume["avertissements"].sum())
        bad = int(resume["entites_avec_erreur"].sum())
        c1, c2, c3, c4, c5 = st.columns(5)
        c1.metric("Entités collectées", f"{n:,}".replace(",", " "))
        c2.metric("Couches", len(resume))
        c3.metric("Collectées aujourd'hui", int(resume["entites_aujourdhui"].sum()))
        c4.metric("Erreurs", e, help="Anomalies bloquantes à corriger")
        c5.metric("Conformité", f"{100 * (n - bad) / max(n, 1):.1f} %", help="Part des entités sans aucune erreur")
        st.subheader("Synthèse par couche")
        st.dataframe(resume.rename(columns={
            "couche": "Couche", "entites": "Entités", "erreurs": "Erreurs", "avertissements": "Avertissements",
            "entites_avec_erreur": "Entités avec erreur", "entites_aujourdhui": "Aujourd'hui", "taux_conformite_pct": "Conformité (%)"}),
            hide_index=True, width="stretch",
            column_config={"Conformité (%)": st.column_config.ProgressColumn(min_value=0, max_value=100, format="%.1f")})
        a, b = st.columns(2)
        with a:
            st.caption("Entités par couche")
            st.bar_chart(resume.set_index("couche")["entites"])
        with b:
            st.caption("Erreurs et avertissements par couche")
            st.bar_chart(resume.set_index("couche")[["erreurs", "avertissements"]])
    if not hist.empty and hist["date_execution"].nunique() > 1:
        st.subheader("Évolution quotidienne")
        a, b = st.columns(2)
        with a:
            st.caption("Entités cumulées par couche")
            st.line_chart(hist.pivot_table(index="date_execution", columns="couche", values="entites", aggfunc="last"))
        with b:
            st.caption("Erreurs (toutes couches)")
            st.line_chart(hist.groupby("date_execution")[["erreurs", "avertissements"]].sum())
    elif not hist.empty:
        st.caption("Le graphique d'évolution apparaîtra dès le deuxième jour de suivi.")

# ---------------------------------- Carte ----------------------------------
with tab_map:
    layers = data.layer_names()
    pick = st.selectbox("Couche", layers, key="map_layer")
    if pick:
        meta = data.layer_meta(pick)
        gdf = data.layer(pick)
        only_err = st.toggle("Afficher seulement les entités avec erreur", value=False)
        if only_err and "nb_erreurs" in gdf:
            gdf = gdf[pd.to_numeric(gdf["nb_erreurs"], errors="coerce").fillna(0) > 0]
        deck = data.build_deck(gdf, meta.get("id_var"), meta.get("name_var"))
        if deck is None:
            st.info("Aucune géométrie à afficher pour cette sélection.")
        else:
            st.pydeck_chart(deck, width="stretch", height=560)
            st.caption("🟢 conforme · 🔴 au moins une erreur — survolez un élément pour son identifiant.")

# ---------------------------------- Qualité ----------------------------------
with tab_qual:
    if anom.empty:
        st.success("Aucune anomalie détectée. 🎉")
    else:
        f1, f2, f3, f4 = st.columns(4)
        sel_l = f1.multiselect("Couche", sorted(anom["layer"].dropna().unique()))
        sel_s = f2.multiselect("Gravité", ["error", "warning"], default=["error", "warning"])
        sel_t = f3.multiselect("Type d'anomalie", sorted(anom["type"].dropna().unique()))
        sel_a = f4.multiselect("Agent", sorted(anom["agent"].dropna().unique()))
        d = anom.copy()
        if sel_l: d = d[d["layer"].isin(sel_l)]
        if sel_s: d = d[d["severity"].isin(sel_s)]
        if sel_t: d = d[d["type"].isin(sel_t)]
        if sel_a: d = d[d["agent"].isin(sel_a)]
        st.write(f"**{len(d)}** anomalie(s) sur {len(anom)}")
        a, b = st.columns(2)
        with a:
            st.caption("Par type d'anomalie")
            st.bar_chart(d["type"].value_counts())
        with b:
            st.caption("Par agent")
            st.bar_chart(d["agent"].value_counts())
        st.dataframe(d, hide_index=True, width="stretch", height=420)
        c1, c2 = st.columns(2)
        c1.download_button("⬇ Anomalies filtrées (CSV)", data.to_csv_bytes(d), "anomalies.csv", "text/csv")
        c2.download_button("⬇ Rapport qualité complet (Excel)", data.QUALITY.read_bytes(), "controle_qualite.xlsx",
                           "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")

# ---------------------------------- Données ----------------------------------
with tab_data:
    layers = data.layer_names()
    pick = st.selectbox("Couche", layers, key="data_layer")
    if pick:
        gdf = data.layer(pick)
        tbl = pd.DataFrame(gdf.drop(columns="geometry"))
        tbl = tbl[[c for c in tbl.columns if not c.startswith("x_")]]
        cen = gdf.geometry.representative_point()
        tbl["longitude"], tbl["latitude"] = cen.x.round(6), cen.y.round(6)
        st.write(f"**{len(tbl)}** entité(s) · {tbl.shape[1]} colonnes")
        st.dataframe(tbl, hide_index=True, width="stretch", height=460)
        c1, c2, c3 = st.columns(3)
        c1.download_button("⬇ Cette couche (CSV)", data.to_csv_bytes(tbl), f"{pick}.csv", "text/csv")
        c2.download_button("⬇ Toutes les couches (Excel)", (data.LATEST / "pcdn_donnees.xlsx").read_bytes(), "pcdn_donnees.xlsx",
                           "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        c3.download_button("⬇ GeoPackage (QGIS)", data.GPKG.read_bytes(), "pcdn_donnees.gpkg", "application/geopackage+sqlite3")

# ---------------------------------- Corrections par agent ----------------------------------
with tab_agents:
    st.write("Un classeur par agent, à renvoyer aux équipes de terrain pour correction.")
    files = data.agent_files()
    if not files:
        st.info("Aucune correction à demander : aucun agent n'a d'anomalie.")
    else:
        if not anom.empty:
            st.dataframe(anom.groupby("agent").agg(erreurs=("severity", lambda s: int((s == "error").sum())),
                                                   avertissements=("severity", lambda s: int((s == "warning").sum()))
                                                   ).sort_values("erreurs", ascending=False),
                         width="stretch")
        cols = st.columns(3)
        for i, f in enumerate(files):
            cols[i % 3].download_button(f"⬇ {f.stem}", f.read_bytes(), f.name,
                                        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", key=f"ag_{f.stem}")

# ---------------------------------- Journal ----------------------------------
with tab_log:
    st.subheader("Fichiers traités")
    st.dataframe(journal, hide_index=True, width="stretch")
    st.caption("« NON RECONNU » : le fichier ne correspond à aucune couche du dictionnaire. "
               "« colonnes absentes » : champs du dictionnaire introuvables dans le fichier.")
    st.subheader("Journal du dernier lancement")
    st.code(runner.tail_log(120), language="text")
