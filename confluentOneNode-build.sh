#!/bin/bash
#########################################################################################
## confluentOneNode installations 
#########################################################################################
# This script only supports Azure currently, mainly due to the disk persistence method
# Installed Zookeeper / Kafka / Schema / Rest / Connect / Control-Center on a single server
#
# USAGE:
#
#    sudo ConfluentOneNode-build.sh ~/ConfluentOneNode-build.ini
#
# USEFUL LINKS: 
# 
#
#########################################################################################

g_prog=confluentOneNode-build
RETVAL=0

######################################################
## defined script variables
######################################################
STAGE_DIR=/tmp/$g_prog/stage
LOG_DIR=/var/log/$g_prog
LOG_FILE=$LOG_DIR/${prog}.log.$(date +%Y%m%d_%H%M%S_%N)
INI_FILE=$LOG_DIR/${g_prog}.ini

THISDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCR=$(basename "${BASH_SOURCE[0]}")
THIS_SCRIPT=$THISDIR/$SCR

######################################################
## log()
##
##   parameter 1 - text to log
##
##   1. write parameter #1 to current logfile
##
######################################################
function log ()
{
    if [[ -e $LOG_DIR ]]; then
        echo "$(date +%Y/%m/%d_%H:%M:%S.%N) $1" >> $LOG_FILE
    fi
}

######################################################
## fatalError()
##
##   parameter 1 - text to log
##
##   1.  log a fatal error and exit
##
######################################################
function fatalError ()
{
    MSG=$1
    log "FATAL: $MSG"
    echo "ERROR: $MSG"
    exit -1
}

function installRPMs()
{
    INSTALL_RPM_LOG=$LOG_DIR/yum.${g_prog}_install.log.$$

    STR=""
   # STR="$STR java-1.8.0-openjdk.x86_64i docker-engine-selinux-1.12.6-1.el7.centos docker-engine-1.12.6-1.el7.centos"
    STR="$STR java-1.8.0-openjdk.x86_64i docker-ce-17.03.0.ce-1.el7.centos"
 
    unset DOCKER_HOST DOCKER_TLS_VERIFY
    yum -y remove docker docker-ce container-selinux docker-rhel-push-plugin docker-common docker-engine-selinux docker-engine yum-utils

    yum install -y yum-utils

   # yum-config-manager \
   #    --add-repo \
   #    https://docs.docker.com/engine/installation/linux/repo_files/centos/docker.repo

    yum-config-manager \
       --add-repo \
       https://download.docker.com/linux/centos/docker-ce.repo

    yum makecache fast
    
    yum list docker-ce  --showduplicates |sort -r > $INSTALL_RPM_LOG

    echo "installRPMs(): to see progress tail $INSTALL_RPM_LOG"
    
    yum -y install $STR > $INSTALL_RPM_LOG

    #if ! yum -y install $STR > $INSTALL_RPM_LOG
    #then
    #    fatalError "installRPMs(): failed; see $INSTALL_RPM_LOG"
    #fi
    systemctl start docker > $INSTALL_RPM_LOG
    systemctl enable docker > $INSTALL_RPM_LOG


}

##############################################################
# Open Zookeeper / Kafka Server Ports
##############################################################
function openZkKafkaPorts()
{
    log "$g_prog.installZookeeper: Opening firewalls ports"    
    systemctl status firewalld  >> $LOG_FILE
    firewall-cmd --get-active-zones  >> $LOG_FILE
    firewall-cmd --zone=public --list-ports  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${zkpserver1low}/tcp --permanent  >> $LOG_FILE  
    firewall-cmd --zone=public --add-port=${zkpserver1high}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${zkpserver2low}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${zkpserver2high}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${zkpserver3low}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${zkpserver3high}/tcp --permanent  >> $LOG_FILE

    firewall-cmd --zone=public --add-port=${zkpclient1}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${kafkapclient1}/tcp --permanent  >> $LOG_FILE
   
    firewall-cmd --zone=public --add-port=${zkpclient2}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${kafkapclient2}/tcp --permanent  >> $LOG_FILE
 
    firewall-cmd --zone=public --add-port=${ccport}/tcp --permanent
 
    firewall-cmd --reload  >> $LOG_FILE
    firewall-cmd --zone=public --list-ports  >> $LOG_FILE

}

