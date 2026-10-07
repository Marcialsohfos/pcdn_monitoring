"""Test headless de l'application : python -m pytest tests/ ou python tests/test_app.py"""
import os, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from streamlit.testing.v1 import AppTest

APP = str(Path(__file__).resolve().parent.parent / "app.py")

def run(env):
    for k, v in env.items():
        os.environ[k] = v
    at = AppTest.from_file(APP, default_timeout=60).run()
    return at

def test_sans_mot_de_passe_bloque():
    os.environ.pop("APP_PASSWORD", None); os.environ.pop("PCDN_ALLOW_NO_AUTH", None)
    at = AppTest.from_file(APP, default_timeout=60).run()
    assert not at.exception
    assert any("mot de passe" in e.value.lower() for e in at.error), "doit refuser de démarrer sans APP_PASSWORD"

def test_mauvais_puis_bon_mot_de_passe():
    os.environ["APP_PASSWORD"] = "secret123"
    at = AppTest.from_file(APP, default_timeout=60).run()
    at.text_input[0].set_value("faux").run()
    assert any("incorrect" in e.value.lower() for e in at.error)
    at.text_input[0].set_value("secret123").run()
    assert not at.exception and len(at.tabs) == 6

def test_tableau_de_bord():
    os.environ["APP_PASSWORD"] = "secret123"
    at = AppTest.from_file(APP, default_timeout=60).run()
    at.text_input[0].set_value("secret123").run()
    assert not at.exception, [e.value for e in at.exception]
    labels = [m.label for m in at.metric]
    assert "Entités collectées" in labels and "Conformité" in labels, labels
    assert len(at.selectbox) >= 2          # sélecteurs de couche (carte + données)
    # changement de couche sur la carte et dans les données
    for sb in at.selectbox:
        for opt in sb.options:
            sb.select(opt).run()
            assert not at.exception, (opt, [e.value for e in at.exception])

if __name__ == "__main__":
    import pytest; sys.exit(pytest.main([__file__, "-q"]))
