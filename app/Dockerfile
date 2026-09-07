# syntax=docker/dockerfile:1

# Pin to SHA for reproducibility. Refresh with:
#   docker pull python:3.11-slim-bookworm
#   docker inspect --format='{{index .RepoDigests 0}}' python:3.11-slim-bookworm
FROM python:3.11-slim-bookworm@sha256:528257d48c1da0dcecc2e725d1ae34498d60c965f1241e39cd6a85a8859bdf84 AS builder

WORKDIR /build
COPY app/requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --prefix=/install -r requirements.txt

# Pin to SHA for reproducibility. Refresh with:
#   docker pull gcr.io/distroless/python3-debian12:nonroot
#   docker inspect --format='{{index .RepoDigests 0}}' gcr.io/distroless/python3-debian12:nonroot
FROM gcr.io/distroless/python3-debian12:nonroot@sha256:7d1042ce588ab97019fe95c24ffca7bc5a82ccdac572511d5e09bda4435c89c5

ARG GIT_SHA=unknown
LABEL org.opencontainers.image.source="https://github.com/AhmedMHCodeLab/Aegis" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.title="Aegis Compliance Checkpoint"

COPY --from=builder /install /usr/local
COPY app/ /app/

WORKDIR /app
ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/usr/local/lib/python3.11/site-packages
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')"]

ENTRYPOINT ["python", "-m", "uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8080"]
