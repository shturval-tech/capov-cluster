# capov-cluster

Helm-чарт для развёртывания Kubernetes-кластера через **Cluster API** с
инфраструктурным провайдером **CAPOV (Cluster API Provider oVirt)** и
Shturval `ClusterConfig`. По смыслу — аналог `capvs-cluster` / `capsm-cluster`,
но VM поднимаются в oVirt.

Чарт создаёт:

- `Namespace` под кластер (имя = `Release.Name`)
- `OVirtProvider` + `OVirtCluster` + `Cluster` (Cluster API)
- `KubeadmControlPlane` + `OVirtMachineTemplate` для control-plane
- По одному `MachineDeployment` + `KubeadmConfigTemplate` +
  `OVirtMachineTemplate` на каждую worker-группу из `values.yaml`
- `MachineHealthCheck` (опционально, на control-plane и/или worker-группы)
- Shturval-специфику: `ClusterConfig`, secret с базовой конфигурацией,
  secret для encryption-at-rest, внешние etcd-секреты (если используется)
- при `workerNodes.<group>.autoscaling.enabled` — Deployment
  `{release}-autoscaler` (Cluster API cluster-autoscaler) + аннотации min/max
  на соответствующем `MachineDeployment`
- опционально (сабчарты): VMAlert/VMRule и Grafana datasource в
  management-кластере (`capov-cluster-vm` / `capov-cluster-grafana`)

> **VIP API:** на control-plane в `/etc/std/nci.json` (ShturvalInit) задаётся
> static Pod **kube-vip** с `vip_address` = `clusterAPI`.
> В `values` см. `nodeInit.kubevip.interface` (обычно `eth0` или `ens*` внутри
> гостя oVirt). Если используете внешний LB, установите
> `useExternalKubeAPILB: true`.

## Предварительные требования

1. Управляющий кластер с установленными операторами:
   - `cluster-api` core;
   - `cluster-api-provider-ovirt` (CAPOV), CRD `infrastructure.cluster.x-k8s.io`
     (чарт использует `v1beta1` для инфраструктурных ресурсов);
2. В oVirt:
   - доступ к oVirt Engine API (`capov.engineAddress`);
   - пользователь с правами на создание/удаление VM;
   - подготовленные VM-шаблоны под целевые версии Kubernetes
     (см. `capov.kubeTemplates`);
   - существующие datacenter / ovirtCluster / storage domain / vNIC profile.
3. При использовании внешнего etcd — сертификаты лежат в `conf/ext_etcd-*`.

### Чувствительные данные и значения по умолчанию

В `values.yaml` заданы плейсхолдеры (`XXXXXXXX` для лицензии, `secret` для
пароля oVirt и т.п.). Реальные значения передавайте при установке:

- `helm upgrade --install ... -f values-local.yaml` (локальный файл не коммитить);
- или `--set licensetoken=...`, `--set capov.password=...` и т.д.

## Быстрый старт

```bash
helm upgrade --install mycluster . \
  --set licensetoken=XXXXXXXX \
  --set systemregistry=myregistry.domain.tld \
  --set kubeVersion=1.35.1 \
  --set clusterAPI=10.0.0.100 \
  --set ingressVip=10.0.0.101 \
  --set ingress="app.cluster.example.com" \
  --set capov.engineAddress="https://ovirt.example.com/ovirt-engine/api" \
  --set capov.username="admin@internal" \
  --set capov.password="supersecret" \
  --set capov.datacenter="Default" \
  --set capov.ovirtCluster="Default" \
  --set capov.storageDomainName="data" \
  --set capov.defaultVnicProfile="ovirtmgmt"
```

## Ключевые секции `values.yaml`

### Релиз 2.14

| Ключ | Назначение |
|------|-----------|
| `shturvalReleaseVersion` | `2.14.0` |
| `kubeVersion` | `1.35.1` |
| `images.pause` / `images.kubeVip` | переопределение образов NCI. Иначе берутся из `conf/releases/<shturvalReleaseVersion>.yaml` |
| `images.clusterAutoscaler` | полный образ CA. Иначе тег из профиля релиза (`2.15.0` — `v1.36.1-325745`) и реестр `systemregistry` |
| `services.enabledservices` / `disablesservices` | минимальный набор сервисов 2.14 |

### `capov` — глобальные настройки oVirt

