# Fraud Detector — Infraestructura como Código

Sistema de detección de fraude en tiempo real desplegado en AWS mediante Terraform.
Transacciones financieras ingresan desde un sitio on-premise simulado, son procesadas por un motor de scoring corriendo en Fargate, y los resultados quedan disponibles en un dashboard web.

La arquitectura detallada está en `[ARCHITECTURE.md](ARCHITECTURE.md)`.

**Flujo de datos:**

1. Dos instancias EC2 on-prem (`producer-1`, `producer-2`) envían transacciones JSON al SQS de ingesta de forma continua (~50 tx/min en total) a través del túnel VPN; para picos adicionales, usar el workflow **Send test transactions**.
2. Fargate consume el mensaje, consulta el perfil del usuario en DynamoDB y calcula el fraud score.
3. El resultado se envía al SQS de resultados; si es fraude, también se encola en el SQS de alertas.
4. La Lambda `results-writer` persiste el resultado en RDS vía RDS Proxy.
5. La Lambda `fraud-summary` se ejecuta cada un intervalo de tiempo configurable, resume los fraudes pendientes y publica un email vía SNS.
6. La Lambda `api` expone esos datos a través de API Gateway.
7. El dashboard (S3) consume la API y muestra el estado en tiempo real.

Toda la operación del lab (deploy, pruebas, destrucción) se hace desde **GitHub Actions**.

---

## GitHub Actions

Los workflows se lanzan manualmente en la pestaña **Actions** del repositorio. Algunos de ellos requieren una confirmación para ejecutar el workflow.


| Workflow                   | Confirmación / inputs                                                                                                                                                         | Qué hace                                                                                                                                                                   |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Validate**               | —                                                                                                                                                                             | `terraform fmt -check`, `terraform validate`, build de artefactos Lambda necesarios para validar. No toca AWS.                                                             |
| **Plan**                   | Escribir `plan`                                                                                                                                                               | `terraform plan` contra el state remoto; sube el artefacto `plan_output.txt`.                                                                                              |
| **Deploy**                 | Escribir `deploy`                                                                                                                                                             | Deploy completo: processor en ECR, `terraform apply`, dashboard en S3, bootstrap de admin si hay `BOOTSTRAP_EMAIL`.                                                        |
| **Destroy**                | Escribir `destroy`                                                                                                                                                            | `terraform destroy` de toda la infra gestionada.                                                                                                                           |
| **Send test transactions** | `count` (Número de transacciones), `fraud_pct` (Porcentaje de transacciones con patrón de fraude), `concurrency` (Workers paralelos en el EC2 on-prem que envían lotes a SQS) | Ejecuta en el EC2 on-prem (vía SSM) un generador que encola un pico en el SQS de ingesta (cola e instancia se resuelven solas desde Terraform y el stack on-prem del lab). |


### 1. Configurar secrets

Dentro de Github, en el repositorio, en **Settings → Secrets and variables → Actions**, crear los siguientes secrets:


| Secret                  | Obligatorio | Para qué                                                            |
| ----------------------- | ----------- | ------------------------------------------------------------------- |
| `AWS_ACCESS_KEY_ID`     | Sí          | Access Key del lab AWS Academy.                                     |
| `AWS_SECRET_ACCESS_KEY` | Sí          | Secret Access Key del lab AWS Academy.                              |
| `AWS_SESSION_TOKEN`     | Sí          | Session Token del lab AWS Academy.                                  |
| `BOOTSTRAP_EMAIL`       | Sí          | Email del primer administrador del dashboard.                       |
| `BOOTSTRAP_PASSWORD`    | Sí          | Contraseña en Cognito para `BOOTSTRAP_EMAIL`. Ver requisitos abajo. |
|                         |             |                                                                     |
|                         |             |                                                                     |


**Requisitos de `BOOTSTRAP_PASSWORD`**:


| Regla           | Valor                  |
| --------------- | ---------------------- |
| Longitud mínima | 12 caracteres          |
| Mayúsculas      | Al menos una (`A`–`Z`) |
| Minúsculas      | Al menos una (`a`–`z`) |
| Números         | Al menos uno (`0`–`9`) |
| Símbolos        | No obligatorios        |


**Valor recomendado** (cumple todas las reglas): `ItbaFraudLab2026!`

### 2. Desplegar

