# syntax=docker/dockerfile:1.6

FROM node:18-alpine AS builder
WORKDIR /build
ARG VUE_APP_API_BASE_URL=https://mc.gzfayusi.com/xiaozhi
ENV VUE_APP_API_BASE_URL=${VUE_APP_API_BASE_URL}
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --no-audit --no-fund
COPY . .
RUN npm run build

FROM nginx:1.27-alpine
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/manager-web.conf
COPY --from=builder /build/dist /usr/share/nginx/html
EXPOSE 8001
CMD ["nginx", "-g", "daemon off;"]