##############################################################
# Install Zookeeper 
##############################################################
function installZookeeper()
{

    log "$g_prog.installZookeeper: Install ZooKeeper - instance 1"
    docker run -d \
        --net=host \
        --name=zk-1 \
        -e ZOOKEEPER_SERVER_ID=1 \
        -e ZOOKEEPER_CLIENT_PORT=${zkpclient1} \
        -e ZOOKEEPER_TICK_TIME=2000 \
        -e ZOOKEEPER_INIT_LIMIT=5 \
        -e ZOOKEEPER_SYNC_LIMIT=2 \
        -e ZOOKEEPER_SERVERS="${zkKafkaSer1}:${zkpserver1low}:${zkpserver1high};${zkKafkaSer1}:${zkpserver2low}:${zkpserver2high};${zkKafkaSer1}:${zkpserver3low}:${zkpserver3high}" \
         confluentinc/cp-zookeeper:3.1.2
#
    RC=$?
    if [ ${RC} -ne 0 ]; then
        fatalError "$g_prog.run(): Error implementing ZooKeeper Instance 1 - check configuration parameters"
    fi
#
    log "$g_prog.installZookeeper: Install ZooKeeper - instance 2"
    docker run -d \
        --net=host \
        --name=zk-2 \
        -e ZOOKEEPER_SERVER_ID=2 \
        -e ZOOKEEPER_CLIENT_PORT=${zkpclient2} \
        -e ZOOKEEPER_TICK_TIME=2000 \
        -e ZOOKEEPER_INIT_LIMIT=5 \
        -e ZOOKEEPER_SYNC_LIMIT=2 \
        -e ZOOKEEPER_SERVERS="${zkKafkaSer1}:${zkpserver1low}:${zkpserver1high};${zkKafkaSer1}:${zkpserver2low}:${zkpserver2high};${zkKafkaSer1}:${zkpserver3low}:${zkpserver3high}" \
         confluentinc/cp-zookeeper:3.1.2
#
    RC=$?
    if [ ${RC} -ne 0 ]; then
        fatalError "$g_prog.run(): Error implementing ZooKeeper Instance 2 - check configuration parameters"
    fi
#
    log "$g_prog.installZookeeper: Install ZooKeeper - instance 3"
    docker run -d \
        --net=host \
        --name=zk-3 \
        -e ZOOKEEPER_SERVER_ID=3 \
        -e ZOOKEEPER_CLIENT_PORT=${zkpclient3} \
        -e ZOOKEEPER_TICK_TIME=2000 \
        -e ZOOKEEPER_INIT_LIMIT=5 \
        -e ZOOKEEPER_SYNC_LIMIT=2 \
        -e ZOOKEEPER_SERVERS="${zkKafkaSer1}:${zkpserver1low}:${zkpserver1high};${zkKafkaSer1}:${zkpserver2low}:${zkpserver2high};${zkKafkaSer1}:${zkpserver3low}:${zkpserver3high}" \
         confluentinc/cp-zookeeper:3.1.2
#
    RC=$?
    if [ ${RC} -ne 0 ]; then
        fatalError "$g_prog.run(): Error implementing ZooKeeper Instance 3 - check configuration parameters"
    fi

}

