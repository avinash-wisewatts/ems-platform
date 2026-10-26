# ============================================================================
# WiseWatts EMS web application shell (Phase 8 frontend foundation).
#
# Produces an INDEPENDENT, immutably-taggable artifact: the built static
# bundle served by nginx. It is deployed and rolled back separately from the
# admin-portal / live-telemetry image -- see
# docs/operations/PHASE8_FRONTEND_DEPLOYMENT.md.
#
# The bundle is emitted under the /app/ base path so it can be served
# same-origin behind the existing admin-portal deployment boundary: by running
# this image as the dedicated `ems-web` container that the admin-portal
# proxies /app/* to (scripts/release/deploy_web.sh), or -- the fallback -- by
# extracting it into the admin-portal container's app/src/spa/ directory
# (scripts/release/deploy_web_bundle.sh). No CORS, no second auth cookie.
# ============================================================================

# ---- build ----------------------------------------------------------------
FROM node:20-bookworm-slim AS build
WORKDIR /web

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY tsconfig.json vite.config.ts index.html vitest.setup.ts ./
COPY src ./src

# Type-check + lint + unit tests are gates in CI (see ci.yml). The image build
# itself only produces the production bundle.
RUN npm run build

# ---- runtime (standalone) ----------------------------------------------------
FROM nginx:1.27-alpine AS runtime

# SPA fallback + long-cache for hashed assets, all under /app/.
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /web/dist /usr/share/nginx/html/app

# A tarball of just the bundle, for the "extract into the admin-portal
# container" deployment path (docker create + docker cp, or an init copy).
RUN cd /usr/share/nginx/html/app && tar czf /srv-spa.tgz .

# Provenance: CI passes the source commit (--build-arg GIT_SHA=<sha>), the same
# SHA the image is tagged with; deploy_web.sh refuses an image whose label
# disagrees with its tag.
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.title="ems-web"

EXPOSE 80
HEALTHCHECK --interval=20s --timeout=5s --retries=5 \
  CMD wget -q -O - http://127.0.0.1:80/app/ >/dev/null 2>&1 || exit 1
