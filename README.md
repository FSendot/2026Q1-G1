# Fraud Detector — Infraestructura como Código

Sistema de detección de fraude en tiempo real desplegado en AWS mediante Terraform.
Transacciones financieras ingresan desde un sitio on-premise simulado, son procesadas por un motor de scoring corriendo en Fargate, y los resultados quedan disponibles en un dashboard web.

La arquitectura detallada está en `[ARCHITECTURE.md](ARCHITECTURE.md)`.

**Flujo de datos:**

1. Un productor on-prem envía una transacción JSON al SQS de ingesta a través del túnel VPN, este JSON contiene información de la transacción y el usuario.
2. Fargate consume el mensaje, consulta el perfil del usuario en DynamoDB y calcula el fraud score
3. El resultado se envía directo al SQS de resultados; si es fraude, también se encola en el SQS de alertas
4. La Lambda `results-writer` toma el mensaje de resultados de SQS y persiste el resultado en RDS vía RDS Proxy
5. La Lambda `fraud-summary` se ejecuta cada `fraud_alert_summary_interval_minutes`, resume los fraudes pendientes y publica un único email vía SNS
6. La Lambda `api` expone esos datos a través de API Gateway
7. El dashboard (S3 website) consume la API y muestra el estado en tiempo real

---

## Deploy con GitHub Actions

**GitHub Actions es el camino recomendado** para desplegar y destruir la infraestructura del lab. Solo **Validate** corre automáticamente en cada push/PR; **Deploy** y el resto se lanzan manualmente desde la pestaña Actions.

### 1. Configurar secrets

En **Settings → Secrets and variables → Actions**:


| Secret                       | Obligatorio | Para qué                                              |
| ---------------------------- | ----------- | ----------------------------------------------------- |
| `AWS_ACCESS_KEY_ID`          | Sí          | Credenciales temporales del lab AWS Academy           |
| `AWS_SECRET_ACCESS_KEY`      | Sí          | (mismo set; expiran ~cada 4 h)                        |
| `AWS_SESSION_TOKEN`          | Sí          |                                                       |
| `BOOTSTRAP_EMAIL`            | Recomendado | Primer admin del dashboard en RDS                     |
| `BOOTSTRAP_PASSWORD`         | Opcional    | Login directo en Cognito (requiere `BOOTSTRAP_EMAIL`) |
| `BOOTSTRAP_ALERT_EMAIL`      | Opcional    | Email suscrito al SNS de resúmenes de fraude          |
| `GOOGLE_OAUTH_CLIENT_ID`     | Opcional    | Login con Google (requiere también el secret)         |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Opcional    | Par con `GOOGLE_OAUTH_CLIENT_ID`                      |


Los workflows **no leen `terraform.tfvars`**. Los defaults del lab están en la composición raíz y en `[terraform.tfvars.example](terraform.tfvars.example)`.

Cuando el lab expira, actualizar los tres secrets AWS antes de relanzar cualquier workflow.

### 2. Desplegar

1. Integrar el código en `main` (push/PR solo dispara **Validate**; no crea recursos en AWS).
2. (Opcional) **Actions → Plan** → Run workflow → escribir `plan` → revisar el artefacto `plan_output.txt`.
3. **Actions → Deploy** → Run workflow → rama `main` → escribir `deploy`.
4. Esperar el run verde.
5. Abrir el **job summary** del run (*Deployment outputs*): ahí están `dashboard_url`, `api_endpoint`, `queue_url` y el resto de lo necesario para acceder al dashboard y a la API.

Un push o merge a `main` **no** despliega nada; hay que lanzar **Deploy** a mano.

**Deploy** ejecuta: build de imagen del processor → `terraform apply` → sync del dashboard a S3 → bootstrap automático si existe `BOOTSTRAP_EMAIL`.

Para cambios solo de infra sin rebuild de apps, existe **Terraform Apply** (confirmación `apply`). No usarlo en el primer deploy ni después de un **Deploy** exitoso (puede dejar ECS en `:placeholder`).

### 3. Bootstrap (si no configuraste secrets de admin)

