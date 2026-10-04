"""Lecture des livrables produits par le pipeline R (local/output/latest)."""
from __future__ import annotations

import io
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd
import pydeck as pdk
import pyogrio
import streamlit as st

from .runner import DATA_DIR, PIPELINE_DIR

OUT = DATA_DIR / "output"
LATEST = OUT / "latest"
GPKG = LATEST / "pcdn_donnees.gpkg"
QUALITY = LATEST / "controle_qualite.xlsx"
HISTORY = OUT / "suivi_quotidien.csv"
AGENT_DIR = LATEST / "corrections_par_agent"

RED, GREEN = [214, 39, 40, 210], [44, 160, 44, 190]


def _mtime(p: Path) -> float:
    return p.stat().st_mtime if p.exists() else 0.0


def has_results() -> bool:
    return QUALITY.exists() and GPKG.exists()


def results_timestamp() -> str | None:
    if not QUALITY.exists():
        return None
    return pd.Timestamp(_mtime(QUALITY), unit="s", tz="UTC").tz_convert("Africa/Douala").strftime("%d/%m/%Y %H:%M")


@st.cache_data(show_spinner=False)
def _sheet(path: str, sheet: str, mtime: float) -> pd.DataFrame:
    try:
        return pd.read_excel(path, sheet_name=sheet)
    except Exception:
        return pd.DataFrame()


def quality_sheet(sheet: str) -> pd.DataFrame:
    return _sheet(str(QUALITY), sheet, _mtime(QUALITY))


@st.cache_data(show_spinner=False)
def _history(path: str, mtime: float) -> pd.DataFrame:
    if not Path(path).exists():
        return pd.DataFrame()
    df = pd.read_csv(path)
    df["date_execution"] = pd.to_datetime(df["date_execution"])
    return df


def history() -> pd.DataFrame:
    return _history(str(HISTORY), _mtime(HISTORY))


@st.cache_data(show_spinner=False)
def _layers(path: str, mtime: float) -> list[str]:
    return [str(n) for n, _ in pyogrio.list_layers(path)]


def layer_names() -> list[str]:
    return _layers(str(GPKG), _mtime(GPKG)) if GPKG.exists() else []


@st.cache_data(show_spinner="Lecture de la couche…")
def _layer(path: str, layer: str, mtime: float) -> gpd.GeoDataFrame:
    return gpd.read_file(path, layer=layer)


def layer(name: str) -> gpd.GeoDataFrame:
    return _layer(str(GPKG), name, _mtime(GPKG))


@st.cache_data(show_spinner=False)
def _layer_meta(mtime: float) -> pd.DataFrame:
    f = PIPELINE_DIR / "config" / "pcdn_layers.csv"
    return pd.read_csv(f) if f.exists() else pd.DataFrame(columns=["layer", "geometry", "id_var", "name_var"])


def layer_meta(name: str) -> dict:
    m = _layer_meta(0)
    r = m[m["layer"] == name]
    return r.iloc[0].to_dict() if len(r) else {"layer": name, "id_var": None, "name_var": None}


def agent_files() -> list[Path]:
    return sorted(AGENT_DIR.glob("*.xlsx")) if AGENT_DIR.exists() else []


# ---------- exports ----------------------------------------------------------------
def to_csv_bytes(df: pd.DataFrame) -> bytes:
    return df.to_csv(index=False).encode("utf-8-sig")      # BOM : accents corrects dans Excel


def to_xlsx_bytes(sheets: dict[str, pd.DataFrame]) -> bytes:
    buf = io.BytesIO()
    with pd.ExcelWriter(buf, engine="openpyxl") as xw:
        for name, df in sheets.items():
            df.to_excel(xw, sheet_name=name[:31], index=False)
    return buf.getvalue()


# ---------- carte -----------------------------------------------------------------
def build_deck(gdf: gpd.GeoDataFrame, id_col: str | None, name_col: str | None) -> pdk.Deck | None:
    g = gdf[gdf.geometry.notna() & ~gdf.geometry.is_empty].copy()
    if g.empty:
        return None
    err = pd.to_numeric(g.get("nb_erreurs", 0), errors="coerce").fillna(0)
    g["statut"] = np.where(err > 0, "avec erreur(s)", "conforme")
    color = [RED if e > 0 else GREEN for e in err]
    label_id = g[id_col].astype(str) if id_col in g else pd.Series("", index=g.index)
    label_nm = g[name_col].astype(str) if name_col and name_col in g else pd.Series("", index=g.index)
    g["label"] = (label_id.replace("None", "").replace("nan", "") + " " + label_nm.replace("None", "").replace("nan", "")).str.strip()

    layers: list[pdk.Layer] = []
    is_line = g.geom_type.isin(["LineString", "MultiLineString"])
    if is_line.any():
        rows = []
        for (idx, row), c in zip(g[is_line].iterrows(), [color[i] for i, v in enumerate(is_line) if v]):
            geoms = list(row.geometry.geoms) if row.geometry.geom_type == "MultiLineString" else [row.geometry]
            for part in geoms:
                rows.append({"path": [list(p[:2]) for p in part.coords], "color": c, "label": row["label"], "statut": row["statut"]})
        layers.append(pdk.Layer("PathLayer", pd.DataFrame(rows), get_path="path", get_color="color",
                                width_min_pixels=3, pickable=True))
    other = g[~is_line]
    if not other.empty:
        cen = other.geometry.representative_point()
        pts = pd.DataFrame({"lon": cen.x, "lat": cen.y, "label": other["label"], "statut": other["statut"],
                            "color": [color[i] for i, v in enumerate(is_line) if not v]})
        layers.append(pdk.Layer("ScatterplotLayer", pts, get_position="[lon, lat]", get_fill_color="color",
                                get_radius=60, radius_min_pixels=5, radius_max_pixels=14, pickable=True))
    xmin, ymin, xmax, ymax = g.total_bounds
    span = max(xmax - xmin, ymax - ymin, 0.01)
    zoom = float(np.clip(np.log2(360 / span) - 0.5, 3, 15))
    view = pdk.ViewState(latitude=(ymin + ymax) / 2, longitude=(xmin + xmax) / 2, zoom=zoom)
    return pdk.Deck(layers=layers, initial_view_state=view,
                    tooltip={"html": "<b>{label}</b><br/>{statut}"}, map_style="light")