##############################################################
# Install Kafka          
##############################################################
function installKafka()
{

    log "$g_prog.installKafka: Install Kafka - instance 1"
    IPADDR=`cat $INI_FILE | grep zkKafkaSer1`
    kafkaserver=`echo ${IPADDR} | awk -F "=" '{print $2}'`

    docker run -d \
        --net=host \
        --name=kafka-1 \
        -e KAFKA_ZOOKEEPER_CONNECT=${zkKafkaSer1}:${zkpclient1},${zkKafkaSer1}:${zkpclient2},${zkKafkaSer1}:${zkpclient3} \
        -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://${kafkaserver1}:${kafkapclient1} \
        confluentinc/cp-kafka:3.1.2

    RC=$?
    if [ ${RC} -ne 0 ]; then
        fatalError "$g_prog.run(): Error implementing Kafka Instance 1 - check configuration parameters"
    fi
#
    log "$g_prog.installKafka: Install Kafka - instance 2"
    IPADDR=`cat $INI_FILE | grep zkKafkaSer1`
    kafkaserver=`echo ${IPADDR} | awk -F "=" '{print $2}'`

    docker run -d \
        --net=host \
        --name=kafka-2 \
        -e KAFKA_ZOOKEEPER_CONNECT=${zkKafkaSer1}:${zkpclient1},${zkKafkaSer1}:${zkpclient2},${zkKafkaSer1}:${zkpclient3} \
        -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://${kafkaserver1}:${kafkapclient2} \
        confluentinc/cp-kafka:3.1.2

    RC=$?
    if [ ${RC} -ne 0 ]; then
        fatalError "$g_prog.run(): Error implementing Kafka Instance 2 - check configuration parameters"
    fi
#
    log "$g_prog.installerKafka: Install Kafka - instance 3"
    IPADDR=`cat $INI_FILE | grep zkKafkaSer1`
    kafkaserver=`echo ${IPADDR} | awk -F "=" '{print $2}'`

    docker run -d \
        --net=host \
        --name=kafka-3 \
        -e KAFKA_ZOOKEEPER_CONNECT=${zkKafkaSer1}:${zkpclient1},${zkKafkaSer1}:${zkpclient2},${zkKafkaSer1}:${zkpclient3} \
        -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://${kafkaserver1}:${kafkapclient3} \
        confluentinc/cp-kafka:3.1.2

    RC=$?
    if [ ${RC} -ne 0 ]; then
        fatalError "$g_prog.run(): Error implementing Kafka Instance 3 - check configuration parameters"
    fi

}

##############################################################
# Install Schema Server
##############################################################
function installSchemaServer()
{
    log "$g_prog.installSchemaServer: Install Schema - instance 1"
    IPADDR=`cat $INI_FILE | grep zkKafkaSer1`
    kafkaserver=`echo ${IPADDR} | awk -F "=" '{print $2}'`

    IPADDR=`cat $INI_FILE | grep srSer1`
    schemaserver=`echo ${IPADDR} | awk -F "=" '{print $2}'`
#
    docker run -d --net=host \
       --name=schema-registry-1 \
       -e SCHEMA_REGISTRY_KAFKASTORE_CONNECTION_URL=${zkKafkaSer1}:${zkpclient1},${zkKafkaSer1}:${zkpclient2},${zkKafkaSer1}:${zkpclient3} \
       -e SCHEMA_REGISTRY_HOST_NAME=${schemaserver} \
       -e SCHEMA_REGISTRY_LISTENERS=http://${schemaserver}:${schemaport1} \
       confluentinc/cp-schema-registry:3.1.2
#
    RC=$?
    if [ ${RC} -ne 0 ]; then
        fatalError "$g_prog.run(): Error implementing SchemaRegistry instance - check configuration parameters"
    fi

}

##############################################################
# Install REST server
##############################################################
function installRestServer()
{
    log "$g_prog.installRestServer: Install Rest - instance 1"
    IPADDR=`cat $INI_FILE | grep zkKafkaSer1`
    kafkaserver=`echo ${IPADDR} | awk -F "=" '{print $2}'`

    IPADDR=`cat $INI_FILE | grep srSer1`
    schemaserver=`echo ${IPADDR} | awk -F "=" '{print $2}'`
#
    docker run -d \
        --net=host \
        --name=kafka-rest-1 \
        -e KAFKA_REST_ZOOKEEPER_CONNECT=${zkKafkaSer1}:${zkpclient1},${zkKafkaSer1}:${zkpclient2},${zkKafkaSer1}:${zkpclient3} \
        -e KAFKA_REST_LISTENERS=http://${schemaserver}:${restport1} \
        -e KAFKA_REST_SCHEMA_REGISTRY_URL=http://${schemaserver}:${schemaport1} \
        -e KAFKA_REST_HOST_NAME=${schemaserver} \
        confluentinc/cp-kafka-rest:3.1.2
#
    RC=$?
    if [ ${RC} -ne 0 ]; then
        fatalError "$g_prog.run(): Error implementing SchemaRegistry instance - check configuration parameters"
    fi

}

