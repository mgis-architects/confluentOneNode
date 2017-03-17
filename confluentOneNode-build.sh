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

 
    unset DOCKER_HOST DOCKER_TLS_VERIFY
    yum -y remove docker docker-ce container-selinux docker-rhel-push-plugin docker-common docker-engine-selinux docker-engine yum-utils

    yum install -y yum-utils

    yum-config-manager \
       --add-repo \
       https://download.docker.com/linux/centos/docker-ce.repo

    yum makecache fast
    
    yum list docker-ce  --showduplicates |sort -r > $INSTALL_RPM_LOG

    echo "installRPMs(): to see progress tail $INSTALL_RPM_LOG"
    
    STR=""
    STR="$STR java-1.8.0-openjdk.x86_64 docker-ce-17.03.0.ce-1.el7.centos cifs-utils"
    yum -y install $STR > $INSTALL_RPM_LOG

    systemctl start docker > $INSTALL_RPM_LOG
    systemctl enable docker > $INSTALL_RPM_LOG


}

function fixSwap()
{
    cat /etc/waagent.conf | while read LINE
    do
        if [ "$LINE" == "ResourceDisk.EnableSwap=n" ]; then
                LINE="ResourceDisk.EnableSwap=y"
        fi

        if [ "$LINE" == "ResourceDisk.SwapSizeMB=2048" ]; then
                LINE="ResourceDisk.SwapSizeMB=14000"
        fi
        echo $LINE
    done > /tmp/waagent.conf
    /bin/cp /tmp/waagent.conf /etc/waagent.conf
    systemctl restart waagent.service
}

createFilesystem()
{
    # createFilesystem /u01 $l_disk $diskSectors
    # size is diskSectors-128 (offset)

    local p_filesystem=$1
    local p_disk=$2
    local p_sizeInSectors=$3
    local l_sectors
    local l_layoutFile=$LOG_DIR/sfdisk.${g_prog}_install.log.$$

    if [ -z $p_filesystem ] || [ -z $p_disk ] || [ -z $p_sizeInSectors ]; then
        fatalError "createFilesystem(): Expected usage mount,device,numsectors, got $p_filesystem,$p_disk,$p_sizeInSectors"
    fi

    let l_sectors=$p_sizeInSectors-128

    cat > $l_layoutFile << EOFsdcLayout
# partition table of /dev/sdc
unit: sectors

/dev/sdc1 : start=     128, size=  ${l_sectors}, Id= 83
/dev/sdc2 : start=        0, size=        0, Id= 0
/dev/sdc3 : start=        0, size=        0, Id= 0
/dev/sdc4 : start=        0, size=        0, Id= 0
EOFsdcLayout

    set -x # debug has been useful here

    if ! sfdisk $p_disk < $l_layoutFile; then fatalError "createFilesystem(): $p_disk does not exist"; fi

    sleep 4 # add a delay - experiencing occasional "cannot stat" for mkfs

    log "createFilesystem(): Dump partition table for $p_disk"
    fdisk -l

    if ! mkfs.ext4 ${p_disk}1; then fatalError "createFilesystem(): mkfs.ext4 ${p_disk}1"; fi

    if ! mkdir -p $p_filesystem; then fatalError "createFilesystem(): mkdir $p_filesystem failed"; fi

    if ! chmod 755 $p_filesystem; then fatalError "createFilesystem(): chmod $p_filesystem failed"; fi

    # if ! chown oracle:oinstall $p_filesystem; then fatalError "createFilesystem(): chown $p_filesystem failed"; fi

    if ! mount ${p_disk}1 $p_filesystem; then fatalError "createFilesystem(): mount $p_disk $p_filesytem failed"; fi

    log "createFilesystem(): Dump blkid"
    blkid

    if ! blkid | egrep ${p_disk}1 | awk '{printf "%s\t'${p_filesystem}' \t ext4 \t defaults \t 1 \t2\n", $2}' >> /etc/fstab; then fatalError "createFilesystem(): fstab update failed"; fi

    log "createFilesystem() fstab success: $(grep $p_disk /etc/fstab)"

    set +x
}

