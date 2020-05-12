#!/bin/bash
pause(){
 echo $1
 read -n1 -rsp $'Press any key to continue or Ctrl+C to exit...\n'
}

node=$(oc get nodes --selector='node-role.kubernetes.io/worker' \
    --selector='!node-role.kubernetes.io/master' -o name | head -1 | sed -e 's|^node/||')

if [ -z "${WORKER_NODE}" ]; then
        pause "env WORKER_NODE not defined! using node ${node} as RT node?"
        export WORKER_NODE=${node}
elif  ! oc get node ${WORKER_NODE}; then
        pause "node ${WORKER_NODE} is not a valid node! using node ${node} as RT node?"
        export WORKER_NODE=${node}
else
        export WORKER_NODE=${WORKER_NODE}
fi

set -e
set -x

if ! oc version 2>&1 >/dev/null; then
	echo "failed to execute oc command"
	exit 1
fi

yum install -y wget skopeo jq

SRIOV_OPERATOR_REPO=https://github.com/openshift/sriov-network-operator.git
SRIOV_OPERATOR_NAMESPACE=openshift-sriov-network-operator

NUM_OF_WORKER=$(oc get nodes | grep ${WORKER_NODE} | wc -l)
NUM_OF_MASTER=$(oc get nodes | grep master | wc -l)

# override SR-IOV images
export OCP_VERSION=$(oc version | sed -r -n 's/Client Version:\s+([0-9].[0-9].[0-9]).*/\1/p')
if [ -z "$OCP_VERSION" ]; then
	echo "failed to get ocp version"
fi

# the following env.sh overwrite the upstream sriov-network-operator/hack/env.sh
source ./env.sh

if [ ! -d "sriov-network-operator" ]; then
	sudo git clone $SRIOV_OPERATOR_REPO
fi
pushd sriov-network-operator
make deploy-setup
popd

oc wait --for condition=available deployment sriov-network-operator -n $SRIOV_OPERATOR_NAMESPACE --timeout=60s
echo "deployment sriov-network-operator -n $SRIOV_OPERATOR_NAMESPACE is done"

for i in {1..10}; do
	sleep 10
	injector=$(oc get ds network-resources-injector \
			-n $SRIOV_OPERATOR_NAMESPACE | tail -n 1 | awk '{print $4}')
	webhook=$(oc get ds operator-webhook \
			-n $SRIOV_OPERATOR_NAMESPACE | tail -n 1 | awk '{print $4}')
	daemonset=$(oc get ds sriov-network-config-daemon \
			-n $SRIOV_OPERATOR_NAMESPACE | tail -n 1 | awk '{print $4}')

	if [ "${injector:-0}" -eq "$NUM_OF_MASTER" ] && [ "${webhook:-0}" -eq "$NUM_OF_MASTER" ] \
		&& [ "${daemonset:-0}" -ge "$NUM_OF_WORKER" ]; then
		break
	fi

	if [ "$i" -eq 10 ]; then
		echo "oc get ds network-resources-injector/operator-webhook/sriov-network-config-daemon -n $SRIOV_OPERATOR_NAMESPACE failed"
		exit 1
	fi
done

for worker in $(oc get nodes | grep ${WORKER_NODE} | awk '{print $1}'); do
	oc label node $worker \
		--overwrite=true feature.node.kubernetes.io/network-sriov.capable=true
done

# Wait for operator webhook to become ready
sleep 30

oc create -f policy-intel-west.yaml
oc create -f policy-intel-east.yaml
RESOURCE_NAME=$(sed -n -r 's/.*resourceName:\s*(\w+).*/\1/p' sn-intel-west.yaml)

for i in {1..60}; do
	sleep 10
	cni=$(oc get ds sriov-cni \
			-n $SRIOV_OPERATOR_NAMESPACE | tail -n 1 | awk '{print $4}')
	dp=$(oc get ds sriov-device-plugin \
			-n $SRIOV_OPERATOR_NAMESPACE | tail -n 1 | awk '{print $4}')

	if [ "$cni" -ge "$NUM_OF_WORKER" ] && [ "$dp" -ge "$NUM_OF_WORKER" ]; then
		break
	fi

	if [ $i -eq 60 ]; then
		exit 1
	fi
done

#Wait for device plugin be rebooted
sleep 30

for i in {1..30}; do
	sleep 20
	count=0
	for worker in $(oc get nodes | grep ${WORKER_NODE} | awk '{print $1}'); do
		resource=$(oc get node $worker \
			-o jsonpath="{.status.allocatable.openshift\.io/${RESOURCE_NAME}}")

		if [ $resource -gt 0 ]; then
			count=$((count+1))
		fi
	done

	if [ $count == $NUM_OF_WORKER ]; then
		break
	fi

	if [ $i -eq 30 ]; then
		echo "couldn't get all configured sriov resource"
		exit 1
	fi
done

oc create -f sn-intel-east.yaml
oc create -f sn-intel-west.yaml

