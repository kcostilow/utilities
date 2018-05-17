#/bin/sh
#
# kcostilow May 2018
# Script to control Docker/Spring boot on any server, generically, sort of like a makefile.
#
# This represents a set of commands and tasks that I found myself running all the time in various
# different 1-line scripts. I got tired of edting them all for different projects, so this lets
# you save settings as env variables and use them generically.

envfile='env.sh'
dockerfile='Dockerfile'

source $envfile

# lower-cased environment variable names for configure()
declare -a keys=('jenkins_host' 'jenkins_project' 'jenkins_artifact' 'jenkins_version' 'jenkins_username' 'docker_image_name' 'docker_work_dir' 'spring_profiles_active')

# prompts for environment variables with existing values as defaults,
# then writes and re-sources that file
configure() {
    declare -A NV
    for k in ${keys[@]}; do
        ename=${k^^}
        dflt=`printenv $ename`
        echo "$k [$dflt] :"
        read newvalue
        newvalue=${newvalue:-$dflt}
        NV[$ename]=$newvalue
    done

    # echo "${!NV[@]}"
    echo "#!/bin/sh" > $envfile
    for k in "${!NV[@]}"; do
        echo "export $k=${NV[$k]}";
    done >> $envfile
    echo "$envfile written"
    source $envfile
}

# Create a standard Dockerfile
# NOTE no ports exposed!
make_docker_file() {
cat > $dockerfile << EOD
FROM frolvlad/alpine-oraclejdk8:slim

WORKDIR ${DOCKER_WORK_DIR}

ADD ${JENKINS_ARTIFACT}-${JENKINS_VERSION}.jar ${JENKINS_ARTIFACT}-${JENKINS_VERSION}.jar

# EXPOSE 8443

RUN sh -c 'touch ${WORKDIR}/${JENKINS_ARTIFACT}-${JENKINS_VERSION}.jar'

ENTRYPOINT ["java","-Djava.security.egd=file:/dev/./urandom","-jar","${DOCKER_WORK_DIR}/${JENKINS_ARTIFACT}-${JENKINS_VERSION}.jar"]
EOD
    echo "$dockerfile written"
}

# Get the jar from jenkins
fetch_jar() {
    curl --user ${JENKINS_USERNAME} -o ${JENKINS_ARTIFACT}-${JENKINS_VERSION}.jar ${JENKINS_HOST}/job/${JENKINS_PROJECT}/lastSuccessfulBuild/artifact/target/${JENKINS_ARTIFACT}-${JENKINS_VERSION}.jar
    filetype=`/bin/file -b ${JENKINS_ARTIFACT}-${JENKINS_VERSION}.jar`
echo "filetype=$filetype"
    if [[ "$filetype" == *"ASCII"* ]]; then
        cat ${JENKINS_ARTIFACT}-${JENKINS_VERSION}.jar
        exit
    fi
}

# build the docker image
build() {
    docker build -t ${JENKINS_ARTIFACT}:${JENKINS_VERSION} .
}

# attach to a running docker
attach() {
    docker exec -it ${JENKINS_ARTIFACT} /bin/sh
}

# get logs into local logs folder, assuming it exists in the Docker vm
get_logs() {
    docker cp ${JENKINS_ARTIFACT}:${DOCKER_WORK_DIR}/logs .
}

# helper to extract a docker image ID by name
get_image_id() {
    docker_image_id=`docker images --format "{{.ID}}" --filter=reference="${DOCKER_IMAGE_NAME}"`
    if [ -n "$docker_image_id" ]
    then
       echo "${DOCKER_IMAGE_NAME} Image ID=${docker_image_id}"
    fi
}

# helper to determine if docker container is running or exists idle
is_running() {
    docker_running_container_id=`docker ps --filter name=${DOCKER_IMAGE_NAME} --format "{{.ID}}"`
    docker_idle_container_id=`docker ps -a --filter name=${DOCKER_IMAGE_NAME} --format "{{.ID}}"`
}