function allocateStorage()
{
    local l_disk
    local l_size
    local l_sectors
    local l_hasPartition

    for l_disk in /dev/sd?
    do
         l_hasPartition=$(( $(fdisk -l $l_disk | wc -l) != 6 ? 1 : 0 ))
        # only use if it doesnt already have a blkid or udev UUID
        if [ $l_hasPartition -eq 0 ]; then
            let l_size=`fdisk -l $l_disk | grep 'Disk.*sectors' | awk '{print $5}'`/1024/1024/1024
            let l_sectors=`fdisk -l $l_disk | grep 'Disk.*sectors' | awk '{print $7}'`

            if [ $u01_Disk_Size_In_GB -eq $l_size ]; then
                log "allocateStorage(): Creating /u01 on $l_disk"
                createFilesystem /u01 $l_disk $l_sectors
            fi
        fi
    done
}

function mountMedia() {

    if [ -f /mnt/software/ogg4bd12201/p24816159_122014_Linux-x86-64.zip ]; then

        log "mountMedia(): Filesystem already mounted"

    else

        umount /mnt/software

        mkdir -p /mnt/software

        eval `grep mediaStorageAccountKey $INI_FILE`
        eval `grep mediaStorageAccount $INI_FILE`
        eval `grep mediaStorageAccountURL $INI_FILE`

        l_str=""
        if [ -z $mediaStorageAccountKey ]; then
            l_str+="mediaStorageAccountKey not found in $INI_FILE; "
        fi
        if [ -z $mediaStorageAccount ]; then
            l_str+="mediaStorageAccount not found in $INI_FILE; "
        fi
        if [ -z $mediaStorageAccountURL ]; then
            l_str+="mediaStorageAccountURL not found in $INI_FILE; "
        fi
        if ! [ -z $l_str ]; then
            fatalError "mountMedia(): $l_str"
        fi

        cat > /etc/cifspw << EOF1
username=${mediaStorageAccount}
password=${mediaStorageAccountKey}
EOF1

        cat >> /etc/fstab << EOF2
//${mediaStorageAccountURL}     /mnt/software   cifs    credentials=/etc/cifspw,vers=3.0,gid=54321      0       0
EOF2

        mount -a

    fi
}

