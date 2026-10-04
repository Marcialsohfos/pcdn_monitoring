"""Lancement du pipeline R (run_daily.R) depuis Python, avec verrou et état du dernier lancement."""
from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PIPELINE_DIR = Path(os.getenv("PCDN_PIPELINE_DIR", ROOT / "pipeline")).resolve()
DATA_DIR = Path(os.getenv("PCDN_DATA_DIR", ROOT / "data")).resolve()
RSCRIPT = os.getenv("PCDN_RSCRIPT", "Rscript")          # Windows : chemin complet vers Rscript.exe
LOCK_TIMEOUT_MIN = int(os.getenv("PCDN_LOCK_TIMEOUT_MIN", "120"))

LOCK = DATA_DIR / "run.lock"
STATE = DATA_DIR / "last_run.json"
STDOUT_LOG = DATA_DIR / "logs" / "last_run_stdout.log"

EXIT_MEANING = {
    0: "Terminé avec succès",
    1: "Terminé : aucune donnée exploitable trouvée",
    2: "Terminé, mais le FTP était injoignable (fichiers déjà présents traités)",
}


def _now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def lock_info() -> dict | None:
    """Contenu du verrou s'il est valide ; supprime un verrou périmé."""
    if not LOCK.exists():
        return None
    try:
        info = json.loads(LOCK.read_text(encoding="utf-8"))
        age_min = (time.time() - LOCK.stat().st_mtime) / 60
    except Exception:
        LOCK.unlink(missing_ok=True)
        return None
    if age_min > LOCK_TIMEOUT_MIN:
        LOCK.unlink(missing_ok=True)
        return None
    return info


def is_running() -> bool:
    return lock_info() is not None


def force_unlock() -> None:
    LOCK.unlink(missing_ok=True)


def last_run() -> dict | None:
    if not STATE.exists():
        return None
    try:
        return json.loads(STATE.read_text(encoding="utf-8"))
    except Exception:
        return None


def ftp_configured() -> dict[str, bool]:
    """Indique quelles variables FTP sont renseignées (sans jamais afficher leur valeur)."""
    return {k: bool(os.getenv(k)) for k in ("PCDN_FTP_HOST", "PCDN_FTP_USER", "PCDN_FTP_PWD")}


def run_blocking(skip_ftp: bool = False, trigger: str = "manuel") -> dict:
    """Exécute le pipeline et attend la fin. Renvoie l'état du lancement."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    STDOUT_LOG.parent.mkdir(parents=True, exist_ok=True)
    try:   # création atomique : un seul lancement à la fois
        fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        if lock_info() is not None:
            return {"started": _now(), "returncode": None, "message": "Un lancement est déjà en cours", "trigger": trigger}
        fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump({"started": _now(), "trigger": trigger, "skip_ftp": skip_ftp}, fh)

    state = {"started": _now(), "trigger": trigger, "skip_ftp": skip_ftp, "returncode": None, "finished": None, "message": ""}
    try:
        cmd = [RSCRIPT, "run_daily.R"] + (["--skip-ftp"] if skip_ftp else [])
        env = {**os.environ, "PCDN_DATA_DIR": str(DATA_DIR), "LC_ALL": os.getenv("LC_ALL", "C.UTF-8")}
        with open(STDOUT_LOG, "w", encoding="utf-8") as out:
            proc = subprocess.run(cmd, cwd=PIPELINE_DIR, env=env, stdout=out, stderr=subprocess.STDOUT, timeout=LOCK_TIMEOUT_MIN * 60)
        state["returncode"] = proc.returncode
        state["message"] = EXIT_MEANING.get(proc.returncode, f"Échec (code {proc.returncode}) : voir le journal")
    except FileNotFoundError:
        state.update(returncode=-1, message=f"Rscript introuvable (« {RSCRIPT} ») : installez R ou renseignez PCDN_RSCRIPT")
    except subprocess.TimeoutExpired:
        state.update(returncode=-2, message=f"Interrompu : durée supérieure à {LOCK_TIMEOUT_MIN} min")
    except Exception as e:  # noqa: BLE001
        state.update(returncode=-3, message=f"Erreur inattendue : {e}")
    finally:
        state["finished"] = _now()
        STATE.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
        LOCK.unlink(missing_ok=True)
    return state


def start_background(skip_ftp: bool = False, trigger: str = "manuel") -> tuple[bool, str]:
    if is_running():
        return False, "Un lancement est déjà en cours."
    threading.Thread(target=run_blocking, args=(skip_ftp, trigger), daemon=True).start()
    time.sleep(0.4)   # laisse le temps au verrou d'être posé
    return True, "Lancement démarré."


def tail_log(n: int = 80) -> str:
    """Dernières lignes du journal du pipeline (journal R du jour, sinon sortie standard)."""
    logs = DATA_DIR / "logs"
    cands = sorted(logs.glob("run_*.log")) if logs.exists() else []
    src = cands[-1] if cands else (STDOUT_LOG if STDOUT_LOG.exists() else None)
    if src is None:
        return "Aucun journal disponible."
    lines = src.read_text(encoding="utf-8", errors="replace").splitlines()
    return "\n".join(lines[-n:])
