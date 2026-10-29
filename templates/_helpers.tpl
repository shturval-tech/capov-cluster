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
Secret в capov-system с ключами username и password.
OVirtProvider 2.15 требует spec.credentialsSecretName.
*/}}
{{- define "capov-cluster.credentialsSecretName" -}}
{{- printf "%s-capov-provider-secret" (include "capov-cluster.providerName" .) -}}
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
{{- /* Существующий ключ не пересчитываем. */ -}}
{{- $key = index $existing.data "secret" | b64dec -}}
{{- else if .Values.etcd.encryptionSeed -}}
{{- $key = sha256sum (printf "%s:%s-encryption-key" (toString .Values.etcd.encryptionSeed) .Release.Name) | trunc 32 -}}
{{- else -}}
{{- $cc := lookup "cluster.shturval.tech/v1beta1" "ClusterConfig" .Release.Name .Release.Name -}}
{{- if and $cc $cc.spec -}}
{{- /* Апгрейд существующего кластера: ключ не меняем. */ -}}
{{- $key = sha256sum (printf "%s-encryption-key" .Release.Name) | trunc 32 -}}
{{- else -}}
{{- fail (printf "новый кластер %s: задайте etcd.encryptionSeed в values (случайная строка, например `openssl rand -base64 32`). Без seed шифрование etcd не будет безопасным." .Release.Name) -}}
{{- end -}}
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
cluster-autoscaler image.
Тег из профиля релиза, не из kubeVersion: 2.15.0 — v1.36.1-325745, 2.14.x — v1.35.1.
Реестр — systemregistry. Полный образ переопределяется images.clusterAutoscaler.
*/}}
{{- define "capov-cluster.clusterAutoscalerImage" -}}
{{- if and .Values.images .Values.images.clusterAutoscaler -}}
{{- .Values.images.clusterAutoscaler -}}
{{- else -}}
{{- $p := include "capov-cluster.releaseProfile" . | fromYaml -}}
{{- $tag := $p.clusterAutoscalerTag | default (printf "v%s" (include "capov-cluster.effectiveKubeVersion" .)) -}}
{{- printf "%s/autoscaling/cluster-autoscaler:%s" .Values.systemregistry $tag -}}
{{- end -}}
{{- end -}}

{{/*
kube-vip image for NCI.
images.kubeVip, иначе conf/releases, иначе nodeInit.kubevip.image.
*/}}
{{- define "capov-cluster.kubeVipImage" -}}
{{- $images := .Values.images | default dict -}}
{{- if $images.kubeVip -}}
{{- $images.kubeVip -}}
{{- else -}}
{{- $p := include "capov-cluster.releaseProfile" . | fromYaml -}}
{{- if $p.kubeVipImage -}}
{{- $p.kubeVipImage -}}
{{- else -}}
{{- $ni := .Values.nodeInit | default dict -}}
{{- $kv := $ni.kubevip | default dict -}}
{{- required "images.kubeVip (или профиль релиза, или nodeInit.kubevip.image) is required" $kv.image -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
pause image for NCI.
images.pause, иначе conf/releases, иначе nodeInit.pauseImage.
*/}}
{{- define "capov-cluster.pauseImage" -}}
{{- $images := .Values.images | default dict -}}
{{- if $images.pause -}}
{{- $images.pause -}}
{{- else -}}
{{- $p := include "capov-cluster.releaseProfile" . | fromYaml -}}
{{- if $p.pauseImage -}}
{{- $p.pauseImage -}}
{{- else -}}
{{- $ni := .Values.nodeInit | default dict -}}
{{- required "images.pause (или профиль релиза, или nodeInit.pauseImage) is required" $ni.pauseImage -}}
{{- end -}}
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

{{/*
Профиль релиза: conf/releases/<shturvalReleaseVersion>.yaml.
Явные values важнее. Профиль нужен для полей, которых не было в 2.14 (CoreDNS),
и как запасной источник, если kubeVersion пустой.
*/}}
{{- define "capov-cluster.releaseProfile" -}}
{{- $ver := .Values.shturvalReleaseVersion | default "2.15.0" -}}
{{- $path := printf "conf/releases/%s.yaml" $ver -}}
{{- $raw := .Files.Get $path -}}
{{- if not $raw -}}
{{- fail (printf "нет профиля релиза %s (%s). Ожидаются 2.14.0, 2.14.1 или 2.15.0" $ver $path) -}}
{{- end -}}
{{- $raw -}}
{{- end -}}

{{- define "capov-cluster.effectiveKubeVersion" -}}
{{- if .Values.kubeVersion -}}
{{- .Values.kubeVersion -}}
{{- else -}}
{{- (include "capov-cluster.releaseProfile" . | fromYaml).kubeVersion -}}
{{- end -}}
{{- end -}}

