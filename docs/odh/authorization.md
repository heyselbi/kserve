# Protecting Inference Services under authorization

Starting Open Data Hub version 2.8, KServe is enhanced with request authorization
for `InferenceServices`. The protected services will require clients to provide
valid credentials in the HTTP Authorization request header. The provided credentials
must be valid, and must have enough privileges for the request to be accepted.

## Setup

Authorization was implemented using [Istio's External Authorization
feature](https://istio.io/latest/docs/tasks/security/authorization/authz-custom/).
The chosen external authorized is [Kuadrant's Authorino project](https://github.com/Kuadrant/authorino).

The Open Data Hub operator will deploy and manage an instance of Authorino. For
this, the [Authorino Operator](https://github.com/Kuadrant/authorino-operator) is
required to be installed in the cluster, which is [available in the
OperatorHub](https://operatorhub.io/operator/authorino-operator).

At the moment, it is not possible to opt-out from the authorization feature. This
means that you need to install the Authorino operator before installing or
upgrading to Open Data Hub 2.8. 

Once you install Open Data Hub 2.8, the minimal `DSCInitialization` resource
required for KServe is the following one:

```yaml
kind: DSCInitialization
apiVersion: dscinitialization.opendatahub.io/v1
metadata:
  name: default-dsci
spec:
  applicationsNamespace: opendatahub
  serviceMesh:
    controlPlane:
      metricsCollection: Istio
      name: data-science-smcp
      namespace: istio-system
    managementState: Managed
  trustedCABundle:
    customCABundle: ''
    managementState: Managed
```

After creating the `DSCInitialization` resource, the Open Data Hub operator should
deploy a Service Mesh instance, and an Authorino instance. Both components will
be configured to work together.

To deploy KServe, the minimal `DataScienceCluster` resource required is the
following one:

```yaml
kind: DataScienceCluster
apiVersion: datasciencecluster.opendatahub.io/v1
metadata:
  name: default-dsc
spec:
  components:
    codeflare:
      managementState: Removed
    dashboard:
      managementState: Removed
    datasciencepipelines:
      managementState: Removed
    kserve:
      managementState: Managed
      serving:
        ingressGateway:
          certificate:
            type: SelfSigned
        managementState: Managed
        name: knative-serving
    kueue:
      managementState: Removed
    modelmeshserving:
      managementState: Removed
    modelregistry:
      managementState: Removed
    ray:
      managementState: Removed
    trustyai:
      managementState: Removed
    workbenches:
      managementState: Removed
```

Notice that the provided `DataScienceCluster` is a KServe-only installation which
will deploy Knative serving and configure it to work with the Service Mesh and
Authorino instances that were deployed via the `DSCInitialization` resource.

## Deploying a protected InferenceService

To demonstrate how to protect an `InferenceService`, a sample model generally
available from the upstream community will be used. The sample model is a
Scikit-learn model, and the following `ServingRuntime` needs to be created in
some namespace:

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: kserve-sklearnserver
spec:
  annotations:
    prometheus.kserve.io/port: '8080'
    prometheus.kserve.io/path: "/metrics"
    serving.knative.openshift.io/enablePassthrough: "true"
    sidecar.istio.io/inject: "true"
    sidecar.istio.io/rewriteAppHTTPProbers: "true"
  supportedModelFormats:
    - name: sklearn
      version: "1"
      autoSelect: true
      priority: 1
  protocolVersions:
    - v1
    - v2
  containers:
    - name: kserve-container
      image: docker.io/kserve/sklearnserver:latest
      args:
        - --model_name={{.Name}}
        - --model_dir=/mnt/models
        - --http_port=8080
      resources:
        requests:
          cpu: "1"
          memory: 2Gi
        limits:
          cpu: "1"
          memory: 2Gi
```

Then, deploy the sample model by creating the following `InferenceService` resource
in the same namespace as the previous `ServingRuntime`:

```yaml
apiVersion: "serving.kserve.io/v1beta1"
kind: "InferenceService"
metadata:
  name: "sklearn-v2-iris"
spec:
  predictor:
    model:
      modelFormat:
        name: sklearn
      protocolVersion: v2
      runtime: kserve-sklearnserver
      storageUri: "gs://kfserving-examples/models/sklearn/1.0/model"
```

The `InferenceService` still does not have authorization enabled. A sanity check
can be done by sending an unauthenticated request to the service, which should
reply as normally:

```bash
# Get the endpoint of the InferenceService
MODEL_ENDPOINT=$(kubectl get inferenceservice sklearn-v2-iris -o jsonpath='{.status.url}')
# Send an inference request:
curl -v \
  -H "Content-Type: application/json" \
  -d @./iris-input-v2.json \
  ${MODEL_ENDPOINT}/v2/models/sklearn-v2-iris/infer
```

You can download the `iris-input-v2.json` file from the following link:
[iris-input.json](https://github.com/opendatahub-io/kserve/blob/c146e06df7ea3907cd3702ed539b1da7885b616c/docs/samples/v1beta1/xgboost/iris-input.json)

If the sanity check is successful, the `InferenceService` is protected by
adding the `security.opendatahub.io/enable-auth=true` annotation:

```bash
oc annotate isvc sklearn-v2-iris security.opendatahub.io/enable-auth=true
```

The KServe controller will re-deploy the model. Once it is ready, the previous
`curl` request should be rejected because it is missing credentials. The credentials
are provided via the standard HTTP Authorization request header. The updated
`curl` request has the following form:

```bash
curl -v \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN"
  -d @./iris-input-v2.json \
  ${MODEL_ENDPOINT}/v2/models/sklearn-v2-iris/infer
```

You can provide any `$TOKEN` that is accepted by the OpenShift API server. The
request will only be accepted if the provided token has the `get` privilege over
`v1/Services` resources (core Kubernetes Services) in the namespace where
the `InferenceService` lives.
