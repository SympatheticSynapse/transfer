mkdir /tmp/rt && cd /tmp/rt && git init -q
printf 'FROM debian:12-slim\n# renovate: datasource=git-tags depName=https://github.com/ibmruntimes/semeru21-binaries versioning=loose extractVersion=^jdk-(?<version>[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+)$\nARG SEMERU_VERSION=21.0.12.10\n' > Dockerfile
echo '{"extends":["customManagers:dockerfileVersions"]}' > renovate.json
git add -A && git -c user.name=t -c user.email=t@t commit -qm t
LOG_LEVEL=debug renovate --platform=local --dry-run=lookup 2>&1 | grep -A8 -E '"updates"|"warnings"'


# maven
mkdir /tmp/rt-mvn && cd /tmp/rt-mvn && git init -q
printf 'FROM debian:12-slim\n# renovate: datasource=maven depName=org.apache.maven:apache-maven\nARG MAVEN_VERSION=3.9.0\n' > Dockerfile
echo '{"extends":["customManagers:dockerfileVersions"]}' > renovate.json
git add -A && git -c user.name=t -c user.email=t@t commit -qm t
env -u RENOVATE_REPOSITORIES -u RENOVATE_CONFIG_FILE LOG_LEVEL=debug renovate --platform=local --dry-run=lookup 2>&1 | grep -A8 -E '"updates"|"warnings"'
