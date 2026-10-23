{{/*
Expand the name of the chart.
*/}}
{{- define "capov-cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "capov-cluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "capov-cluster.labels" -}}
helm.sh/chart: {{ include "capov-cluster.chart" . }}
{{ include "capov-cluster.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "capov-cluster.selectorLabels" -}}
app.kubernetes.io/name: {{ include "capov-cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
OVirtProvider name — defaults to Release.Name if not set
*/}}
{{- define "capov-cluster.providerName" -}}
{{- default .Release.Name .Values.capov.providerName }}
{{- end }}

{{/*
Read the ClusterConfig secret value
*/}}
{{- define "capov-cluster.clusterConfig" -}}
{{- tpl (.Files.Get .Values.clusterConfigFile) . | b64enc | quote }}
{{- end }}

{{/*
etcd external CA cert
*/}}
{{- define "capov-cluster.etcd.caCrt" -}}
{{- if .Values.etcd.external.caCrt }}
{{- .Files.Get .Values.etcd.external.caCrt | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
etcd external client cert
*/}}
{{- define "capov-cluster.etcd.apiCrt" -}}
{{- if .Values.etcd.external.apiCrt }}
{{- .Files.Get .Values.etcd.external.apiCrt | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
etcd external client key
*/}}
{{- define "capov-cluster.etcd.apiKey" -}}
{{- if .Values.etcd.external.apiKey }}
{{- .Files.Get .Values.etcd.external.apiKey | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
oVirt Engine TLS CA cert (read from file if capov.tls.caCertsFile is set)
*/}}
{{- define "capov-cluster.capov.caCerts" -}}
{{- if .Values.capov.tls.caCertsFile }}
{{- .Files.Get .Values.capov.tls.caCertsFile }}
{{- end }}
{{- end }}

{{/*
Raw encryption key material (32 chars). Same contract as backend/cluster-manager/capsm:
  Secret.data["secret"] (after decode) == raw key
  EncryptionConfiguration aescbc.keys[].secret == base64(raw key)
Cached in Values._encryptionKey for one helm render so Secret and NCI always match.
*/}}
{{- define "capov-cluster.encryptionKeyMaterial" -}}
{{- if not .Values._encryptionKey -}}
{{- $key := "" -}}
{{- $secretName := printf "%s-encryption-configuration" .Release.Name -}}
{{- $existing := lookup "v1" "Secret" .Release.Name $secretName -}}
{{- if and $existing $existing.data $existing.data.secret -}}
{{- $key = index $existing.data "secret" | b64dec -}}
{{- else -}}
{{- $key = sha256sum (printf "%s-encryption-key" .Release.Name) | trunc 32 -}}
{{- end -}}
{{- $_ := set .Values "_encryptionKey" $key -}}
{{- end -}}
{{- .Values._encryptionKey -}}
{{- end -}}

{{/*
Backward-compatible alias: raw key material (NOT base64).
*/}}
{{- define "capov-cluster.encryptionKey" -}}
{{- include "capov-cluster.encryptionKeyMaterial" . -}}
{{- end -}}

{{/*
Content of /etc/kubernetes/secrets_encryption.yaml — format matches cluster-manager
pkg/nodeconfig/generator/security.go encryptionConfiguration().
*/}}
{{- define "capov-cluster.secretsEncryptionContent" -}}
---
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
    - secrets
    providers:
    - aescbc:
        keys:
          - name: key1
            secret: {{ include "capov-cluster.encryptionKeyMaterial" . | b64enc }}
    - identity: {}
{{- end -}}

{{/*
Generate nci.json (ShturvalInit) as base64-encoded JSON.
Usage: include "capov-cluster.nci.json.b64" (dict "ctx" . "controlplane" true)
  controlplane=true  — adds kube-vip (unless external LB), and when secure=true: secrets_encryption, audit_policy, etcd certs
  controlplane=false — directories and system config only (workers)
*/}}
{{- define "capov-cluster.nci.json.b64" -}}
{{- $ctx := .ctx -}}
{{- $nciCtx := dict
  "Values"       $ctx.Values
  "Files"        $ctx.Files
  "Release"      $ctx.Release
  "Chart"        $ctx.Chart
  "controlplane" .controlplane
-}}
{{- tpl ($ctx.Files.Get "conf/nci.yaml") $nciCtx | fromYaml | toJson | b64enc -}}
{{- end }}

{{/*
Generate monitoringid
*/}}
{{- define "capov-cluster.monitoringid" -}}
{{ adler32sum .Release.Name | int }}
{{- end }}

{{/*
Minimal KubeletConfiguration YAML — base64-encoded for injection via preKubeadmCommands.
Additional kubelet settings are managed by shturvald/NCI post-provisioning.
*/}}
{{- define "capov-cluster.kubelet.b64" -}}
{{- $cfg := `---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
protectKernelDefaults: true
` -}}
{{- $cfg | b64enc }}
{{- end }}

{{/*
kube-apiserver extra args.
Audit/encryption args only when secure=true.
OIDC args are intentionally omitted — they are configured by shturvald post-provisioning.
*/}}
{{- define "capov-cluster.apiserver" -}}
extraArgs:
{{- if .Values.secure }}
- name: audit-log-maxage
  value: "30"
- name: audit-log-maxbackup
  value: "10"
- name: audit-log-maxsize
  value: "100"
- name: audit-log-mode
  value: batch
- name: audit-log-path
  value: /var/log/kube-api-audit/audit.log
- name: audit-policy-file
  value: "{{ .Values.auditPolicy.location }}"
- name: encryption-provider-config
  value: /etc/kubernetes/secrets_encryption.yaml
{{- end }}
- name: authorization-mode
  value: Node,RBAC
- name: default-not-ready-toleration-seconds
  value: "30"
- name: default-unreachable-toleration-seconds
  value: "30"
- name: kubelet-certificate-authority
  value: /etc/kubernetes/pki/ca.crt
- name: profiling
  value: "false"
- name: request-timeout
  value: 60s
- name: tls-min-version
  value: VersionTLS13
{{- end }}

{{/*
kube-controller-manager extra args
*/}}
{{- define "capov-cluster.controllerManager" -}}
controllerManager:
  extraArgs:
  - name: bind-address
    value: 0.0.0.0
  - name: node-monitor-grace-period
    value: 20s
  - name: node-monitor-period
    value: 2s
  - name: profiling
    value: "false"
  - name: terminated-pod-gc-threshold
    value: "10"
  - name: tls-min-version
    value: VersionTLS13
{{- end }}

{{/*
kube-scheduler extra args
*/}}
{{- define "capov-cluster.scheduler" -}}
scheduler:
  extraArgs:
  - name: bind-address
    value: 0.0.0.0
  - name: profiling
    value: "false"
{{- end }}

{{/*
True if any workerNodes group has autoscaling.enabled.
*/}}
{{- define "capov-cluster.autoscalingEnabled" -}}
{{- $enabled := false -}}
{{- range $k, $v := .Values.workerNodes -}}
{{- if and $v.autoscaling $v.autoscaling.enabled -}}
{{- $enabled = true -}}
{{- end -}}
{{- end -}}
{{- $enabled -}}
{{- end -}}

{{/*
Resolve scale params for a worker MachineDeployment group.
Input: dict "root" $ "name" <groupKey> "group" <groupValues>
Output (YAML): enabled, minSize, maxMachines (if enabled), replicas

При autoscaling.enabled чарт не выставляет MachineDeployment.spec.replicas
(см. machinedeployment.yaml) — иначе helm template / helm-diff всегда
показывают drift относительно живого значения, которым владеет cluster-autoscaler.
replicas из values при этом остаётся min-size (пол автоскейлера);
фактический размер группы догоняет autoscaler (--enforce-node-group-min-size).
*/}}
{{- define "capov-cluster.workerGroupScale" -}}
{{- $name := .name -}}
{{- $group := .group -}}
{{- $autoscaling := $group.autoscaling | default dict -}}
{{- $enabled := $autoscaling.enabled | default false -}}
{{- $minSize := $group.replicas -}}
{{- $replicas := $group.replicas -}}
{{- if $enabled -}}
{{- $_ := required (printf "workerNodes.%s.replicas is required when autoscaling.enabled" $name) $group.replicas -}}
{{- $_ := required (printf "workerNodes.%s.autoscaling.maxMachines is required when autoscaling.enabled" $name) $autoscaling.maxMachines -}}
{{- if gt (int $minSize) (int $autoscaling.maxMachines) -}}
{{- fail (printf "workerNodes.%s.replicas (%v) must be <= autoscaling.maxMachines (%v)" $name $minSize $autoscaling.maxMachines) -}}
{{- end -}}
{{- end -}}
enabled: {{ $enabled }}
minSize: {{ $minSize }}
{{- if $enabled }}
maxMachines: {{ $autoscaling.maxMachines }}
{{- end }}
replicas: {{ $replicas }}
{{- end -}}

{{/*
cluster-autoscaler image: <systemregistry>/autoscaling/cluster-autoscaler:v<kubeVersion>
Override via images.clusterAutoscaler when needed.
*/}}
{{- define "capov-cluster.clusterAutoscalerImage" -}}
{{- if and .Values.images .Values.images.clusterAutoscaler -}}
{{- .Values.images.clusterAutoscaler -}}
{{- else -}}
{{- printf "%s/autoscaling/cluster-autoscaler:v%s" .Values.systemregistry .Values.kubeVersion -}}
{{- end -}}
{{- end -}}

{{/*
kube-vip image for NCI (images.kubeVip, fallback nodeInit.kubevip.image)
*/}}
{{- define "capov-cluster.kubeVipImage" -}}
{{- $images := .Values.images | default dict -}}
{{- if $images.kubeVip -}}
{{- $images.kubeVip -}}
{{- else -}}
{{- $ni := .Values.nodeInit | default dict -}}
{{- $kv := $ni.kubevip | default dict -}}
{{- required "images.kubeVip (or nodeInit.kubevip.image) is required" $kv.image -}}
{{- end -}}
{{- end -}}

{{/*
pause image for NCI (images.pause, fallback nodeInit.pauseImage)
*/}}
{{- define "capov-cluster.pauseImage" -}}
{{- $images := .Values.images | default dict -}}
{{- if $images.pause -}}
{{- $images.pause -}}
{{- else -}}
{{- $ni := .Values.nodeInit | default dict -}}
{{- required "images.pause (or nodeInit.pauseImage) is required" $ni.pauseImage -}}
{{- end -}}
{{- end -}}

{{/*
VIP interface for kube-vip (nodeInit.kubevip.interface)
*/}}
{{- define "capov-cluster.vipInterface" -}}
{{- $ni := .Values.nodeInit | default dict -}}
{{- $kv := $ni.kubevip | default dict -}}
{{- $kv.interface | default "eth0" -}}
{{- end -}}

{{/*
Filename for a kubeadm patch in kubeadmPatches.directory.
patch.filename, otherwise kubeapi → kube-apiserver.yaml, otherwise <name>.yaml.
*/}}
{{- define "capov-cluster.kubeadmPatchFilename" -}}
{{- $name := .name -}}
{{- $patch := .patch | default dict -}}
{{- if $patch.filename -}}
{{- $patch.filename -}}
{{- else if eq $name "kubeapi" -}}
kube-apiserver.yaml
{{- else -}}
{{- printf "%s.yaml" $name -}}
{{- end -}}
{{- end -}}