Si **no** definiste `BOOTSTRAP_EMAIL` (y opcionalmente `BOOTSTRAP_PASSWORD`), el deploy termina bien pero nadie puede administrar el dashboard hasta crear el primer admin:

```bash
make init   # credenciales AWS del lab en el entorno
make bootstrap-auth BOOTSTRAP_EMAIL=tu-email@example.com
```

Con contraseña fija en Cognito:

```bash
make bootstrap-auth BOOTSTRAP_EMAIL=tu-email@example.com BOOTSTRAP_PASSWORD='UnaPasswordDemo123!'
```

Sin `BOOTSTRAP_PASSWORD`, el script solo crea el acceso admin en RDS; el usuario debe registrarse en Cognito Hosted UI con el mismo email.

### 4. Destruir al terminar el lab

**Actions → Destroy** → Run workflow → escribir `destroy`.

El bucket de state S3 `itba-tp-fraud-tfstate-<account-id>` no se elimina con Destroy.

---

## Probar el flujo completo


| Paso                             | Cómo                                                                                                |
| -------------------------------- | --------------------------------------------------------------------------------------------------- |
| 1. Enviar transacciones          | **Actions → Send test transactions** (requiere infra desplegada y `enable_onprem_sim = true`)       |
| 2. Ver el dashboard              | Abrir `dashboard_url` del job summary de **Deploy**                                                 |
| 3. Iniciar sesión                | Cognito Hosted UI; si no usaste `BOOTSTRAP_PASSWORD`, completar registro con el email del bootstrap |
| 4. (Opcional) Logs del processor | Local: `make logs` (AWS CLI con credenciales del lab)                                               |


**Send test transactions** — inputs habituales: `count` (default `50000`), `fraud_pct` (`20`), `concurrency` (`128`). El generador corre en el EC2 on-prem vía SSM; el tráfico llega a SQS por VPN.

Equivalente local (mismas credenciales AWS que el lab):

```bash
python3 -m pip install boto3
make init
make send-test-tx
```

Parámetros opcionales:

```bash
make send-test-tx TX_COUNT=10000 FRAUD_PCT=30 TX_CONCURRENCY=256
```

Patrones generados: transacciones **normales** (usuarios recurrentes, montos bajos/medios) y **fraude** (account drain, country shift, card testing, etc.).

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

Cola SQS de ingesta de transacciones con Dead Letter Queue. El acceso está restringido al rol IAM `LabRole` (único principal autorizado para `SendMessage`/`ReceiveMessage`) y se deniega cualquier tráfico no cifrado (`aws:SecureTransport = false`). La restricción de red queda garantizada arquitecturalmente por la combinación VPN Site-to-Site + Interface VPC Endpoint: el endpoint SQS solo es alcanzable desde dentro de la VPC, y la VPN es el único camino desde el on-prem hasta ella. Se intentó agregar un `Deny` explícito por CIDR/VPC mediante `aws:VpcSourceIp` y `aws:SourceVpc`, pero estas condition keys no se propagan para tráfico cross-VPC vía VPN hacia Interface Endpoints.

**Recursos:** `[aws_sqs_queue.main](modules/queue/main.tf#L31)` + `[aws_sqs_queue.dlq](modules/queue/main.tf#L10)`, `[aws_sqs_queue_redrive_allow_policy.dlq](modules/queue/main.tf#L22)`, `[aws_sqs_queue_policy.main](modules/queue/main.tf#L98)` y `[aws_sqs_queue_policy.dlq](modules/queue/main.tf#L143)`

---

### `modules/data_store`

Toda la capa de persistencia del sistema en un único módulo:

