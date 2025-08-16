# syntax=docker/dockerfile:1
#####################################################################
# Apache OFBiz - Dockerfile ajustado para Railway
# - Sem mounts de cache do BuildKit
# - Sem VOLUME no stage final
# - Expõe 8443 (HTTPS) e 8080 (HTTP)
#####################################################################

##############################
# Builder
##############################
FROM eclipse-temurin:17@sha256:e8d451f3b5aa6422c2b00bb913cb8d37a55a61934259109d945605c5651de9a6 AS builder

# Git é usado em tasks do build do OFBiz
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /builder

# Gradle wrapper
COPY --chmod=755 gradle/init-gradle-wrapper.sh gradle/
COPY --chmod=755 gradlew .
RUN sed -i 's/shasum/sha1sum/g' gradle/init-gradle-wrapper.sh
RUN gradle/init-gradle-wrapper.sh

# Dispara o download do Gradle (sem BuildKit cache)
RUN ./gradlew --console plain

# Copia o código do OFBiz
COPY buildSrc/ buildSrc/
COPY applications/ applications/
COPY config/ config/
COPY framework/ framework/
COPY gradle/ gradle/
COPY lib/ lib/
# Regex para plugins existir ou não
COPY plugin[s]/ plugins/
COPY themes/ themes/
COPY APACHE2_HEADER build.gradle common.gradle gradle.properties NOTICE settings.gradle dependencies.gradle .

# Build do OFBiz (gera distTar) - sem mounts de cache
RUN ./gradlew --console plain distTar

##############################
# Runtime base
##############################
FROM eclipse-temurin:17@sha256:e8d451f3b5aa6422c2b00bb913cb8d37a55a61934259109d945605c5651de9a6 AS runtimebase

# xsltproc é usado para desabilitar componentes na 1ª execução
RUN apt-get update \
    && apt-get install -y --no-install-recommends xsltproc \
    && rm -rf /var/lib/apt/lists/*

# Usuário dedicado
RUN useradd ofbiz

# Diretórios de hooks do entrypoint oficial
RUN mkdir -p \
    /docker-entrypoint-hooks/before-config-applied.d \
    /docker-entrypoint-hooks/after-config-applied.d \
    /docker-entrypoint-hooks/before-data-load.d \
    /docker-entrypoint-hooks/after-data-load.d \
    /docker-entrypoint-hooks/additional-data.d \
 && chown -R ofbiz:ofbiz /docker-entrypoint-hooks

USER ofbiz
WORKDIR /ofbiz

# Extrai o tar do OFBiz produzido no build
RUN --mount=type=bind,from=builder,source=/builder/build/distributions/ofbiz.tar,target=/mnt/ofbiz.tar \
    tar --extract --strip-components=1 --file=/mnt/ofbiz.tar

# Diretórios usuais do OFBiz
RUN mkdir /ofbiz/runtime /ofbiz/config /ofbiz/lib-extra

# Versão do Java no VERSION
COPY --chmod=644 --chown=ofbiz:ofbiz VERSION .
RUN echo '${uiLabelMap.CommonJavaVersion}:' "$(java --version | grep Runtime | sed 's/.*Runtime Environment //; s/ (build.*//;')" >> /ofbiz/VERSION

# Scripts do entrypoint oficial
COPY --chmod=555 docker/docker-entrypoint.sh docker/send_ofbiz_stop_signal.sh .
COPY --chmod=444 docker/disable-component.xslt .
COPY --chmod=444 docker/templates templates

##############################
# FINAL para Railway (sem VOLUME)
##############################
FROM runtimebase AS final

USER ofbiz

# (Opcional, recomendado) Se você tiver um entityengine.xml que usa ${sysenv:...},
# descomente a linha abaixo e coloque o arquivo no repo em docker/entityengine.xml:
# COPY --chmod=444 --chown=ofbiz:ofbiz docker/entityengine.xml /ofbiz/config/entityengine.xml

# Expor HTTPS (8443) e também HTTP (8080) para facilitar teste
EXPOSE 8443
EXPOSE 8080
# (Se precisar de AJP/debug, você pode expor 8009/5005 também)

# ENTRYPOINT oficial do OFBiz
ENTRYPOINT ["/ofbiz/docker-entrypoint.sh"]

# Comando padrão
CMD ["bin/ofbiz"]
