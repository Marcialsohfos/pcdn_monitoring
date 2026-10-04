"""Protection par mot de passe (APP_PASSWORD dans les secrets Streamlit ou l'environnement)."""
from __future__ import annotations

import hmac
import os

import streamlit as st


def _expected() -> str | None:
    try:
        v = st.secrets.get("APP_PASSWORD")
    except Exception:  # pas de fichier secrets.toml
        v = None
    return v or os.getenv("APP_PASSWORD") or None


def require_login() -> None:
    """Bloque l'application tant que le mot de passe n'est pas saisi."""
    expected = _expected()
    if not expected:
        if os.getenv("PCDN_ALLOW_NO_AUTH") == "1":
            st.sidebar.warning("Accès non protégé (mode développement).")
            return
        st.error("Aucun mot de passe configuré. Définissez `APP_PASSWORD` (voir README) avant de déployer.")
        st.stop()
    if st.session_state.get("authenticated"):
        return
    st.title("🛤️ PCDN – Monitoring des données géospatiales")
    pwd = st.text_input("Mot de passe", type="password")
    if pwd:
        if hmac.compare_digest(pwd.encode(), expected.encode()):
            st.session_state["authenticated"] = True
            st.rerun()
        else:
            st.error("Mot de passe incorrect.")
    st.stop()
