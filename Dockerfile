# syntax=docker/dockerfile:1
#####################################################################
# Apache OFBiz - Dockerfile ajustado para Railway
# - Sem mounts de cache/bind/tmpfs (Railway bloqueia)
# - Sem VOLUME no stage final (Railway pede volumes via painel)
# - Garante driver PostgreSQL em /ofbiz/lib-extra (copia de /ofbiz/lib ou baixa do Maven)
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

# Dispara o download do Gradle
RUN ./gradlew --console plain

# Copia o código do OFBiz (inclui lib/ com seus jars)
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

# Build do OFBiz (gera distTar)
RUN ./gradlew --console plain distTar

##############################
# Runtime base
##############################
FROM eclipse-temurin:17@sha256:e8d451f3b5aa6422c2b00bb913cb8d37a55a61934259109d945605c5651de9a6 AS runtimebase

# xsltproc é usado para desabilitar componentes na 1ª execução + curl para fallback do driver
RUN apt-get update \
    && apt-get install -y --no-install-recommends xsltproc curl \
    && rm -rf /var/lib/apt/lists/*

# Usuário dedicado
RUN useradd ofbiz

WORKDIR /ofbiz

# Copia o tar do builder e extrai
COPY --from=builder --chown=ofbiz:ofbiz /builder/build/distributions/ofbiz.tar /tmp/ofbiz.tar
RUN tar --extract --strip-components=1 --file=/tmp/ofbiz.tar && rm /tmp/ofbiz.tar

# Diretórios usuais do OFBiz
RUN mkdir -p /ofbiz/runtime /ofbiz/config /ofbiz/lib-extra && chown -R ofbiz:ofbiz /ofbiz
USER ofbiz

# Copia entityengine.xml e demais configs do diretório "config" para sobrescrever os defaults
COPY --chmod=444 --chown=ofbiz:ofbiz config/ /ofbiz/config/

# Versão do Java no VERSION
COPY --chmod=644 --chown=ofbiz:ofbiz VERSION .
RUN echo '${uiLabelMap.CommonJavaVersion}:' "$(java --version | grep Runtime | sed 's/.*Runtime Environment //; s/ (build.*//;')" >> /ofbiz/VERSION

# Scripts do entrypoint oficial
COPY --chmod=555 docker/docker-entrypoint.sh docker/send_ofbiz_stop_signal.sh .
COPY --chmod=444 docker/disable-component.xslt .
COPY --chmod=444 docker/templates templates

# >>> GARANTE O DRIVER POSTGRES EM /ofbiz/lib-extra (copia se existir; senão baixa)
RUN set -e; \
    mkdir -p /ofbiz/lib-extra; \
    if [ -f /ofbiz/lib/postgresql-42.7.3.jar ]; then \
      cp /ofbiz/lib/postgresql-42.7.3.jar /ofbiz/lib-extra/; \
    else \
      echo "Baixando driver PostgreSQL 42.7.3..."; \
      curl -fsSL -o /ofbiz/lib-extra/postgresql-42.7.3.jar \
        https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.3/postgresql-42.7.3.jar; \
    fi; \
    ls -l /ofbiz/lib-extra/postgresql-42.7.3.jar

##############################
# FINAL para Railway (sem VOLUME)
##############################
FROM runtimebase AS final

USER ofbiz

# (Opcional, recomendado) copie seu entityengine.xml que usa ${sysenv:...}
# Coloque o arquivo no repo em docker/entityengine.xml e descomente a linha abaixo:
# COPY --chmod=444 --chown=ofbiz:ofbiz docker/entityengine.xml /ofbiz/config/entityengine.xml

# Expor HTTPS (8443) e também HTTP (8080) para facilitar teste
EXPOSE 8443
EXPOSE 8080

# ENTRYPOINT oficial do OFBiz
ENTRYPOINT ["/ofbiz/docker-entrypoint.sh"]

# Comando padrão
CMD ["bin/ofbiz"]
