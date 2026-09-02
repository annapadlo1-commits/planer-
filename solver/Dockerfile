FROM python:3.12.13-slim-bookworm

ARG SOLVER_SOURCE_SHA
ARG SOLVER_BUILD_TIMESTAMP

LABEL org.opencontainers.image.revision="${SOLVER_SOURCE_SHA}" \
      org.opencontainers.image.created="${SOLVER_BUILD_TIMESTAMP}"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src \
    SOLVER_SOURCE_SHA=${SOLVER_SOURCE_SHA} \
    SOLVER_BUILD_TIMESTAMP=${SOLVER_BUILD_TIMESTAMP} \
    SOLVER_CONTRACT_VERSION=SOLVER_CONTRACT_V2

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN python -m pip install --no-cache-dir --disable-pip-version-check -r /app/requirements.txt

COPY pyproject.toml /app/pyproject.toml
COPY src /app/src

USER 65532:65532
ENTRYPOINT ["python", "-m", "grafik_solver"]
