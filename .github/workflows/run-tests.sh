#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

source $FATS_DIR/.configure.sh

# setup namespace
kubectl create namespace $NAMESPACE
fats_create_push_credentials $NAMESPACE
source ${FATS_DIR}/macros/create-riff-dev-pod.sh

if [ $RUNTIME = "streaming" ]; then
  echo "##[group]Create gateway"
  riff streaming kafka-gateway create franz --bootstrap-servers kafka.kafka.svc.cluster.local:9092 --namespace $NAMESPACE --tail
  echo "##[endgroup]"
fi

for test in java java-boot node npm command; do
  if [ $RUNTIME = "streaming" -a $test = "command" ]; then
    continue
  fi

  name=fats-cluster-uppercase-${test}
  image=$(fats_image_repo ${name})
  curl_opts="-H Content-Type:text/plain -H Accept:text/plain -d release"
  expected_data="RELEASE"

  echo "##[group]Run function $name"

  riff function create $name --image $image --namespace $NAMESPACE --tail \
    --git-repo https://github.com/$FATS_REPO --git-revision $FATS_REFSPEC --sub-path functions/uppercase/${test} &

  if [ $RUNTIME = "core" ]; then
    riff $RUNTIME deployer create $name \
      --function-ref $name \
      --ingress-policy External \
      --namespace $NAMESPACE \
      --tail

    # TODO also test external ingress for core runtime
    source ${FATS_DIR}/macros/invoke_incluster.sh \
      "$(kubectl get deployers.${RUNTIME}.projectriff.io ${name} --namespace ${NAMESPACE} -ojsonpath='{.status.address.url}')" \
      "${curl_opts}" \
      "${expected_data}"

    riff $RUNTIME deployer delete $name --namespace $NAMESPACE
  fi

  if [ $RUNTIME = "knative" ]; then
    riff $RUNTIME deployer create $name \
      --function-ref $name \
      --ingress-policy External \
      --namespace $NAMESPACE \
      --tail

    # TODO also test clusterlocal ingress for knative runtime
    source ${FATS_DIR}/macros/invoke_${RUNTIME}_deployer.sh \
      $name \
      "${curl_opts}" \
      "${expected_data}"

    riff $RUNTIME deployer delete $name --namespace $NAMESPACE
  fi

  if [ $RUNTIME = "streaming" ]; then
    lower_stream=${name}-lower
    upper_stream=${name}-upper

    riff streaming stream create ${lower_stream} --namespace $NAMESPACE --gateway franz --content-type 'text/plain' --tail
    riff streaming stream create ${upper_stream} --namespace $NAMESPACE --gateway franz --content-type 'text/plain' --tail

    riff streaming processor create $name --function-ref $name --namespace $NAMESPACE --input ${lower_stream} --output ${upper_stream} --tail

    kubectl exec riff-dev -n $NAMESPACE -- subscribe ${upper_stream} -n $NAMESPACE --payload-as-string | tee result.txt &
    sleep 10
    kubectl exec riff-dev -n $NAMESPACE -- publish ${lower_stream} -n $NAMESPACE --payload "system" --content-type "text/plain"

    actual_data=""
    expected_data="SYSTEM"
    cnt=1
    while [ $cnt -lt 60 ]; do
      echo -n "."
      cnt=$((cnt+1))

      actual_data=`cat result.txt | jq -r .payload`
      if [ "$actual_data" == "$expected_data" ]; then
        break
      fi

      sleep 1
    done
    fats_assert "$expected_data" "$actual_data"

    kubectl exec riff-dev -n $NAMESPACE -- sh -c 'kill $(pidof subscribe)'

    riff streaming stream delete ${lower_stream} --namespace $NAMESPACE
    riff streaming stream delete ${upper_stream} --namespace $NAMESPACE
    riff streaming processor delete $name --namespace $NAMESPACE
  fi

  riff function delete $name --namespace $NAMESPACE
  fats_delete_image $image

  echo "##[endgroup]"
done

if [ $RUNTIME = "streaming" ]; then
  riff streaming kafka-gateway delete franz --namespace $NAMESPACE
fi
