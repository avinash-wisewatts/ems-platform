# ============================================================================
# WiseWatts EMS Administration Portal
#
# A small server-rendered FastAPI application used for controlled EMS tenant,
# site, gateway, device, identifier, asset, and Grafana onboarding.
# ============================================================================

FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Create an unprivileged runtime user.
RUN groupadd --system emsapp \
    && useradd --system \
        --gid emsapp \
        --home-dir /app \
        --shell /usr/sbin/nologin \
        emsapp

COPY requirements.txt /app/requirements.txt

RUN pip install \
      --no-cache-dir \
      --requirement /app/requirements.txt

COPY src /app/src

RUN chown -R emsapp:emsapp /app

USER emsapp

EXPOSE 8080

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8080"]
