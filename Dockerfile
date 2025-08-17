# syntax=docker/dockerfile:1
#####################################################################
# Apache OFBiz Dockerfile customizado para Railway
#####################################################################

FROM eclipse-temurin:17 AS builder

# Git é necessário para build
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /builder

# Configura gradle wrapper
COPY --chmod=755 gradle/init-gradle-wrapper.sh gradle/
COPY --chmod=755 gradlew .
RUN ["sed", "-i", "s/shasum/sha1sum/g", "gradle/init-gradle-wrapper.sh"]
RUN ["gradle/init-gradle-wrapper.sh"]

# Trigger download da distribuição gradle
RUN --mount=type=cache,id=gradle-cache-builder,target=/root/.gradle \
    ./gradlew --console plain

# Copia fontes do OFBiz
COPY buildSrc/ buildSrc/
COPY applications/ applications/
COPY config/ config/
COPY framework/ framework/
COPY gradle/ gradle/
COPY lib/ lib/
COPY plugin[s]/ plugins/
COPY themes/ themes/
COPY APACHE2_HEADER build.gradle common.gradle gradle.properties NOTICE settings.gradle dependencies.gradle .

# Build OFBiz
RUN --mount=type=cache,id=gradle-cache-builder,target=/root/.gradle \
    --mount=type=tmpfs,target=runtime/tmp \
    ./gradlew --console plain distTar

###################################################################################

FROM eclipse-temurin:17 AS runtimebase

# xsltproc usado pelo entrypoint
RUN apt-get update \
    && apt-get install -y --no-install-recommends xsltproc wget \
    && rm -rf /var/lib/apt/lists/*

RUN useradd ofbiz
USER ofbiz
WORKDIR /ofbiz

# Extrai distribuição gerada
RUN --mount=type=bind,from=builder,source=/builder/build/distributions/ofbiz.tar,target=/mnt/ofbiz.tar \
    tar --extract --strip-components=1 --file=/mnt/ofbiz.tar

# Copia driver PostgreSQL (deixe o .jar dentro de docker/drivers/)
COPY --chmod=444 --chown=ofbiz:ofbiz docker/drivers/postgresql-42.7.3.jar /ofbiz/lib-extra/postgresql-42.7.3.jar

# Copia entityengine.xml e demais configs do diretório "config" para sobrescrever os defaults
COPY --chmod=444 --chown=ofbiz:ofbiz config/ /ofbiz/config/

# Ajusta versão
COPY --chmod=644 --chown=ofbiz:ofbiz VERSION .
RUN echo 'JavaVersion:' "$(java --version | grep Runtime | sed 's/.*Runtime Environment //; s/ (build.*//;')" >> /ofbiz/VERSION

# Scripts de entrada originais do OFBiz
COPY --chmod=555 docker/docker-entrypoint.sh docker/send_ofbiz_stop_signal.sh .
COPY --chmod=444 docker/disable-component.xslt .
COPY --chmod=444 docker/templates templates

EXPOSE 8443
EXPOSE 8080
EXPOSE 5005

ENTRYPOINT ["/ofbiz/docker-entrypoint.sh"]
CMD ["bin/ofbiz"]

###################################################################################
# Final image
FROM runtimebase AS final

# Nada extra aqui, apenas expõe os mesmos ports
EXPOSE 8443
EXPOSE 8080
EXPOSE 5005

CMD ["bin/ofbiz"]
