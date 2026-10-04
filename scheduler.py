"""Planificateur quotidien : lance le pipeline chaque jour à PCDN_RUN_TIME (HH:MM, fuseau TZ)."""
import os
import time
from datetime import datetime, timedelta

from pcdn_app import runner

RUN_TIME = os.getenv("PCDN_RUN_TIME", "06:00")
RUN_ON_START = os.getenv("PCDN_RUN_ON_START", "0") == "1"


def next_run(now: datetime) -> datetime:
    h, m = (int(x) for x in RUN_TIME.split(":"))
    t = now.replace(hour=h, minute=m, second=0, microsecond=0)
    return t if t > now else t + timedelta(days=1)


def main() -> None:
    print(f"[scheduler] lancement quotidien à {RUN_TIME} (TZ={os.getenv('TZ', 'système')})", flush=True)
    if RUN_ON_START:
        print("[scheduler] lancement initial", flush=True)
        print("[scheduler]", runner.run_blocking(trigger="planificateur").get("message"), flush=True)
    while True:
        target = next_run(datetime.now())
        print(f"[scheduler] prochain lancement : {target:%Y-%m-%d %H:%M}", flush=True)
        while datetime.now() < target:
            time.sleep(30)
        res = runner.run_blocking(trigger="planificateur")
        print(f"[scheduler] {datetime.now():%H:%M} -> {res.get('message')}", flush=True)
        time.sleep(61)   # évite un double déclenchement dans la même minute


if __name__ == "__main__":
    main()