1. (Opcional) **Actions → Plan** → Run workflow → escribir `plan` → esto genera el plan de ejecución de Terraform. Es opcional porque **Deploy** lo ejecuta automáticamente.
2. **Actions → Deploy** → Run workflow → rama `main` → escribir `deploy`.
3. Esperar el run en verde.
4. Abrir el dashboard desde el **job summary** del run (*Deployment outputs* → `dashboard_url`).

**Deploy** ejecuta, en orden: preparación del modelo, build y push de la imagen del processor a ECR, `terraform apply`, publicación del dashboard en S3 y, si `BOOTSTRAP_EMAIL` está configurado, bootstrap automático del administrador (con `BOOTSTRAP_PASSWORD` si fue definido).

### 3. Primer acceso al dashboard

Tras un **Deploy** exitoso, usar la URL HTTPS del job summary (`dashboard_url`). No usar el endpoint HTTP del website estático de S3: el flujo Cognito PKCE requiere HTTPS.


| Paso                     | Acción                                                                                            |
| ------------------------ | ------------------------------------------------------------------------------------------------- |
| Iniciar sesión           | Cognito Hosted UI con el email de `BOOTSTRAP_EMAIL`.                                              |
| Con `BOOTSTRAP_PASSWORD` | Login directo con la contraseña del secret.                                                       |
| Sin `BOOTSTRAP_PASSWORD` | Completar el registro en Cognito con el mismo email; el bootstrap ya creó el acceso admin en RDS. |
| Sin `BOOTSTRAP_EMAIL`    | Agregar el secret y volver a ejecutar **Deploy**.                                                 |


- **Transaction User**: `user_id` de las transacciones financieras.
- **Dashboard User**: persona autenticada en Cognito.

Cognito autentica; RDS autoriza vía `dashboard_access`. El admin bootstrap invita emails desde la pestaña **Invitaciones**; el invitado debe registrarse en Cognito con el mismo email.

Para Google OAuth, registrar en Google Cloud el redirect URI:

```text
https://itba-fraud-auth-<account-id>.auth.us-east-1.amazoncognito.com/oauth2/idpresponse
```

### 4. Probar el flujo


| Paso                           | Workflow                                                                                                   |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| Enviar transacciones de prueba | **Send test transactions** (infra desplegada; simulación on-prem habilitada por defecto en la composición) |
| Ver el dashboard               | `dashboard_url` en el job summary de **Deploy**                                                            |
| Tráfico continuo on-prem       | Automático: 2 productores EC2 (~50 tx/min total, ~8 % patrón de fraude)                                    |
| Resúmenes por email            | Cada `fraud_alert_summary_interval_minutes` (default 7); hasta 500 alertas por envío                       |


**Send test transactions** — inputs del workflow:


| Input         | Default | Para qué se usa                                                                                                                 |
| ------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `count`       | `50000` | Total de transacciones sintéticas que el generador intenta encolar en SQS durante el pico.                                      |
| `fraud_pct`   | `8`     | Porcentaje de esas transacciones generadas con patrón de fraude (el resto son normales).                                        |
| `concurrency` | `128`   | Cantidad de workers paralelos en el EC2 que envían lotes a SQS; más valor = pico más rápido (más carga en el EC2 y en la cola). |


Región (`us-east-1`), cola de ingesta (`terraform output queue_url`) e instancia on-prem (`VpnGatewayInstanceId` del stack `itba-tp-fraud-onprem-strongswan`) están fijados por el lab y no se exponen como inputs del workflow.

Patrones generados: transacciones **normales** (usuarios recurrentes, montos bajos/medios) y **fraude** (account drain, country shift, card testing, etc.).

### 5. Destruir al terminar el lab

**Actions → Destroy** → Run workflow → escribir `destroy`.

El bucket de state S3 `itba-tp-fraud-tfstate-<account-id>` **no** se elimina con **Destroy**.

---

## Módulos

### `modules/network`

Provisiona la VPC privada que aloja toda la infraestructura. No tiene NAT Gateway ni Internet Gateway. Todo el egress a servicios AWS fluye por VPC Endpoints, reduciendo costos y superficie de ataque.

**Recursos clave:**

