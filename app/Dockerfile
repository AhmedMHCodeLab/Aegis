# Builder must match the distroless runtime interpreter (Debian 12 ships Python 3.11).
FROM python:3.11-slim AS builder

WORKDIR /build
COPY app/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# :nonroot runs as uid 65532. The default tag runs as root.
FROM gcr.io/distroless/python3-debian12:nonroot

COPY --from=builder /install /usr/local
COPY app/ /app/

WORKDIR /app
# Distroless strips site-packages from sys.path, so it must be named explicitly.
ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/usr/local/lib/python3.11/site-packages
EXPOSE 8080

ENTRYPOINT ["python", "-m", "uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8080"]
