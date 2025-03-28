#!/bin/bash

#set -e  # Exit on error

SCRIPTDIR="$(dirname "$0")"

source $SCRIPTDIR/env_vars.env

if [[ "${DEBUG_IMAGE}" == "true" ]];
then
	echo "DEBUG: Show all the environment variables"
	export 
fi


case "$BACKUP_DESTINATION" in
    "aws_s3"|"AWS_S3")
        RESTIC_REPOSITORY="s3:s3.${AWS_DEFAULT_REGION}.amazonaws.com/${AWS_S3_BUCKET}/${CLUSTER_NAME}-${CLUSTER_NAMESPACE}"
        ;;
    "azure_blob"|"AZURE_BLOB")
        RESTIC_REPOSITORY="azure:${AZURE_CONTAINER}:${CLUSTER_NAME}-${CLUSTER_NAMESPACE}"
        ;;
    "google_cloud"|"GOOGLE_CLOUD")
        RESTIC_REPOSITORY="gs:${GCP_BUCKET}/${CLUSTER_NAME}-${CLUSTER_NAMESPACE}"
        ;;
    "generic_s3"|"GENERIC_S3")
	RESTIC_REPOSITORY="s3:${S3_ENDPOINT}/${AWS_S3_BUCKET}/${VALKEY_TYPE}-${VALKEY_NAME}-${VALKEY_NAMESPACE}"
	;;
    *)
        echo "ERROR: Invalid choice. Exiting."
        exit 1
        ;;
esac

echo "INFO: Checking connectivity to the S3 service"
nc -zv ${S3_HOST} ${S3_PORT}
if [ $? == 0 ];
then
	echo "INFO: Successfully accesible: host ${S3_HOST} - port ${S3_PORT}"
else
	echo "ERROR: Service S3 is not accesible: host ${S3_HOST} - port ${S3_PORT}"
fi

#
# setting some connection configurations options
#

opts=""
if [[ "${VALKEY_USE_TLS}" == "true" ]];
then
	if [ ! -d /certs ];
	then
		echo "ERROR: Please mount the certificates into /certs directory"
		exit 1
	fi
	echo "INFO: the service uses TLS"
	opts=$opts" --tls --cacert /certs/ca.crt --cert /certs/tls.crt --key /certs/tls.key"
fi

if [ ! -z ${VALKEY_PASSWORD} ];
then
	echo "INFO: the service uses password authentication"
	opts=$opts" -a ${VALKEY_PASSWORD} --no-auth-warning"
fi


VALKEY_MASTER=0.0.0.0

initialize_repository() {
    # To set the password of the repo you must pass it the env Variable  RESTIC_PASSWORD
    echo "INFO: Initializing from restic the repository"
    if ! restic -r "$RESTIC_REPOSITORY" snapshots &>/dev/null ; then
	set -e
        echo "INFO: Initializing restic repository..."
        restic init --repo "$RESTIC_REPOSITORY"
	set +e
    else
        echo "INFO: Restic repository already initialized."
    fi
}


# This is valid only if this is a single or replication redis
discover_master() {

	echo "INFO: Discovering Valkey Master"
	echo "INFO: Getting ip(s) of the instance: $VALKEY_NAME"

	case "${VALKEY_TYPE}" in

		  "standalone")
			VALKEY_MASTER=$(kubectl get pods -n $VALKEY_NAMESPACE -o wide -l app.kubernetes.io/instance=$VALKEY_NAME | tail -n +2 | awk '{print $6}')
                	echo "INFO: Master found with IP: $VALKEY_MASTER"
		    ;;
		
		  "replication")
			VALKEY_MASTER=$(kubectl get pods -n $VALKEY_NAMESPACE -o wide -l app.kubernetes.io/instance=$VALKEY_NAME,app.kubernetes.io/component=primary | tail -n +2 | awk '{print $6}')
                        echo "INFO: Primary node found with IP: $VALKEY_MASTER"
		    ;;
		
		  "sentinel")
		        VALKEY_MASTER=$(redis-cli -h ${VALKEY_NAME}.${VALKEY_NAMESPACE}.svc  -p 26379 $opts sentinel primary myprimary | grep ${VALKEY_NAME})
			echo "INFO: Primary node found with IP: $VALKEY_MASTER"
		    ;;
		
		  *)
		   	echo "ERROR: not recognized VALKEY_TYPE" 
			exit 1
		    ;;
	esac
}

# Used only by redis standalone and replication
perform_redis_backup() {
	
	echo "INFO: Performing the backup"
	if [[ "${VALKEY_MASTER}" != "0.0.0.0" ]];
	then
		set -e
		echo "INFO: Connecting to the master and performing the backup"
		redis-cli -h ${VALKEY_MASTER} -p ${VALKEY_PORT} $opts --rdb "/tmp/${VALKEY_NAME}.rdb"
		echo "INFO: Saving the data in S3"
		restic -r "$RESTIC_REPOSITORY" backup "/tmp/${VALKEY_NAME}.rdb" --host "${VALKEY_NAME}_${VALKEY_NAMESPACE}" --tag "${VALKEY_NAME}" --tag "valkey"
		rm "/tmp/${VALKEY_NAME}.rdb"
		echo "INFO: Backup completed successfully."
		set +e
	fi

}