- `[module "vpc"](modules/network/main.tf#L22)` (`terraform-aws-modules/vpc/aws`): VPC `10.0.0.0/16` con 2 subnets privadas en distintas AZs; Virtual Private Gateway (VGW) para la VPN site-to-site vía `[enable_vpn_gateway](modules/network/main.tf#L38)`
- **Gateway VPC Endpoints** (S3, DynamoDB): `[aws_vpc_endpoint.gateway](modules/network/main.tf#L83)`
- **Interface VPC Endpoints** (SQS, ECR API, ECR DKR, CloudWatch Logs, SNS, Secrets Manager, Cognito IDP): `[aws_vpc_endpoint.interface](modules/network/main.tf#L97)`
- Cuando la simulación on-prem está habilitada, el Security Group de endpoints también permite HTTPS desde `192.168.0.0/16` para que el EC2 on-prem resuelva `sqs.<region>.amazonaws.com` hacia el VPCE y envíe tráfico por la VPN.

**Módulo externo**: el pin `~> 5.13` está en `[modules/network/main.tf](modules/network/main.tf#L22)`; los VPC Endpoints propios son los recursos enlazados arriba.

---

### `modules/queue`

Cola SQS de ingesta de transacciones con Dead Letter Queue. El acceso está restringido al rol IAM `LabRole` y se deniega cualquier tráfico no cifrado (`aws:SecureTransport = false`). La restricción de red queda garantizada arquitecturalmente por VPN Site-to-Site + Interface VPC Endpoint.

**Recursos:** `[aws_sqs_queue.main](modules/queue/main.tf#L31)` + `[aws_sqs_queue.dlq](modules/queue/main.tf#L10)`, `[aws_sqs_queue_redrive_allow_policy.dlq](modules/queue/main.tf#L22)`, `[aws_sqs_queue_policy.main](modules/queue/main.tf#L98)` y `[aws_sqs_queue_policy.dlq](modules/queue/main.tf#L143)`

---

### `modules/data_store`

Toda la capa de persistencia del sistema en un único módulo:

- **DynamoDB** `itba-tp-fraud-user-behavior`: `[aws_dynamodb_table.user_behavior](modules/data_store/main.tf#L13)` — perfiles de comportamiento de usuarios. Clave de partición `user_id`. Consultado por Fargate durante el scoring.
- **RDS PostgreSQL 17.4** `itba-tp-fraud-results-db`: `[aws_db_instance.results](modules/data_store/main.tf#L118)` — resultados de scoring. Acceso exclusivo desde la VPC vía RDS Proxy.
- **Secrets Manager**: credenciales RDS para el proxy.
- **RDS Proxy**: pool entre Lambdas y RDS en `db.t3.micro`.
- Las reglas cruzadas de security group con Lambdas/RDS están en la raíz — `[main.tf](main.tf#L208)` — para evitar dependencias circulares entre módulos.

---

### `modules/compute`

Motor de scoring en ECS Fargate. Lee transacciones de SQS, consulta DynamoDB, aplica el modelo ML (con fallback a reglas), publica resultados y encola fraudes para resumen.

**Recursos:** ECR, ECS cluster/service, Application Auto Scaling (`[modules/compute/main.tf](modules/compute/main.tf)`).

**Auto Scaling**: target tracking con `messages_per_task = ApproximateNumberOfMessagesVisible / max(RunningTaskCount, 1)`; escala hasta 10 tasks si el backlog supera 10 mensajes por task.

---

### `modules/notification`

Alertas resumidas: fraudes en `itba-tp-fraud-fraud-alerts`, Lambda programada cada `fraud_alert_summary_interval_minutes`, SNS a emails confirmados.

**Recursos:** submódulos `[topic](modules/notification/topic/main.tf)`, `[summary_queue](modules/notification/summary_queue/main.tf)` y `[summarizer](modules/notification/summarizer/main.tf)`.

---

### `modules/results_writer`

Pipeline SQS → Lambda → RDS. El processor envía cada resultado a esta cola.

**Recursos:** cola `itba-tp-fraud-results-events` + DLQ, Lambda writer, event source mapping (`[modules/results_writer/main.tf](modules/results_writer/main.tf)`).

---

### `modules/api`

API REST protegida por Cognito para el dashboard.