| Ключ | Назначение |
|------|-----------|
| `providerName` | Имя `OVirtProvider`. Пусто => `Release.Name` |
| `engineAddress` | URL oVirt Engine API |
| `username`, `password` | Креденшелы oVirt |
| `tls.insecure` | Отключить проверку TLS (только для dev/test) |
| `tls.useSystemCA` | Использовать системные CA |
| `tls.caCertsFile` | Путь к PEM-файлу CA для oVirt |
| `datacenter`, `ovirtCluster`, `storageDomainName` | Базовый placement для ВМ |
| `templateNetInterface` | Интерфейс в гостевой ОС для cloud-init |
| `defaultVmType` | Тип ВМ (`desktop`, `server`, `high_performance`) |
| `defaultVnicProfile` | vNIC profile по умолчанию |
| `allowEditCSI` | Флаг аннотации для Shturval CSI |
| `enableCSI` | `true` — `shturval-capov-csi` и Secret `ovirt-csi-config` из полей `capov` |
| `ipPoolName` | Имя пула IP (добавляется как label на `OVirtProvider`) |
| `kubeTemplates` | Маппинг `v<k8s-version> -> template` в oVirt |

### Per-group переопределения

`master.*` и `workerNodes.<group>.*` могут переопределить часть параметров
`capov.*`:

```yaml
master:
  replicas: 3
  vmtype: high_performance
  cpu:
    sockets: 2
    cores: 4
    threads: 1
  memory:
    sizemb: 8192
    guaranteedmb: 4096
  osdisksizegb: 80
  nics:
    - vnicprofile: ovirtmgmt

workerNodes:
  workers:
    replicas: 3
    cpu:
      sockets: 2
      cores: 4
      threads: 1
    memory:
      sizemb: 8192
      guaranteedmb: 4096
    osdisksizegb: 80
  infra:
    replicas: 2
    taints:
      - key: mytaint/infra
        effect: NoSchedule
```

### Сеть и балансировщики

- `clusterAPI` — endpoint kube-apiserver (VIP или внешний LB)
- `useExternalKubeAPILB`:
  - `false` => поднимается VIP через kube-vip/keepalived
  - `true` => используется внешний балансировщик
- `ingressVip`, `useExternalIngressLB` — аналогично для ingress

### Внешний etcd

```yaml
etcd:
  external:
    endpoints:
      - "https://10.0.0.1:2379"
    caCrt: "conf/ext_etcd-ca.crt"
    apiCrt: "conf/ext_etcd-client.crt"
    apiKey: "conf/ext_etcd-client.key"
```

При `etcd.external` чарт создаёт secrets:
- `<release>-etcd`
- `<release>-apiserver-etcd-client`

## API-версии

- `infrastructure.cluster.x-k8s.io/v1beta1` — `OVirtProvider`,
  `OVirtCluster`, `OVirtMachineTemplate`
- `cluster.x-k8s.io/v1beta2` — `Cluster`, `MachineDeployment`,
  `MachineHealthCheck`
- `controlplane.cluster.x-k8s.io/v1beta2` — `KubeadmControlPlane`
- `bootstrap.cluster.x-k8s.io/v1beta2` — `KubeadmConfigTemplate`
- `cluster.shturval.tech/v1beta1` — `ClusterConfig`

## Типовые сценарии

### Изменить количество реплик worker-группы

```yaml
workerNodes:
  workers:
    replicas: 5
```

Затем выполните `helm upgrade`. CAPOV создаст новые VM в oVirt.

### Автомасштабирование группы узлов (cluster-autoscaler)

Для группы worker-узлов можно включить автомасштабирование через Cluster API
cluster-autoscaler (как в UI/backend Штурвала и в чартах `capsm-cluster` /
`capvs-cluster`):

```yaml
workerNodes:
  workers:
    replicas: 2 # минимум и стартовое число узлов
    autoscaling:
      enabled: true
      maxMachines: 6
    cpu:
      sockets: 2
      cores: 4
      threads: 1
    memory:
      sizemb: 8192
      guaranteedmb: 4096
    osdisksizegb: 80
```

Что происходит при `autoscaling.enabled: true`:

- на `MachineDeployment` выставляются аннотации
  `cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size` (= `replicas`) и
  `...-max-size` (= `maxMachines`);
- `spec.replicas` **не рендерится** (им владеет autoscaler) — иначе
  `helm template` / helm-diff показывают вечный drift;
- в namespace кластера создаются ServiceAccount, ClusterRoleBinding на
  `shturval-cluster-autoscaler` и Deployment `{release}-autoscaler`
  с `--enforce-node-group-min-size`.

