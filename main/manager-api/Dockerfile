# syntax=docker/dockerfile:1.6

FROM maven:3.9.9-eclipse-temurin-21 AS builder
WORKDIR /build
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B -q dependency:go-offline
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -B clean package -Dmaven.test.skip=true \
    && cp target/xiaozhi-esp32-api.jar /build/app.jar

FROM bellsoft/liberica-runtime-container:jre-21-glibc
WORKDIR /app
RUN apk add --no-cache fontconfig ttf-dejavu \
    && rm -rf /var/cache/apk/* \
    && fc-cache -f
ENV TZ=Asia/Shanghai \
    SPRING_PROFILES_ACTIVE=docker \
    JAVA_OPTS=""
COPY --from=builder /build/app.jar /app/app.jar
EXPOSE 8002
ENTRYPOINT ["sh","-c","exec java $JAVA_OPTS -jar /app/app.jar"]
