#!/bin/bash -eu

# Publish any versions of the docker image not yet pushed to jenkins/jenkins
# Arguments:
#   -n dry run, do not publish images
#   -d debug
#   -f force, will publish images no matter what

set -eou pipefail

. jenkins-support

: "${DOCKERHUB_ORGANISATION:=jenkins4eval}"
: "${DOCKERHUB_REPO:=jenkins}"

JENKINS_REPO="${DOCKERHUB_ORGANISATION}/${DOCKERHUB_REPO}"

cat <<EOF
Docker repository in Use:
* JENKINS_REPO: ${JENKINS_REPO}
EOF

#This is precautionary step to avoid accidental push to official jenkins image
if [[ "$DOCKERHUB_ORGANISATION" == "jenkins" ]]; then
    echo "Experimental docker image should not published to jenkins organization , hence exiting with failure";
    exit 1;
fi

docker-login() {
    docker login --username ${DOCKERHUB_USERNAME} --password ${DOCKERHUB_PASSWORD}
    echo "Docker logged in successfully"
}

docker-enable-experimental() {
    echo '{"experimental": "enabled"}' > ~/.docker/config.json
    echo "Docker experimental enabled successfully"
}

get-local-digest() {
    local tag=$1
    docker inspect --format="{{.Id}}" ${JENKINS_REPO}:${tag}
}

get-remote-digest() {
    local tag=$1
    docker manifest inspect ${JENKINS_REPO}:${tag} | grep -A 10 -o '"config".*' | grep digest | head -1 | cut -d':' -f 2,3 | xargs echo
}

compare-digests() {
    local tag=$1

    local_digest=$(get-local-digest "${tag}")
    remote_digest=$(get-remote-digest "${tag}")

    if [[ "$debug" = true ]]; then
        >&2 echo "DEBUG: Local Digest for ${tag}: ${local_digest}"
        >&2 echo "DEBUG: Remote Digest for ${tag}: ${remote_digest}"
    fi

    if [[ "${local_digest}" == "${remote_digest}" ]]; then
        echo "Images are already the same"
        true
    else
        echo "Images are different!"
        false
    fi
}

sort-versions() {
    if [[ "$(uname)" == 'Darwin' ]]; then
        gsort --version-sort
    else
        sort --version-sort
    fi
}

get-latest-versions() {
    curl -q -fsSL https://repo.jenkins-ci.org/releases/org/jenkins-ci/main/jenkins-war/maven-metadata.xml | grep '<version>.*</version>' | grep -E -o '[0-9]+(\.[0-9]+)+' | sort-versions | uniq | tail -n 20
}

is-published() {
    local version_variant=$1
    local arch=$2
    local tag="${version_variant}-${arch}"
    local opts=""
    if [ "$debug" = true ]; then
        opts="-v"
    fi
    local http_code;
    http_code=$(curl $opts -q -fsL -o /dev/null -w "%{http_code}" "https://hub.docker.com/v2/repositories/${JENKINS_REPO}/tags/${tag}")
    false
    if [ "$http_code" -eq "404" ]; then
        false
    elif [ "$http_code" -eq "200" ]; then
        true
    else
        echo "Received unexpected http code from Docker hub: $http_code"
        exit 1
    fi
}