{{/*
Шаблон ВМ по умолчанию: capov.kubeTemplates[<effectiveKubeVersion>].
Может вернуть пустую строку — тогда обязателен явный master.template / <group>.template.
*/}}
{{- define "capov-cluster.defaultVMBaseTemplate" -}}
{{- $kubeVersion := include "capov-cluster.effectiveKubeVersion" . | toString | trim -}}
{{- $normalizedVersion := printf "v%s" (trimPrefix "v" $kubeVersion) -}}
{{- get (.Values.capov.kubeTemplates | default dict) $normalizedVersion | default "" -}}
{{- end -}}

{{/*
Обязательный шаблон ВМ: явный override или capov.kubeTemplates по kubeVersion.
Аргументы: dict "explicit" <значение> "root" $
*/}}
{{- define "capov-cluster.requiredVMBaseTemplate" -}}
{{- $explicit := .explicit | default "" -}}
{{- if $explicit -}}
{{- $explicit -}}
{{- else -}}
{{- $fallback := include "capov-cluster.defaultVMBaseTemplate" .root -}}
{{- required (printf "шаблон ВМ не задан: укажите template у группы/master либо добавьте capov.kubeTemplates[\"v%s\"]" (include "capov-cluster.effectiveKubeVersion" .root | trimPrefix "v")) $fallback -}}
{{- end -}}
{{- end -}}

{{/*
Тег CoreDNS. Пустая строка для 2.14.x — блок dns в KubeadmControlPlane не пишется.
Переопределение: images.coreDNS.
*/}}
{{- define "capov-cluster.coreDNSTag" -}}
{{- if and .Values.images (index .Values.images "coreDNS") -}}
{{- index .Values.images "coreDNS" -}}
{{- else -}}
{{- $p := include "capov-cluster.releaseProfile" . | fromYaml -}}
{{- $p.coreDNSImageTag | default "" -}}
{{- end -}}
{{- end -}}

{{/*
Тег etcd. Явный etcd.local.imageTag важнее профиля релиза.
*/}}
{{- define "capov-cluster.etcdImageTag" -}}
{{- $local := .Values.etcd.local | default dict -}}
{{- if $local.imageTag -}}
{{- $local.imageTag -}}
{{- else -}}
{{- $p := include "capov-cluster.releaseProfile" . | fromYaml -}}
{{- required "etcd.local.imageTag (или etcdImageTag в профиле релиза) is required" $p.etcdImageTag -}}
{{- end -}}
{{- end -}}

{{/*
Списки сервисов.
Если ClusterConfig уже есть — берём списки из него (webhook запрещает правку).
Иначе values и, для controllerType=gateway, та же нормализация, что ApplyIngressControllerServiceLists.
*/}}
{{- define "capov-cluster.serviceLists" -}}
{{- $enabled := .Values.services.enabledservices | default (list) -}}
{{- $disabled := .Values.services.disablesservices | default (list) -}}
{{- $cc := lookup "cluster.shturval.tech/v1beta1" "ClusterConfig" .Release.Name .Release.Name -}}
{{- if and $cc $cc.spec $cc.spec.systemServicesConfig -}}
{{- $ssc := $cc.spec.systemServicesConfig -}}
{{- if hasKey $ssc "enabledServices" -}}
{{- $enabled = $ssc.enabledServices | default (list) -}}
{{- end -}}
{{- if hasKey $ssc "disabledServices" -}}
{{- $disabled = $ssc.disabledServices | default (list) -}}
{{- end -}}
{{- else -}}
{{- $gateway := eq (.Values.ingressControllerType | default "nginx") "gateway" -}}
{{- $install := "shturval-ingress-controller" -}}
{{- $remove := "shturval-gateway-api-crds" -}}
{{- if $gateway -}}
{{- $install = "shturval-gateway-api-crds" -}}
{{- $remove = "shturval-ingress-controller" -}}
{{- end -}}
{{- $newEnabled := list -}}
{{- $hasInstall := false -}}
{{- range $enabled -}}
{{- if ne . $remove -}}
{{- $newEnabled = append $newEnabled . -}}
{{- if eq . $install }}{{- $hasInstall = true }}{{- end -}}
{{- end -}}
{{- end -}}
{{- if not $hasInstall -}}
{{- $newEnabled = append $newEnabled $install -}}
{{- end -}}
{{- $enabled = $newEnabled -}}
{{- $newDisabled := list -}}
{{- $hasRemove := false -}}
{{- range $disabled -}}
{{- if ne . $install -}}
{{- $newDisabled = append $newDisabled . -}}
{{- if eq . $remove }}{{- $hasRemove = true }}{{- end -}}
{{- end -}}
{{- end -}}
{{- if and $gateway (not $hasRemove) -}}
{{- $newDisabled = append $newDisabled $remove -}}
{{- end -}}
{{- $disabled = $newDisabled -}}
{{- end -}}
enabled:
{{ toYaml $enabled | nindent 2 }}
disabled:
{{ toYaml $disabled | nindent 2 }}
{{- end -}}

