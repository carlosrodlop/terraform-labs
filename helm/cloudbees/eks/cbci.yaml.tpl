OperationsCenter:
  HostName: @@HOSTNAME@@
  Platform: eks
  Protocol: https
  Ingress:
    Class: alb
    Annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
  CasC:
    Enabled: true
  ConfigMapName: oc-casc-bundle
  ContainerEnv:
    - name: SECRETS
      value: /var/run/secrets/cjoc
  ExtraVolumes:
    - name: oc-secrets
      secret:
        secretName: oc-secrets
  ExtraVolumeMounts:
    - name: oc-secrets
      mountPath: /var/run/secrets/cjoc
      readOnly: true
Agents:
  SeparateNamespace:
    Enabled: true
    # Agents.SeparateNamespace.Name -- Namespace where to create agents resources. Defaults to `${namespace}-builds` where `${namespace}` is the namespace where the chart is installed.
    Name: @@AGENT_NAMESPACE@@
    # Agents.SeparateNamespace.Create -- If true, the second namespace will be created when installing this chart. Otherwise, the existing namespace should be labeled with `cloudbees.com/role: agents` in order for network policies to work.
    Create: true