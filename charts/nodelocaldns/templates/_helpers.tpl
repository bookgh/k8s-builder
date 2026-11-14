{{- define "nodelocaldns.name" -}}
node-local-dns
{{- end }}

{{- define "nodelocaldns.namespace" -}}
{{- .Values.namespace | default "kube-system" }}
{{- end }}

{{- define "nodelocaldns.labels" -}}
k8s-app: {{ include "nodelocaldns.name" . }}
kubernetes.io/cluster-service: "true"
app.kubernetes.io/name: nodelocaldns
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "nodelocaldns.serviceAccountName" -}}
{{- include "nodelocaldns.name" . }}
{{- end }}