{{- define "capov-cluster.validateIngressCerts" -}}
{{- $n := 0 -}}
{{- if .Values.ingressCert }}{{- $n = add $n 1 }}{{- end -}}
{{- if .Values.caCert }}{{- $n = add $n 1 }}{{- end -}}
{{- if .Values.acme }}
{{- if or .Values.acme.serverURL .Values.acme.rootCA .Values.acme.rootCABundle .Values.acme.email }}
{{- $n = add $n 1 }}
{{- end }}
{{- end -}}
{{- if .Values.vault }}
{{- if or .Values.vault.server .Values.vault.path .Values.vault.token .Values.vault.caBundle .Values.vault.rootCA }}
{{- $n = add $n 1 }}
{{- end }}
{{- end -}}
{{- if gt (int $n) 1 -}}
{{- fail "укажите только один способ сертификата ingress: ingressCert, caCert, acme или vault" -}}
{{- end -}}
{{- $ct := .Values.ingressControllerType | default "nginx" -}}
{{- if not (or (eq $ct "nginx") (eq $ct "gateway")) -}}
{{- fail "ingressControllerType должен быть nginx или gateway" -}}
{{- end -}}
{{- if and .Values.update .Values.update.strategy -}}
{{- if not (or (eq .Values.update.strategy "InPlace") (eq .Values.update.strategy "RollingUpdate")) -}}
{{- fail "update.strategy должен быть InPlace или RollingUpdate" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "capov-cluster.assertCompatibleUpgrade" -}}
{{- $cc := lookup "cluster.shturval.tech/v1beta1" "ClusterConfig" .Release.Name .Release.Name -}}
{{- if and $cc $cc.spec $cc.spec.releaseVersion -}}
{{- $live := $cc.spec.releaseVersion | toString -}}
{{- $want := .Values.shturvalReleaseVersion | toString -}}
{{- if and $live (ne $live $want) (not .Values.platformUpgrade) -}}
{{- fail (printf "ClusterConfig %s уже имеет spec.releaseVersion=%s, в values указано %s. Смена версии запускает обновление платформы. Чтобы обновить только чарт, оставьте shturvalReleaseVersion=%s. Чтобы обновить платформу, задайте platformUpgrade=true. При helm template и в Argo CD lookup пустой, проверка не срабатывает — сверяйте values с живым ClusterConfig до apply." .Release.Name $live $want $live) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "capov-cluster.preflight" -}}
{{- include "capov-cluster.validateIngressCerts" . -}}
{{- include "capov-cluster.assertCompatibleUpgrade" . -}}
{{- end -}}

{{/*
Имя Secret, который cluster-manager читает как values shturval-capov-csi.
Совпадает с backend (ovirt-csi-config в namespace кластера, ключ data).
*/}}
{{- define "capov-cluster.csiSecretName" -}}
ovirt-csi-config
{{- end -}}

{{- define "capov-cluster.csiConfigYaml" -}}
ovirtCredentials:
  ovirtCaBundle: {{ include "capov-cluster.capov.caCerts" . | quote }}
  ovirtInsecure: {{ .Values.capov.tls.insecure | toString | quote }}
  ovirtPassword: {{ .Values.capov.password | quote }}
  ovirtUrl: {{ .Values.capov.engineAddress | quote }}
  ovirtUsername: {{ .Values.capov.username | quote }}
storageClass:
  parameters:
    storageDomainName: {{ .Values.capov.storageDomainName | quote }}
{{- end -}}

{{/*
true, если в ClusterConfig нужна ссылка на секрет, который собирает чарт.
*/}}
{{- define "capov-cluster.csiSecretWanted" -}}
{{- $root := . -}}
{{- $name := include "capov-cluster.csiSecretName" $root -}}
{{- $on := false -}}
{{- if $root.Values.csi -}}
{{- range $root.Values.csi -}}
{{- if eq .serviceConfigName "shturval-capov-csi" -}}
{{- if not .providerSecretRef -}}
{{- $on = true -}}
{{- else if and (eq .providerSecretRef.name $name) (or (not .providerSecretRef.namespace) (eq .providerSecretRef.namespace $root.Release.Name)) -}}
{{- $on = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- else if $root.Values.capov.enableCSI -}}
{{- $on = true -}}
{{- end -}}
{{- if $on }}true{{ end -}}
{{- end -}}