show_available_backups() {
	echo "INFO: Show list of available backups"
	echo
	restic -r "$RESTIC_REPOSITORY" snapshots
}

restore_last() {
	export SNAPSHOT_ID=$(restic -r "$RESTIC_REPOSITORY" snapshots --json --tag "${VALKEY_NAME}" | jq -r 'max_by(.time) | .id')
	echo "INFO: Restore the from the last snapshot"
	restore_snapshot
}

restore_snapshot() {

	if [ ! -z ${SNAPSHOT_ID} ];
	then
	        set -e
		# Procedure taken from: https://artifacthub.io/packages/helm/bitnami/valkey
		echo "INFO: Proceeding with the restore of the data from the snapshot: ${SNAPSHOT_ID}"
		echo

		echo "INFO: Saving the current valkey yaml manifest applied to the instance"
		kubectl apply view-last-applied valkey ${VALKEY_NAME} -n ${VALKEY_NAMESPACE} -o yaml > ${VALKEY_NAME}.yaml

	        # Before valkey is one more time restored, it is necessary to check what is the current configuration of the appendonly
                # If the appendonly parameter is set to no, then it can be just run the normal deployment saved.
                # if the appendonly is set to yes there are to ways to verify that:
                # - the commonConfiguration is not set in the yaml.
                #    * Then this means that it is taken from the default configuration of the deployment.
                # - else it is important to check if the appendonly parameter is present and then change it.
                # For all this steps if the appendonly is set to yes, it will be necessary to change it to no.
                # Then we will apply the yaml with the restore
                # When this is running, through the redis-cli we connect and change it to yes to reconestruct the aof files.
                # finally we will apply the original file with the appendonly yes so it can be fully restored with the paramenter set.

	        set +e
                # Checking if it is configured valkey with appendonly yes
                # In other words if the appendonly is NOT set to no
		aof_found=0
                if ! redis-cli -h ${VALKEY_MASTER} -p ${VALKEY_PORT} $opts config get appendonly | tail -n 1 | grep no 1>/dev/null;
                then
                        # making copy of the original file to add new parameters

                        echo "INFO: Creating a copy of the deployment file"
                        cp ${VALKEY_NAME}.yaml ${VALKEY_NAME}-mod.yaml

                        # if appendonly is set to yes check if this is set through the commonConfiguration
                        if grep commonConfiguration ${VALKEY_NAME}.yaml 1>/dev/null;
                        then
                                if grep appendonly ${VALKEY_NAME}.yaml 1>/dev/null;
                                then
                                        echo "INFO: Found the appendonly definition in the deployment definition"
                                        echo "INFO: Changing the appendonly value to no"
                                        sed -i 's/appendonly yes/appendonly no/' ${VALKEY_NAME}-mod.yaml
                                fi
                        else
                                echo "INFO: No custom configuration found, adding custom configuration with appendonly no"
                                echo "  commonConfiguration: |-" >> ${VALKEY_NAME}-mod.yaml
                                echo "    # Enable AOF https://valkey.io/topics/persistence#append-only-file" >> ${VALKEY_NAME}-mod.yaml
                                echo "    appendonly no" >> ${VALKEY_NAME}-mod.yaml
                                echo "    # Disable RDB persistence, AOF persistence already enabled." >> ${VALKEY_NAME}-mod.yaml
                                echo "    save \"\"" >> ${VALKEY_NAME}-mod.yaml
                        fi

			aof_found=1
		fi
		set -e

		echo "INFO: Deleting the instance ${VALKEY_NAME} for the restore"
		kubectl delete valkey ${VALKEY_NAME} -n ${VALKEY_NAMESPACE}

		# Perform the restore
                echo "INFO: Restoring Valkey backup for pod ${REDIS_NAME} from snapshot ID ${SNAPSHOT_ID}"
                restic -r "$RESTIC_REPOSITORY" restore "${SNAPSHOT_ID}" --target "/"

                if [[ "${DEBUG_IMAGE}" == "true" ]];
                then
                        echo "DEBUG: Files local"
                        ls -l
                        echo
                        echo "DEBUG: Files in /tmp"
                        ls -l /tmp
                fi

		#
		# Considering a process that involve all cases, standalone, replica and sentinel
		# to restore the dump.rdb backed up
		#

		echo "INFO: Detecting volumes for: ${VALKEY_NAME}"
		volumes=$(kubectl  get pvc -o jsonpath="{.items[*].metadata.name}" -l app.kubernetes.io/instance=${VALKEY_NAME})
		for volume in $volumes
		do
			export VALKEY_VOLUME_NAME=$volume
			echo "INFO: Creating the pod to mount the volume of the node"
			cat lightweight-tty-pod.yaml | envsubst > restore-from-${VALKEY_VOLUME_NAME}.yaml
			kubectl	apply -f restore-from-${VALKEY_VOLUME_NAME}.yaml -n ${VALKEY_NAMESPACE}

			echo "INFO: Waiting for the container to be ready"
			kubectl wait --for=jsonpath='{.status.phase}'=Running pod/restore-from-${VALKEY_VOLUME_NAME} -n ${VALKEY_NAMESPACE}

	        	# Move the restored file to the correct location
			# taken from https://docs.simplebackups.com/database-backup/f43rJaVYoNkbCGWqr3j9Jb/restore-a-redis-backup/aGGDek7aMmxgNSdEwUpUUi
			echo "INFO: Deleting old data present"
			kubectl exec restore-from-${VALKEY_VOLUME_NAME} -n ${VALKEY_NAMESPACE} --tty=false -- /bin/sh -c "rm -f /mnt/appendonlydir/* /mnt/*.rdb"

			echo "INFO: Copying the restored data to valkey volume"
	        	kubectl cp "/tmp/${VALKEY_NAME}.rdb" restore-from-${VALKEY_VOLUME_NAME}:/mnt/dump.rdb -n ${VALKEY_NAMESPACE}
	        
			echo "INFO: Change the ownership of the restored file"
			kubectl exec restore-from-${VALKEY_VOLUME_NAME} -n ${VALKEY_NAMESPACE} --tty=false -- /bin/sh -c "chown 1001:1001 /mnt/dump.rdb"

			echo "INFO: Deleting the restore pod"
			kubectl delete pod restore-from-${VALKEY_VOLUME_NAME} -n ${VALKEY_NAMESPACE}

		done
		# Before valkey is one more time restored, it is necessary to check what is the current configuration of the appendonly
		# If the appendonly parameter is set to no, then it can be just run the normal deployment saved.
		# if the appendonly is set to yes there are to ways to verify that:
		# - the commonConfiguration is not set in the yaml.
		#    * Then this means that it is taken from the default configuration of the deployment.
		# - else it is important to check if the appendonly parameter is present and then change it.
		# For all this steps if the appendonly is set to yes, it will be necessary to change it to no.
		# Then we will apply the yaml with the restore
		# When this is running, through the redis-cli we connect and change it to yes to reconestruct the aof files.
		# finally we will apply the original file with the appendonly yes so it can be fully restored with the paramenter set.

		set +e
		# Checking if it is configured valkey with appendonly yes
		# In other words if the appendonly is NOT set to no
		if (( $aof_found == 1 ));
		then
			echo "INFO: After modification deploy the instance with appendonly no"
			kubectl apply -f ${VALKEY_NAME}-mod.yaml -n ${VALKEY_NAMESPACE}

			echo "INFO: Sleep for 10 secs"
                        sleep 10

			echo "INFO: Waiting for the container to be ready"
			kubectl wait --for=condition=ContainersReady pods -n ${VALKEY_NAMESPACE} -l app.kubernetes.io/instance=${VALKEY_NAME}

			echo "INFO: Sleep for 10 secs"
			sleep 10

			echo "INFO: Detecting the new master node due to the redeployment changed the CLUSTER_IP"
			discover_master

			echo "INFO: Activate the appendonly to yes to reconstruct the aof files"
			redis-cli -h ${VALKEY_MASTER} -p ${VALKEY_PORT} $opts config set appendonly yes
			#redis-cli -h ${VALKEY_MASTER} -p ${VALKEY_PORT} $opts config rewrite

			echo "INFO: Sleep for 10 secs"
			sleep 10
		fi
                set -e

		echo "INFO: Restoring the valkey instance ${VALKEY_NAME} with the original configuration"
		kubectl apply -f ${VALKEY_NAME}.yaml -n ${VALKEY_NAMESPACE}

		echo "INFO: Sleep for 10 secs"
                sleep 10

                echo "INFO: Waiting for the container to be ready"
                kubectl wait --for=condition=ContainersReady pods -n ${VALKEY_NAMESPACE} -l app.kubernetes.io/instance=${VALKEY_NAME}

	
	        echo "INFO: Restore completed successfully for instance ${VALKEY_NAME}"
	        set +e
	fi

}

#
#
#
# Starting main program
#
#
#

if [[ "${RESTORE}" == "true" ]]; 
then
	echo "INFO: Restore of ${VALKEY_NAME}"

	discover_master

	case $RESTORE_OPERATION in
		"show_available_backups")
			show_available_backups
			;;
		"restore_last")
			restore_last
			;;
		"restore_snapshot")
			restore_snapshot 
			;;
		*)
			echo "Error: Restore option ( $RESTORE_OPERATION ) not valid"  >&2
			exit 1
			;;
	esac

else
	initialize_repository
	echo "INFO: Valkey type set: ${VALKEY_TYPE}"
	discover_master
	perform_redis_backup 
fi
