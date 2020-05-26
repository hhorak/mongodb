# Functions for tests for the MongoDB image in OpenShift.
#
# IMAGE_NAME specifies a name of the candidate image used for testing.
# The image has to be available before this script is executed.
#

THISDIR=$(dirname ${BASH_SOURCE[0]})

source ${THISDIR}/test-lib.sh
source ${THISDIR}/test-lib-openshift.sh

function test_mongodb_integration() {
  local image_name=$1
  local VERSION=$2
  local import_image=$3
  local service_name=${import_image##*/}
  ct_os_template_exists mongodb-ephemeral && t=mongodb-ephemeral || t=mongodb-persistent
  ct_os_test_template_app_func "${image_name}" \
                               "${t}" \
                               "${service_name}" \
                               "ct_os_check_cmd_internal '${import_image}' '${service_name}' \"mongo <IP>/testdb -u testu -ptestp --eval 'quit()'\" '.*' 120" \
                               "-p MONGODB_VERSION=${VERSION} \
                                -p DATABASE_SERVICE_NAME="${service_name}-testing" \
                                -p MONGODB_USER=testu \
                                -p MONGODB_PASSWORD=testp \
                                -p MONGODB_DATABASE=testdb" "" "${import_image}"
}

# get_version_number [version_string]
# --------------------
# Extracts the version number from provided version string.
# e.g. 3.0upg => 3.0
function get_version_number() {
  echo $1 | sed -e 's/^\([0-9.]*\).*/\1/'
}

function mongo_cmd() {
    docker run --rm ${CONTAINER_ARGS:-} $IMAGE_NAME mongo ${shell_args:-} $CONTAINER_IP/$DB -u "$USER" -p"$PASS" --eval "${@}"
}

function mongo_admin_cmd() {
    docker run --rm ${CONTAINER_ARGS:-} $IMAGE_NAME mongo ${shell_args:-} $CONTAINER_IP/admin -u admin -p"$ADMIN_PASS" --eval "${@}"
}

function test_connection() {
    local name=$1 ; shift
    CONTAINER_IP=$(ct_get_cip $name)
    echo "  Testing MongoDB connection to $CONTAINER_IP..."
    local max_attempts=20
    local sleep_time=2
    for i in $(seq $max_attempts); do
        echo "    Trying to connect..."
        set +e
        mongo_cmd "db.getSiblingDB('test_database');"
        status=$?
        set -e
        if [ $status -eq 0 ]; then
            echo "  Success!"
            return 0
        fi
        sleep $sleep_time
    done
    echo "  Giving up: Failed to connect. Logs:"
    docker logs $(ct_get_cid $name)
    return 1
}

function test_config_option() {
    local env_var=$1 ; shift
    local env_val=$1 ; shift
    local config_part=$1 ; shift

    local name="configuration_${env_var}"

    # If $value is a string, it needs to be in simple quotes ''.
    CONTAINER_ARGS="
-e MONGODB_DATABASE=db
-e MONGODB_USER=user
-e MONGODB_PASSWORD=password
-e MONGODB_ADMIN_PASSWORD=adminPassword
-e $env_var=${env_val}
"
    ct_create_container $name

    # need to set these because `mongo_cmd` relies on global variables
    USER=user
    PASS=password
    DB=db

    test_connection ${name}

    # If nothing is found, grep returns 1 and test fails.
    docker exec $(ct_get_cid $name) bash -c "cat /etc/mongod.conf" | grep -q "${config_part}"

    docker stop $(ct_get_cid ${name})
}

function assert_login_access() {
    local USER=$1 ; shift
    local PASS=$1 ; shift
    local success=$1 ; shift

    if mongo_cmd 'db.version()' ; then
        if $success ; then
            echo "    $USER($PASS) access granted as expected"
            return
        fi
    else
        if ! $success ; then
            echo "    $USER($PASS) access denied as expected"
            return
        fi
    fi
    echo "    $USER($PASS) login assertion failed"
    exit 1
}

function test_general() {
    local name=$1 ; shift
    CONTAINER_ARGS="-e MONGODB_USER=$USER -e MONGODB_PASSWORD=$PASS -e MONGODB_DATABASE=$DB"
    if [ -v ADMIN_PASS ]; then
        CONTAINER_ARGS="$CONTAINER_ARGS -e MONGODB_ADMIN_PASSWORD=$ADMIN_PASS"
    fi
    ct_create_container $name
    CONTAINER_IP=$(ct_get_cip $name)
    test_connection $name
    echo "  Testing scl usage"
    ct_scl_usage_old "${name}_scl" 'mongo --version' $(get_version_number $VERSION)
    test_mongo $name
}

function _s2i_test_image() {
    local name="$1"
    local mount_opts="$2"
    echo "    Testing s2i app image environment variable checking"
    ct_assert_container_creation_fails $mount_opts -e MONGODB_USER=user -e MONGODB_PASSWORD=password -e MONGODB_DATABASE=db -e MONGODB_ADMIN_PASSWORD=adminPass
    ct_assert_container_creation_fails $mount_opts -e MONGODB_USER=user -e MONGODB_PASSWORD=password -e MONGODB_DATABASE=db -e MONGODB_ADMIN_PASSWORD=adminPass -e MONGODB_BACKUP_USER=backup -e MONGODB_BACKUP_PASSWORD=pass || [ $? -eq 1 ]

    echo "    Testing s2i app image with correct configuration"

    CONTAINER_ARGS="
-e MONGODB_ADMIN_PASSWORD=adminPass
-e MONGODB_USER=user
-e MONGODB_PASSWORD=password
-e MONGODB_DATABASE=db
-e MONGODB_BACKUP_USER=backup
-e MONGODB_BACKUP_PASSWORD=bPass
$mount_opts
"
    ct_create_container $name
    CONTAINER_IP=$(ct_get_cip ${name})
    ADMIN_PASS=adminPass

    echo "    Testing s2i app image backup user"
    DB=admin USER=backup PASS=bPass test_connection "${name}"

    echo "    Testing s2i app image mongodb-cfg/mongod.conf"
    mongo_admin_cmd "if (db.serverCmdLineOpts()['parsed']['replication']['oplogSizeMB'] == 128){quit(0)}; quit(1)"

    echo "    Testing s2i app image reading initial data"
    mongo_admin_cmd "if (db.getSiblingDB('db').constants.count({subject: \"s2i build example\"}) == 1){quit(0)}; quit(1)"
}

function test_mongo() {
    echo "  Testing MongoDB"
    if [ -v ADMIN_PASS ]; then
        echo "  Testing Admin user privileges"
        mongo_admin_cmd "db=db.getSiblingDB('${DB}');db.dropUser('${USER}');"
        mongo_admin_cmd "db=db.getSiblingDB('${DB}');db.createUser({user:'${USER}',pwd:'${PASS}',roles:['readWrite','userAdmin','dbAdmin']});"
        mongo_admin_cmd "db=db.getSiblingDB('${DB}');db.testData.insert({x:0});"
        mongo_cmd "db.createUser({user:'test_user2',pwd:'test_password2',roles:['readWrite']});"
    fi
    echo "  Testing user privileges"
    mongo_cmd "db.testData.insert({ y : 1 });"
    mongo_cmd "db.testData.insert({ z : 2 });"
    mongo_cmd "db.testData.find().forEach(printjson);"
    mongo_cmd "db.testData.count();"
    mongo_cmd "db.testData.drop();"
    mongo_cmd "db.dropDatabase();"
    echo "  Success!"
}

VERSION_NUM=$(get_version_number $VERSION | sed  -e 's/\.//g')
S2I_ARGS="--pull-policy=never "
TEST_DIR="$(readlink -f $(dirname "${BASH_SOURCE[0]}"))"

# vim: set tabstop=2:shiftwidth=2:expandtab:
