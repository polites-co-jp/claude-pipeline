FROM node:20-slim

WORKDIR /app/web

COPY web/package.json web/package-lock.json* ./
RUN npm install --production

COPY web/server.js ./server.js
COPY web/public/ ./public/

ENV PORT=3000
ENV BASE_DIR=/app

EXPOSE 3000

CMD ["node", "server.js"]
