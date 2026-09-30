FROM debian:12-slim

# Leave empty to resolve the latest release at build time, or pin:
#   --build-arg SEMERU_TAG=jdk-21.0.12.15 --build-arg MAVEN_VERSION=3.9.11
ARG SEMERU_TAG=""
ARG MAVEN_VERSION=""

ENV JAVA_HOME=/opt/java/semeru \
  MAVEN_HOME=/opt/maven \
  LANG=C.UTF-8
ENV PATH="${JAVA_HOME}/bin:${MAVEN_HOME}/bin:${PATH}"

RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends ca-certificates curl; \
  rm -rf /var/lib/apt/lists/*

# --- Semeru Open Edition JDK 21 (OpenJ9) ---
RUN set -eux; \
  case "$(dpkg --print-architecture)" in \
  amd64)   ARCH=x64 ;; \
  arm64)   ARCH=aarch64 ;; \
  ppc64el) ARCH=ppc64le ;; \
  s390x)   ARCH=s390x ;; \
  *) echo "unsupported architecture" >&2; exit 1 ;; \
  esac; \
  REPO=https://github.com/ibmruntimes/semeru21-binaries; \
  TAG="${SEMERU_TAG}"; \
  if [ -z "$TAG" ]; then \
  TAG="$(curl -fsSI "$REPO/releases/latest" | sed -n 's#^location: .*/tag/\([^[:space:]]*\).*#\1#Ip')"; \
  fi; \
  FILE="$(curl -fsSL "$REPO/releases/expanded_assets/$TAG" \
  | grep -o "ibm-semeru-open-jdk_${ARCH}_linux_[^\"/]*\.tar\.gz" | head -1)"; \
  test -n "$FILE"; \
  cd /tmp; \
  curl -fsSLO "$REPO/releases/download/$TAG/$FILE"; \
  curl -fsSLO "$REPO/releases/download/$TAG/$FILE.sha256.txt"; \
  sha256sum -c "$FILE.sha256.txt"; \
  mkdir -p "$JAVA_HOME"; \
  tar -xzf "$FILE" -C "$JAVA_HOME" --strip-components=1; \
  rm -f "$FILE" "$FILE.sha256.txt"

# --- Apache Maven (latest GA release) ---
RUN set -eux; \
  V="${MAVEN_VERSION}"; \
  if [ -z "$V" ]; then \
  V="$(curl -fsSL https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/maven-metadata.xml \
  | grep -o '<version>[^<]*</version>' | sed 's/<[^>]*>//g' \
  | grep -Eiv 'alpha|beta|rc' | sort -V | tail -1)"; \
  fi; \
  BASE="https://archive.apache.org/dist/maven/maven-${V%%.*}/${V}/binaries"; \
  FILE="apache-maven-${V}-bin.tar.gz"; \
  cd /tmp; \
  curl -fsSLO "$BASE/$FILE"; \
  echo "$(curl -fsSL "$BASE/$FILE.sha512" | cut -d' ' -f1)  $FILE" | sha512sum -c -; \
  mkdir -p "$MAVEN_HOME"; \
  tar -xzf "$FILE" -C "$MAVEN_HOME" --strip-components=1; \
  rm -f "$FILE"

RUN java -version && mvn -version