function installConfluent()
{
    # confluentVersion=3.0
    # confluentVersion=3.1

    # http://docs.confluent.io/3.0.1/installation.html
    # http://docs.confluent.io/3.1.2/installation.html
    # lot of effort to get a kafka client...
    # will be installed here... /usr/share/java/kafka
    # sudo yum -y remove confluent-platform-2.11

    sudo rpm --import http://packages.confluent.io/rpm/${confluentVersion}/archive.key
    sudo su - -c "cat > /etc/yum.repos.d/confluent.repo << EOFrepo
[Confluent.dist]
name=Confluent repository (dist)
baseurl=http://packages.confluent.io/rpm/${confluentVersion}/7
gpgcheck=1
gpgkey=http://packages.confluent.io/rpm/${confluentVersion}/archive.key
enabled=1

[Confluent]
name=Confluent repository
baseurl=http://packages.confluent.io/rpm/${confluentVersion}
gpgcheck=1
gpgkey=http://packages.confluent.io/rpm/${confluentVersion}/archive.key
enabled=1

EOFrepo
"
    sudo yum clean all
    sudo yum -y install confluent-platform-2.11
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
#
    firewall-cmd --zone=public --add-port=${zkpclient1}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${kafkapclient1}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${zkpserver1low}/tcp --permanent  >> $LOG_FILE  
    firewall-cmd --zone=public --add-port=${zkpserver1high}/tcp --permanent  >> $LOG_FILE
#
    firewall-cmd --zone=public --add-port=${zkpclient2}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${kafkapclient2}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${zkpserver2low}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${zkpserver2high}/tcp --permanent  >> $LOG_FILE
#
    firewall-cmd --zone=public --add-port=${zkpclient3}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${kafkapclient3}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${zkpserver3low}/tcp --permanent  >> $LOG_FILE
    firewall-cmd --zone=public --add-port=${zkpserver3high}/tcp --permanent  >> $LOG_FILE
#
    firewall-cmd --zone=public --add-port=${schemaport1}/tcp --permanent
    firewall-cmd --zone=public --add-port=${restport1}/tcp --permanent
#
    firewall-cmd --zone=public --add-port=${ccport}/tcp --permanent
#
#   all for connect distributed worker rest port
    firewall-cmd --zone=public --add-port=8080-8089/tcp --permanent >> $LOG_FILE
#
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
       -e CONTROL_CENTER_CONNECT_CLUSTER=${schemaserver}:${connectport1} \
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
function installKafkaConnect()
{
    cd /u01
    mkdir -p /u01/app/kafka-connect-cassandra
    mkdir /u01/worker_config
    mkdir /u01/logs
    tar xzvf /mnt/software/confluent/kafka-connect-cassandra-0.2.4-3.0.1-all.tar.gz -C /u01/app/kafka-connect-cassandra

#######################
# Useful functions
#######################
    cat > /u01/set_env << EOFenv
export confluentRestUrl=http://${HOSTNAME}:${restport1}
alias brokers.list='curl -X GET -H "Content-Type: application/json" ${confluentRestUrl}/brokers 2> /dev/null | python -mjson.tool'
function topics.list() { curl -X GET -H "Content-Type: application/json" ${confluentRestUrl}/topics/${1} 2>/dev/null | python -mjson.tool; }
function topic.get() { curl -X GET -H "Content-Type: application/json" ${confluentRestUrl}/topics/${1} 2>/dev/null | python -mjson.tool; }
function partition.list() { curl -X GET -H "Content-Type: application/json" ${confluentRestUrl}/topics/${1}/partitions 2>/dev/null | python -mjson.tool; }
function partition.get() { curl -X GET -H "Content-Type: application/json" ${confluentRestUrl}/topics/${1}/partitions/${2} 2>/dev/null | python -mjson.tool; }
function consumer.createbinary() { group=\$1; instance=\$2; echo '{ "id": "'$instance'", "format": "binary", "auto.offset.reset": "smallest", "auto.commit.enable": "false" }' > /tmp/consumer.create.$$.json; curl -X POST -H "Content-Type: application/vnd.kafka.binary.v1+json" --data-binary "@/tmp/consumer.create.$$.json" ${confluentRestUrl}/consumers/${group} 2>/dev/null | python -mjson.tool; }
function consumer.createavro() { group=\$1; instance=\$2; echo '{ "id": "'$instance'", "format": "binary", "auto.offset.reset": "smallest", "auto.commit.enable": "false" }' > /tmp/consumer.create.$$.json; curl -X POST -H "Content-Type: application/vnd.kafka.avro.v1+json" --data-binary "@/tmp/consumer.create.$$.json" ${confluentRestUrl}/consumers/${group} 2>/dev/null | python -mjson.tool; }
function consumer.readbinary() { group=\$1; instance=\$2; topic_name=$3; curl -X GET -H "Content-Type: application/vnd.kafka.binary.v2+json" ${confluentRestUrl}/consumers/${group}/instances/${instance}/topics/${topic_name} 2>/dev/null | python -mjson.tool; }
#function consumer.readavro() { group=\$1; instance=\$2; topic_name=$3; curl -X GET -H "Content-Type: application/vnd.kafka.avro.v1+json" ${confluentRestUrl}/consumers/${group}/instances/${instance}/topics/${topic_name} 2>/dev/null | python -mjson.tool; }
function consumer.readavro() { group=\$1; instance=\$2; topic_name=$3; curl -X GET -H "Accept: application/vnd.kafka.avro.v1+json" ${confluentRestUrl}/consumers/${group}/instances/${instance}/topics/${topic_name} 2>/dev/null | python -mjson.tool; }
function consumer.readavro() { group=\$1; instance=\$2; topic_name=$3; curl -X GET -H "Accept: application/vnd.kafka.v2+json" ${confluentRestUrl}/consumers/${group}/instances/${instance}/topics/${topic_name} 2>/dev/null | python -mjson.tool; }
function consumer.readavro() { group=\$1; instance=\$2; topic_name=$3; curl -X GET -H "Accept: application/vnd.kafka.binary.v1+json" ${confluentRestUrl}/consumers/${group}/instances/${instance}/topics/${topic_name} 2>/dev/null | python -mjson.tool; }
function consumer.commit() { group=\$1; instance=\$2; curl -X POST -H "Content-Type: application/json" ${confluentRestUrl}/consumers/${group}/instances/${instance}/offsets 2>/dev/null | python -mjson.tool; }
function consumer.delete() { group=\$1; instance=\$2; curl -X DELETE -H "Content-Type: application/json" ${confluentRestUrl}/consumers/${group}/instances/${instance}; }
# partition.produce-avro	POST /topics/{topic}/partitions/{partition} with Content-Type: application/vnd.kafka.avro.v1+json header
# partition.produce-binary	POST /topics/{topic}/partitions/{partition} with Content-Type: application/vnd.kafka.binary.v1+json header
# topic.produce-avro	POST /topics/{topic} with Content-Type: application/vnd.kafka.avro.v1+json header
# topic.produce-binary	POST /topics/{topic} with Content-Type: application/vnd.kafka.binary.v1+json header

export schemaRegistryRestUrl=http://${HOSTNAME}:${schemaport1}
function sr.subject.list() { curl -X GET -H "Accept: application/vnd.schemaregistry.v1+json" ${schemaRegistryRestUrl}/subjects 2>/dev/null | python -mjson.tool; }
function sr.subject.versions() { subject=\$1; curl -X GET -H "Accept: application/vnd.schemaregistry.v1+json" ${schemaRegistryRestUrl}/subjects/${subject}/versions 2>/dev/null | python -mjson.tool; }
function sr.subject.getversion() { subject=\$1; version=\$2; curl -X GET -H "Accept: application/vnd.schemaregistry.v1+json" ${schemaRegistryRestUrl}/subjects/${subject}/versions/${version} 2>/dev/null | python -mjson.tool; }
function sr.schema.get() { id=\$1; curl -X GET -H "Accept: application/vnd.schemaregistry.v1+json" ${schemaRegistryRestUrl}/schemas/ids/${id} 2>/dev/null | python -mjson.tool; }
EOFenv

###########################################################
# Create "AVRO1" sample config 
###########################################################

##############################################
# Create topics for the sample worker
##############################################
    cat> /u01/worker_config/avro1-worker-topics.sh << EOFtop
    kafka-topics --create --zookeeper ${HOSTNAME}:${zkpclient1} --topic avro1-connect-configs --replication-factor 3 --partitions 1
    kafka-topics --create --zookeeper ${HOSTNAME}:${zkpclient1} --topic avro1-connect-offsets --replication-factor 3 --partitions 50
    kafka-topics --create --zookeeper ${HOSTNAME}:${zkpclient1} --topic avro1-connect-status --replication-factor 3 --partitions 10
EOFtop

    bash -x /u01/worker_config/avro1-worker-topics.sh

##############################################
# Create the sample worker
##############################################
    cat > /u01/worker_config/avro1-worker.properties << EOF
bootstrap.servers=${zkKafkaSer1}:${kafkapclient1},${zkKafkaSer1}:${kafkapclient2},${zkKafkaSer1}:${kafkapclient3}
group.id=connect-avro1
key.converter=io.confluent.connect.avro.AvroConverter
key.converter.schema.registry.url=http://${schemaserver}:${schemaport1}
value.converter=io.confluent.connect.avro.AvroConverter
value.converter.schema.registry.url=http://${schemaserver}:${schemaport1}
internal.key.converter=org.apache.kafka.connect.json.JsonConverter
internal.value.converter=org.apache.kafka.connect.json.JsonConverter
internal.key.converter.schemas.enable=false
internal.value.converter.schemas.enable=false
config.storage.topic=avro1-connect-configs
offset.storage.topic=avro1-connect-offsets
status.storage.topic=avro1-connect-statuses
rest.port=8083
EOF

##############################################
# start the sample worker
##############################################
    cat > /u01/worker_config/avro1-worker-start.sh << EOFstart
export CLASSPATH=/u01/app/kafka-connect-cassandra/kafka-connect-cassandra-0.2.4-3.0.1-all.jar
nohup connect-distributed /u01/worker_config/avro1-worker.properties > /u01/logs/avro1-worker.log 2>&1 &
EOFstart
    bash -x /u01/worker_config/avro1-worker-start.sh
    sleep 30

##############################################
# Create the cassandra sink and apply to worker
##############################################

    CREATE_CONFIG=/u01/worker_config/avro1-cassandra-sink-create.json

    cat > $CREATE_CONFIG << EOF2
{
    "name": "avro1-cassandra-sink",
    "config": {
        "connector.class": "com.datamountaineer.streamreactor.connect.cassandra.sink.CassandraSinkConnector",
        "tasks.max": "1",
        "topics": "AVRO1.CUSTOMERS",
        "connect.cassandra.sink.kcql": "INSERT INTO customers SELECT customer_id, first_name, last_name FROM AVRO1.CUSTOMERS PK customer_id",
        "connect.cassandra.contact.points": "${cassandraContactPoints}",
        "connect.cassandra.port": "${cassandraPort}",
        "connect.cassandra.key.space": "AVRO1",
        "connect.cassandra.username": "cassandra",
        "connect.cassandra.password": "cassandra",
        "connect.cassandra.ssl.enabled": "false",
        "connect.cassandra.error.policy": "throw"
    }
}
EOF2

    cat > /u01/worker_config/avro1-cassandra-sink-create.sh << EOF3
curl -X POST -H "Content-Type: application/json" --data @$CREATE_CONFIG http://${HOSTNAME}:8083/connectors
EOF3
    bash -x /u01/worker_config/avro1-cassandra-sink-create.sh

##############################################
# Save commands to update Cassandra sink
##############################################
    UPDATE_CONFIG=/u01/worker_config/avro1-cassandra-sink-update.json
    cat > $UPDATE_CONFIG << EOF4
{
    "connector.class": "com.datamountaineer.streamreactor.connect.cassandra.sink.CassandraSinkConnector",
    "tasks.max": "1",
    "topics": "AVRO1.CUSTOMERS",
    "connect.cassandra.sink.kcql": "INSERT INTO customers SELECT CUSTOMER_ID, FIRST_NAME, LAST_NAME FROM AVRO1.CUSTOMERS PK customer_id",
    "connect.cassandra.contact.points": "${cassandraContactPoints}",
    "connect.cassandra.port": "9042",
    "connect.cassandra.key.space": "AVRO1",
    "connect.cassandra.username": "cassandra",
    "connect.cassandra.password": "cassandra",
    "connect.cassandra.ssl.enabled": "false",
    "connect.cassandra.error.policy": "throw"
}
EOF4

    # just save to a file...
    cat > /u01/worker_config/avro1-cassandra-sink-update.sh << EOF5
curl -X PUT -H "Content-Type: application/json" --data @$UPDATE_CONFIG http://$HOSTNAME:8083/connectors/avro1-cassandra-sink1/config
EOF5

}

function run()
{
    eval `grep platformEnvironment $INI_FILE`
    if [ -z $platformEnvironment ]; then    
        fatalError "$g_prog.run(): Unknown environment, check platformEnvironment setting in iniFile"
    elif [ $platformEnvironment != "AZURE" ]; then    
        fatalError "$g_prog.run(): platformEnvironment=AZURE is the only valid setting currently"
    fi

    eval `grep cassandraContactPoints ${INI_FILE}`
    eval `grep cassandraPort ${INI_FILE}`

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
    eval `grep ccport ${INI_FILE}`
    eval `grep nofile ${INI_FILE}`
    eval `grep repfactor ${INI_FILE}`
    eval `grep montopicpart ${INI_FILE}`
    eval `grep inttopicpart ${INI_FILE}`
    eval `grep streamthread ${INI_FILE}`
    eval `grep confluentVersion $INI_FILE`
    eval `grep u01_Disk_Size_In_GB $INI_FILE`

    # function calls
    openZkKafkaPorts
    fixSwap
    installRPMs
#
    installZookeeper 
    installKafka
    installSchemaServer
    installRestServer
    installConnectionServer
    installControlCentreServer 
#
    allocateStorage
    mountMedia
    installConfluent
    installKafkaConnect
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

