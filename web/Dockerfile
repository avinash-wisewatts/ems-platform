# ============================================================================
# WiseWatts EMS web application shell (Phase 8 frontend foundation).
#
# Produces an INDEPENDENT, immutably-taggable artifact: the built static
# bundle served by nginx. It is deployed and rolled back separately from the
# admin-portal / live-telemetry image -- see
# docs/operations/PHASE8_FRONTEND_DEPLOYMENT.md.
#
# The bundle is emitted under the /app/ base path so it can be served
# same-origin behind the existing admin-portal deployment boundary (either by
# extracting it into the admin-portal container's app/src/spa/ directory, or
# by running this image as a sidecar). No CORS, no second auth cookie.
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

EXPOSE 80
HEALTHCHECK --interval=20s --timeout=5s --retries=5 \
  CMD wget -q -O - http://localhost:80/app/ >/dev/null 2>&1 || exit 1