set-base-image() {
    local variant=$1
    local arch=$2
    local dockerfile
    local BASEIMAGE

    dockerfile="./multiarch/Dockerfile${variant}-${arch}"


    if [[ "$variant" =~ alpine ]]; then
        /bin/cp -f multiarch/Dockerfile.alpine "$dockerfile"
    elif [[ "$variant" =~ slim ]]; then
        /bin/cp -f multiarch/Dockerfile.slim "$dockerfile"
    elif [[ "$variant" =~ debian ]]; then
        /bin/cp -f multiarch/Dockerfile.debian "$dockerfile"
    fi

    # Parse architectures and variants
    if [[ $arch == amd64 ]]; then
        BASEIMAGE="amd64/openjdk:8-jdk"
    elif [[ $arch == arm ]]; then
        BASEIMAGE="arm32v7/openjdk:8-jdk"
    elif [[ $arch == arm64 ]]; then
        BASEIMAGE="arm64v8/openjdk:8-jdk"
    elif [[ $arch == s390x ]]; then
        BASEIMAGE="s390x/openjdk:8-jdk"
    elif [[ $arch == ppc64le ]]; then
        BASEIMAGE="ppc64le/openjdk:8-jdk"
    fi

    # The Alpine image only supports arm32v6 but should work fine on arm32v7
    # hardware - https://github.com/moby/moby/issues/34875
    if [[ $variant =~ alpine && $arch == arm ]]; then
        BASEIMAGE="arm32v6/openjdk:8-jdk-alpine"
    elif [[ $variant =~ alpine ]]; then
        BASEIMAGE="$BASEIMAGE-alpine"
    elif [[ $variant =~ slim ]]; then
        BASEIMAGE="$BASEIMAGE-slim"
    fi

    # Make the Dockerfile after we set the base image
    if [[ "$(uname)" == 'Darwin' ]]; then
        sed -i '' "s|BASEIMAGE|${BASEIMAGE}|g" "$dockerfile"
    else
        sed -i "s|BASEIMAGE|${BASEIMAGE}|g" "$dockerfile"
    fi

}

publish() {
    local version=$1
    local variant=$2
    local arch=$3
    local tag="${version}${variant}-${arch}"
    local sha
    build_opts=(--no-cache --pull)

    if [[ "$dry_run" = true ]]; then
        build_opts=()
    fi

    sha=$(curl -q -fsSL "https://repo.jenkins-ci.org/releases/org/jenkins-ci/main/jenkins-war/${version}/jenkins-war-${version}.war.sha256" )


    set-base-image "$variant" "$arch"

    docker build --file "multiarch/Dockerfile$variant-$arch" \
                 --build-arg "JENKINS_VERSION=$version" \
                 --build-arg "JENKINS_SHA=$sha" \
                 --build-arg "GIT_LFS_VERSION=2.9.2" \
                 --tag "${JENKINS_REPO}:${tag}" \
                 "${build_opts[@]+"${build_opts[@]}"}" .

    # " line to fix syntax highlightning
    if [[ ! "$dry_run" = true ]]; then
        if [[ "$force" = true ]]; then
            docker push "${JENKINS_REPO}:${tag}"
        else
            if [[ ! digest_check=$(compare-digests "${tag}") ]]; then
                docker push "${JENKINS_REPO}:${tag}"
            else
                echo "No pushing image because Image already exist in DockerHub!"
            fi
        fi
    fi
}

cleanup() {
    echo "Cleaning up"
    rm -rf ./multiarch/Dockerfile-*
}

# Process arguments
dry_run=false
debug=false
force=false
variant=""
arch=""

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -n)
        dry_run=true
        ;;
        -d)
        debug=true
        ;;
        -f)
        force=true
        ;;
        -v|--variant)
        variant="-"$2
        shift
        ;;
        -a|--arch)
        arch=$2
        shift
        ;;
        *)
        echo "Unknown option: $key"
        return 1
        ;;
    esac
    shift
done


if [[ "$dry_run" = true ]]; then
    echo "Dry run, will not publish images"
fi

if [[ "$debug" = true ]]; then
    set -x
fi

docker-login
docker-enable-experimental
docker-login

version=""
for version in $(get-latest-versions); do
    if [[ "$force" = true ]]; then
        echo "Force Publishing version(${arch}): ${version}${variant}"
        publish "$version" "$variant" "$arch"
    elif is-published "$version$variant" "$arch"; then
        echo "Tag is already published: ${version}${variant}-${arch}"
    else
        echo "Publishing version(${arch}): ${version}${variant}"
        publish "$version" "$variant" "$arch"
    fi
done

cleanup