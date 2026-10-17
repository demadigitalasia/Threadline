FROM node:22-alpine AS deps
WORKDIR /app
ENV MIGRATION_DATABASE_URL=postgresql://build:build@127.0.0.1:5432/build
COPY package*.json ./
RUN npm install

FROM node:22-alpine AS build
WORKDIR /app
ENV MIGRATION_DATABASE_URL=postgresql://build:build@127.0.0.1:5432/build
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npx prisma generate && npm run build

FROM node:22-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/prisma ./prisma
COPY --from=build /app/prisma.config.ts ./prisma.config.ts
COPY --from=build /app/package.json ./package.json
EXPOSE 3001
CMD ["sh", "-c", "npx prisma migrate deploy && node dist/main.js"]
