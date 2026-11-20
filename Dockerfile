# Multi-stage build: Java/Maven are needed only while building the image.
FROM maven:3.9.11-eclipse-temurin-21 AS build
WORKDIR /workspace
COPY pom.xml ./
COPY src/main ./src/main
# Unit/Oracle integration tests are run separately with ./mvnw verify.
# A container image build must not require a Docker socket for Testcontainers.
RUN mvn -B -ntp -DskipTests package

# Small runtime with Java 21; Maven and application source are not shipped.
FROM eclipse-temurin:21-jre-noble
WORKDIR /app
COPY --from=build /workspace/target/wallet-api-0.0.1-SNAPSHOT.jar /app/wallet-api.jar
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/wallet-api.jar"]