- **DynamoDB** `itba-tp-fraud-user-behavior`: `[aws_dynamodb_table.user_behavior](modules/data_store/main.tf#L13)` — perfiles de comportamiento de usuarios. Clave de partición `user_id`. Consultado por Fargate durante el scoring para enriquecer la decisión con historial del usuario.
- **RDS PostgreSQL 17.4** `itba-tp-fraud-results-db`: `[aws_db_instance.results](modules/data_store/main.tf#L118)` almacena los resultados de scoring (`transaction_id`, `fraud_score`, `is_fraud`, `decision`, `processed_at`, etc.). Acceso exclusivo desde dentro de la VPC a través del RDS Proxy.
- **Secrets Manager**: `[aws_secretsmanager_secret.db_credentials](modules/data_store/main.tf#L161)` y `[aws_secretsmanager_secret_version](modules/data_store/main.tf#L172)` — credenciales RDS en JSON para autenticación del proxy.
- **RDS Proxy**: `[aws_db_proxy.results](modules/data_store/main.tf#L194)`, `[aws_db_proxy_default_target_group](modules/data_store/main.tf#L216)`, `[aws_db_proxy_target](modules/data_store/main.tf#L230)` — pool entre Lambdas y RDS; mitiga el agotamiento de conexiones en `db.t3.micro` (~50 conexiones máx).
- **Security Group del proxy**: `[aws_security_group.proxy](modules/data_store/main.tf#L182)`; las reglas cruzadas con Lambdas/RDS están en la raíz — `[main.tf](main.tf#L169)` (`proxy_to_rds`, `rds_from_proxy`, `writer_lambda_to_proxy`, `api_lambda_to_proxy`, etc.) para evitar dependencias circulares entre módulos.

---

### `modules/compute`

Motor de scoring corriendo en ECS Fargate. Lee transacciones de SQS, consulta DynamoDB, aplica el modelo ML (con fallback a reglas si el modelo no está disponible), publica todos los resultados en la cola de persistencia, y publica sólo fraudes en la cola de resúmenes.

**Recursos:** `[aws_ecr_repository.app](modules/compute/main.tf#L48)`, `[aws_ecs_cluster.main](modules/compute/main.tf#L78)` (Container Insights en el cluster), `[aws_ecs_task_definition.app](modules/compute/main.tf#L142)`, `[aws_ecs_service.app](modules/compute/main.tf#L165)`, Application Auto Scaling (`[aws_appautoscaling_target](modules/compute/main.tf#L194)`, `[aws_appautoscaling_policy](modules/compute/main.tf#L204)`).

**Auto Scaling**: política de target tracking con métrica compuesta `messages_per_task = ApproximateNumberOfMessagesVisible / max(RunningTaskCount, 1)`. Si el backlog supera 10 mensajes por task, escala horizontalmente hasta 10 tasks.

**Variables de entorno del contenedor**: `QUEUE_URL`, `RESULTS_QUEUE_URL`, `FRAUD_ALERT_QUEUE_URL`, `DYNAMODB_TABLE_NAME`, `AWS_REGION`, `S3_AUDIT_BUCKET`.

---

### `modules/notification`

Composición de alertas resumidas. El processor no publica resultados crudos en SNS: encola sólo los fraudes en `itba-tp-fraud-fraud-alerts`, una Lambda programada cada `fraud_alert_summary_interval_minutes` minutos genera un resumen, y SNS lo distribuye a los emails confirmados.

**Recursos:** submódulos `[topic](modules/notification/topic/main.tf)`, `[summary_queue](modules/notification/summary_queue/main.tf)` y `[summarizer](modules/notification/summarizer/main.tf)`.

---

### `modules/results_writer`

Pipeline SQS → Lambda para persistir resultados en RDS. El processor envía cada resultado directamente a esta cola.

**Recursos:**

- SQS `itba-tp-fraud-results-events` + DLQ: `[aws_sqs_queue.results](modules/results_writer/main.tf#L35)` + `[aws_sqs_queue.results_dlq](modules/results_writer/main.tf#L14)` (`[aws_sqs_queue_redrive_allow_policy.results_dlq](modules/results_writer/main.tf#L26)`, `[aws_sqs_queue_policy.results](modules/results_writer/main.tf#L114)`) — buffer con `maxReceiveCount = 3` y visibility timeout de 180s (≥6× el timeout de la Lambda)
- Lambda Python 3.12 en VPC con psycopg2: `[aws_lambda_function.writer](modules/results_writer/main.tf#L163)`
- Event Source Mapping: `[aws_lambda_event_source_mapping.sqs_results](modules/results_writer/main.tf#L201)`

