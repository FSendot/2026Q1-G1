FROM alpine:3.21 AS build

ARG API_BASE=http://localhost:5000

WORKDIR /site

COPY dashboard/index.html dashboard/app.js ./

RUN printf '%s\n' \
    '// API Gateway endpoint - generated during the dashboard build.' \
    "window.API_BASE = \"${API_BASE}\";" \
    > config.js

FROM scratch AS export

COPY --from=build /site/ /

FROM nginx:1.27-alpine AS runtime

COPY --from=export /index.html /usr/share/nginx/html/index.html
COPY --from=export /app.js /usr/share/nginx/html/app.js
COPY --from=export /config.js /usr/share/nginx/html/config.js

EXPOSE 80