##############################################################
# Install Connection server
##############################################################
function installConnectionServer()
{
    log "$g_prog.installConnectionServer: Install Connection - instance 1"
    IPADDR=`cat $INI_FILE | grep zkKafkaSer1`
    kafkaserver=`echo ${IPADDR} | awk -F "=" '{print $2}'`

    IPADDR=`cat $INI_FILE | grep srSer1`
    schemaserver=`echo ${IPADDR} | awk -F "=" '{print $2}'`
#
    docker run -d \
       --net=host \
       --name=kafka-connect-1 \
       -e CONNECT_BOOTSTRAP_SERVERS=${zkKafkaSer1}:${kafkapclient1},${zkKafkaSer1}:${kafkapclient2},${zkKafkaSer1}:${kafkapclient3} \
       -e CONNECT_REST_PORT=${connectport1} \
       -e CONNECT_GROUP_ID="quickstart" \
       -e CONNECT_CONFIG_STORAGE_TOPIC="quickstart-config" \
       -e CONNECT_OFFSET_STORAGE_TOPIC="quickstart-offsets" \
       -e CONNECT_STATUS_STORAGE_TOPIC="quickstart-status" \
       -e CONNECT_KEY_CONVERTER="org.apache.kafka.connect.json.JsonConverter" \
       -e CONNECT_VALUE_CONVERTER="org.apache.kafka.connect.json.JsonConverter" \
       -e CONNECT_INTERNAL_KEY_CONVERTER="org.apache.kafka.connect.json.JsonConverter" \
       -e CONNECT_INTERNAL_VALUE_CONVERTER="org.apache.kafka.connect.json.JsonConverter" \
       -e CONNECT_REST_ADVERTISED_HOST_NAME=${schemaserver} \
       confluentinc/cp-kafka-connect:3.1.2
#
    RC=$?
    if [ ${RC} -ne 0 ]; then
        fatalError "$g_prog.run(): Error implementing SchemaRegistry instance - check configuration parameters"
    fi

}

##############################################################
# Install Control Centre Server
##############################################################
function installControlCentreServer()
{
    log "$g_prog.installControlCentreServer: Install Control Centre - instance 1"
    IPADDR=`cat $INI_FILE | grep zkKafkaSer1`
    kafkaserver=`echo ${IPADDR} | awk -F "=" '{print $2}'`

    IPADDR=`cat $INI_FILE | grep srSer1`
    schemaserver=`echo ${IPADDR} | awk -F "=" '{print $2}'`
#
    IPADDR=`cat $INI_FILE | grep ccSer1`
    ccserver=`echo ${IPADDR} | awk -F "=" '{print $2}'`
#
    mkdir -p /tmp/control-center/data
    RC=$?
    if [ ${RC} -ne 0 ]; then
        fatalError "$g_prog.run(): Error creating folder /tmp/control-center/data"
    fi
#
    docker run -d \
       --net=host \
       --name=control-center \
       --ulimit nofile=${nofile}:${nofile} \
       -p ${ccport}:${ccport} \
       -v /tmp/control-center/data:/var/lib/confluent-control-center \
       -e CONTROL_CENTER_ZOOKEEPER_CONNECT=${zkKafkaSer1}:${zkpclient1},${zkKafkaSer1}:${zkpclient2},${zkKafkaSer1}:${zkpclient3} \
       -e CONTROL_CENTER_BOOTSTRAP_SERVERS=${zkKafkaSer1}:${kafkapclient1},${zkKafkaSer1}:${kafkapclient2},${zkKafkaSer1}:${kafkapclient3} \
       -e CONTROL_CENTER_REPLICATION_FACTOR=${repfactor} \
       -e CONTROL_CENTER_MONITORING_INTERCEPTOR_TOPIC_PARTITIONS=${montopicpart} \
       -e CONTROL_CENTER_INTERNAL_TOPICS_PARTITIONS=${inttopicpart} \
       -e CONTROL_CENTER_STREAMS_NUM_STREAM_THREADS=${streamthread} \
       -e CONTROL_CENTER_CONNECT_CLUSTER=${schemaserver}:${connectport} \
       confluentinc/cp-enterprise-control-center:3.1.2
#
    RC=$?
    if [ ${RC} -ne 0 ]; then
        fatalError "$g_prog.run(): Error implementing Control Centre instance - check configuration parameters"
    fi

}