La Lambda crea la tabla `transactions` si no existe (schema migration automático en cold start) e inserta con `ON CONFLICT DO NOTHING` para idempotencia (importante dado que SQS puede entregar el mismo mensaje más de una vez).

---

### `modules/api`

API REST serverless protegida por Cognito que sirve los datos del dashboard.

**Endpoints:**


| Método | Path                      | Descripción                                                                                           |
| ------ | ------------------------- | ----------------------------------------------------------------------------------------------------- |
| GET    | `/health`                 | Health check con ping a RDS (requiere JWT Cognito)                                                    |
| GET    | `/dashboard/me`           | Perfil del dashboard user autenticado; activa invitaciones pendientes si el email verificado coincide |
| GET    | `/dashboard/invites`      | Lista de invitaciones/accesos del dashboard (solo bootstrap admin)                                    |
| POST   | `/dashboard/invites`      | Crea o reactiva una invitación por email (solo bootstrap admin)                                       |
| DELETE | `/dashboard/invites/{id}` | Soft-disable de un acceso de dashboard (solo bootstrap admin; no aplica al bootstrap admin)           |
| PUT    | `/dashboard/me/password`  | Cambio de contraseña para usuarios Cognito locales                                                    |
| GET    | `/stats`                  | Totales: transacciones, bloqueadas, permitidas, challenge                                             |
| GET    | `/transactions?limit=N`   | Últimas N transacciones (máx 100)                                                                     |


