#!/bin/bash
set +x -e -o pipefail
declare -i poll_period=10
declare -i seconds_until_timeout=$((60 * 30))

function print_status {
    P='\033[1;35m'
    N='\033[0m'
    printf "* ${P}${1}${N}\n"
}

PACKAGE="jenkins"

print_status "Building Docker image: $PACKAGE..."

docker build -t $PACKAGE .

print_status "Saving Docker image: $PACKAGE..."

docker save -o $PACKAGE.tar $PACKAGE

print_status "Cloning mesosphere/universe..."

git clone git@github.com:mesosphere/universe

print_status "Building local Universe..."

PACKAGE_PRE=$(echo "${PACKAGE:0:1}" | tr '[:lower:]' '[:upper:]')
rm -rf universe/repo/packages
mkdir -p "universe/repo/packages/${PACKAGE_PRE}/${PACKAGE}"
ln -s $WORKSPACE/package/ "universe/repo/packages/${PACKAGE_PRE}/${PACKAGE}/0"
DOCKER_UUID=$(docker images -q $PACKAGE)

echo $(
    cat package/package.json | \
    jq '.version = "latest"'
) > package/package.json

echo $(                                                                              \
    cat package/resource.json |                                                      \
    jq 'del(.assets.container.docker)' |                                             \
    jq ".assets.container.docker.\"${DOCKER_UUID}\" = \"${PACKAGE}:latest\"" \
) > package/resource.json

./universe/scripts/build.sh

print_status "Building Docker image: mesosphere/universe-server:local-universe..."

DOCKER_TAG="local-universe" universe/docker/server/build.bash

print_status "Saving Docker image: mesosphere/universe-server:local-universe..."

docker save -o local-universe.tar mesosphere/universe-server:local-universe

CLUSTER_ID=$(http \
    --ignore-stdin                                 \
    "https://ccm.mesosphere.com/api/cluster/"      \
    "Authorization:Token ${CCM_AUTH_TOKEN}"        \
    "name=${JOB_NAME##*/}-${BUILD_NUMBER}"         \
    "cluster_desc=${JOB_NAME##*/} ${BUILD_NUMBER}" \
    time=60                                        \
    cloud_provider=0                               \
    region=us-west-2                               \
    channel=testing/master                         \
    template=ee.single-master.cloudformation.json  \
    adminlocation=0.0.0.0/0                        \
    public_agents=0                                \
    private_agents=1                               \
    | jq ".id"
)

print_status "Waiting for DC/OS cluster to form... (ID: ${CLUSTER_ID})"

while (("$seconds_until_timeout" >= "0")); do
    STATUS=$(http \
        --ignore-stdin \
        "https://ccm.mesosphere.com/api/cluster/${CLUSTER_ID}/" \
        "Authorization:Token ${CCM_AUTH_TOKEN}" \
        | jq ".status"
    )

    if [[ ${STATUS} -eq 0 ]]; then
        break
    elif [[ ${STATUS} -eq 7 ]]; then
        print_status "ERROR: cluster creation failed."
        exit 7
    fi

    sleep $poll_period
    let "seconds_until_timeout -= $poll_period"
done

if (("$seconds_until_timeout" <= "0")); then
    print_status "ERROR: timed out waiting for cluster."
    exit 2
fi

CLUSTER_INFO=$(http                                         \
    --ignore-stdin                                          \
    "https://ccm.mesosphere.com/api/cluster/${CLUSTER_ID}/" \
    "Authorization:Token ${CCM_AUTH_TOKEN}"                 \
    | jq -r ".cluster_info"
)

DCOS_URL="http://$(echo "${CLUSTER_INFO}" | jq -r ".DnsAddress")"

ln -s $DOT_SHAKEDOWN ~/.shakedown
TERM=velocity shakedown --stdout all --ssh-key-file $CLI_TEST_SSH_KEY --dcos-url $DCOS_URL

print_status "Deleting DC/OS cluster..."

http                                                        \
    --ignore-stdin                                          \
    DELETE                                                  \
    "https://ccm.mesosphere.com/api/cluster/${CLUSTER_ID}/" \
    "Authorization:Token ${CCM_AUTH_TOKEN}"
