FROM node:26-alpine
WORKDIR /schema
COPY package.json ./
RUN npm install --omit=dev
COPY migrate.mjs grants.sql ./
COPY migrations ./migrations
CMD ["node", "migrate.mjs"]
