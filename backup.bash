#!/bin/bash

#set -e  # Exit on error

SCRIPTDIR="$(dirname "$0")"

source $SCRIPTDIR/env_vars.env

if [[ "${DEBUG_IMAGE}" == "true" ]];
then
	# show all the environment variables
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
	echo "Show list of available backups"
	echo
	restic -r "$RESTIC_REPOSITORY" snapshots
}

restore_last() {
	export SNAPSHOT_ID=$(restic -r "$RESTIC_REPOSITORY" snapshots --json --tag "${VALKEY_NAME}" | jq -r 'max_by(.time) | .id')
	echo "Restore the from the last snapshot"
	restore_snapshot
}

restore_snapshot() {

	if [ ! -z ${SNAPSHOT_ID} ];
	then
	        set -e
		# Procedure taken from: https://artifacthub.io/packages/helm/bitnami/valkey
		echo "Proceeding with the restore of the data from the snapshot: ${SNAPSHOT_ID}"
		echo

		echo "Saving the current valkey yaml manifest applied to the instance"
		kubectl apply view-last-applied valkey ${VALKEY_NAME} -n ${VALKEY_NAMESPACE} -o yaml > ${VALKEY_NAME}.yaml

		echo "Deleting the instance ${VALKEY_NAME} for the restore"
		kubectl delete valkey ${VALKEY_NAME} -n ${VALKEY_NAMESPACE}

		echo "Creating the pod to mount the volume of the node"
		kubectl run volpod -n ${VALKEY_NAMESPACE} --overrides='
		{
		    "apiVersion": "v1",
		    "kind": "Pod",
		    "metadata": {
		        "name": "restore-'${VALKEY_NAME}'-volpod"
		    },
		    "spec": {
		        "containers": [{
		           "command": [
		                "tail",
		                "-f",
		                "/dev/null"
		           ],
		           "image": "bitnami/os-shell",
		           "name": "mycontainer",
		           "volumeMounts": [{
		               "mountPath": "/mnt",
		               "name": "valkeydata"
		            }]
		        }],
		        "restartPolicy": "Never",
		        "volumes": [{
		            "name": "valkeydata",
		            "persistentVolumeClaim": {
		                "claimName": "valkey-data-'${VALKEY_NAME}'-primary-0"
		            }
		        }]
		    }
		}' --image="bitnami/os-shell"	


	        # Perform the restore
	        echo "INFO: Restoring Valkey backup for pod ${REDIS_NAME} from snapshot ID ${SNAPSHOT_ID}"
	        restic -r "$RESTIC_REPOSITORY" restore "${SNAPSHOT_ID}" --target "/"
	
 		if [[ "${DEBUG_IMAGE}" == "true" ]];
		then
			echo "Files local"
			ls -l
			echo
			echo "Files in /tmp"
			ls -l /tmp

		fi
					
	        # Move the restored file to the correct location
		echo "Copying the restored data to valkey volume"
	        kubectl cp "/tmp/${VALKEY_NAME}.rdb" restore-${VALKEY_NAME}-volpod:/mnt/dump.rdb -n ${VALKEY_NAMESPACE}

		echo "Deleting the restore pod"
		kubectl delete pod restore-${VALKEY_NAME}-volpod -n ${VALKEY_NAMESPACE}

		echo "Restarting the valkey instance ${VALKEY_NAME}"
		kubectl apply -f ${VALKEY_NAME}.yaml -n ${VALKEY_NAMESPACE}
	
	        # Change the ownership of the restored file
	        # chown redis:redis "${DATA_DIR}/dump.rdb"
	
	        echo "Restore completed successfully for instance ${VALKEY_NAME}"
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