##############################################################
# Install components
##############################################################
function installServer()
{
    installZookeeper 
    installKafka
    installSchemaServer
    installRestServer
    installConnectionServer
    installControlCentreServer
}


function run()
{
    eval `grep platformEnvironment $INI_FILE`
    if [ -z $platformEnvironment ]; then    
        fatalError "$g_prog.run(): Unknown environment, check platformEnvironment setting in iniFile"
    elif [ $platformEnvironment != "AZURE" ]; then    
        fatalError "$g_prog.run(): platformEnvironment=AZURE is the only valid setting currently"
    fi

    eval `grep zkKafkaSer1 ${INI_FILE}`
#
    eval `grep zkpclient1 ${INI_FILE}`
    eval `grep zkpclient2 ${INI_FILE}`
    eval `grep zkpclient3 ${INI_FILE}`
#
    eval `grep zkpserver1low ${INI_FILE}`
    eval `grep zkpserver1high ${INI_FILE}`
    eval `grep zkpserver2low ${INI_FILE}`
    eval `grep zkpserver2high ${INI_FILE}`
    eval `grep zkpserver3low ${INI_FILE}`
    eval `grep zkpserver3high ${INI_FILE}`
#
    eval `grep kafkapclient1 ${INI_FILE}`
    eval `grep kafkapclient2 ${INI_FILE}`
    eval `grep kafkapclient3 ${INI_FILE}` 
#
    eval `grep schemaport1 ${INI_FILE}`
    eval `grep restport1 ${INI_FILE}`
    eval `grep connectport1 ${INI_FILE}`
# 
#
    eval `grep ccport ${INI_FILE}`
    eval `grep nofile ${INI_FILE}`
    eval `grep repfactor ${INI_FILE}`
    eval `grep montopicpart ${INI_FILE}`
    eval `grep inttopicpart ${INI_FILE}`
    eval `grep streamthread ${INI_FILE}`
#
  # function calls
    installRPMs
    openZkKafkaPorts
    installServer
}


######################################################
## Main Entry Point
######################################################

log "$g_prog starting"
log "STAGE_DIR=$STAGE_DIR"
log "LOG_DIR=$LOG_DIR"
log "INI_FILE=$INI_FILE"
log "LOG_FILE=$LOG_FILE"
echo "$g_prog starting, LOG_FILE=$LOG_FILE"

if [[ $EUID -ne 0 ]]; then
    fatalError "$THIS_SCRIPT must be run as root"
    exit 1
fi

INI_FILE_PATH=$1

if [[ -z $INI_FILE_PATH ]]; then
    fatalError "${g_prog} called with null parameter, should be the path to the driving ini_file"
fi

if [[ ! -f $INI_FILE_PATH ]]; then
    fatalError "${g_prog} ini_file cannot be found"
fi

if ! mkdir -p $LOG_DIR; then
    fatalError "${g_prog} cant make $LOG_DIR"
fi


chmod 777 $LOG_DIR

cp $INI_FILE_PATH $INI_FILE

run

log "$g_prog ended cleanly"
exit $RETVAL

