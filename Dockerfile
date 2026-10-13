FROM eclipse-temurin:8-jre

ENV PARAMS="--spring.profiles.active=test"

WORKDIR /app
COPY austin-web/target/austin-web-0.0.1-SNAPSHOT.jar /app/austin.jar

EXPOSE 7777
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/austin.jar $PARAMS"]
