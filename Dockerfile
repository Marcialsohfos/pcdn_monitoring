# Image unique : Python (Streamlit) + R (pipeline de contrôle) + bibliothèques géospatiales
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 LANG=C.UTF-8 \
    TZ=Africa/Douala \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      tzdata ca-certificates \
      python3 python3-venv python3-pip \
      r-base-core r-cran-sf r-cran-dplyr r-cran-tidyr r-cran-stringr r-cran-purrr r-cran-tibble \
      r-cran-lubridate r-cran-xml2 r-cran-curl r-cran-openxlsx r-cran-digest \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt
ENV PATH=/opt/venv/bin:$PATH

COPY . .

# Utilisateur non-root ; /data = volume persistant (fichiers FTP, résultats, journaux)
RUN useradd -m -u 1000 app && mkdir -p /data && chown -R app:app /data /app
USER app
ENV PCDN_DATA_DIR=/data
VOLUME /data

EXPOSE 8501
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8501/_stcore/health').status==200 else 1)"

CMD ["streamlit", "run", "app.py", "--server.port=8501", "--server.address=0.0.0.0"]