| Método          | Path                     | Descripción                                     |
| --------------- | ------------------------ | ----------------------------------------------- |
| GET             | `/health`                | Health check con ping a RDS (JWT Cognito)       |
| GET             | `/dashboard/me`          | Perfil del usuario autenticado                  |
| GET/POST/DELETE | `/dashboard/invites`     | Gestión de invitaciones (solo bootstrap admin)  |
| PUT             | `/dashboard/me/password` | Cambio de contraseña (usuarios Cognito locales) |
| GET             | `/stats`                 | Totales de transacciones                        |
| GET             | `/transactions?limit=N`  | Últimas N transacciones (máx. 100)              |


---

### `modules/onprem_sim`

Simulación on-prem con VPN Site-to-Site, strongSwan, productores EC2 y DNS privado para el VPCE de SQS. Gated por `var.enable_onprem_sim` (default `true`).

---

### `modules/dashboard`

Sitio estático en S3. Terraform crea bucket y objetos iniciales; **Deploy** publica el build actualizado con `aws s3 sync`.

---

### `modules/auth`

Cognito User Pool (email), Hosted UI, dominio `itba-fraud-auth-<account-id>`, app client PKCE. Google OAuth opcional vía secrets `GOOGLE_OAUTH_`*. Autorización fina en RDS (`dashboard_access`).

---

## Funciones y meta-argumentos de Terraform

### Funciones utilizadas


| Función                | Dónde                      | Para qué                                     |
| ---------------------- | -------------------------- | -------------------------------------------- |
| `format()`             | Todos los módulos          | Nombres de recursos con prefijo del proyecto |
| `merge()`              | Todos los módulos          | Combinar `common_tags` con tags del recurso  |
| `cidrsubnet()`         | `modules/network`          | CIDRs de subnets privadas                    |
| `toset()`              | `modules/network`          | Set para `for_each` en gateway endpoints     |
| `slice()`              | `main.tf`                  | Primeras 2 AZs de la región                  |
| `jsonencode()`         | Colas, data store          | Políticas IAM en JSON                        |
| `contains()`           | Variables con `validation` | Rangos permitidos                            |
| `can()` + `cidrhost()` | Variables con `validation` | CIDRs IPv4 válidos                           |
| `replace()`            | `modules/network`          | Normalizar nombres de endpoints              |
| `templatefile()`       | `modules/dashboard`        | Inyectar URL de API en `config.js`           |
| `filebase64sha256()`   | `main.tf`                  | Hash de la capa psycopg2                     |
| `filemd5()`            | `modules/dashboard`        | Hash de archivos estáticos                   |
| `length()`             | Validaciones y red         | Contar elementos en listas                   |


### Meta-argumentos utilizados


| Meta-argumento                        | Dónde                                      | Para qué                                                        |
| ------------------------------------- | ------------------------------------------ | --------------------------------------------------------------- |
| `for_each`                            | `modules/network` — VPC Endpoints          | Un endpoint por servicio desde un mapa/set                      |
| `count`                               | `main.tf` — `module.onprem_sim`            | Activar o no la simulación on-prem                              |
| `lifecycle { ignore_changes }`        | ECS service, RDS, objetos S3 del dashboard | Delegar capacidad a autoscaling / CI / evitar drift de password |
| `lifecycle { create_before_destroy }` | Lambda Layer psycopg2                      | Nueva versión antes de destruir la anterior                     |
| `depends_on`                          | ECS service, stack strongSwan              | Ordenar dependencias explícitas                                 |
| `validation`                          | Variables                                  | Validar en `terraform plan`                                     |


---

## Mapa del repositorio

```
.
├── main.tf                  # Composición raíz
├── variables.tf
├── outputs.tf
├── versions.tf
├── backend.tf
├── .github/workflows/       # Validate, Plan, Deploy, Destroy, Send test transactions
├── modules/                 # network, queue, data_store, compute, onprem_sim, notification, results_writer, api, dashboard, auth
├── app/                     # processor, api, results_writer, notification, dashboard
├── layers/psycopg2/         # Capa Lambda (generada en CI)
├── templates/               # CloudFormation strongSwan on-prem
├── ARCHITECTURE.md
├── CONTRIBUTING.md
└── docs/                    # STYLE_GUIDE, NAMING, WORKFLOW, SECURITY, CONSIGNA
```

Documentación operativa adicional para contribuidores: `[CONTRIBUTING.md](CONTRIBUTING.md)`, `[docs/WORKFLOW.md](docs/WORKFLOW.md)`.