# helper to stop docker container
stop_docker() {
    is_running
    if [ -n "$docker_running_container_id" ]
    then
        `docker stop $docker_running_container_id`
        echo "Stopped Docker Container $docker_running_container_id"
    else
        echo "Docker Container $docker_running_container_id was not running"
    fi
}

# helper to remove previouis jar
# TODO maybe just rename it to .prev?
remove_jar() {
    rm -f ${JENKINS_ARTIFACT}-${JENKINS_VERSION}.jar
    echo "Removed ${JENKINS_ARTIFACT}-${JENKINS_VERSION}.jar"
}

# Remove docker cntainer in preparation for a rebuild
remove_container() {
    stop_docker
    if [ -n "$docker_idle_container_id" ]
    then
        `docker rm $docker_idle_container_id`
        echo "Removed Docker Container $docker_idle_container_id"
    else
        echo "Docker Container $docker_idle_container_id not found"
    fi
}

# Remove docker image in preparation for a rebuild
remove_image() {
    remove_container
    get_image_id
    if [ -n "$docker_image_id" ]
    then
        docker rmi $docker_image_id
        echo "Removed Docker Image $docker_image_id"
    else
        echo "Docker Image $docker_image_id not found"
    fi
}

# build the image
build_image() {
    make_docker_file
    docker_built_image_id=`docker build -t ${DOCKER_IMAGE_NAME}:${JENKINS_VERSION} .`
    echo "Built $docker_built_image_id"
}

# MAIN

PS3="Choose action#: "
options=(info config clean fetch makedockerfile build install daemon console getlogs "tail" quit)
while true
do
select option in "${options[@]}"
    do
        case $option in

        info)
            for k in ${keys[@]}; do
                ename=${k^^}
                echo "$ename = `printenv $ename`"
            done
            echo `file ${JENKINS_ARTIFACT}-${JENKINS_VERSION}.jar`
            get_image_id
            is_running
            if [[ -z "$docker_running_container_id" ]]
            then
                echo "$DOCKER_IMAGE_NAME Container ID: $docker_idle_container_id NOT RUNNING"
            else
                echo "$DOCKER_IMAGE_NAME Container ID: $docker_running_container_id RUNNING"
            fi
            break;;
        fetch)  echo "Fetching"
            fetch_jar
            break;;
        clean)  echo "Cleaning"
            remove_jar
            remove_image
            break;;
        build)  echo "Building"
            build_image
            break;;
        install)  echo "Installing"
            remove_jar
            remove_image
            fetch_jar
            build_image
            echo -e "To run as conosle:\n    docker run --name ${JENKINS_ARTIFACT} --restart always -d -e SPRING_PROFILES_ACTIVE=${SPRING_PROFILES_ACTIVE} ${JENKINS_ARTIFACT}:${JENKINS_VERSION}"
            echo -e "To run as daemon:\n    docker run --name ${JENKINS_ARTIFACT} --rm -e SPRING_PROFILES_ACTIVE=${SPRING_PROFILES_ACTIVE} ${JENKINS_ARTIFACT}:${JENKINS_VERSION}"
            break;;
        daemon)
            docker run --name ${JENKINS_ARTIFACT} --restart always -d -e SPRING_PROFILES_ACTIVE=${SPRING_PROFILES_ACTIVE} ${JENKINS_ARTIFACT}:${JENKINS_VERSION}
            break;;
        console)
            docker run --name ${JENKINS_ARTIFACT} --rm -e SPRING_PROFILES_ACTIVE=${SPRING_PROFILES_ACTIVE} ${JENKINS_ARTIFACT}:${JENKINS_VERSION}
            break;;
        makedockerfile)  echo "Making $dockerfile"
            make_docker_file
            break;;
        getlogs)  echo "fetch log files"
            get_logs
            ls logs
            break;;
        tail)  echo "tailing docker stdout"
            docker logs "${JENKINS_ARTIFACT}"
            echo "Use this to follow in your own shell:  docker logs -f ${JENKINS_ARTIFACT}"
            break;;
        config)  echo "Configuring"
            configure
            break;;
        quit)
            exit
            break;;
        esac
    done
    echo -e "\n"
done
