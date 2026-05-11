FROM node:22-bookworm AS deps
WORKDIR /app/web
COPY web/package*.json ./
RUN npm ci

FROM node:22-bookworm AS builder
WORKDIR /app
COPY --from=deps /app/web/node_modules ./web/node_modules
COPY web ./web
COPY examples ./examples
WORKDIR /app/web
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

FROM node:22-bookworm AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 python3-pip git \
  && rm -rf /var/lib/apt/lists/* \
  && pip3 install --break-system-packages beancount
COPY --from=builder /app/web/.next/standalone ./
COPY --from=builder /app/web/.next/static ./web/.next/static
COPY --from=builder /app/web/public ./web/public
COPY --from=builder /app/examples ./examples
EXPOSE 3000
CMD ["node", "web/server.js"]