**Recursos:** `[aws_lambda_function.api](modules/api/main.tf#L51)` (Python 3.12 en VPC + psycopg2), `[aws_apigatewayv2_api.main](modules/api/main.tf#L88)` (HTTP API), `[aws_apigatewayv2_stage.default](modules/api/main.tf#L117)` (`$default`, `auto_deploy = true`), integración y rutas: `[aws_apigatewayv2_integration.lambda](modules/api/main.tf#L128)`, `[aws_apigatewayv2_route](modules/api/main.tf#L135)` (`/transactions`, `/stats`, `/health` y [catch-all `$default](modules/api/main.tf#L154)`).

---

### `modules/onprem_sim`

Simula un sitio corporativo on-premise conectado a AWS mediante una VPN Site-to-Site.

**Recursos:**

- VPC pública `192.168.0.0/16`: `[aws_vpc.onprem](modules/onprem_sim/main.tf#L18)`, subnets/IGW/rutas en el mismo archivo; EC2 strongSwan vía `[aws_cloudformation_stack.strongswan](modules/onprem_sim/main.tf#L225)` y plantilla `[templates/vpn-gateway-strongswan.yml](templates/vpn-gateway-strongswan.yml)`
- VPN: `[aws_customer_gateway.cgw](modules/onprem_sim/main.tf#L158)`, `[aws_vpn_connection.vpn](modules/onprem_sim/main.tf#L168)` (2 túneles BGP contra el VGW)
- PSKs: `[aws_secretsmanager_secret` / `secret_version` túnel 1 y 2](modules/onprem_sim/main.tf#L184)
- Route 53 Private Hosted Zone: `[aws_route53_zone.sqs_private](modules/onprem_sim/main.tf#L296)`, `[aws_route53_record.sqs_apex](modules/onprem_sim/main.tf#L314)` — resuelve `sqs.<region>.amazonaws.com` a las IPs privadas del VPC Endpoint

Controlado por `[var.enable_onprem_sim](variables.tf#L62)` (default: `true`). Ponerlo en `false` destruye la simulación on-prem y elimina el CIDR lock de la cola de ingesta.

---

### `modules/dashboard`

Sitio web estático en S3 con el panel de operaciones. Muestra las últimas transacciones y estadísticas en tiempo real consumiendo la API Gateway.

**Recursos:** `[aws_s3_bucket.dashboard](modules/dashboard/main.tf#L9)`, `[aws_s3_bucket_website_configuration.dashboard](modules/dashboard/main.tf#L23)`, `[aws_s3_bucket_policy.dashboard](modules/dashboard/main.tf#L41)`, objetos estáticos: `[aws_s3_object.index_html](modules/dashboard/main.tf#L58)`, `[aws_s3_object.app_js](modules/dashboard/main.tf#L72)`, `[aws_s3_object.config_js](modules/dashboard/main.tf#L86)` (`templatefile()` con la URL de API Gateway).

Terraform crea el bucket y objetos iniciales; el contenido actualizado del frontend se publica con `aws s3 sync` al final del workflow **Deploy** (manual).

### `modules/auth`

Capa de autenticación del dashboard. Crea un Cognito User Pool con email como identidad de acceso, self-signup habilitado, Hosted UI, dominio administrado `itba-fraud-auth-<account-id>` y un app client público para flujo Authorization Code + PKCE. Google OAuth es opcional y sólo se habilita si se pasan `GOOGLE_OAUTH_CLIENT_ID` y `GOOGLE_OAUTH_CLIENT_SECRET` al plan/apply.

La autorización final no vive sólo en Cognito: la Lambda API mantiene una tabla `dashboard_access` en RDS. Un usuario puede autenticarse correctamente en Cognito y aun así quedar bloqueado si su email verificado no fue pre-invitado por el bootstrap admin.

---

## Funciones y meta-argumentos de Terraform

### Funciones utilizadas


| Función                | Dónde                                                           | Para qué                                                        |
| ---------------------- | --------------------------------------------------------------- | --------------------------------------------------------------- |
| `format()`             | Todos los módulos                                               | Construir nombres de recursos con prefijo del proyecto          |
| `merge()`              | Todos los módulos                                               | Combinar `common_tags` con tags específicos del recurso         |
| `cidrsubnet()`         | `modules/network`                                               | Calcular CIDRs de subnets privadas a partir del CIDR de la VPC  |
| `toset()`              | `modules/network`                                               | Convertir la lista de servicios Gateway a set para `for_each`   |
| `slice()`              | `main.tf`                                                       | Tomar las primeras 2 AZs disponibles en la región               |
| `jsonencode()`         | `modules/queue`, `modules/results_writer`, `modules/data_store` | Serializar políticas IAM y configuraciones como JSON            |
| `contains()`           | Variables con `validation`                                      | Validar que valores numéricos estén dentro de rangos permitidos |
| `can()` + `cidrhost()` | Variables con `validation`                                      | Validar que CIDRs sean IPv4 válidos                             |
| `replace()`            | `modules/network`                                               | Normalizar nombres de endpoints (reemplazar `_` por `-`)        |
| `templatefile()`       | `modules/dashboard`                                             | Inyectar la URL de API Gateway en `config.js` en deploy time    |
| `filebase64sha256()`   | `main.tf`                                                       | Hash del zip de la capa psycopg2 para detectar cambios          |
| `filemd5()`            | `modules/dashboard`                                             | Hash de archivos estáticos del dashboard                        |
| `length()`             | Validaciones y lógica de red                                    | Contar elementos en listas                                      |


### Meta-argumentos utilizados


| Meta-argumento                        | Dónde                                       | Para qué                                                                                                                                                             |
| ------------------------------------- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `for_each`                            | `modules/network` — VPC Endpoints           | Crear un endpoint por servicio (sqs, ecr_api, ecr_dkr, logs, sns, secretsmanager, cognito_idp, s3, dynamodb) desde un mapa/set, evitando duplicar bloques de recurso |
| `count`                               | `main.tf` — `module.onprem_sim`             | Crear o no la simulación on-prem según `var.enable_onprem_sim`. Permite habilitar/deshabilitar toda la infraestructura VPN con un flag                               |
| `lifecycle { ignore_changes }`        | `modules/compute` — ECS Service             | Ignora cambios en `desired_count` para que Application Auto Scaling sea el dueño del número de tasks, sin que Terraform lo revierta en cada apply                    |
| `lifecycle { ignore_changes }`        | `modules/data_store` — RDS Instance         | Ignora cambios en `password` para que Terraform no intente actualizar la contraseña (RDS no expone la contraseña actual al provider)                                 |
| `lifecycle { ignore_changes }`        | `modules/dashboard` — S3 Objects            | Los archivos HTML/JS son actualizados por CI con `aws s3 sync`; Terraform los crea una vez y luego ignora cambios para no entrar en conflicto con el pipeline        |
| `lifecycle { create_before_destroy }` | `main.tf` — Lambda Layer                    | Garantiza que la nueva versión de la capa psycopg2 esté disponible antes de destruir la anterior, evitando downtime en las Lambdas                                   |
| `depends_on`                          | `modules/compute` — ECS Service             | Fuerza que las reglas de egress del SG existan antes de crear el servicio ECS                                                                                        |
| `depends_on`                          | `modules/onprem_sim` — CloudFormation stack | Espera a que los Secrets Manager secret versions con los PSKs estén creados antes de levantar el router strongSwan                                                   |
| `validation`                          | Todas las variables                         | Valida tipos, rangos y formatos (CIDRs, ARNs, valores permitidos de CPU/memoria) en tiempo de `terraform plan`, antes de hacer ningún cambio en AWS                  |


---

## Dashboard y autenticación

Tras un **Deploy** exitoso, usar `dashboard_url` del **job summary** (no el endpoint HTTP de S3 website: PKCE requiere HTTPS).

- **Transaction User**: `user_id` de las transacciones financieras.
- **Dashboard User**: persona autenticada en Cognito.

Cognito autentica; RDS autoriza vía `dashboard_access`. El bootstrap admin invita emails desde la pestaña **Invitaciones**; el invitado se registra en Cognito con el mismo email.

Para Google OAuth, registrar en Google Cloud el redirect URI:

```text
https://itba-fraud-auth-<account-id>.auth.us-east-1.amazoncognito.com/oauth2/idpresponse
```

---

## Mapa del repositorio

```
.
├── main.tf                  # Composición raíz — wiring de todos los módulos
├── variables.tf             # Variables de entrada de la composición
├── outputs.tf               # Outputs expuestos
├── versions.tf              # Versiones de Terraform y providers
├── backend.tf               # Backend S3 (partial config, bucket se pasa en init)
├── terraform.tfvars.example # Plantilla de configuración
├── Makefile                 # Targets: init, plan, apply, destroy, build-layers, seed, send-test-tx, logs
├── .github/workflows/       # Validate, Plan, Deploy, Terraform Apply, Destroy, Send test transactions
├── modules/
│   ├── network/             # VPC, subnets, VPN Gateway, VPC Endpoints
│   ├── queue/               # SQS ingesta + DLQ + CIDR lock on-prem
│   ├── data_store/          # DynamoDB + RDS + RDS Proxy + Secrets Manager
│   ├── compute/             # ECR + ECS Fargate + Auto Scaling
│   ├── onprem_sim/          # VPC on-prem + strongSwan EC2 + VPN site-to-site
│   ├── notification/        # SNS resumen + SQS alertas + Lambda summarizer
│   ├── results_writer/      # SQS resultados + Lambda writer (processor→SQS→Lambda→RDS)
│   ├── api/                 # Lambda API + HTTP API Gateway
│   └── dashboard/           # S3 bucket + website config + config.js templating
├── app/
│   ├── processor/           # Motor de scoring en Go (SQS consumer → SQS publishers)
│   ├── notification/        # Código Python de la Lambda summarizer de alertas
│   ├── api/                 # Dashboard API Lambda handler (Python)
│   └── dashboard/           # Frontend vanilla JS (index.html, app.js)
├── layers/
│   └── psycopg2/            # Layer psycopg2 (generado por make build-layers)
├── templates/
│   └── vpn-gateway-strongswan.yml  # CloudFormation template del router on-prem
├── ARCHITECTURE.md          # Arquitectura detallada y trade-offs
├── CONTRIBUTING.md          # Branching, commits, PR checklist
└── docs/
    ├── STYLE_GUIDE.md       # Convenciones HCL
    ├── NAMING.md            # Nomenclatura de recursos
    ├── WORKFLOW.md          # Flujo init/plan/apply
    ├── SECURITY.md          # Qué nunca commitear
    └── CONSIGNA.md          # Requisitos del trabajo práctico
```