CAPOV при scale up создаёт новые VM в oVirt из template — нужны свободные
ресурсы и квота. На management-кластере должен быть ClusterRole
`shturval-cluster-autoscaler` (ставит платформа).

### Добавить новую worker-группу

```yaml
workerNodes:
  gpu:
    replicas: 2
    vmtype: high_performance
    cpu:
      sockets: 2
      cores: 8
      threads: 1
    memory:
      sizemb: 32768
      guaranteedmb: 16384
    osdisksizegb: 120
    labels:
      - "node-role.kubernetes.io/gpu="
    taints:
      - key: node-role.kubernetes.io/gpu
        effect: NoSchedule
```

### Включить MachineHealthCheck для группы

```yaml
workerNodes:
  workers:
    machineHealthCheck:
      enabled: true
      checks:
        nodeStartupTimeoutSeconds: 0
        unhealthyNodeConditions:
          - status: "False"
            timeoutSeconds: 600
            type: Ready
      remediation:
        triggerIf:
          unhealthyLessThanOrEqualTo: 40%
```

### Не поднимается VIP для kube-apiserver (`clusterAPI`)

Проверьте:

1. Корректность `clusterAPI` и доступность IP в нужной L2-сети.
2. Правильность `nodeInit.kubevip.interface` (проверьте `ip -br a` на master).
3. Наличие `/etc/std/nci.json` и Pod `kube-vip` на control-plane-ноде.
4. Логи `shturvald` / `std` (должно дойти до `std node status == synched`).
5. Если внешний LB — используйте `useExternalKubeAPILB: true`.

### Мониторинг в management-кластере

Сабчарты (те же, что в CAPSM/CAPVS; в values — через alias):

```yaml
capov-cluster-vm:
  enable: true       # VMAlert / VMRule под monitoringId кластера
capov-cluster-grafana:
  enable: true       # datasource в Grafana management-кластера
```

Ресурсы создаются в namespace релиза (имя клиентского кластера).

## Удаление

```bash
helm uninstall mycluster
```

VM будут удалены контроллерами Cluster API и CAPOV после удаления
`MachineDeployment` / `KubeadmControlPlane`.

## Обновление чарта с 2.14 на 2.15

Чарт `2.15` ставит новый кластер Штурвала **2.15.0** (Kubernetes 1.36.5).
Уже работающий кластер 2.14 этим чартом обновляется только как Helm-релиз:
машины не пересоздаются и обновление платформы не стартует, если values
по-прежнему описывают 2.14.

1. Сначала обновите менеджмент-кластер до Штурвала 2.15 (CRD `InfrastructureProvider`, CAPI v1beta2). Потом обновляйте чарты клиентских кластеров.
2. Возьмите values, которыми кластер ставился (`helm get values <release> -n <namespace> -o yaml`), а не дефолты нового чарта.
3. Не используйте `--reuse-values` вслепую и не подставляйте голый `--reset-values`: новый чарт по умолчанию содержит `shturvalReleaseVersion: 2.15.0`, `kubeVersion: 1.36.5`, новые теги etcd, pause и kube-vip. Для обновления только чарта оставьте прежние версии.
4. Предпочтительно `helm upgrade --reset-then-reuse-values` вместе с файлом старых values, затем `helm diff upgrade` (если плагин установлен) или `helm template` / `helm upgrade --dry-run`.
5. `shturvalReleaseVersion` меняйте только вместе с `platformUpgrade: true`. Иначе при живом кластере чарт останавливает рендер: смена `spec.releaseVersion` запускает обновление платформы. `helm template` и Argo CD не видят объекты кластера (`lookup` пустой), поэтому проверку нужно сделать до apply.
6. `enabledServices` и `disabledServices` у существующего ClusterConfig чарт не переписывает: webhook запрещает их менять, списки читаются из живого объекта.
7. `InfrastructureProvider` создаётся только если CRD уже есть (`infrastructureProvider.create: auto`) и объект с тем же именем не принадлежит другому релизу. Нативные секреты и аннотации `shturval.tech/*` чарт не удаляет: они нужны менеджмент-кластеру 2.14 и миграции 2.15.
8. Поле `services.disablesservices` — явный список. Значение `all` в ClusterConfig не работает (его понимает только REST API backend и нельзя совместить с `enabledServices`). Некритичный сервис, которого нет ни в одном списке и у которого режим по умолчанию `auto`, будет установлен.

Платформенное обновление клиентского кластера 2.14 → 2.15 делайте отдельно, через shturval-update / `platformUpgrade: true`, а не как побочный эффект `helm upgrade`.
